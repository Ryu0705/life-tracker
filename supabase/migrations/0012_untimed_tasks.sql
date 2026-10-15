-- Life Tracker v2 — 時刻のないやること・目標の回数 (すべての予定が目標の回数を持つ・繰り越しは時刻なしだけ)
-- 2026-10-14 / 設計: docs/untimed-tasks-design.md (本人決定)・docs/untimed-tasks-implementation-plan.md「1. DB」(細部はこちらが正)
-- 適用方法: Supabase MCP apply_migration (name: v2_untimed_tasks) / supabase-cli は使わない
-- 本番適用は本人 OK 待ち (2026-10-14 時点で未適用)。順序: 新ビルドを作る → 0012 を適用 → すぐ新ビルドを入れる → それから時刻なしを作る。
--   適用から新ビルドを入れるまでの間、旧ビルドの予定の保存は「関数が無い」で失敗する (引数が変わった関数は DROP 済み。読み取り・丸・スキップは動く)。
--   時刻なしを 1 件でも作った後・目標 2 以上の時刻つきの予定を 1 件でも作った後は旧ビルドに戻せない
--
-- 冪等: 何度流しても同じ状態になる (IF NOT EXISTS・backfill はタップの無い行だけ・作り直す制約と索引は DROP IF EXISTS → ADD を無条件に・
--   引数が変わる関数は旧シグネチャを DROP FUNCTION IF EXISTS → CREATE OR REPLACE)。
--   0007 の「無ければ足す」書き方だと既存の同名制約 (時刻必須の time_chk) が残り、時刻なしの done が入らない (レビュー中 6)
-- 順序: 列 → backfill → 制約・索引 → 関数 → GRANT
--
-- 記法: V = 見ている日。回の日 = occurrence_date (scheduled_task にも足す。日の判定は start_at の JST 日でなくこの列)
-- 回の記録 = actual_task の 1 行 (done / skipped。status は増やさない＝旧ビルドも読める) ＋タップ actual_task_tap (押した時刻)。
--   回数 = タップの数。完了 = 回数 ≥ その回の目標。閉じた日 (目標の回数目のタップの JST 日とスキップした日の早い方) は保存せず毎回求める
-- 時刻つきで目標 1 の回は今の checkin_set / checkin_clear のまま。record_tap_* / record_skip_* は時刻なしの回と時刻つきの目標 2 以上の回だけ
-- 規則の原本は Swift 側 (InMemoryScheduleDataSource・TodoBuilder)。この関数群はその写し

-- ============================================================
-- 列
-- ============================================================

-- task_template の旧列 (0013 で削除)。時刻なしの系列は NULL で写す
ALTER TABLE task_template
  ALTER COLUMN start_minutes_from_midnight DROP NOT NULL,
  ALTER COLUMN duration_minutes DROP NOT NULL;

ALTER TABLE task_template_version
  ALTER COLUMN start_minutes_from_midnight DROP NOT NULL,
  ALTER COLUMN duration_minutes DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS target_count INT NOT NULL DEFAULT 1,      -- 目標の回数 (時刻の有無に依らない。既存の行は 1)
  ADD COLUMN IF NOT EXISTS carry_over BOOLEAN NOT NULL DEFAULT false; -- 終わらなければ翌日にも出す (時刻なしだけ)

ALTER TABLE scheduled_task
  ADD COLUMN IF NOT EXISTS occurrence_date DATE,                     -- 一覧に出る日 (JST)。時刻つきは開始の JST 日
  ADD COLUMN IF NOT EXISTS target_count INT NOT NULL DEFAULT 1,
  ALTER COLUMN start_at DROP NOT NULL,
  ALTER COLUMN end_at DROP NOT NULL;                                  -- 0001 の end_at > start_at は NULL で通る

ALTER TABLE actual_task
  ADD COLUMN IF NOT EXISTS skipped_on DATE;                          -- スキップした日 (V)。時刻つきの目標 1 のスキップ (checkin_set) は NULL = 回の日

-- タップ 1 回 = 1 行 (本人決定 4: タップごとに時刻も残す)。回の記録を消すとタップも消える
CREATE TABLE IF NOT EXISTS actual_task_tap (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actual_task_id UUID NOT NULL REFERENCES actual_task (id) ON DELETE CASCADE,
  tapped_at      TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS actual_task_tap_actual_idx ON actual_task_tap (actual_task_id, tapped_at);
-- 表の権限は 0009 (sleep_record) と同じく Supabase の既定の権限に任せる (GRANT は書かない。RLS 無効)

-- ============================================================
-- backfill (再実行しても二重にならない)
-- ============================================================
UPDATE scheduled_task SET occurrence_date = (start_at AT TIME ZONE 'Asia/Tokyo')::date WHERE occurrence_date IS NULL;
ALTER TABLE scheduled_task ALTER COLUMN occurrence_date SET NOT NULL;

-- 作った日時 (やることの節の並び「同じ中は作った順」に使う)。既存の行は作った日時が残っていないので開始の時刻で近似する
-- (時刻の無い行は既存に無い。念のため now())。列は既定値なしで足してから埋める (既定値つきで足すと既存の行が適用の時刻になる)
ALTER TABLE scheduled_task ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ;
UPDATE scheduled_task SET created_at = COALESCE(start_at, now()) WHERE created_at IS NULL;
ALTER TABLE scheduled_task
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

-- 回につながる既存の done に、タップを 1 行 (押した時刻 = 実績の終了)。これで「回数 ≥ 目標 (1)」= 今の「やった」と同じ。
-- タップの無い行だけ (2 回目に流しても増えない)
INSERT INTO actual_task_tap (actual_task_id, tapped_at)
SELECT a.id, a.end_at
  FROM actual_task a
 WHERE a.status = 'done'
   AND (a.template_id IS NOT NULL OR a.scheduled_task_id IS NOT NULL)
   AND a.end_at IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM actual_task_tap t WHERE t.actual_task_id = a.id);

-- ============================================================
-- 制約・索引 (作り直すものは DROP IF EXISTS → ADD を無条件に)
-- ============================================================
ALTER TABLE task_template_version
  DROP CONSTRAINT IF EXISTS task_template_version_target_chk,
  DROP CONSTRAINT IF EXISTS task_template_version_timing_chk,
  DROP CONSTRAINT IF EXISTS task_template_version_carry_chk;
ALTER TABLE task_template_version
  ADD CONSTRAINT task_template_version_target_chk CHECK (target_count BETWEEN 1 AND 99),
  -- 開始と長さは両方あるか両方 NULL (時刻なし)
  ADD CONSTRAINT task_template_version_timing_chk
    CHECK ((start_minutes_from_midnight IS NULL) = (duration_minutes IS NULL)),
  -- 繰り越しは時刻なしだけ (本人決定 2)
  ADD CONSTRAINT task_template_version_carry_chk CHECK (NOT carry_over OR start_minutes_from_midnight IS NULL);

ALTER TABLE scheduled_task
  DROP CONSTRAINT IF EXISTS scheduled_task_target_chk,
  DROP CONSTRAINT IF EXISTS scheduled_task_timing_chk;
ALTER TABLE scheduled_task
  ADD CONSTRAINT scheduled_task_target_chk CHECK (target_count BETWEEN 1 AND 99),
  -- 時刻あり (回の日 = 開始の JST 日) か、時刻なし (開始・終了とも NULL)
  ADD CONSTRAINT scheduled_task_timing_chk CHECK (
    (start_at IS NOT NULL AND end_at IS NOT NULL AND occurrence_date = (start_at AT TIME ZONE 'Asia/Tokyo')::date)
    OR (start_at IS NULL AND end_at IS NULL));

-- 同じ系列の同じ日の O(d) は 1 つ (0001 の start_at の式の索引を回の日の索引に置き換える)
DROP INDEX IF EXISTS scheduled_task_template_day_unique;
DROP INDEX IF EXISTS scheduled_task_template_occurrence_unique;
CREATE UNIQUE INDEX scheduled_task_template_occurrence_unique
  ON scheduled_task (template_id, occurrence_date) WHERE template_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS scheduled_task_occurrence_date_idx ON scheduled_task (occurrence_date);

ALTER TABLE actual_task
  DROP CONSTRAINT IF EXISTS actual_task_status_chk,
  DROP CONSTRAINT IF EXISTS actual_task_time_chk,
  DROP CONSTRAINT IF EXISTS actual_task_skipped_on_chk;
ALTER TABLE actual_task
  ADD CONSTRAINT actual_task_status_chk CHECK (status IN ('done', 'skipped')),
  -- done = 時刻は両方あって終了 > 開始、または両方 NULL (時刻なしの間に作った done)。skipped = 時刻 NULL。
  -- 予定外の実績の時刻必須は actual_save が守る (CHECK にすると、系列を消して SET NULL になった時刻なしの done で止まる)
  ADD CONSTRAINT actual_task_time_chk CHECK (
    (status = 'done' AND ((start_at IS NOT NULL AND end_at IS NOT NULL AND end_at > start_at)
                          OR (start_at IS NULL AND end_at IS NULL)))
    OR (status = 'skipped' AND start_at IS NULL AND end_at IS NULL)),
  ADD CONSTRAINT actual_task_skipped_on_chk CHECK (skipped_on IS NULL OR status = 'skipped');
-- actual_task_link_chk・actual_task_skip_needs_link・一意索引 (0007) はそのまま

-- ============================================================
-- 内部の関数 (アプリからは呼ばない)。PostgREST が公開しないスキーマ private に置く (API からは 404)。
-- REVOKE だけで閉じると、SECURITY INVOKER の公開 RPC が中から呼んだ時点で anon の権限不足になる
-- (中から呼ぶ関数にも呼び出した人の EXECUTE が要る。2026-10-14 使い捨て DB で実測: todo_fetch・single_delete が
--  permission denied)。そのため EXECUTE は anon・authenticated に付け、外からの呼び出しはスキーマで止める (下の GRANT)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS private;
GRANT USAGE ON SCHEMA private TO anon, authenticated;

-- 回の中身: 単発 → その実体。系列 → O(d) があればその実体、無ければ d に効く世代 (effective_from ≤ d の最新)。
-- 見つからなければ全部 NULL。d に効く世代が終了の世代 (is_ended) なら回は無い = NULL
-- (Swift の原本 InMemoryScheduleDataSource.occurrenceInfo → TemplateVersions.effectiveVersion と同じ。2026-10-14 突き合わせ)。
-- o_timed = 時刻つきの回か
CREATE OR REPLACE FUNCTION private.todo_occurrence(
  p_template_id uuid, p_date date, p_scheduled_task_id uuid,
  OUT o_date date, OUT o_target int, OUT o_start timestamptz, OUT o_end timestamptz, OUT o_timed boolean
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_start_min int;
  v_duration int;
  v_ended boolean;
BEGIN
  IF p_scheduled_task_id IS NOT NULL THEN
    SELECT occurrence_date, target_count, start_at, end_at, start_at IS NOT NULL
      INTO o_date, o_target, o_start, o_end, o_timed
      FROM scheduled_task WHERE id = p_scheduled_task_id AND template_id IS NULL;
    RETURN;
  END IF;
  SELECT occurrence_date, target_count, start_at, end_at, start_at IS NOT NULL
    INTO o_date, o_target, o_start, o_end, o_timed
    FROM scheduled_task WHERE template_id = p_template_id AND occurrence_date = p_date;
  IF FOUND THEN RETURN; END IF;
  SELECT target_count, start_minutes_from_midnight, duration_minutes, is_ended
    INTO o_target, v_start_min, v_duration, v_ended
    FROM task_template_version
   WHERE template_id = p_template_id AND effective_from <= p_date
   ORDER BY effective_from DESC
   LIMIT 1;
  IF NOT FOUND OR v_ended THEN
    o_target := NULL;
    RETURN;
  END IF;
  o_date := p_date;
  o_timed := v_start_min IS NOT NULL;
  IF o_timed THEN
    o_start := (p_date + make_interval(mins => v_start_min)) AT TIME ZONE 'Asia/Tokyo';
    o_end := o_start + make_interval(mins => v_duration);
  END IF;
END $$;

-- 回の目標: 単発 → その target。系列 → O(d) があればその target、無ければ d に効く世代の target
CREATE OR REPLACE FUNCTION private.todo_target(p_template_id uuid, p_date date, p_scheduled_task_id uuid) RETURNS int
LANGUAGE sql STABLE
AS $$ SELECT o_target FROM private.todo_occurrence(p_template_id, p_date, p_scheduled_task_id) $$;

-- 閉じた日 = 目標の回数目のタップの JST 日と、スキップした日 (skipped_on。NULL なら回の日) の早い方。どちらも無ければ NULL。
-- 保存しない (タップ・目標・skipped_on から毎回求める)。回が見つからない (つながりの無い行・終了の世代の日) ときの目標は 1
-- (Swift の原本 InMemoryScheduleDataSource.closedOn・CountProgress.closedOn と同じ)
CREATE OR REPLACE FUNCTION private.todo_closed_on(p_actual_id uuid) RETURNS date
LANGUAGE sql STABLE
AS $$
  SELECT LEAST(
           (SELECT (t.tapped_at AT TIME ZONE 'Asia/Tokyo')::date
              FROM actual_task_tap t
             WHERE t.actual_task_id = a.id
             ORDER BY t.tapped_at, t.id
            OFFSET g.target - 1
             LIMIT 1),
           CASE WHEN a.status = 'skipped' THEN COALESCE(a.skipped_on, a.occurrence_date) END)
    FROM actual_task a
   CROSS JOIN LATERAL (SELECT GREATEST(COALESCE(private.todo_target(a.template_id, a.occurrence_date, a.scheduled_task_id), 1), 1)
                         AS target) g
   WHERE a.id = p_actual_id
$$;

-- 単発を編集・削除してよいか。p_new_date NULL = 元の日 (削除)。p_new_untimed = 保存する中身が時刻なしか (削除は NULL)。
-- 今が時刻なしで「今日の時点で閉じていない」(閉じた日が NULL か ≥ 今日) 単発:
--   - 元の日のまま (p_new_date = 元の日・削除) は通す (繰り越し中の単発を元の日のまま保存・削除できる。設計書 重大 2)。
--     ただし時刻ありへ切り替える保存は p_new_date ≥ 今日 が要る (過去日の時刻つきの単発を作らない。2026-10-14 リード指示)
--   - 日付を変えるのは、閉じた日を持たない単発だけ・新しい日 ≥ 今日 (閉じた単発は元の日が何日でも日付を変えられない。
--     今日閉じた単発を明日へ移すとどの日にも出なくなるため。計画「AI 既定」・2026-10-14 リード指示)
-- それ以外 (時刻つきの単発・今日より前に閉じた時刻なしの単発) は今と同じ「元の日 ≥ 今日 かつ 新しい日 ≥ 今日」
DROP FUNCTION IF EXISTS private.schedule_assert_single_editable(uuid, date);
CREATE OR REPLACE FUNCTION private.schedule_assert_single_editable(p_id uuid, p_new_date date, p_new_untimed boolean) RETURNS void
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_date date;
  v_untimed boolean;
  v_closed date;
BEGIN
  SELECT occurrence_date, start_at IS NULL INTO v_date, v_untimed
    FROM scheduled_task WHERE id = p_id AND template_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'single task not found: %', p_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_untimed THEN
    SELECT private.todo_closed_on(a.id) INTO v_closed FROM actual_task a WHERE a.scheduled_task_id = p_id;
    IF v_closed IS NULL OR v_closed >= jst_today() THEN
      IF p_new_date IS NULL OR p_new_date = v_date THEN
        IF p_new_untimed IS FALSE AND v_date < jst_today() THEN
          RAISE EXCEPTION 'timed single needs today or later: %', v_date USING ERRCODE = 'check_violation';
        END IF;
        RETURN;
      END IF;
      IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'closed single cannot change its date: %', p_id USING ERRCODE = 'check_violation';
      END IF;
      IF p_new_date >= jst_today() THEN
        RETURN;
      END IF;
      RAISE EXCEPTION 'past day is not editable: %', p_new_date USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  PERFORM schedule_assert_editable(v_date);
  PERFORM schedule_assert_editable(COALESCE(p_new_date, v_date));
END $$;

-- 繰り越し中で、今日の時点で閉じていない繰り返しの回か (今日以降の一覧に「◯◯ から」で出ている回)。
-- 回の日 < 今日・時刻なしの回 (O(d) があればその中身、無ければ d に効く世代)・d に効く世代が繰り越しオン・
-- 閉じた日が NULL か ≥ 今日。真なら「この予定」の削除を過去の日でも通す (2026-10-15 本人決定 1。単発の
-- schedule_assert_single_editable の「閉じていない単発は日付に関係なく消せる」と同じ考え)。
-- rrule・除外日は見ない (その日に回が無くても、足すのは見えない除外日だけ)。
-- Swift の原本 InMemoryScheduleDataSource の isOpenCarried と同じ
CREATE OR REPLACE FUNCTION private.todo_is_open_carried(p_template_id uuid, p_date date) RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT p_date < jst_today()
     AND COALESCE((SELECT o.o_target IS NOT NULL AND NOT o.o_timed
                     FROM private.todo_occurrence(p_template_id, p_date, NULL) o), false)
     AND COALESCE((SELECT v.carry_over AND NOT v.is_ended
                     FROM task_template_version v
                    WHERE v.template_id = p_template_id AND v.effective_from <= p_date
                    ORDER BY v.effective_from DESC
                    LIMIT 1), false)
     AND NOT EXISTS (SELECT 1 FROM actual_task a
                      WHERE a.template_id = p_template_id AND a.occurrence_date = p_date
                        AND private.todo_closed_on(a.id) < jst_today())
$$;

-- ============================================================
-- 予定の RPC (0006・0007 の写しを回の日・目標・時刻なしに広げる)。引数が変わるものは旧シグネチャを DROP してから作る
-- (重ねて残すと PostgREST が 1 つに決められない = PGRST203)。plpgsql は中から呼ぶ関数の DROP を検知しないので、
-- 中から呼ぶ経路 (end_to_single → single_save、template_create → single_delete) も新しいシグネチャで呼ぶ
-- ============================================================

-- 単発を作る / 書き換える。p_id NULL = 新規。時刻なしは p_start・p_duration が NULL。
-- p_date = 単発の日 (繰り越し中は元の日のまま渡す。日付を変えたときだけ新しい日)。時刻の有無を変えても記録は残す (本人決定 2)。
-- 実績の回の日も単発の日に合わせる。戻り値 = 実体の id
DROP FUNCTION IF EXISTS schedule_single_save(uuid, date, text, uuid, int, int);
CREATE OR REPLACE FUNCTION schedule_single_save(
  p_id uuid, p_date date, p_name text, p_category_id uuid, p_start int, p_duration int, p_target int
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_start timestamptz := CASE WHEN p_start IS NULL THEN NULL
                              ELSE (p_date + make_interval(mins => p_start)) AT TIME ZONE 'Asia/Tokyo' END;
  v_end timestamptz := v_start + make_interval(mins => p_duration);
  v_id uuid;
BEGIN
  IF (p_start IS NULL) <> (p_duration IS NULL) THEN
    RAISE EXCEPTION 'start and duration must be both set or both null' USING ERRCODE = 'check_violation';
  END IF;
  IF p_id IS NULL THEN
    PERFORM schedule_assert_editable(p_date);
    INSERT INTO scheduled_task (name, category_id, occurrence_date, start_at, end_at, target_count)
    VALUES (p_name, p_category_id, p_date, v_start, v_end, p_target)
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  PERFORM private.schedule_assert_single_editable(p_id, p_date, p_start IS NULL);
  UPDATE scheduled_task
     SET name = p_name, category_id = p_category_id, occurrence_date = p_date,
         start_at = v_start, end_at = v_end, target_count = p_target
   WHERE id = p_id;
  UPDATE actual_task SET occurrence_date = p_date WHERE scheduled_task_id = p_id AND occurrence_date <> p_date;
  RETURN p_id;
END $$;

-- 単発を消す (skipped の実績も消す。done はつながりを外して残す = 時刻なしの done は見えない記録として残る。タップも残る)
CREATE OR REPLACE FUNCTION schedule_single_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM private.schedule_assert_single_editable(p_id, NULL, NULL);
  DELETE FROM actual_task WHERE scheduled_task_id = p_id AND status = 'skipped';
  DELETE FROM scheduled_task WHERE id = p_id;
END $$;

-- D からの系列を作る。p_replace_single_id を渡すと、その単発を消して系列に置き換える (単発 → 系列)。
-- 単発に付いた実績は外さず、新しい系列の D の回へつなぎ直す (タップは押した時刻のまま D の回の進みに入る)。
-- 順序: 系列を作る → 単発の検査 (assert_single_editable。つなぎ直す前) → 実績をつなぎ直す → 単発を消す。戻り値 = 系列の id
DROP FUNCTION IF EXISTS schedule_template_create(date, text, uuid, int, int, text, boolean, uuid);
CREATE OR REPLACE FUNCTION schedule_template_create(
  p_date date, p_name text, p_category_id uuid, p_start int, p_duration int,
  p_rrule text, p_show_on_holiday boolean, p_replace_single_id uuid, p_target int, p_carry_over boolean
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_template_id uuid;
  v_version_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  IF p_rrule IS NULL AND NOT p_show_on_holiday THEN
    RAISE EXCEPTION 'series needs weekdays or holiday' USING ERRCODE = 'check_violation';
  END IF;
  -- 旧列は旧ビルド向けの写し (0013 で削除。時刻なしは NULL)
  INSERT INTO task_template (name, category_id, start_minutes_from_midnight, duration_minutes, rrule)
  VALUES (p_name, p_category_id, p_start, p_duration, p_rrule)
  RETURNING id INTO v_template_id;
  INSERT INTO task_template_version (template_id, effective_from, name, category_id,
                                     start_minutes_from_midnight, duration_minutes, rrule, target_count, carry_over)
  VALUES (v_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule, p_target, p_carry_over)
  RETURNING id INTO v_version_id;
  IF p_show_on_holiday THEN
    INSERT INTO pattern_version_membership (pattern_id, version_id)
    VALUES (schedule_holiday_pattern_id(), v_version_id);
  END IF;
  IF p_replace_single_id IS NOT NULL THEN
    -- 単発の検査はつなぎ直す前に (後だと実績が外れて閉じた日が求まらず、今日より前に閉じた単発も通ってしまう。
    -- 2026-10-14 Swift 側の指摘)。検査は削除と同じ (元の日のまま = p_new_date NULL)
    PERFORM private.schedule_assert_single_editable(p_replace_single_id, NULL, NULL);
    UPDATE actual_task
       SET scheduled_task_id = NULL, template_id = v_template_id, occurrence_date = p_date
     WHERE scheduled_task_id = p_replace_single_id;
    PERFORM schedule_single_delete(p_replace_single_id);
  END IF;
  RETURN v_template_id;
END $$;

-- 「これ以降のすべての予定」で保存: D の世代を作るか書き換え、D より後の世代は消す。
-- O(D) は消す (本人決定 1)。D より後の O・X は残す。時刻の有無を変えても D の回の記録は残す (本人決定 2)。
-- ただし D より後の O(d) のうち、時刻の有無が新しい中身と違うものは消し、その回の skipped の実績も消す
-- (残すと時刻つきとやることの 2 か所に出たり、記録できない回が繰り越し続けたりする。実装後レビュー R1)。
-- done は O(D) と同じく消さない (実績は template_id ＋回の日でつながるので、回は新しい世代の中身で出て記録が付く)。戻り値 = D の世代の id
DROP FUNCTION IF EXISTS schedule_template_save_following(uuid, date, text, uuid, int, int, text, boolean);
CREATE OR REPLACE FUNCTION schedule_template_save_following(
  p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start int, p_duration int,
  p_rrule text, p_show_on_holiday boolean, p_target int, p_carry_over boolean
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE v_version_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  IF p_rrule IS NULL AND NOT p_show_on_holiday THEN
    RAISE EXCEPTION 'series needs weekdays or holiday (use schedule_template_end_to_single)' USING ERRCODE = 'check_violation';
  END IF;
  DELETE FROM task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
  -- id を保ったまま書き換える (upsert で id を送ると PK が書き換わる。レビュー §1-1)
  UPDATE task_template_version
     SET is_ended = false, name = p_name, category_id = p_category_id,
         start_minutes_from_midnight = p_start, duration_minutes = p_duration, rrule = p_rrule,
         target_count = p_target, carry_over = p_carry_over
   WHERE template_id = p_template_id AND effective_from = p_date
   RETURNING id INTO v_version_id;
  IF v_version_id IS NULL THEN
    INSERT INTO task_template_version (template_id, effective_from, name, category_id,
                                       start_minutes_from_midnight, duration_minutes, rrule, target_count, carry_over)
    VALUES (p_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule, p_target, p_carry_over)
    RETURNING id INTO v_version_id;
  END IF;
  DELETE FROM pattern_version_membership WHERE version_id = v_version_id;
  IF p_show_on_holiday THEN
    INSERT INTO pattern_version_membership (pattern_id, version_id)
    VALUES (schedule_holiday_pattern_id(), v_version_id);
  END IF;
  DELETE FROM scheduled_task WHERE template_id = p_template_id AND occurrence_date = p_date;
  DELETE FROM actual_task a
   USING scheduled_task s
   WHERE s.template_id = p_template_id AND s.occurrence_date > p_date AND (s.start_at IS NULL) <> (p_start IS NULL)
     AND a.template_id = p_template_id AND a.occurrence_date = s.occurrence_date AND a.status = 'skipped';
  DELETE FROM scheduled_task
   WHERE template_id = p_template_id AND occurrence_date > p_date AND (start_at IS NULL) <> (p_start IS NULL);
  RETURN v_version_id;
END $$;

-- 「これ以降のすべての予定」を削除 (0007 の写し。日の判定を回の日に、終了の世代に目標・繰り越しも写す = 設計書 重大 3)。
-- D より前の回 (閉じていない繰り越し) は残す (決定 3)
CREATE OR REPLACE FUNCTION schedule_template_delete_following(p_template_id uuid, p_date date) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_first date;
  v_version_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date >= p_date AND status = 'skipped';
  DELETE FROM scheduled_task WHERE template_id = p_template_id AND occurrence_date >= p_date;
  DELETE FROM task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
  SELECT min(effective_from) INTO v_first FROM task_template_version WHERE template_id = p_template_id;
  IF v_first IS NULL OR v_first >= p_date THEN
    -- 世代・除外日・祝日の登録は CASCADE。done の実績は SET NULL (予定外として残る。時刻なしの done は見えない記録)。
    -- D より前の実体があれば FK (RESTRICT) が止める = 最後の砦
    DELETE FROM actual_task WHERE template_id = p_template_id AND status = 'skipped';
    DELETE FROM task_template WHERE id = p_template_id;
    RETURN;
  END IF;
  INSERT INTO task_template_version (template_id, effective_from, is_ended, name, category_id,
                                     start_minutes_from_midnight, duration_minutes, rrule, target_count, carry_over)
  SELECT template_id, p_date, true, name, category_id, start_minutes_from_midnight, duration_minutes, NULL,
         target_count, carry_over
    FROM task_template_version
   WHERE template_id = p_template_id AND effective_from < p_date
   ORDER BY effective_from DESC
   LIMIT 1
  ON CONFLICT (template_id, effective_from) DO UPDATE
    SET is_ended = true, rrule = NULL
  RETURNING id INTO v_version_id;
  DELETE FROM pattern_version_membership WHERE version_id = v_version_id;
END $$;

-- 繰り返しをやめる: D の単発を作る (時刻の有無は渡された中身のまま) → D の回の実績を単発へつなぎ直す → 「これ以降」削除。戻り値 = 単発の id
DROP FUNCTION IF EXISTS schedule_template_end_to_single(uuid, date, text, uuid, int, int);
CREATE OR REPLACE FUNCTION schedule_template_end_to_single(
  p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start int, p_duration int, p_target int
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE v_single uuid;
BEGIN
  v_single := schedule_single_save(NULL, p_date, p_name, p_category_id, p_start, p_duration, p_target);
  UPDATE actual_task
     SET template_id = NULL, scheduled_task_id = v_single
   WHERE template_id = p_template_id AND occurrence_date = p_date;
  PERFORM schedule_template_delete_following(p_template_id, p_date);
  RETURN v_single;
END $$;

-- 「この予定」で保存: O(D) を作るか書き換え。p_pattern_id は祝日パターン経由の回なら休日パターン (origin の CHECK を満たす)。
-- 「その日だけ」で時刻の有無は変えない: D に効く世代と時刻の有無が違う保存は拒否 (D に効く世代が無い・終了の世代なら検査しない。
-- Swift の原本と同じ。0006 は世代を見ていなかった)。戻り値 = 実体の id
DROP FUNCTION IF EXISTS schedule_occurrence_save(uuid, date, uuid, text, uuid, int, int);
CREATE OR REPLACE FUNCTION schedule_occurrence_save(
  p_template_id uuid, p_date date, p_pattern_id uuid,
  p_name text, p_category_id uuid, p_start int, p_duration int, p_target int
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_start timestamptz := CASE WHEN p_start IS NULL THEN NULL
                              ELSE (p_date + make_interval(mins => p_start)) AT TIME ZONE 'Asia/Tokyo' END;
  v_end timestamptz := v_start + make_interval(mins => p_duration);
  v_version_timed boolean;
  v_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  IF (p_start IS NULL) <> (p_duration IS NULL) THEN
    RAISE EXCEPTION 'start and duration must be both set or both null' USING ERRCODE = 'check_violation';
  END IF;
  SELECT CASE WHEN is_ended THEN NULL ELSE start_minutes_from_midnight IS NOT NULL END INTO v_version_timed
    FROM task_template_version
   WHERE template_id = p_template_id AND effective_from <= p_date
   ORDER BY effective_from DESC
   LIMIT 1;
  IF v_version_timed IS NOT NULL AND v_version_timed <> (p_start IS NOT NULL) THEN
    RAISE EXCEPTION 'occurrence cannot change timed/untimed (use save_following)' USING ERRCODE = 'check_violation';
  END IF;
  UPDATE scheduled_task
     SET name = p_name, category_id = p_category_id, pattern_id = p_pattern_id,
         start_at = v_start, end_at = v_end, target_count = p_target
   WHERE template_id = p_template_id AND occurrence_date = p_date
   RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO scheduled_task (name, category_id, occurrence_date, start_at, end_at, target_count, template_id, pattern_id)
    VALUES (p_name, p_category_id, p_date, v_start, v_end, p_target, p_template_id, p_pattern_id)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

-- 「この予定」を削除: X(D) を足し、O(D) があれば消す。D の skipped も消す (done は残る。時刻なしの done は見えない記録)。
-- 繰り越し中で閉じていない回 (private.todo_is_open_carried) は D < 今日でも消せる (2026-10-15 本人決定 1)
CREATE OR REPLACE FUNCTION schedule_occurrence_delete(p_template_id uuid, p_date date) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT private.todo_is_open_carried(p_template_id, p_date) THEN
    PERFORM schedule_assert_editable(p_date);
  END IF;
  INSERT INTO task_template_exdate (template_id, date) VALUES (p_template_id, p_date)
  ON CONFLICT DO NOTHING;
  DELETE FROM scheduled_task WHERE template_id = p_template_id AND occurrence_date = p_date;
  DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date = p_date AND status = 'skipped';
END $$;

-- ============================================================
-- 実績の RPC
-- ============================================================

-- 時刻つきで目標 1 の回の丸・スワイプ・実績の時刻の保存 (0007 と同じ引数。旧ビルドもそのまま使える)。
-- 単発の回の日は単発の occurrence_date。done は時刻必須 (time_chk が時刻 NULL の done を通すようになったため関数で検査)。
-- done にしたときタップが 0 件なら 1 行足す (押した時刻 = p_end。後で時刻なしへ切り替えても回数 1 で残る)。タップは減らさない。
-- スキップ → やったの保存で skipped_on を外す (skipped_on_chk。再レビュー重大 3)。戻り値 = actual_task.id
CREATE OR REPLACE FUNCTION checkin_set(
  p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid,
  p_status text, p_name text, p_category_id uuid,
  p_start timestamptz, p_end timestamptz
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_date date;
  v_start timestamptz := CASE WHEN p_status = 'skipped' THEN NULL ELSE p_start END;
  v_end timestamptz := CASE WHEN p_status = 'skipped' THEN NULL ELSE p_end END;
  v_id uuid;
BEGIN
  IF (p_template_id IS NULL) = (p_scheduled_task_id IS NULL) THEN
    RAISE EXCEPTION 'checkin needs exactly one of template_id / scheduled_task_id' USING ERRCODE = 'check_violation';
  END IF;
  IF p_scheduled_task_id IS NOT NULL THEN
    -- O(D) (template_id 付きの実体) は template_id ＋日でつなぐ決まり。単発だけを受ける
    SELECT occurrence_date INTO v_date
      FROM scheduled_task WHERE id = p_scheduled_task_id AND template_id IS NULL;
    IF v_date IS NULL THEN
      RAISE EXCEPTION 'single task not found: %', p_scheduled_task_id USING ERRCODE = 'no_data_found';
    END IF;
  ELSE
    v_date := p_occurrence_date;
  END IF;
  IF v_date IS NULL OR v_date > jst_today() THEN
    RAISE EXCEPTION 'future occurrence cannot be checked in: %', v_date USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF p_status = 'done' AND (v_start IS NULL OR v_end IS NULL OR v_end <= v_start) THEN
    RAISE EXCEPTION 'done needs start and end (end > start)' USING ERRCODE = 'check_violation';
  END IF;

  IF p_template_id IS NOT NULL THEN
    INSERT INTO actual_task (name, category_id, status, template_id, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, p_status, p_template_id, v_date, v_start, v_end)
    ON CONFLICT (template_id, occurrence_date) WHERE template_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = EXCLUDED.status,
                  start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at,
                  skipped_on = CASE WHEN EXCLUDED.status = 'skipped' THEN actual_task.skipped_on ELSE NULL END
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO actual_task (name, category_id, status, scheduled_task_id, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, p_status, p_scheduled_task_id, v_date, v_start, v_end)
    ON CONFLICT (scheduled_task_id) WHERE scheduled_task_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = EXCLUDED.status,
                  occurrence_date = EXCLUDED.occurrence_date, start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at,
                  skipped_on = CASE WHEN EXCLUDED.status = 'skipped' THEN actual_task.skipped_on ELSE NULL END
    RETURNING id INTO v_id;
  END IF;
  IF p_status = 'done' AND NOT EXISTS (SELECT 1 FROM actual_task_tap WHERE actual_task_id = v_id) THEN
    INSERT INTO actual_task_tap (actual_task_id, tapped_at) VALUES (v_id, v_end);
  END IF;
  RETURN v_id;
END $$;

-- 回の実績を消す (記録なしに戻す。タップは CASCADE)。キーで消す = 端末のキャッシュが古くても冪等
CREATE OR REPLACE FUNCTION checkin_clear(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF (p_template_id IS NULL) = (p_scheduled_task_id IS NULL) THEN
    RAISE EXCEPTION 'checkin needs exactly one of template_id / scheduled_task_id' USING ERRCODE = 'check_violation';
  END IF;
  IF p_template_id IS NOT NULL THEN
    DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date;
  ELSE
    DELETE FROM actual_task WHERE scheduled_task_id = p_scheduled_task_id;
  END IF;
END $$;

-- 回数の記録の共通の検査 (record_tap_* / record_skip_* の中だけで使う。外へは開かない)。
-- キーは丁度 1 つ・回がある・回の日 ≤ 今日・時刻つきで目標 1 の回でない (それは checkin_set / checkin_clear)。
-- 戻り値 = 回の中身 (todo_occurrence と同じ)
CREATE OR REPLACE FUNCTION private.record_occurrence_checked(
  p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid,
  OUT o_date date, OUT o_target int, OUT o_start timestamptz, OUT o_end timestamptz, OUT o_timed boolean
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  IF (p_template_id IS NULL) = (p_scheduled_task_id IS NULL) THEN
    RAISE EXCEPTION 'record needs exactly one of template_id / scheduled_task_id' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO o_date, o_target, o_start, o_end, o_timed
    FROM private.todo_occurrence(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF o_target IS NULL THEN
    RAISE EXCEPTION 'occurrence not found: % % %', p_template_id, p_occurrence_date, p_scheduled_task_id
      USING ERRCODE = 'no_data_found';
  END IF;
  IF o_date > jst_today() THEN
    RAISE EXCEPTION 'future occurrence cannot be recorded: %', o_date USING ERRCODE = 'check_violation';
  END IF;
  IF o_timed AND o_target = 1 THEN
    RAISE EXCEPTION 'timed occurrence with target 1 uses checkin_set / checkin_clear' USING ERRCODE = 'check_violation';
  END IF;
END $$;

-- タップを 1 回足す (時刻あり / なし共通)。回の行が無ければ done で作る (時刻つきは p_start・p_end = 予定の時刻、時刻なしは NULL)。
-- 押した時刻の JST 日は 回の日以上・今日以下。skipped の回は拒否。戻り値 = actual_task.id。
-- p_tap_id = タップの id (アプリが作る。NULL なら DB が作る)。同じ id のタップが既にあれば何もせず成功 (再送で冪等。
-- アプリは読み込んだタップに同じ id があれば楽観更新の上乗せから外す。実装後レビュー R5)
DROP FUNCTION IF EXISTS record_tap_add(uuid, date, uuid, text, uuid, timestamptz, timestamptz, timestamptz);
CREATE OR REPLACE FUNCTION record_tap_add(
  p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid,
  p_name text, p_category_id uuid, p_tapped_at timestamptz, p_start timestamptz, p_end timestamptz, p_tap_id uuid
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  o record;
  v_tap_day date := (p_tapped_at AT TIME ZONE 'Asia/Tokyo')::date;
  v_id uuid;
  v_status text;
BEGIN
  SELECT actual_task_id INTO v_id FROM actual_task_tap WHERE id = p_tap_id;
  IF FOUND THEN
    RETURN v_id;
  END IF;
  SELECT * INTO o FROM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF v_tap_day IS NULL OR v_tap_day < o.o_date OR v_tap_day > jst_today() THEN
    RAISE EXCEPTION 'tap must be between the occurrence day and today: %', p_tapped_at USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF o.o_timed AND (p_start IS NULL OR p_end IS NULL OR p_end <= p_start) THEN
    RAISE EXCEPTION 'timed occurrence needs planned start and end' USING ERRCODE = 'check_violation';
  END IF;
  IF p_template_id IS NOT NULL THEN
    SELECT id, status INTO v_id, v_status FROM actual_task
     WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date;
  ELSE
    SELECT id, status INTO v_id, v_status FROM actual_task WHERE scheduled_task_id = p_scheduled_task_id;
  END IF;
  IF v_status = 'skipped' THEN
    RAISE EXCEPTION 'skipped occurrence cannot be tapped (clear the skip first)' USING ERRCODE = 'check_violation';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO actual_task (name, category_id, status, template_id, occurrence_date, scheduled_task_id, start_at, end_at)
    VALUES (p_name, p_category_id, 'done', p_template_id, o.o_date, p_scheduled_task_id,
            CASE WHEN o.o_timed THEN p_start END, CASE WHEN o.o_timed THEN p_end END)
    RETURNING id INTO v_id;
  END IF;
  INSERT INTO actual_task_tap (id, actual_task_id, tapped_at) VALUES (COALESCE(p_tap_id, gen_random_uuid()), v_id, p_tapped_at)
  ON CONFLICT (id) DO NOTHING;
  RETURN v_id;
END $$;

-- タップを 1 回消す: JST 日が p_as_of 以前のタップのうち最も新しい 1 行。skipped の回は拒否。
-- 0 件になったら行も消す (実績の時刻も消える = 記録なしに戻る)。記録が無ければ何もしない
CREATE OR REPLACE FUNCTION record_tap_remove(
  p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_as_of date
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_id uuid;
  v_status text;
BEGIN
  PERFORM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF p_template_id IS NOT NULL THEN
    SELECT id, status INTO v_id, v_status FROM actual_task
     WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date;
  ELSE
    SELECT id, status INTO v_id, v_status FROM actual_task WHERE scheduled_task_id = p_scheduled_task_id;
  END IF;
  IF v_id IS NULL THEN RETURN; END IF;
  IF v_status = 'skipped' THEN
    RAISE EXCEPTION 'skipped occurrence cannot be untapped (clear the skip first)' USING ERRCODE = 'check_violation';
  END IF;
  DELETE FROM actual_task_tap
   WHERE id = (SELECT id FROM actual_task_tap
                WHERE actual_task_id = v_id AND (tapped_at AT TIME ZONE 'Asia/Tokyo')::date <= p_as_of
                ORDER BY tapped_at DESC, id DESC
                LIMIT 1);
  IF NOT EXISTS (SELECT 1 FROM actual_task_tap WHERE actual_task_id = v_id) THEN
    DELETE FROM actual_task WHERE id = v_id;
  END IF;
END $$;

-- スキップする (時刻なしと時刻つきの目標 2 以上)。status = skipped、skipped_on = p_on (一覧のスワイプでは V。回の日以上・今日以下)。
-- タップは残す。戻り値 = actual_task.id
CREATE OR REPLACE FUNCTION record_skip_set(
  p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid,
  p_name text, p_category_id uuid, p_on date
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  o record;
  v_id uuid;
BEGIN
  SELECT * INTO o FROM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF p_on IS NULL OR p_on < o.o_date OR p_on > jst_today() THEN
    RAISE EXCEPTION 'skip day must be between the occurrence day and today: %', p_on USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF p_template_id IS NOT NULL THEN
    INSERT INTO actual_task (name, category_id, status, template_id, occurrence_date, skipped_on)
    VALUES (p_name, p_category_id, 'skipped', p_template_id, o.o_date, p_on)
    ON CONFLICT (template_id, occurrence_date) WHERE template_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = 'skipped',
                  start_at = NULL, end_at = NULL, skipped_on = EXCLUDED.skipped_on
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO actual_task (name, category_id, status, scheduled_task_id, occurrence_date, skipped_on)
    VALUES (p_name, p_category_id, 'skipped', p_scheduled_task_id, o.o_date, p_on)
    ON CONFLICT (scheduled_task_id) WHERE scheduled_task_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = 'skipped',
                  occurrence_date = EXCLUDED.occurrence_date, start_at = NULL, end_at = NULL, skipped_on = EXCLUDED.skipped_on
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

-- スキップを取り消す (時刻なしと時刻つきの目標 2 以上)。タップがあれば done に戻し skipped_on を NULL に
-- (時刻つきは実績の時刻 = 予定の時刻を入れ直す)、無ければ行を消す。スキップでなければ何もしない
CREATE OR REPLACE FUNCTION record_skip_clear(
  p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  o record;
  v_id uuid;
BEGIN
  SELECT * INTO o FROM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF p_template_id IS NOT NULL THEN
    SELECT id INTO v_id FROM actual_task
     WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date AND status = 'skipped';
  ELSE
    SELECT id INTO v_id FROM actual_task WHERE scheduled_task_id = p_scheduled_task_id AND status = 'skipped';
  END IF;
  IF v_id IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM actual_task_tap WHERE actual_task_id = v_id) THEN
    UPDATE actual_task
       SET status = 'done', skipped_on = NULL,
           start_at = CASE WHEN o.o_timed THEN o.o_start END, end_at = CASE WHEN o.o_timed THEN o.o_end END
     WHERE id = v_id;
  ELSE
    DELETE FROM actual_task WHERE id = v_id;
  END IF;
END $$;

-- ============================================================
-- 読み取りの RPC (やることの節。1 往復)。範囲は Swift が決めて渡す (p_from = V−7、p_count_from = V−366)。
-- どの回を出すか (世代・rrule・祝日・繰り越しのオン・オフ) は Swift (TodoBuilder)。SQL は範囲で絞るだけ
-- (単発の「V より前に閉じた」だけは件数を抑えるため SQL で絞る = 規則の写し)。行は表の列名のまま (snake_case)。
-- singles・overrides は scheduled_task の全列 (created_at を含む。並び「作った順」に使う)
-- ============================================================
CREATE OR REPLACE FUNCTION todo_fetch(p_date date, p_from date, p_count_from date) RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH singles AS (
    -- 時刻なしの単発で 回の日 ≤ V かつ 閉じた日が NULL か ≥ V (閉じた日は 1 行に 1 回だけ求める。OFFSET 0 で式の展開を止める)
    SELECT s.*
      FROM scheduled_task s
      LEFT JOIN actual_task a ON a.scheduled_task_id = s.id
     CROSS JOIN LATERAL (SELECT private.todo_closed_on(a.id) AS closed_on OFFSET 0) c
     WHERE s.template_id IS NULL AND s.start_at IS NULL AND s.occurrence_date <= p_date
       AND (c.closed_on IS NULL OR c.closed_on >= p_date)
  ),
  overrides AS (
    SELECT s.*
      FROM scheduled_task s
     WHERE s.template_id IS NOT NULL AND s.start_at IS NULL AND s.occurrence_date BETWEEN p_from AND p_date
  ),
  -- 時刻なしの世代か時刻なしの O を持つ系列 (先に絞る。時刻つきだけの系列の実績で回の中身を求めない。実装後レビュー R8)
  untimed_templates AS (
    SELECT template_id FROM task_template_version WHERE start_minutes_from_midnight IS NULL
    UNION
    SELECT template_id FROM scheduled_task WHERE template_id IS NOT NULL AND start_at IS NULL
  ),
  -- 時刻なしの系列の回の実績 (回の中身 = O(d) か d に効く世代が時刻なし)
  series_actuals AS (
    SELECT a.*
      FROM actual_task a
     CROSS JOIN LATERAL private.todo_occurrence(a.template_id, a.occurrence_date, NULL) o
     WHERE a.template_id IN (SELECT template_id FROM untimed_templates)
       AND a.occurrence_date BETWEEN p_count_from AND p_date
       AND o.o_target IS NOT NULL AND NOT o.o_timed
  ),
  actuals AS (
    SELECT a.* FROM actual_task a WHERE a.scheduled_task_id IN (SELECT id FROM singles)
    UNION ALL
    SELECT * FROM series_actuals WHERE occurrence_date >= p_from
  ),
  taps AS (
    SELECT t.*
      FROM actual_task_tap t
     WHERE t.actual_task_id IN (SELECT id FROM actuals)
       AND (t.tapped_at AT TIME ZONE 'Asia/Tokyo')::date <= p_date
  ),
  older_closed AS (
    SELECT template_id, occurrence_date
      FROM series_actuals
     WHERE occurrence_date >= p_count_from AND occurrence_date < p_from
       AND private.todo_closed_on(id) < p_date
  )
  SELECT jsonb_build_object(
    'singles',      COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.occurrence_date, x.id) FROM singles x), '[]'::jsonb),
    'overrides',    COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.occurrence_date, x.id) FROM overrides x), '[]'::jsonb),
    'actuals',      COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.occurrence_date, x.id) FROM actuals x), '[]'::jsonb),
    'taps',         COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.tapped_at, x.id) FROM taps x), '[]'::jsonb),
    'exdates',      COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.date, x.template_id)
                                FROM task_template_exdate x WHERE x.date BETWEEN p_count_from AND p_date), '[]'::jsonb),
    'day_metas',    COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.date)
                                FROM day_meta x WHERE x.date BETWEEN p_count_from AND p_date), '[]'::jsonb),
    'older_closed', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.occurrence_date, x.template_id) FROM older_closed x), '[]'::jsonb)
  )
$$;

-- ============================================================
-- 権限。RLS 無効・anon キーで使う構成 (docs/continuity-design.md) に合わせて実行権限を明示する
-- ============================================================
GRANT EXECUTE ON FUNCTION
  schedule_single_save(uuid, date, text, uuid, int, int, int),
  schedule_single_delete(uuid),
  schedule_template_create(date, text, uuid, int, int, text, boolean, uuid, int, boolean),
  schedule_template_save_following(uuid, date, text, uuid, int, int, text, boolean, int, boolean),
  schedule_template_delete_following(uuid, date),
  schedule_template_end_to_single(uuid, date, text, uuid, int, int, int),
  schedule_occurrence_save(uuid, date, uuid, text, uuid, int, int, int),
  schedule_occurrence_delete(uuid, date),
  checkin_set(uuid, date, uuid, text, text, uuid, timestamptz, timestamptz),
  checkin_clear(uuid, date, uuid),
  record_tap_add(uuid, date, uuid, text, uuid, timestamptz, timestamptz, timestamptz, uuid),
  record_tap_remove(uuid, date, uuid, date),
  record_skip_set(uuid, date, uuid, text, uuid, date),
  record_skip_clear(uuid, date, uuid),
  todo_fetch(date, date, date)
TO anon, authenticated;

-- 内部の関数: PUBLIC (Postgres の既定) からは外し、公開 RPC の中から呼べるよう anon・authenticated にだけ付ける。
-- private は PostgREST の公開スキーマ (public) に入っていないので、API からは呼べない (レビュー中 4 の意図)
REVOKE EXECUTE ON FUNCTION
  private.todo_occurrence(uuid, date, uuid),
  private.todo_target(uuid, date, uuid),
  private.todo_closed_on(uuid),
  private.schedule_assert_single_editable(uuid, date, boolean),
  private.todo_is_open_carried(uuid, date),
  private.record_occurrence_checked(uuid, date, uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  private.todo_occurrence(uuid, date, uuid),
  private.todo_target(uuid, date, uuid),
  private.todo_closed_on(uuid),
  private.schedule_assert_single_editable(uuid, date, boolean),
  private.todo_is_open_carried(uuid, date),
  private.record_occurrence_checked(uuid, date, uuid)
TO anon, authenticated;
