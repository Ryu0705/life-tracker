-- Life Tracker v2 — 繰り返しの予定の世代管理 (段階 1)
-- 2026-09-30 / 設計: docs/day-cycle-walkthrough.md「段階 1 確定仕様」、レビュー docs/day-cycle-review-2026-09-30-db.md §1・§4
-- 適用方法: Supabase MCP apply_migration (name: v2_template_version) / supabase-cli は使わない
-- 本番適用は本人 OK 待ち (2026-09-30 時点で未適用)
--
-- 追加のみ (今のビルドを壊さない):
--   - task_template の中身の列と pattern_template_membership は残す。新しいビルドは読まない。
--     新しいビルドで実 DB の読み書きを確認できてから 0011 で削除する (本人 OK 後。旧称 0007・0008・0010)
--   - 新しい系列を RPC で作るときも task_template の旧列 (NOT NULL) は第 1 世代の中身で埋める (旧ビルド向けの写し。以後は更新しない)
-- 順序: 表 → 索引 → 休日パターン → backfill → 関数。途中で止まっても続きを手で流せる
-- 過去を守るトリガーは入れない (本人決定 3)。「過去日は書き換えない」は各関数の先頭の検査だけで守る。
--   関数を通さない書き込み (MCP の直接 SQL 等) には効かない。必要になったらトリガーの migration を 1 本足す
--
-- 規則の原本は Swift 側 (TemplateVersions.resolve / InMemoryScheduleDataSource)。この関数群はその写し。
-- 記法: D = 編集する日 (p_date)。O(d) = その日だけ変えた回 (scheduled_task, template_id = 系列)。X(d) = 除外日

-- ============================================================
-- 世代 (予定の中身の履歴)。task_template は系列の id を保つためだけの表になる
-- ============================================================
CREATE TABLE task_template_version (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id                 UUID NOT NULL REFERENCES task_template (id) ON DELETE CASCADE,
  effective_from              DATE NOT NULL,              -- この日から、次の世代の前日まで効く
  is_ended                    BOOLEAN NOT NULL DEFAULT false,
                                                          -- true = この日以降は出ない (「これ以降を削除」)。
                                                          -- 中身の列は直前の世代のコピー (レビュー §1-4 案 A)
  name                        TEXT NOT NULL,
  category_id                 UUID NOT NULL REFERENCES category (id) ON DELETE RESTRICT,
  start_minutes_from_midnight INT  NOT NULL CHECK (start_minutes_from_midnight BETWEEN 0 AND 1439),
  duration_minutes            INT  NOT NULL CHECK (duration_minutes > 0 AND duration_minutes <= 1440),
  rrule                       TEXT,                       -- NULL = パターン (祝日) 経由でのみ出る
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (template_id, effective_from),
  CONSTRAINT task_template_version_ended_chk CHECK (NOT is_ended OR rrule IS NULL)
);

-- 祝日に出すか (パターンへの登録) も世代ごとに持つ。過去の祝日の表示を変えないため
CREATE TABLE pattern_version_membership (
  pattern_id UUID NOT NULL REFERENCES pattern (id) ON DELETE CASCADE,
  version_id UUID NOT NULL REFERENCES task_template_version (id) ON DELETE CASCADE,
  PRIMARY KEY (pattern_id, version_id)
);

CREATE INDEX pattern_version_membership_version_idx ON pattern_version_membership (version_id);

-- ============================================================
-- 休日パターンを固定する (レビュー §1-8)。パターンの存在は世代を持たないので、後から作ると過去の祝日の組み立てが変わる。
-- 常に 1 件ある前提にし、アプリ側で後から作る処理 (ensureHolidayPattern) はやめる。パターン行は消さない運用
-- ============================================================
INSERT INTO pattern (name, apply_day)
SELECT '休日', 'Holiday'
WHERE NOT EXISTS (SELECT 1 FROM pattern WHERE apply_day = 'Holiday');

-- ============================================================
-- backfill (再実行しても二重にならない)
-- 第 1 世代の effective_from = 2026-04-26 (v2 の DB を作った日)。task_template に作成日時が無いための近似 (レビュー §1-7)。
-- その期間の実績は 0 件なので分析上の実害はない
-- ============================================================
INSERT INTO task_template_version (template_id, effective_from, name, category_id,
                                   start_minutes_from_midnight, duration_minutes, rrule)
SELECT t.id, DATE '2026-04-26', t.name, t.category_id, t.start_minutes_from_midnight, t.duration_minutes, t.rrule
FROM task_template t
WHERE NOT EXISTS (SELECT 1 FROM task_template_version v WHERE v.template_id = t.id);

INSERT INTO pattern_version_membership (pattern_id, version_id)
SELECT m.pattern_id, v.id
FROM pattern_template_membership m
JOIN task_template_version v
  ON v.template_id = m.template_id AND v.effective_from = DATE '2026-04-26'
WHERE NOT EXISTS (
  SELECT 1 FROM pattern_version_membership pv
  WHERE pv.pattern_id = m.pattern_id AND pv.version_id = v.id
);

-- ============================================================
-- RPC (plpgsql。1 呼び出し = 1 トランザクション。全部成功か全部取り消し)
-- 各関数の先頭で D >= JST の今日 を検査し、違えば例外 (本人決定 2・3)
-- ============================================================

CREATE FUNCTION jst_today() RETURNS date
LANGUAGE sql STABLE
AS $$ SELECT (now() AT TIME ZONE 'Asia/Tokyo')::date $$;

CREATE FUNCTION schedule_assert_editable(p_date date) RETURNS void
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  IF p_date IS NULL OR p_date < jst_today() THEN
    RAISE EXCEPTION 'past day is not editable: %', p_date USING ERRCODE = 'check_violation';
  END IF;
END $$;

-- 休日パターンの id (上で固定済み)
CREATE FUNCTION schedule_holiday_pattern_id() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT id FROM pattern WHERE apply_day = 'Holiday' $$;

-- 単発 (template_id NULL) の実体を作る / 書き換える。p_id NULL = 新規。戻り値 = 実体の id
CREATE FUNCTION schedule_single_save(
  p_id uuid, p_date date, p_name text, p_category_id uuid, p_start int, p_duration int
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_start timestamptz := (p_date + make_interval(mins => p_start)) AT TIME ZONE 'Asia/Tokyo';
  v_id uuid;
  v_old_date date;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  IF p_id IS NULL THEN
    INSERT INTO scheduled_task (name, category_id, start_at, end_at)
    VALUES (p_name, p_category_id, v_start, v_start + make_interval(mins => p_duration))
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  SELECT (start_at AT TIME ZONE 'Asia/Tokyo')::date INTO v_old_date
    FROM scheduled_task WHERE id = p_id AND template_id IS NULL;
  IF v_old_date IS NULL THEN
    RAISE EXCEPTION 'single task not found: %', p_id USING ERRCODE = 'no_data_found';
  END IF;
  PERFORM schedule_assert_editable(v_old_date);
  UPDATE scheduled_task
     SET name = p_name, category_id = p_category_id,
         start_at = v_start, end_at = v_start + make_interval(mins => p_duration)
   WHERE id = p_id;
  RETURN p_id;
END $$;

-- 単発を消す
CREATE FUNCTION schedule_single_delete(p_id uuid) RETURNS void
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
  DELETE FROM scheduled_task WHERE id = p_id;
END $$;

-- D からの系列を作る。p_replace_single_id を渡すと、その単発を消して系列に置き換える (単発 → 系列。レビュー §2-2)
-- 戻り値 = 系列の id
CREATE FUNCTION schedule_template_create(
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
  IF p_replace_single_id IS NOT NULL THEN
    PERFORM schedule_single_delete(p_replace_single_id);
  END IF;
  -- 旧列は旧ビルド向けの写し (0011 で削除。旧称 0007・0008・0010)
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
  RETURN v_template_id;
END $$;

-- 「これ以降のすべての予定」で保存: D の世代を作るか書き換え、D より後の世代は消す。
-- O(D) は消す (本人決定 1)。D より後の O・X は残す。戻り値 = D の世代の id
CREATE FUNCTION schedule_template_save_following(
  p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start int, p_duration int,
  p_rrule text, p_show_on_holiday boolean
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
         start_minutes_from_midnight = p_start, duration_minutes = p_duration, rrule = p_rrule
   WHERE template_id = p_template_id AND effective_from = p_date
   RETURNING id INTO v_version_id;
  IF v_version_id IS NULL THEN
    INSERT INTO task_template_version (template_id, effective_from, name, category_id,
                                       start_minutes_from_midnight, duration_minutes, rrule)
    VALUES (p_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule)
    RETURNING id INTO v_version_id;
  END IF;
  DELETE FROM pattern_version_membership WHERE version_id = v_version_id;
  IF p_show_on_holiday THEN
    INSERT INTO pattern_version_membership (pattern_id, version_id)
    VALUES (schedule_holiday_pattern_id(), v_version_id);
  END IF;
  DELETE FROM scheduled_task
   WHERE template_id = p_template_id
     AND (start_at AT TIME ZONE 'Asia/Tokyo')::date = p_date;
  RETURN v_version_id;
END $$;

-- 「これ以降のすべての予定」を削除: D 以降の O はすべて消す。D より後の世代は消す。
-- 系列の最初の世代が D 以降 (一度も過去に出ていない。判定は世代の日付。レビュー §2-3) なら系列ごと消す。
-- それ以外は D に終了の世代 (中身は直前の世代のコピー、rrule NULL、祝日の登録なし)。D 以降の X は残す
CREATE FUNCTION schedule_template_delete_following(p_template_id uuid, p_date date) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_first date;
  v_version_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  DELETE FROM scheduled_task
   WHERE template_id = p_template_id
     AND (start_at AT TIME ZONE 'Asia/Tokyo')::date >= p_date;
  DELETE FROM task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
  SELECT min(effective_from) INTO v_first FROM task_template_version WHERE template_id = p_template_id;
  IF v_first IS NULL OR v_first >= p_date THEN
    -- 世代・除外日・祝日の登録は CASCADE。D より前の実体があれば FK (RESTRICT) が止める = 最後の砦
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

-- 繰り返しをやめる (曜日も祝日も全部外した): 「これ以降」削除 ＋ D の単発を作る (系列 → 単発。レビュー §2-2)
-- 戻り値 = 単発の id
CREATE FUNCTION schedule_template_end_to_single(
  p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start int, p_duration int
) RETURNS uuid
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM schedule_template_delete_following(p_template_id, p_date);
  RETURN schedule_single_save(NULL, p_date, p_name, p_category_id, p_start, p_duration);
END $$;

-- 「この予定」で保存: O(D) を作るか書き換え。p_pattern_id は祝日パターン経由の回なら休日パターン (origin の CHECK を満たす)
-- 式インデックス (template_id, JST 日) は upsert の onConflict に指定できないので UPDATE → INSERT (レビュー §1-2)
-- 戻り値 = 実体の id
CREATE FUNCTION schedule_occurrence_save(
  p_template_id uuid, p_date date, p_pattern_id uuid,
  p_name text, p_category_id uuid, p_start int, p_duration int
) RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_start timestamptz := (p_date + make_interval(mins => p_start)) AT TIME ZONE 'Asia/Tokyo';
  v_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  UPDATE scheduled_task
     SET name = p_name, category_id = p_category_id, pattern_id = p_pattern_id,
         start_at = v_start, end_at = v_start + make_interval(mins => p_duration)
   WHERE template_id = p_template_id
     AND (start_at AT TIME ZONE 'Asia/Tokyo')::date = p_date
   RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO scheduled_task (name, category_id, start_at, end_at, template_id, pattern_id)
    VALUES (p_name, p_category_id, v_start, v_start + make_interval(mins => p_duration), p_template_id, p_pattern_id)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

-- 「この予定」を削除: X(D) を足し、O(D) があれば消す
CREATE FUNCTION schedule_occurrence_delete(p_template_id uuid, p_date date) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM schedule_assert_editable(p_date);
  INSERT INTO task_template_exdate (template_id, date) VALUES (p_template_id, p_date)
  ON CONFLICT DO NOTHING;
  DELETE FROM scheduled_task
   WHERE template_id = p_template_id
     AND (start_at AT TIME ZONE 'Asia/Tokyo')::date = p_date;
END $$;

-- RLS 無効・anon キーで使う構成 (docs/continuity-design.md) に合わせて実行権限を明示する
GRANT EXECUTE ON FUNCTION
  jst_today(),
  schedule_assert_editable(date),
  schedule_holiday_pattern_id(),
  schedule_single_save(uuid, date, text, uuid, int, int),
  schedule_single_delete(uuid),
  schedule_template_create(date, text, uuid, int, int, text, boolean, uuid),
  schedule_template_save_following(uuid, date, text, uuid, int, int, text, boolean),
  schedule_template_delete_following(uuid, date),
  schedule_template_end_to_single(uuid, date, text, uuid, int, int),
  schedule_occurrence_save(uuid, date, uuid, text, uuid, int, int),
  schedule_occurrence_delete(uuid, date)
TO anon, authenticated;
