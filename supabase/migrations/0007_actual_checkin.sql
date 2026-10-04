-- Life Tracker v2 — 予定の予実の記録 (段階 2 チェックイン)
-- 2026-09-30 / 設計: docs/day-cycle-walkthrough.md「段階 2 確定仕様」「設計レビューの反映」、
--   レビュー docs/day-cycle-review-2026-09-30-stage2.md (§1-2・§2-2・§2-3・§2-5・§6)
-- 適用方法: Supabase MCP apply_migration (name: v2_actual_checkin) / supabase-cli は使わない
-- 本番適用: 2026-10-04 本人 OK で適用 (睡眠を抜いた版。MCP apply_migration v2_actual_checkin)
-- 2026-10-03 睡眠を抜いた版に書き換え (睡眠は 0009 sleep_record。docs/sleep-design/implementation-plan.md)
--
-- 冪等: 何度流しても同じ状態になる (IF NOT EXISTS・制約は pg_constraint を見て足す・関数は CREATE OR REPLACE)。
--   apply_migration が 1 トランザクションか未確認のため、途中で止まっても頭から流し直せる形にする
-- 順序: 旧 CHECK の DROP → 列 → 制約・索引 → 新関数 → 段階 1 の関数の置き換え (新列を参照するので列の後) → GRANT
--
-- 実績と回のつなぎ (決定 C1。規約 D-4 は 2026-09-30 改訂済み):
--   繰り返しの予定の回 = template_id ＋ occurrence_date (その日だけ変えた回 O(D) でも同じ。O(D) の id は使わない)
--   繰り返さない予定 = scheduled_task_id。どちらも空 = 予定外の実績 (C6)
--   occurrence_date は全行必須 = 一覧に出る日 (JST)。回の日 / 単発の日 / 予定外は開始の JST 日。取得は occurrence_date IN (D-1, D)
-- 予定側の RPC が実績に触れるのは「つながりの列 (単発↔繰り返しの変換でのつなぎ直し)」と「skipped の行の削除」だけ
-- 規則の原本は Swift 側 (InMemoryScheduleDataSource)。この関数群はその写し

-- ============================================================
-- actual_task の列
-- ============================================================
ALTER TABLE actual_task DROP CONSTRAINT IF EXISTS actual_task_check;   -- 0001 の無名 CHECK (end_at > start_at)。下の time_chk に置き換える

ALTER TABLE actual_task
  ADD COLUMN IF NOT EXISTS status            TEXT NOT NULL DEFAULT 'done',
  ADD COLUMN IF NOT EXISTS template_id       UUID REFERENCES task_template (id) ON DELETE SET NULL,   -- 繰り返しの予定の回
  ADD COLUMN IF NOT EXISTS occurrence_date   DATE,                                                   -- 一覧に出る日 (JST)
  ADD COLUMN IF NOT EXISTS scheduled_task_id UUID REFERENCES scheduled_task (id) ON DELETE SET NULL, -- 繰り返さない予定
  ALTER COLUMN start_at DROP NOT NULL,
  ALTER COLUMN end_at DROP NOT NULL;

-- 既存の行 (本番は 0 件) は開始の JST 日を入れてから NOT NULL にする
UPDATE actual_task SET occurrence_date = (start_at AT TIME ZONE 'Asia/Tokyo')::date WHERE occurrence_date IS NULL;
ALTER TABLE actual_task ALTER COLUMN occurrence_date SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'actual_task_status_chk') THEN
    ALTER TABLE actual_task ADD CONSTRAINT actual_task_status_chk CHECK (status IN ('done', 'skipped'));
  END IF;
  -- やったなら時刻必須 (終了 > 開始)。スキップは時刻なし (決定 C2)
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'actual_task_time_chk') THEN
    ALTER TABLE actual_task ADD CONSTRAINT actual_task_time_chk CHECK (
      (status = 'done' AND start_at IS NOT NULL AND end_at IS NOT NULL AND end_at > start_at)
      OR (status = 'skipped' AND start_at IS NULL AND end_at IS NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'actual_task_link_chk') THEN
    ALTER TABLE actual_task ADD CONSTRAINT actual_task_link_chk CHECK (template_id IS NULL OR scheduled_task_id IS NULL);
  END IF;
  -- 最後の砦 (レビュー §2-2): つながりの無いスキップは作れない。予定を消す RPC が skipped を先に消し忘れると、
  -- SET NULL の瞬間にここで止まる (= 見えない・消せない行が積もらない)
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'actual_task_skip_needs_link') THEN
    ALTER TABLE actual_task ADD CONSTRAINT actual_task_skip_needs_link
      CHECK (status <> 'skipped' OR template_id IS NOT NULL OR scheduled_task_id IS NOT NULL);
  END IF;
END $$;

-- 1 つの回に実績は 1 行 (決定 C2)
CREATE UNIQUE INDEX IF NOT EXISTS actual_task_occurrence_unique ON actual_task (template_id, occurrence_date) WHERE template_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS actual_task_scheduled_unique ON actual_task (scheduled_task_id) WHERE scheduled_task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS actual_task_occurrence_date_idx ON actual_task (occurrence_date);

-- ============================================================
-- チェックインの RPC (過去日の検査はしない = 実績は過去日も入力できる。未来の日は拒む)
-- ============================================================

-- 回の実績を作る / 書き換える (1 つの回に 1 行の upsert)。つながりは丁度 1 つ (予定外は actual_save)。
-- 単発の回の日は RPC が単発の開始の JST 日で決める (p_occurrence_date は繰り返しの回だけ使う)。
-- skipped は時刻を NULL に正規化する。睡眠の種類は受けない (睡眠は sleep_record に記録する。0009)
-- 戻り値 = actual_task.id
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
    SELECT (start_at AT TIME ZONE 'Asia/Tokyo')::date INTO v_date
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

  IF p_template_id IS NOT NULL THEN
    INSERT INTO actual_task (name, category_id, status, template_id, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, p_status, p_template_id, v_date, v_start, v_end)
    ON CONFLICT (template_id, occurrence_date) WHERE template_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = EXCLUDED.status,
                  start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO actual_task (name, category_id, status, scheduled_task_id, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, p_status, p_scheduled_task_id, v_date, v_start, v_end)
    ON CONFLICT (scheduled_task_id) WHERE scheduled_task_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = EXCLUDED.status,
                  occurrence_date = EXCLUDED.occurrence_date, start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

-- 回の実績を消す (記録なしに戻す)。キーで消す = 端末のキャッシュが古くても冪等
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

-- 予定外の実績 (C6) を作る / 書き換える。p_id NULL = 新規。つながりの有無は問わない
-- (「この予定」削除の後などに予定外として出る done 行も同じ関数で直す。つながりの列には触れない)。
-- 一覧に出る日: つながりの無い行は開始の JST 日に合わせる。つながりの有る行は回の日のまま。戻り値 = id
CREATE OR REPLACE FUNCTION actual_save(
  p_id uuid, p_name text, p_category_id uuid, p_start timestamptz, p_end timestamptz
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_date date := (p_start AT TIME ZONE 'Asia/Tokyo')::date;
  v_id uuid;
BEGIN
  IF v_date IS NULL OR v_date > jst_today() THEN
    RAISE EXCEPTION 'future day cannot be recorded: %', v_date USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO actual_task (name, category_id, status, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, 'done', v_date, p_start, p_end)
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  UPDATE actual_task
     SET name = p_name, category_id = p_category_id, start_at = p_start, end_at = p_end,
         occurrence_date = CASE WHEN template_id IS NULL AND scheduled_task_id IS NULL THEN v_date ELSE occurrence_date END
   WHERE id = p_id AND status = 'done'
   RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'actual not found: %', p_id USING ERRCODE = 'no_data_found';
  END IF;
  RETURN v_id;
END $$;

-- 予定外の実績を消す (つながりの有無は問わない。過去日も可 = 実績なので)
CREATE OR REPLACE FUNCTION actual_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM actual_task WHERE id = p_id;
END $$;

-- ============================================================
-- 段階 1 の関数の置き換え (引数・戻り値の型は 0006 と同じ。GRANT は保たれる)
-- 予定の行を消す操作は skipped を先に消す (予定のないスキップは意味がない)。done は残す (つながりは SET NULL か、回が出なくなるだけ)。
-- 曜日・祝日の変更 (save_following) で回が出なくなった skipped は残し、表示・分析で無視する (本人確認 2026-09-30 (b))
-- ============================================================

-- 単発を消す (skipped の実績も消す)
CREATE OR REPLACE FUNCTION schedule_single_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE v_old_date date;
BEGIN
  SELECT (start_at AT TIME ZONE 'Asia/Tokyo')::date INTO v_old_date
    FROM scheduled_task WHERE id = p_id AND template_id IS NULL;
  IF v_old_date IS NULL THEN
    RAISE EXCEPTION 'single task not found: %', p_id USING ERRCODE = 'no_data_found';
  END IF;
  PERFORM schedule_assert_editable(v_old_date);
  DELETE FROM actual_task WHERE scheduled_task_id = p_id AND status = 'skipped';
  DELETE FROM scheduled_task WHERE id = p_id;
END $$;

-- D からの系列を作る。p_replace_single_id を渡すと、その単発を消して系列に置き換える (単発 → 系列)。
-- 単発に付いた実績は外さず、新しい系列の D の回へつなぎ直す (本人確認 2026-09-30 (a)、レビュー §1-2)。
-- 順序: 系列を作る → 実績をつなぎ直す → 単発を消す (先に消すと SET NULL で行を見失い、skipped は CHECK で止まる)
CREATE OR REPLACE FUNCTION schedule_template_create(
  p_date date, p_name text, p_category_id uuid, p_start int, p_duration int,
  p_rrule text, p_show_on_holiday boolean, p_replace_single_id uuid
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
  -- 旧列は旧ビルド向けの写し (0010 で削除)
  INSERT INTO task_template (name, category_id, start_minutes_from_midnight, duration_minutes, rrule)
  VALUES (p_name, p_category_id, p_start, p_duration, p_rrule)
  RETURNING id INTO v_template_id;
  INSERT INTO task_template_version (template_id, effective_from, name, category_id,
                                     start_minutes_from_midnight, duration_minutes, rrule)
  VALUES (v_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule)
  RETURNING id INTO v_version_id;
  IF p_show_on_holiday THEN
    INSERT INTO pattern_version_membership (pattern_id, version_id)
    VALUES (schedule_holiday_pattern_id(), v_version_id);
  END IF;
  IF p_replace_single_id IS NOT NULL THEN
    UPDATE actual_task
       SET scheduled_task_id = NULL, template_id = v_template_id, occurrence_date = p_date
     WHERE scheduled_task_id = p_replace_single_id;
    PERFORM schedule_single_delete(p_replace_single_id);
  END IF;
  RETURN v_template_id;
END $$;

-- 「これ以降のすべての予定」を削除 (0006 の中身＋ D 以降の skipped を先に消す)。
-- 系列ごと消すときは日付に依らず skipped を消す (FK の SET NULL で skip_needs_link に当たらないように)
CREATE OR REPLACE FUNCTION schedule_template_delete_following(p_template_id uuid, p_date date) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_first date;
  v_version_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date >= p_date AND status = 'skipped';
  DELETE FROM scheduled_task
   WHERE template_id = p_template_id
     AND (start_at AT TIME ZONE 'Asia/Tokyo')::date >= p_date;
  DELETE FROM task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
  SELECT min(effective_from) INTO v_first FROM task_template_version WHERE template_id = p_template_id;
  IF v_first IS NULL OR v_first >= p_date THEN
    -- 世代・除外日・祝日の登録は CASCADE。done の実績は SET NULL (予定外として残る)。
    -- D より前の実体があれば FK (RESTRICT) が止める = 最後の砦
    DELETE FROM actual_task WHERE template_id = p_template_id AND status = 'skipped';
    DELETE FROM task_template WHERE id = p_template_id;
    RETURN;
  END IF;
  INSERT INTO task_template_version (template_id, effective_from, is_ended, name, category_id,
                                     start_minutes_from_midnight, duration_minutes, rrule)
  SELECT template_id, p_date, true, name, category_id, start_minutes_from_midnight, duration_minutes, NULL
    FROM task_template_version
   WHERE template_id = p_template_id AND effective_from < p_date
   ORDER BY effective_from DESC
   LIMIT 1
  ON CONFLICT (template_id, effective_from) DO UPDATE
    SET is_ended = true, rrule = NULL
  RETURNING id INTO v_version_id;
  DELETE FROM pattern_version_membership WHERE version_id = v_version_id;
END $$;

-- 繰り返しをやめる: D の単発を作る → D の回の実績を単発へつなぎ直す → 「これ以降」削除 (系列 → 単発)。
-- つなぎ直した行は template_id が外れるので、delete_following の skipped 削除の対象にならない。戻り値 = 単発の id
CREATE OR REPLACE FUNCTION schedule_template_end_to_single(
  p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start int, p_duration int
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE v_single uuid;
BEGIN
  v_single := schedule_single_save(NULL, p_date, p_name, p_category_id, p_start, p_duration);
  UPDATE actual_task
     SET template_id = NULL, scheduled_task_id = v_single
   WHERE template_id = p_template_id AND occurrence_date = p_date;
  PERFORM schedule_template_delete_following(p_template_id, p_date);
  RETURN v_single;
END $$;

-- 「この予定」を削除: X(D) を足し、O(D) があれば消す。D の skipped も消す (done は残り、予定外として出る)
CREATE OR REPLACE FUNCTION schedule_occurrence_delete(p_template_id uuid, p_date date) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM schedule_assert_editable(p_date);
  INSERT INTO task_template_exdate (template_id, date) VALUES (p_template_id, p_date)
  ON CONFLICT DO NOTHING;
  DELETE FROM scheduled_task
   WHERE template_id = p_template_id
     AND (start_at AT TIME ZONE 'Asia/Tokyo')::date = p_date;
  DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date = p_date AND status = 'skipped';
END $$;

-- RLS 無効・anon キーで使う構成 (docs/continuity-design.md) に合わせて実行権限を明示する
GRANT EXECUTE ON FUNCTION
  checkin_set(uuid, date, uuid, text, text, uuid, timestamptz, timestamptz),
  checkin_clear(uuid, date, uuid),
  actual_save(uuid, text, uuid, timestamptz, timestamptz),
  actual_delete(uuid),
  schedule_single_delete(uuid),
  schedule_template_create(date, text, uuid, int, int, text, boolean, uuid),
  schedule_template_delete_following(uuid, date),
  schedule_template_end_to_single(uuid, date, text, uuid, int, int),
  schedule_occurrence_delete(uuid, date)
TO anon, authenticated;
