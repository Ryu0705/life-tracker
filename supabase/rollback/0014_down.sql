-- Life Tracker v2 — 0014 (人ごとのデータ・RLS) の戻し。番号付きの前進用の migration ではない (supabase/migrations/ の外に置く)
-- 2026-10-19 / 計画: docs/auth-multiuser-implementation-plan.md §1-4・設計 §6 (M15)
--
-- ★ 本人 1 人しかデータが無いうちだけ安全。2 人目が記録した後に user_id を消すと、人の区別が失われて混ざる
--   (先頭の DO で、user_id が 2 種類以上ある・自作の種目がある、なら止める)
-- ★ 戻しても supabase_migrations.schema_migrations に 0014 (v2_multiuser_rls) の記録は残り、list_migrations では適用済みに見える
-- ★ v1 の残りの関数 6 つ (0014 の o) は戻さない (使っていない・もう無い表を参照していた)
-- ★ btree_gist は残す (害が無い)。列の並びは戻らない (足し直した user_profile.id・exercise.note・exercise.is_archived は表の末尾)
-- ★ 0014 が途中までしか流れていない状態からも通るように IF EXISTS で書く (apply_migration は 1 つのトランザクションなので、ふつうは起きない)
-- 流し方: 今のビルド (0014 の前のアプリ) を入れ直すのと一緒に。MCP の execute_sql か SQL エディタで 1 回で流す
-- 確かめ: supabase/test/run.sh --rollback (0013 の後と、0014 → この戻しの後の形が同じ)
--
-- 順序 (0014 の逆): 砦 → RLS と policy → 関数 → view → 索引 → 種目 → 1 人前提の形 → 外部キー → user_id → 権限

-- ============================================================
-- 砦
-- ============================================================
DO $$
DECLARE
  v_t text;
  v_owners int := 0;
BEGIN
  IF to_regclass('public.exercise') IS NULL THEN RETURN; END IF;
  -- user_id の種類を全表で数える (列が無い表は飛ばす)
  CREATE TEMP TABLE _rollback_owner (user_id uuid) ON COMMIT DROP;
  FOREACH v_t IN ARRAY ARRAY['actual_task', 'actual_task_tap', 'body_weight_record', 'category', 'day_meta', 'pattern', 'pattern_version_membership', 'routine', 'routine_exercise', 'scheduled_task', 'sleep_record', 'task_template', 'task_template_exdate', 'task_template_version', 'training_goal', 'user_profile', 'workout_entry', 'workout_session', 'workout_set'] LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = v_t AND column_name = 'user_id') THEN
      EXECUTE format('INSERT INTO _rollback_owner SELECT DISTINCT user_id FROM public.%I WHERE user_id IS NOT NULL', v_t);
    END IF;
  END LOOP;
  IF to_regclass('public.exercise_preference') IS NOT NULL THEN
    INSERT INTO _rollback_owner SELECT DISTINCT user_id FROM public.exercise_preference;
  END IF;
  SELECT count(DISTINCT user_id) INTO v_owners FROM _rollback_owner;
  IF v_owners > 1 THEN
    RAISE EXCEPTION 'rollback: data of % users exists (only safe with one)', v_owners;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'exercise' AND column_name = 'user_id')
     AND EXISTS (SELECT 1 FROM public.exercise WHERE user_id IS NOT NULL) THEN
    RAISE EXCEPTION 'rollback: custom exercises exist (would become shared)';
  END IF;
END $$;

-- ============================================================
-- n. RLS と policy
-- ============================================================
DROP POLICY IF EXISTS own_rows ON public.actual_task;
DROP POLICY IF EXISTS own_rows ON public.actual_task_tap;
DROP POLICY IF EXISTS own_rows ON public.body_weight_record;
DROP POLICY IF EXISTS own_rows ON public.category;
DROP POLICY IF EXISTS own_rows ON public.day_meta;
DROP POLICY IF EXISTS own_rows ON public.pattern;
DROP POLICY IF EXISTS own_rows ON public.pattern_version_membership;
DROP POLICY IF EXISTS own_rows ON public.routine;
DROP POLICY IF EXISTS own_rows ON public.routine_exercise;
DROP POLICY IF EXISTS own_rows ON public.scheduled_task;
DROP POLICY IF EXISTS own_rows ON public.sleep_record;
DROP POLICY IF EXISTS own_rows ON public.task_template;
DROP POLICY IF EXISTS own_rows ON public.task_template_exdate;
DROP POLICY IF EXISTS own_rows ON public.task_template_version;
DROP POLICY IF EXISTS own_rows ON public.training_goal;
DROP POLICY IF EXISTS own_rows ON public.user_profile;
DROP POLICY IF EXISTS own_rows ON public.workout_entry;
DROP POLICY IF EXISTS own_rows ON public.workout_session;
DROP POLICY IF EXISTS own_rows ON public.workout_set;
DROP POLICY IF EXISTS own_rows ON public.exercise_preference;
DROP POLICY IF EXISTS exercise_select ON public.exercise;
DROP POLICY IF EXISTS exercise_insert ON public.exercise;
DROP POLICY IF EXISTS exercise_update ON public.exercise;
DROP POLICY IF EXISTS exercise_delete ON public.exercise;
ALTER TABLE public.actual_task DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.actual_task_tap DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.body_weight_record DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.category DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.day_meta DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.exercise DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.pattern DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.pattern_version_membership DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.routine DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.routine_exercise DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheduled_task DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.sleep_record DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_template DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_template_exdate DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_template_version DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.training_goal DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profile DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_entry DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_session DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_set DISABLE ROW LEVEL SECURITY;

-- ============================================================
-- l. 関数を 0013 の後の定義に戻す (本文ごと。RESET search_path だけでは本文の public. が残り、形が戻らない)。
-- CREATE OR REPLACE は SET 句も置き換えるので、search_path の設定は消える。権限は保たれる (最後に戻す)
-- ============================================================
DROP FUNCTION IF EXISTS public.ensure_user_defaults();

CREATE OR REPLACE FUNCTION public.jst_today()
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$ SELECT (now() AT TIME ZONE 'Asia/Tokyo')::date $function$
;
CREATE OR REPLACE FUNCTION public.schedule_assert_editable(p_date date)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
  IF p_date IS NULL OR p_date < jst_today() THEN
    RAISE EXCEPTION 'past day is not editable: %', p_date USING ERRCODE = 'check_violation';
  END IF;
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_holiday_pattern_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$ SELECT id FROM pattern WHERE apply_day = 'Holiday' $function$
;
CREATE OR REPLACE FUNCTION public.schedule_single_delete(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM private.schedule_assert_single_editable(p_id, NULL, NULL);
  DELETE FROM actual_task WHERE scheduled_task_id = p_id AND status = 'skipped';
  DELETE FROM scheduled_task WHERE id = p_id;
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_template_delete_following(p_template_id uuid, p_date date)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_occurrence_delete(p_template_id uuid, p_date date)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT private.todo_is_open_carried(p_template_id, p_date) THEN
    PERFORM schedule_assert_editable(p_date);
  END IF;
  INSERT INTO task_template_exdate (template_id, date) VALUES (p_template_id, p_date)
  ON CONFLICT DO NOTHING;
  DELETE FROM scheduled_task WHERE template_id = p_template_id AND occurrence_date = p_date;
  DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date = p_date AND status = 'skipped';
END $function$
;
CREATE OR REPLACE FUNCTION public.checkin_set(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_status text, p_name text, p_category_id uuid, p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.checkin_clear(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF (p_template_id IS NULL) = (p_scheduled_task_id IS NULL) THEN
    RAISE EXCEPTION 'checkin needs exactly one of template_id / scheduled_task_id' USING ERRCODE = 'check_violation';
  END IF;
  IF p_template_id IS NOT NULL THEN
    DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date;
  ELSE
    DELETE FROM actual_task WHERE scheduled_task_id = p_scheduled_task_id;
  END IF;
END $function$
;
CREATE OR REPLACE FUNCTION public.actual_save(p_id uuid, p_name text, p_category_id uuid, p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.actual_delete(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  DELETE FROM actual_task WHERE id = p_id;
END $function$
;
CREATE OR REPLACE FUNCTION public.workout_set_delete(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_entry   uuid;
  v_session uuid;
BEGIN
  SET CONSTRAINTS workout_set_entry_id_set_index_key, workout_entry_session_id_sort_order_key DEFERRED;
  DELETE FROM workout_set WHERE id = p_id
    RETURNING entry_id, session_id INTO v_entry, v_session;
  IF FOUND THEN
    UPDATE workout_set s
       SET set_index = r.n
      FROM (SELECT id, row_number() OVER (ORDER BY set_index, id) AS n
              FROM workout_set WHERE entry_id = v_entry) r
     WHERE s.id = r.id AND s.set_index <> r.n;
    IF NOT EXISTS (SELECT 1 FROM workout_set WHERE entry_id = v_entry) THEN
      DELETE FROM workout_entry WHERE id = v_entry;
      UPDATE workout_entry e
         SET sort_order = r.n
        FROM (SELECT id, row_number() OVER (ORDER BY sort_order, id) AS n
                FROM workout_entry WHERE session_id = v_session) r
       WHERE e.id = r.id AND e.sort_order <> r.n;
    END IF;
  END IF;
  -- 関数の終わりで検査を戻す (重複があればここで失敗し、削除ごと取り消される)
  SET CONSTRAINTS workout_set_entry_id_set_index_key, workout_entry_session_id_sort_order_key IMMEDIATE;
END $function$
;
CREATE OR REPLACE FUNCTION public.workout_entry_reorder(p_session uuid, p_entry_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  SET CONSTRAINTS workout_entry_session_id_sort_order_key DEFERRED;
  UPDATE workout_entry e
     SET sort_order = r.n
    FROM (SELECT e2.id,
                 row_number() OVER (ORDER BY (a.ord IS NULL), a.ord, e2.sort_order, e2.id) AS n
            FROM workout_entry e2
            LEFT JOIN (SELECT id, min(ord) AS ord
                         FROM unnest(p_entry_ids) WITH ORDINALITY AS u(id, ord)
                        GROUP BY id) a ON a.id = e2.id
           WHERE e2.session_id = p_session) r
   WHERE e.id = r.id AND e.sort_order <> r.n;
  SET CONSTRAINTS workout_entry_session_id_sort_order_key IMMEDIATE;
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_single_save(p_id uuid, p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_target integer)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_template_create(p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_rrule text, p_show_on_holiday boolean, p_replace_single_id uuid, p_target integer, p_carry_over boolean)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_template_id uuid;
  v_version_id uuid;
BEGIN
  PERFORM schedule_assert_editable(p_date);
  IF p_rrule IS NULL AND NOT p_show_on_holiday THEN
    RAISE EXCEPTION 'series needs weekdays or holiday' USING ERRCODE = 'check_violation';
  END IF;
  -- 系列の id だけを作る (中身は世代に持つ。0013 で旧列を消した)
  INSERT INTO task_template DEFAULT VALUES
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
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_template_save_following(p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_rrule text, p_show_on_holiday boolean, p_target integer, p_carry_over boolean)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_template_end_to_single(p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_target integer)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE v_single uuid;
BEGIN
  v_single := schedule_single_save(NULL, p_date, p_name, p_category_id, p_start, p_duration, p_target);
  UPDATE actual_task
     SET template_id = NULL, scheduled_task_id = v_single
   WHERE template_id = p_template_id AND occurrence_date = p_date;
  PERFORM schedule_template_delete_following(p_template_id, p_date);
  RETURN v_single;
END $function$
;
CREATE OR REPLACE FUNCTION public.schedule_occurrence_save(p_template_id uuid, p_date date, p_pattern_id uuid, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_target integer)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.record_tap_add(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_name text, p_category_id uuid, p_tapped_at timestamp with time zone, p_start timestamp with time zone, p_end timestamp with time zone, p_tap_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.record_tap_remove(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_as_of date)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.record_skip_set(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_name text, p_category_id uuid, p_on date)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.record_skip_clear(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION public.todo_fetch(p_date date, p_from date, p_count_from date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION private.todo_occurrence(p_template_id uuid, p_date date, p_scheduled_task_id uuid, OUT o_date date, OUT o_target integer, OUT o_start timestamp with time zone, OUT o_end timestamp with time zone, OUT o_timed boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION private.todo_target(p_template_id uuid, p_date date, p_scheduled_task_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$ SELECT o_target FROM private.todo_occurrence(p_template_id, p_date, p_scheduled_task_id) $function$
;
CREATE OR REPLACE FUNCTION private.todo_closed_on(p_actual_id uuid)
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION private.schedule_assert_single_editable(p_id uuid, p_new_date date, p_new_untimed boolean)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
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
END $function$
;
CREATE OR REPLACE FUNCTION private.todo_is_open_carried(p_template_id uuid, p_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION private.record_occurrence_checked(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, OUT o_date date, OUT o_target integer, OUT o_start timestamp with time zone, OUT o_end timestamp with time zone, OUT o_timed boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
AS $function$
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
END $function$
;

-- ============================================================
-- k. view
-- ============================================================
ALTER VIEW public.workout_training_day RESET (security_invoker);

-- ============================================================
-- j. 索引
-- ============================================================
DROP INDEX IF EXISTS public.actual_task_tap_user_idx;
DROP INDEX IF EXISTS public.category_user_idx;
DROP INDEX IF EXISTS public.exercise_user_idx;
DROP INDEX IF EXISTS public.pattern_user_idx;
DROP INDEX IF EXISTS public.pattern_version_membership_user_idx;
DROP INDEX IF EXISTS public.routine_user_idx;
DROP INDEX IF EXISTS public.routine_exercise_user_idx;
DROP INDEX IF EXISTS public.task_template_user_idx;
DROP INDEX IF EXISTS public.task_template_exdate_user_idx;
DROP INDEX IF EXISTS public.task_template_version_user_idx;
DROP INDEX IF EXISTS public.workout_entry_user_idx;
DROP INDEX IF EXISTS public.workout_set_completed_at_idx;
DROP INDEX IF EXISTS public.actual_task_occurrence_date_idx;
CREATE INDEX actual_task_occurrence_date_idx ON public.actual_task (occurrence_date);
DROP INDEX IF EXISTS public.scheduled_task_occurrence_date_idx;
CREATE INDEX scheduled_task_occurrence_date_idx ON public.scheduled_task (occurrence_date);
DROP INDEX IF EXISTS public.sleep_record_end_at_idx;
CREATE INDEX sleep_record_end_at_idx ON public.sleep_record (end_at);
DROP INDEX IF EXISTS public.workout_session_started_at_idx;
CREATE INDEX workout_session_started_at_idx ON public.workout_session (started_at DESC);

-- ============================================================
-- i. 種目。exercise_preference の値を exercise に書き戻してから消す (砦で 1 人と確かめてある)
-- ============================================================
DROP VIEW IF EXISTS public.exercise_for_user;
ALTER TABLE public.exercise ADD COLUMN IF NOT EXISTS note text;
ALTER TABLE public.exercise ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;
DO $$
BEGIN
  IF to_regclass('public.exercise_preference') IS NOT NULL THEN
    UPDATE public.exercise e SET is_archived = p.is_archived, note = p.note
    FROM public.exercise_preference p WHERE p.exercise_id = e.id;
  END IF;
END $$;
DROP TABLE IF EXISTS public.exercise_preference;
DROP INDEX IF EXISTS public.exercise_shared_name_unique;
DROP INDEX IF EXISTS public.exercise_user_name_unique;
DROP INDEX IF EXISTS public.exercise_name_unique;
CREATE UNIQUE INDEX exercise_name_unique ON public.exercise (name);
DROP INDEX IF EXISTS public.exercise_muscle_group_idx;
CREATE INDEX exercise_muscle_group_idx ON public.exercise (muscle_group) WHERE is_archived = false;

-- ============================================================
-- h. 1 人前提の形 (D1〜D8・種類の一意)
-- ============================================================
DROP INDEX IF EXISTS public.category_user_kind_unique;

DROP INDEX IF EXISTS public.pattern_apply_day_unique;
CREATE UNIQUE INDEX pattern_apply_day_unique ON public.pattern (apply_day) WHERE apply_day IS NOT NULL;

ALTER TABLE public.sleep_record DROP CONSTRAINT IF EXISTS sleep_record_no_overlap;
ALTER TABLE public.sleep_record
  ADD CONSTRAINT sleep_record_no_overlap EXCLUDE USING gist (tstzrange(start_at, end_at) WITH &&);

DROP INDEX IF EXISTS public.workout_session_single_in_progress;
CREATE UNIQUE INDEX workout_session_single_in_progress ON public.workout_session ((ended_at IS NULL)) WHERE ended_at IS NULL;

ALTER TABLE public.training_goal DROP CONSTRAINT IF EXISTS training_goal_user_id_effective_from_key;
ALTER TABLE public.training_goal DROP CONSTRAINT IF EXISTS training_goal_effective_from_key;
ALTER TABLE public.training_goal ADD CONSTRAINT training_goal_effective_from_key UNIQUE (effective_from);

ALTER TABLE public.day_meta DROP CONSTRAINT IF EXISTS day_meta_pkey;
ALTER TABLE public.day_meta ADD CONSTRAINT day_meta_pkey PRIMARY KEY (date);

ALTER TABLE public.body_weight_record DROP CONSTRAINT IF EXISTS body_weight_record_pkey;
ALTER TABLE public.body_weight_record ADD CONSTRAINT body_weight_record_pkey PRIMARY KEY (recorded_on);

-- プロフィールは 1 行だけの表に戻す (行が 2 つ以上あると主キーで止まる。砦で 1 人と確かめてある)
ALTER TABLE public.user_profile DROP CONSTRAINT IF EXISTS user_profile_pkey;
ALTER TABLE public.user_profile ADD COLUMN IF NOT EXISTS id smallint NOT NULL DEFAULT 1;
ALTER TABLE public.user_profile DROP CONSTRAINT IF EXISTS user_profile_single_chk;
ALTER TABLE public.user_profile ADD CONSTRAINT user_profile_single_chk CHECK (id = 1);
ALTER TABLE public.user_profile ADD CONSTRAINT user_profile_pkey PRIMARY KEY (id);

-- ============================================================
-- g. 外部キーを 1 列に戻し、親の (id, user_id) を消す
-- ============================================================
-- セット → 種目を (entry_id, exercise_id) に戻す (0014 で user_id を足した組にした。SQL レビュー S2)
ALTER TABLE public.workout_set DROP CONSTRAINT IF EXISTS workout_set_entry_fk;
ALTER TABLE public.workout_entry DROP CONSTRAINT IF EXISTS workout_entry_id_exercise_id_key;
ALTER TABLE public.workout_entry ADD CONSTRAINT workout_entry_id_exercise_id_key UNIQUE (id, exercise_id);
ALTER TABLE public.workout_set
  ADD CONSTRAINT workout_set_entry_fk FOREIGN KEY (entry_id, exercise_id) REFERENCES public.workout_entry (id, exercise_id);
ALTER TABLE public.workout_entry DROP CONSTRAINT IF EXISTS workout_entry_id_exercise_id_user_id_key;
ALTER TABLE public.actual_task DROP CONSTRAINT IF EXISTS actual_task_category_id_fkey;
ALTER TABLE public.actual_task ADD CONSTRAINT actual_task_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.category (id) ON DELETE RESTRICT;
ALTER TABLE public.actual_task DROP CONSTRAINT IF EXISTS actual_task_scheduled_task_id_fkey;
ALTER TABLE public.actual_task ADD CONSTRAINT actual_task_scheduled_task_id_fkey FOREIGN KEY (scheduled_task_id) REFERENCES public.scheduled_task (id) ON DELETE SET NULL;
ALTER TABLE public.actual_task DROP CONSTRAINT IF EXISTS actual_task_template_id_fkey;
ALTER TABLE public.actual_task ADD CONSTRAINT actual_task_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.task_template (id) ON DELETE SET NULL;
ALTER TABLE public.actual_task_tap DROP CONSTRAINT IF EXISTS actual_task_tap_actual_task_id_fkey;
ALTER TABLE public.actual_task_tap ADD CONSTRAINT actual_task_tap_actual_task_id_fkey FOREIGN KEY (actual_task_id) REFERENCES public.actual_task (id) ON DELETE CASCADE;
ALTER TABLE public.day_meta DROP CONSTRAINT IF EXISTS day_meta_applied_pattern_id_fkey;
ALTER TABLE public.day_meta ADD CONSTRAINT day_meta_applied_pattern_id_fkey FOREIGN KEY (applied_pattern_id) REFERENCES public.pattern (id) ON DELETE RESTRICT;
ALTER TABLE public.pattern_version_membership DROP CONSTRAINT IF EXISTS pattern_version_membership_pattern_id_fkey;
ALTER TABLE public.pattern_version_membership ADD CONSTRAINT pattern_version_membership_pattern_id_fkey FOREIGN KEY (pattern_id) REFERENCES public.pattern (id) ON DELETE CASCADE;
ALTER TABLE public.pattern_version_membership DROP CONSTRAINT IF EXISTS pattern_version_membership_version_id_fkey;
ALTER TABLE public.pattern_version_membership ADD CONSTRAINT pattern_version_membership_version_id_fkey FOREIGN KEY (version_id) REFERENCES public.task_template_version (id) ON DELETE CASCADE;
ALTER TABLE public.routine_exercise DROP CONSTRAINT IF EXISTS routine_exercise_routine_id_fkey;
ALTER TABLE public.routine_exercise ADD CONSTRAINT routine_exercise_routine_id_fkey FOREIGN KEY (routine_id) REFERENCES public.routine (id) ON DELETE CASCADE;
ALTER TABLE public.scheduled_task DROP CONSTRAINT IF EXISTS scheduled_task_category_id_fkey;
ALTER TABLE public.scheduled_task ADD CONSTRAINT scheduled_task_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.category (id) ON DELETE RESTRICT;
ALTER TABLE public.scheduled_task DROP CONSTRAINT IF EXISTS scheduled_task_pattern_id_fkey;
ALTER TABLE public.scheduled_task ADD CONSTRAINT scheduled_task_pattern_id_fkey FOREIGN KEY (pattern_id) REFERENCES public.pattern (id) ON DELETE RESTRICT;
ALTER TABLE public.scheduled_task DROP CONSTRAINT IF EXISTS scheduled_task_template_id_fkey;
ALTER TABLE public.scheduled_task ADD CONSTRAINT scheduled_task_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.task_template (id) ON DELETE RESTRICT;
ALTER TABLE public.task_template_exdate DROP CONSTRAINT IF EXISTS task_template_exdate_template_id_fkey;
ALTER TABLE public.task_template_exdate ADD CONSTRAINT task_template_exdate_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.task_template (id) ON DELETE CASCADE;
ALTER TABLE public.task_template_version DROP CONSTRAINT IF EXISTS task_template_version_category_id_fkey;
ALTER TABLE public.task_template_version ADD CONSTRAINT task_template_version_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.category (id) ON DELETE RESTRICT;
ALTER TABLE public.task_template_version DROP CONSTRAINT IF EXISTS task_template_version_template_id_fkey;
ALTER TABLE public.task_template_version ADD CONSTRAINT task_template_version_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.task_template (id) ON DELETE CASCADE;
ALTER TABLE public.workout_entry DROP CONSTRAINT IF EXISTS workout_entry_session_id_fkey;
ALTER TABLE public.workout_entry ADD CONSTRAINT workout_entry_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.workout_session (id) ON DELETE CASCADE;
ALTER TABLE public.workout_set DROP CONSTRAINT IF EXISTS workout_set_session_id_fkey;
ALTER TABLE public.workout_set ADD CONSTRAINT workout_set_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.workout_session (id) ON DELETE CASCADE;
ALTER TABLE public.workout_session DROP CONSTRAINT IF EXISTS workout_session_actual_task_id_fkey;
ALTER TABLE public.workout_session ADD CONSTRAINT workout_session_actual_task_id_fkey FOREIGN KEY (actual_task_id) REFERENCES public.actual_task (id) ON DELETE SET NULL;
ALTER TABLE public.workout_session DROP CONSTRAINT IF EXISTS workout_session_routine_id_fkey;
ALTER TABLE public.workout_session ADD CONSTRAINT workout_session_routine_id_fkey FOREIGN KEY (routine_id) REFERENCES public.routine (id) ON DELETE SET NULL;

ALTER TABLE public.category DROP CONSTRAINT IF EXISTS category_id_user_id_key;
ALTER TABLE public.scheduled_task DROP CONSTRAINT IF EXISTS scheduled_task_id_user_id_key;
ALTER TABLE public.task_template DROP CONSTRAINT IF EXISTS task_template_id_user_id_key;
ALTER TABLE public.actual_task DROP CONSTRAINT IF EXISTS actual_task_id_user_id_key;
ALTER TABLE public.pattern DROP CONSTRAINT IF EXISTS pattern_id_user_id_key;
ALTER TABLE public.task_template_version DROP CONSTRAINT IF EXISTS task_template_version_id_user_id_key;
ALTER TABLE public.routine DROP CONSTRAINT IF EXISTS routine_id_user_id_key;
ALTER TABLE public.workout_session DROP CONSTRAINT IF EXISTS workout_session_id_user_id_key;

-- ============================================================
-- d〜f. user_id (auth.users への外部キーも一緒に消える)
-- ============================================================
ALTER TABLE public.actual_task DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.actual_task_tap DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.body_weight_record DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.category DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.day_meta DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.exercise DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.pattern DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.pattern_version_membership DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.routine DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.routine_exercise DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.scheduled_task DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.sleep_record DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.task_template DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.task_template_exdate DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.task_template_version DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.training_goal DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.user_profile DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.workout_entry DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.workout_session DROP COLUMN IF EXISTS user_id;
ALTER TABLE public.workout_set DROP COLUMN IF EXISTS user_id;

-- ============================================================
-- m・b2. 権限を Supabase の既定に戻す (0014 の前の本番の形。service_role は 0014 で触れていない)
-- ============================================================
ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon;

GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA private TO anon;
