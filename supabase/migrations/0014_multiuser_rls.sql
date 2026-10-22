-- Life Tracker v2 — 人ごとのデータ (user_id) と RLS・権限
-- 2026-10-19 / 設計: docs/auth-multiuser-design.md (§1〜§6)・計画: docs/auth-multiuser-implementation-plan.md §1-3 (細部はこちらが正)
-- 適用方法: Supabase MCP apply_migration (name: v2_multiuser_rls) / supabase-cli は使わない
-- 本番適用: 済 (2026-10-23 00:43 JST・段階 3・本人 OK。MCP apply_migration v2_multiuser_rls・version 20261022154341。本番に記録された SQL はこのファイルの UID を置き換えたものと md5 が一致)
--
-- '__OWNER_UID__' は流すときに本人の UID に置き換える (UID は公開の repo に書かない。置き換え忘れは下の DO と ::uuid で止まる)
-- 1 つのトランザクションで流れる (apply_migration は 1 回の SQL を 1 つのトランザクションにする。2026-10-19 probe_txn で確かめた)。
--   BEGIN／COMMIT は書かない。途中で失敗すると全部戻る
-- 大きさ (約 67KB) で apply_migration が通らなければ、ダッシュボードの SQL エディタで 1 回で流す (1 回の問い合わせなので 1 つのトランザクションは保てる)。
--   分けて流さない (途中で止まったときに全部戻らなくなる。計画 §1-3・SQL レビュー S8)
-- 戻し: supabase/rollback/0014_down.sql (本人 1 人しかデータが無いうちだけ安全)
-- 確かめ: supabase/test/run.sh (docker。multiuser_test.sql)
--
-- 新しい migration の決まり (この migration から): 表・view・関数を作ったら GRANT と REVOKE を書き、RLS と policy も同じ migration に書く。
--   既定の権限 (下の b2) で anon には開かないが、それに頼らない
--
-- 順序: btree_gist → 既定の権限 → UID の確かめ → user_id を NULL 可で足す → 本人の UID で埋める → NOT NULL・既定値
--   → 親の (id, user_id) と子の外部キーの組 → 1 人前提の一意を人ごとに → 種目 → 索引 → view → 関数 → 権限 → RLS → v1 の残り
-- ADD COLUMN ... NOT NULL DEFAULT auth.uid() を 1 行で書かない (postgres から見た auth.uid() は NULL で、既存の行が NOT NULL で止まる。設計 §6)

-- ============================================================
-- b. btree_gist (睡眠の重なりを人ごとにする EXCLUDE で uuid の = を gist に載せる。pgcrypto と同じ置き場)
-- ============================================================
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- ============================================================
-- b2. 既定の権限。この後に作る物 (表・view・関数) が最初から閉じた形で作られるように、先に変える
-- 関数は「作るときに PUBLIC に EXECUTE」が組み込みの既定。スキーマ単位 (IN SCHEMA) の既定の権限は組み込みに足し算で重なるだけで
-- PUBLIC の分を消せないので、グローバル (IN SCHEMA なし) で外す (計画レビュー P1・docker で実測)
-- ============================================================
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- ============================================================
-- c. 本人の UID の確かめ (置き換え忘れ・取り違えを、データを変える前に止める)
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '__OWNER_UID__'::uuid) THEN
    RAISE EXCEPTION '0014: owner uid not found in auth.users';
  END IF;
END $$;

-- ============================================================
-- d. user_id を NULL 可で足す (20 表。exercise は共有の行が NULL のまま)
-- ============================================================
ALTER TABLE public.actual_task ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.actual_task_tap ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.body_weight_record ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.category ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.day_meta ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.exercise ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.pattern ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.pattern_version_membership ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.routine ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.routine_exercise ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.scheduled_task ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.sleep_record ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.task_template ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.task_template_exdate ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.task_template_version ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.training_goal ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.user_profile ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.workout_entry ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.workout_session ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.workout_set ADD COLUMN user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;

-- ============================================================
-- e. 今ある行を本人に付ける (exercise を除く 19 表。種目の seed は共有のまま)
-- ============================================================
UPDATE public.actual_task SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.actual_task_tap SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.body_weight_record SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.category SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.day_meta SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.pattern SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.pattern_version_membership SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.routine SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.routine_exercise SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.scheduled_task SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.sleep_record SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.task_template SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.task_template_exdate SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.task_template_version SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.training_goal SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.user_profile SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.workout_entry SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.workout_session SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;
UPDATE public.workout_set SET user_id = '__OWNER_UID__'::uuid WHERE user_id IS NULL;

-- ============================================================
-- f. NOT NULL (19 表) と既定値 auth.uid() (20 表)。アプリと関数の INSERT は user_id を送らずに本人の値が入る
-- ============================================================
ALTER TABLE public.actual_task ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.actual_task_tap ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.body_weight_record ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.category ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.day_meta ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.exercise ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.pattern ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.pattern_version_membership ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.routine ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.routine_exercise ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.scheduled_task ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.sleep_record ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.task_template ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.task_template_exdate ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.task_template_version ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.training_goal ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.user_profile ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.workout_entry ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.workout_session ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.workout_set ALTER COLUMN user_id SET NOT NULL, ALTER COLUMN user_id SET DEFAULT auth.uid();

-- ============================================================
-- g. 親と子の持ち主をそろえる。親 8 表に UNIQUE (id, user_id)、子の外部キー 18 本を (親の id, user_id) の組に作り直す (と workout_set_entry_fk。計 19 本)
-- 名前と削除のときの動きは今と同じ。SET NULL は列を指定する形にして user_id は消さない (PostgreSQL 15 以上)
-- exercise を指す 3 本は今のまま (共有の種目は user_id が NULL で組にできない。設計 §1)。
-- workout_set → workout_entry (workout_set_entry_fk) も (entry_id, exercise_id, user_id) の組にする (下。SQL レビュー S2: セットと種目の
--   session が同じことは DB が検査しないので、組にしないと他人の entry にセットを付けられ、付けられた側が最後のセットを消せなくなる)
-- ============================================================
ALTER TABLE public.category ADD CONSTRAINT category_id_user_id_key UNIQUE (id, user_id);
ALTER TABLE public.scheduled_task ADD CONSTRAINT scheduled_task_id_user_id_key UNIQUE (id, user_id);
ALTER TABLE public.task_template ADD CONSTRAINT task_template_id_user_id_key UNIQUE (id, user_id);
ALTER TABLE public.actual_task ADD CONSTRAINT actual_task_id_user_id_key UNIQUE (id, user_id);
ALTER TABLE public.pattern ADD CONSTRAINT pattern_id_user_id_key UNIQUE (id, user_id);
ALTER TABLE public.task_template_version ADD CONSTRAINT task_template_version_id_user_id_key UNIQUE (id, user_id);
ALTER TABLE public.routine ADD CONSTRAINT routine_id_user_id_key UNIQUE (id, user_id);
ALTER TABLE public.workout_session ADD CONSTRAINT workout_session_id_user_id_key UNIQUE (id, user_id);

ALTER TABLE public.actual_task
  DROP CONSTRAINT actual_task_category_id_fkey,
  ADD CONSTRAINT actual_task_category_id_fkey FOREIGN KEY (category_id, user_id) REFERENCES public.category (id, user_id) ON DELETE RESTRICT;
ALTER TABLE public.actual_task
  DROP CONSTRAINT actual_task_scheduled_task_id_fkey,
  ADD CONSTRAINT actual_task_scheduled_task_id_fkey FOREIGN KEY (scheduled_task_id, user_id) REFERENCES public.scheduled_task (id, user_id) ON DELETE SET NULL (scheduled_task_id);
ALTER TABLE public.actual_task
  DROP CONSTRAINT actual_task_template_id_fkey,
  ADD CONSTRAINT actual_task_template_id_fkey FOREIGN KEY (template_id, user_id) REFERENCES public.task_template (id, user_id) ON DELETE SET NULL (template_id);
ALTER TABLE public.actual_task_tap
  DROP CONSTRAINT actual_task_tap_actual_task_id_fkey,
  ADD CONSTRAINT actual_task_tap_actual_task_id_fkey FOREIGN KEY (actual_task_id, user_id) REFERENCES public.actual_task (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.day_meta
  DROP CONSTRAINT day_meta_applied_pattern_id_fkey,
  ADD CONSTRAINT day_meta_applied_pattern_id_fkey FOREIGN KEY (applied_pattern_id, user_id) REFERENCES public.pattern (id, user_id) ON DELETE RESTRICT;
ALTER TABLE public.pattern_version_membership
  DROP CONSTRAINT pattern_version_membership_pattern_id_fkey,
  ADD CONSTRAINT pattern_version_membership_pattern_id_fkey FOREIGN KEY (pattern_id, user_id) REFERENCES public.pattern (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.pattern_version_membership
  DROP CONSTRAINT pattern_version_membership_version_id_fkey,
  ADD CONSTRAINT pattern_version_membership_version_id_fkey FOREIGN KEY (version_id, user_id) REFERENCES public.task_template_version (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.routine_exercise
  DROP CONSTRAINT routine_exercise_routine_id_fkey,
  ADD CONSTRAINT routine_exercise_routine_id_fkey FOREIGN KEY (routine_id, user_id) REFERENCES public.routine (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.scheduled_task
  DROP CONSTRAINT scheduled_task_category_id_fkey,
  ADD CONSTRAINT scheduled_task_category_id_fkey FOREIGN KEY (category_id, user_id) REFERENCES public.category (id, user_id) ON DELETE RESTRICT;
ALTER TABLE public.scheduled_task
  DROP CONSTRAINT scheduled_task_pattern_id_fkey,
  ADD CONSTRAINT scheduled_task_pattern_id_fkey FOREIGN KEY (pattern_id, user_id) REFERENCES public.pattern (id, user_id) ON DELETE RESTRICT;
ALTER TABLE public.scheduled_task
  DROP CONSTRAINT scheduled_task_template_id_fkey,
  ADD CONSTRAINT scheduled_task_template_id_fkey FOREIGN KEY (template_id, user_id) REFERENCES public.task_template (id, user_id) ON DELETE RESTRICT;
ALTER TABLE public.task_template_exdate
  DROP CONSTRAINT task_template_exdate_template_id_fkey,
  ADD CONSTRAINT task_template_exdate_template_id_fkey FOREIGN KEY (template_id, user_id) REFERENCES public.task_template (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.task_template_version
  DROP CONSTRAINT task_template_version_category_id_fkey,
  ADD CONSTRAINT task_template_version_category_id_fkey FOREIGN KEY (category_id, user_id) REFERENCES public.category (id, user_id) ON DELETE RESTRICT;
ALTER TABLE public.task_template_version
  DROP CONSTRAINT task_template_version_template_id_fkey,
  ADD CONSTRAINT task_template_version_template_id_fkey FOREIGN KEY (template_id, user_id) REFERENCES public.task_template (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.workout_entry
  DROP CONSTRAINT workout_entry_session_id_fkey,
  ADD CONSTRAINT workout_entry_session_id_fkey FOREIGN KEY (session_id, user_id) REFERENCES public.workout_session (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.workout_set
  DROP CONSTRAINT workout_set_session_id_fkey,
  ADD CONSTRAINT workout_set_session_id_fkey FOREIGN KEY (session_id, user_id) REFERENCES public.workout_session (id, user_id) ON DELETE CASCADE;
ALTER TABLE public.workout_session
  DROP CONSTRAINT workout_session_actual_task_id_fkey,
  ADD CONSTRAINT workout_session_actual_task_id_fkey FOREIGN KEY (actual_task_id, user_id) REFERENCES public.actual_task (id, user_id) ON DELETE SET NULL (actual_task_id);
ALTER TABLE public.workout_session
  DROP CONSTRAINT workout_session_routine_id_fkey,
  ADD CONSTRAINT workout_session_routine_id_fkey FOREIGN KEY (routine_id, user_id) REFERENCES public.routine (id, user_id) ON DELETE SET NULL (routine_id);

-- セット → 種目 (今は (entry_id, exercise_id) → workout_entry (id, exercise_id)・削除のときは NO ACTION)。user_id を足した組にし、旧い一意は消す
ALTER TABLE public.workout_entry ADD CONSTRAINT workout_entry_id_exercise_id_user_id_key UNIQUE (id, exercise_id, user_id);
ALTER TABLE public.workout_set
  DROP CONSTRAINT workout_set_entry_fk,
  ADD CONSTRAINT workout_set_entry_fk FOREIGN KEY (entry_id, exercise_id, user_id)
    REFERENCES public.workout_entry (id, exercise_id, user_id);
ALTER TABLE public.workout_entry DROP CONSTRAINT workout_entry_id_exercise_id_key;

-- ============================================================
-- h. 1 人前提の形を人ごとに (設計 §2 D1〜D8・§3)。消すものの種類を間違えない (索引は DROP INDEX・制約は DROP CONSTRAINT)
-- ============================================================
-- D1 プロフィール: id = 1 の 1 行 → 人ごとに 1 行 (DROP COLUMN id で主キーと user_profile_single_chk も消える)
ALTER TABLE public.user_profile DROP COLUMN id;
ALTER TABLE public.user_profile ADD CONSTRAINT user_profile_pkey PRIMARY KEY (user_id);

-- D2 体重: 日ごとに 1 行 → 人と日ごとに 1 行 (アプリの upsert は onConflict: user_id,recorded_on)
ALTER TABLE public.body_weight_record
  DROP CONSTRAINT body_weight_record_pkey,
  ADD CONSTRAINT body_weight_record_pkey PRIMARY KEY (user_id, recorded_on);

-- D3 日のメタ
ALTER TABLE public.day_meta
  DROP CONSTRAINT day_meta_pkey,
  ADD CONSTRAINT day_meta_pkey PRIMARY KEY (user_id, date);

-- D4 週の目標 (アプリの upsert は onConflict: user_id,effective_from。id 列は残す)
ALTER TABLE public.training_goal
  DROP CONSTRAINT training_goal_effective_from_key,
  ADD CONSTRAINT training_goal_user_id_effective_from_key UNIQUE (user_id, effective_from);

-- D5 進行中のセッションは人ごとに 1 件 (部分 UNIQUE は索引で)
DROP INDEX public.workout_session_single_in_progress;
CREATE UNIQUE INDEX workout_session_single_in_progress ON public.workout_session (user_id) WHERE ended_at IS NULL;

-- D6 睡眠の重なりは人ごとに禁止
ALTER TABLE public.sleep_record
  DROP CONSTRAINT sleep_record_no_overlap,
  ADD CONSTRAINT sleep_record_no_overlap EXCLUDE USING gist (user_id WITH =, tstzrange(start_at, end_at) WITH &&);

-- D8 曜日・祝日のパターンは人ごとに 1 件
DROP INDEX public.pattern_apply_day_unique;
CREATE UNIQUE INDEX pattern_apply_day_unique ON public.pattern (user_id, apply_day) WHERE apply_day IS NOT NULL;

-- ジムと睡眠の種類は人ごとに 1 件 (ensure_user_defaults が同時に呼ばれても 2 件にならない砦。設計 §3・M9)
CREATE UNIQUE INDEX category_user_kind_unique ON public.category (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL;

-- ============================================================
-- i. 種目 (設計 §3・M16)。159 件は共有のマスタ (user_id NULL)、自作は人ごと。
-- アーカイブ・メモ・並び順は人ごとの exercise_preference に移し、アプリは view exercise_for_user を読む
-- ============================================================
-- D7 名前の一意は「共有の中で」と「人ごとの中で」
DROP INDEX public.exercise_name_unique;
CREATE UNIQUE INDEX exercise_shared_name_unique ON public.exercise (name) WHERE user_id IS NULL;
CREATE UNIQUE INDEX exercise_user_name_unique ON public.exercise (user_id, name) WHERE user_id IS NOT NULL;

CREATE TABLE public.exercise_preference (
  user_id     uuid    NOT NULL DEFAULT auth.uid() REFERENCES auth.users (id) ON DELETE CASCADE,
  exercise_id uuid    NOT NULL REFERENCES public.exercise (id) ON DELETE CASCADE,
  is_archived boolean NOT NULL DEFAULT false,
  note        text,
  sort_order  integer,                -- NULL = マスタの並び (exercise.sort_order)
  PRIMARY KEY (user_id, exercise_id)
);

-- 今のアーカイブ・メモは本人のもの (本番は 2026-10-19 に全部 false／NULL。写す行は無い見込み)
INSERT INTO public.exercise_preference (user_id, exercise_id, is_archived, note)
SELECT '__OWNER_UID__'::uuid, e.id, e.is_archived, e.note
FROM public.exercise e
WHERE e.is_archived OR e.note IS NOT NULL;

DROP INDEX public.exercise_muscle_group_idx;
ALTER TABLE public.exercise DROP COLUMN is_archived, DROP COLUMN note;
CREATE INDEX exercise_muscle_group_idx ON public.exercise (muscle_group);

-- アプリの Exercise と同じ列の形。結合の条件に本人を入れる (RLS を越える postgres で読んでも人の数だけ行が増えないように。計画 §1-3)
CREATE VIEW public.exercise_for_user WITH (security_invoker = true) AS
SELECT e.id, e.name, e.muscle_group, e.equipment, e.metric_kind,
       p.note,
       COALESCE(p.is_archived, false) AS is_archived,
       COALESCE(p.sort_order, e.sort_order) AS sort_order
FROM public.exercise e
LEFT JOIN public.exercise_preference p
  ON p.exercise_id = e.id AND p.user_id = (SELECT auth.uid());

-- ============================================================
-- j. 索引。全表に user_id が先頭の (部分でない) 索引を置く (RLS の絞り込みと auth.users からの CASCADE のため)。
-- 範囲で読む表は (user_id, 今の列) に作り直す。主キー・一意で足りる表 (体重・日のメタ・週の目標・プロフィール・種目の設定) は足さない
-- ============================================================
DROP INDEX public.actual_task_occurrence_date_idx;
CREATE INDEX actual_task_occurrence_date_idx ON public.actual_task (user_id, occurrence_date);
DROP INDEX public.scheduled_task_occurrence_date_idx;
CREATE INDEX scheduled_task_occurrence_date_idx ON public.scheduled_task (user_id, occurrence_date);
DROP INDEX public.sleep_record_end_at_idx;
CREATE INDEX sleep_record_end_at_idx ON public.sleep_record (user_id, end_at);
DROP INDEX public.workout_session_started_at_idx;
CREATE INDEX workout_session_started_at_idx ON public.workout_session (user_id, started_at DESC);
CREATE INDEX workout_set_completed_at_idx ON public.workout_set (user_id, completed_at);
CREATE INDEX actual_task_tap_user_idx ON public.actual_task_tap (user_id);
CREATE INDEX category_user_idx ON public.category (user_id);
CREATE INDEX exercise_user_idx ON public.exercise (user_id);
CREATE INDEX pattern_user_idx ON public.pattern (user_id);
CREATE INDEX pattern_version_membership_user_idx ON public.pattern_version_membership (user_id);
CREATE INDEX routine_user_idx ON public.routine (user_id);
CREATE INDEX routine_exercise_user_idx ON public.routine_exercise (user_id);
CREATE INDEX task_template_user_idx ON public.task_template (user_id);
CREATE INDEX task_template_exdate_user_idx ON public.task_template_exdate (user_id);
CREATE INDEX task_template_version_user_idx ON public.task_template_version (user_id);
CREATE INDEX workout_entry_user_idx ON public.workout_entry (user_id);

-- ============================================================
-- k. view は呼んだ人の権限で読む (RLS で本人の行だけになる)
-- ============================================================
ALTER VIEW public.workout_training_day SET (security_invoker = true);

-- ============================================================
-- l. 関数 (順 5)
-- ============================================================
-- 関数 28 個を search_path = '' とスキーマ付きの名前で作り直す (設計 §4・計画 §1-3 の l)。
-- 本文は 0013 の後の定義 (pg_get_functiondef) から、名前の修飾と SET CONSTRAINTS の名前だけを変えた

CREATE OR REPLACE FUNCTION public.jst_today()
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path = ''
AS $function$ SELECT (now() AT TIME ZONE 'Asia/Tokyo')::date $function$;

CREATE OR REPLACE FUNCTION public.schedule_holiday_pattern_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path = ''
AS $function$ SELECT id FROM public.pattern WHERE apply_day = 'Holiday' $function$;

CREATE OR REPLACE FUNCTION public.schedule_assert_editable(p_date date)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path = ''
AS $function$
BEGIN
  IF p_date IS NULL OR p_date < public.jst_today() THEN
    RAISE EXCEPTION 'past day is not editable: %', p_date USING ERRCODE = 'check_violation';
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION private.todo_occurrence(p_template_id uuid, p_date date, p_scheduled_task_id uuid, OUT o_date date, OUT o_target integer, OUT o_start timestamp with time zone, OUT o_end timestamp with time zone, OUT o_timed boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path = ''
AS $function$
DECLARE
  v_start_min int;
  v_duration int;
  v_ended boolean;
BEGIN
  IF p_scheduled_task_id IS NOT NULL THEN
    SELECT occurrence_date, target_count, start_at, end_at, start_at IS NOT NULL
      INTO o_date, o_target, o_start, o_end, o_timed
      FROM public.scheduled_task WHERE id = p_scheduled_task_id AND template_id IS NULL;
    RETURN;
  END IF;
  SELECT occurrence_date, target_count, start_at, end_at, start_at IS NOT NULL
    INTO o_date, o_target, o_start, o_end, o_timed
    FROM public.scheduled_task WHERE template_id = p_template_id AND occurrence_date = p_date;
  IF FOUND THEN RETURN; END IF;
  SELECT target_count, start_minutes_from_midnight, duration_minutes, is_ended
    INTO o_target, v_start_min, v_duration, v_ended
    FROM public.task_template_version
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
END $function$;

CREATE OR REPLACE FUNCTION private.todo_target(p_template_id uuid, p_date date, p_scheduled_task_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path = ''
AS $function$ SELECT o_target FROM private.todo_occurrence(p_template_id, p_date, p_scheduled_task_id) $function$;

CREATE OR REPLACE FUNCTION private.todo_closed_on(p_actual_id uuid)
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path = ''
AS $function$
  SELECT LEAST(
           (SELECT (t.tapped_at AT TIME ZONE 'Asia/Tokyo')::date
              FROM public.actual_task_tap t
             WHERE t.actual_task_id = a.id
             ORDER BY t.tapped_at, t.id
            OFFSET g.target - 1
             LIMIT 1),
           CASE WHEN a.status = 'skipped' THEN COALESCE(a.skipped_on, a.occurrence_date) END)
    FROM public.actual_task a
   CROSS JOIN LATERAL (SELECT GREATEST(COALESCE(private.todo_target(a.template_id, a.occurrence_date, a.scheduled_task_id), 1), 1)
                         AS target) g
   WHERE a.id = p_actual_id
$function$;

CREATE OR REPLACE FUNCTION private.todo_is_open_carried(p_template_id uuid, p_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path = ''
AS $function$
  SELECT p_date < public.jst_today()
     AND COALESCE((SELECT o.o_target IS NOT NULL AND NOT o.o_timed
                     FROM private.todo_occurrence(p_template_id, p_date, NULL) o), false)
     AND COALESCE((SELECT v.carry_over AND NOT v.is_ended
                     FROM public.task_template_version v
                    WHERE v.template_id = p_template_id AND v.effective_from <= p_date
                    ORDER BY v.effective_from DESC
                    LIMIT 1), false)
     AND NOT EXISTS (SELECT 1 FROM public.actual_task a
                      WHERE a.template_id = p_template_id AND a.occurrence_date = p_date
                        AND private.todo_closed_on(a.id) < public.jst_today())
$function$;

CREATE OR REPLACE FUNCTION private.schedule_assert_single_editable(p_id uuid, p_new_date date, p_new_untimed boolean)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path = ''
AS $function$
DECLARE
  v_date date;
  v_untimed boolean;
  v_closed date;
BEGIN
  SELECT occurrence_date, start_at IS NULL INTO v_date, v_untimed
    FROM public.scheduled_task WHERE id = p_id AND template_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'single task not found: %', p_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_untimed THEN
    SELECT private.todo_closed_on(a.id) INTO v_closed FROM public.actual_task a WHERE a.scheduled_task_id = p_id;
    IF v_closed IS NULL OR v_closed >= public.jst_today() THEN
      IF p_new_date IS NULL OR p_new_date = v_date THEN
        IF p_new_untimed IS FALSE AND v_date < public.jst_today() THEN
          RAISE EXCEPTION 'timed single needs today or later: %', v_date USING ERRCODE = 'check_violation';
        END IF;
        RETURN;
      END IF;
      IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'closed single cannot change its date: %', p_id USING ERRCODE = 'check_violation';
      END IF;
      IF p_new_date >= public.jst_today() THEN
        RETURN;
      END IF;
      RAISE EXCEPTION 'past day is not editable: %', p_new_date USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  PERFORM public.schedule_assert_editable(v_date);
  PERFORM public.schedule_assert_editable(COALESCE(p_new_date, v_date));
END $function$;

CREATE OR REPLACE FUNCTION private.record_occurrence_checked(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, OUT o_date date, OUT o_target integer, OUT o_start timestamp with time zone, OUT o_end timestamp with time zone, OUT o_timed boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path = ''
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
  IF o_date > public.jst_today() THEN
    RAISE EXCEPTION 'future occurrence cannot be recorded: %', o_date USING ERRCODE = 'check_violation';
  END IF;
  IF o_timed AND o_target = 1 THEN
    RAISE EXCEPTION 'timed occurrence with target 1 uses checkin_set / checkin_clear' USING ERRCODE = 'check_violation';
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_single_delete(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
BEGIN
  PERFORM private.schedule_assert_single_editable(p_id, NULL, NULL);
  DELETE FROM public.actual_task WHERE scheduled_task_id = p_id AND status = 'skipped';
  DELETE FROM public.scheduled_task WHERE id = p_id;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_template_delete_following(p_template_id uuid, p_date date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  v_first date;
  v_version_id uuid;
BEGIN
  PERFORM public.schedule_assert_editable(p_date);
  DELETE FROM public.actual_task WHERE template_id = p_template_id AND occurrence_date >= p_date AND status = 'skipped';
  DELETE FROM public.scheduled_task WHERE template_id = p_template_id AND occurrence_date >= p_date;
  DELETE FROM public.task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
  SELECT min(effective_from) INTO v_first FROM public.task_template_version WHERE template_id = p_template_id;
  IF v_first IS NULL OR v_first >= p_date THEN
    -- 世代・除外日・祝日の登録は CASCADE。done の実績は SET NULL (予定外として残る。時刻なしの done は見えない記録)。
    -- D より前の実体があれば FK (RESTRICT) が止める = 最後の砦
    DELETE FROM public.actual_task WHERE template_id = p_template_id AND status = 'skipped';
    DELETE FROM public.task_template WHERE id = p_template_id;
    RETURN;
  END IF;
  INSERT INTO public.task_template_version (template_id, effective_from, is_ended, name, category_id,
                                     start_minutes_from_midnight, duration_minutes, rrule, target_count, carry_over)
  SELECT template_id, p_date, true, name, category_id, start_minutes_from_midnight, duration_minutes, NULL,
         target_count, carry_over
    FROM public.task_template_version
   WHERE template_id = p_template_id AND effective_from < p_date
   ORDER BY effective_from DESC
   LIMIT 1
  ON CONFLICT (template_id, effective_from) DO UPDATE
    SET is_ended = true, rrule = NULL
  RETURNING id INTO v_version_id;
  DELETE FROM public.pattern_version_membership WHERE version_id = v_version_id;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_occurrence_delete(p_template_id uuid, p_date date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
BEGIN
  IF NOT private.todo_is_open_carried(p_template_id, p_date) THEN
    PERFORM public.schedule_assert_editable(p_date);
  END IF;
  INSERT INTO public.task_template_exdate (template_id, date) VALUES (p_template_id, p_date)
  ON CONFLICT DO NOTHING;
  DELETE FROM public.scheduled_task WHERE template_id = p_template_id AND occurrence_date = p_date;
  DELETE FROM public.actual_task WHERE template_id = p_template_id AND occurrence_date = p_date AND status = 'skipped';
END $function$;

CREATE OR REPLACE FUNCTION public.checkin_set(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_status text, p_name text, p_category_id uuid, p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
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
      FROM public.scheduled_task WHERE id = p_scheduled_task_id AND template_id IS NULL;
    IF v_date IS NULL THEN
      RAISE EXCEPTION 'single task not found: %', p_scheduled_task_id USING ERRCODE = 'no_data_found';
    END IF;
  ELSE
    v_date := p_occurrence_date;
  END IF;
  IF v_date IS NULL OR v_date > public.jst_today() THEN
    RAISE EXCEPTION 'future occurrence cannot be checked in: %', v_date USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF p_status = 'done' AND (v_start IS NULL OR v_end IS NULL OR v_end <= v_start) THEN
    RAISE EXCEPTION 'done needs start and end (end > start)' USING ERRCODE = 'check_violation';
  END IF;

  IF p_template_id IS NOT NULL THEN
    INSERT INTO public.actual_task (name, category_id, status, template_id, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, p_status, p_template_id, v_date, v_start, v_end)
    ON CONFLICT (template_id, occurrence_date) WHERE template_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = EXCLUDED.status,
                  start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at,
                  skipped_on = CASE WHEN EXCLUDED.status = 'skipped' THEN actual_task.skipped_on ELSE NULL END
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.actual_task (name, category_id, status, scheduled_task_id, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, p_status, p_scheduled_task_id, v_date, v_start, v_end)
    ON CONFLICT (scheduled_task_id) WHERE scheduled_task_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = EXCLUDED.status,
                  occurrence_date = EXCLUDED.occurrence_date, start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at,
                  skipped_on = CASE WHEN EXCLUDED.status = 'skipped' THEN actual_task.skipped_on ELSE NULL END
    RETURNING id INTO v_id;
  END IF;
  IF p_status = 'done' AND NOT EXISTS (SELECT 1 FROM public.actual_task_tap WHERE actual_task_id = v_id) THEN
    INSERT INTO public.actual_task_tap (actual_task_id, tapped_at) VALUES (v_id, v_end);
  END IF;
  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.checkin_clear(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
BEGIN
  IF (p_template_id IS NULL) = (p_scheduled_task_id IS NULL) THEN
    RAISE EXCEPTION 'checkin needs exactly one of template_id / scheduled_task_id' USING ERRCODE = 'check_violation';
  END IF;
  IF p_template_id IS NOT NULL THEN
    DELETE FROM public.actual_task WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date;
  ELSE
    DELETE FROM public.actual_task WHERE scheduled_task_id = p_scheduled_task_id;
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.actual_save(p_id uuid, p_name text, p_category_id uuid, p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  v_date date := (p_start AT TIME ZONE 'Asia/Tokyo')::date;
  v_id uuid;
BEGIN
  IF v_date IS NULL OR v_date > public.jst_today() THEN
    RAISE EXCEPTION 'future day cannot be recorded: %', v_date USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.actual_task (name, category_id, status, occurrence_date, start_at, end_at)
    VALUES (p_name, p_category_id, 'done', v_date, p_start, p_end)
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  UPDATE public.actual_task
     SET name = p_name, category_id = p_category_id, start_at = p_start, end_at = p_end,
         occurrence_date = CASE WHEN template_id IS NULL AND scheduled_task_id IS NULL THEN v_date ELSE occurrence_date END
   WHERE id = p_id AND status = 'done'
   RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'actual not found: %', p_id USING ERRCODE = 'no_data_found';
  END IF;
  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.actual_delete(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
BEGIN
  DELETE FROM public.actual_task WHERE id = p_id;
END $function$;

CREATE OR REPLACE FUNCTION public.workout_set_delete(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  v_entry   uuid;
  v_session uuid;
BEGIN
  SET CONSTRAINTS public.workout_set_entry_id_set_index_key, public.workout_entry_session_id_sort_order_key DEFERRED;
  DELETE FROM public.workout_set WHERE id = p_id
    RETURNING entry_id, session_id INTO v_entry, v_session;
  IF FOUND THEN
    UPDATE public.workout_set s
       SET set_index = r.n
      FROM (SELECT id, row_number() OVER (ORDER BY set_index, id) AS n
              FROM public.workout_set WHERE entry_id = v_entry) r
     WHERE s.id = r.id AND s.set_index <> r.n;
    IF NOT EXISTS (SELECT 1 FROM public.workout_set WHERE entry_id = v_entry) THEN
      DELETE FROM public.workout_entry WHERE id = v_entry;
      UPDATE public.workout_entry e
         SET sort_order = r.n
        FROM (SELECT id, row_number() OVER (ORDER BY sort_order, id) AS n
                FROM public.workout_entry WHERE session_id = v_session) r
       WHERE e.id = r.id AND e.sort_order <> r.n;
    END IF;
  END IF;
  -- 関数の終わりで検査を戻す (重複があればここで失敗し、削除ごと取り消される)
  SET CONSTRAINTS public.workout_set_entry_id_set_index_key, public.workout_entry_session_id_sort_order_key IMMEDIATE;
END $function$;

CREATE OR REPLACE FUNCTION public.workout_entry_reorder(p_session uuid, p_entry_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
BEGIN
  SET CONSTRAINTS public.workout_entry_session_id_sort_order_key DEFERRED;
  UPDATE public.workout_entry e
     SET sort_order = r.n
    FROM (SELECT e2.id,
                 row_number() OVER (ORDER BY (a.ord IS NULL), a.ord, e2.sort_order, e2.id) AS n
            FROM public.workout_entry e2
            LEFT JOIN (SELECT id, min(ord) AS ord
                         FROM unnest(p_entry_ids) WITH ORDINALITY AS u(id, ord)
                        GROUP BY id) a ON a.id = e2.id
           WHERE e2.session_id = p_session) r
   WHERE e.id = r.id AND e.sort_order <> r.n;
  SET CONSTRAINTS public.workout_entry_session_id_sort_order_key IMMEDIATE;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_single_save(p_id uuid, p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_target integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
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
    PERFORM public.schedule_assert_editable(p_date);
    INSERT INTO public.scheduled_task (name, category_id, occurrence_date, start_at, end_at, target_count)
    VALUES (p_name, p_category_id, p_date, v_start, v_end, p_target)
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  PERFORM private.schedule_assert_single_editable(p_id, p_date, p_start IS NULL);
  UPDATE public.scheduled_task
     SET name = p_name, category_id = p_category_id, occurrence_date = p_date,
         start_at = v_start, end_at = v_end, target_count = p_target
   WHERE id = p_id;
  UPDATE public.actual_task SET occurrence_date = p_date WHERE scheduled_task_id = p_id AND occurrence_date <> p_date;
  RETURN p_id;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_template_create(p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_rrule text, p_show_on_holiday boolean, p_replace_single_id uuid, p_target integer, p_carry_over boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  v_template_id uuid;
  v_version_id uuid;
BEGIN
  PERFORM public.schedule_assert_editable(p_date);
  IF p_rrule IS NULL AND NOT p_show_on_holiday THEN
    RAISE EXCEPTION 'series needs weekdays or holiday' USING ERRCODE = 'check_violation';
  END IF;
  -- 系列の id だけを作る (中身は世代に持つ。0013 で旧列を消した)
  INSERT INTO public.task_template DEFAULT VALUES
  RETURNING id INTO v_template_id;
  INSERT INTO public.task_template_version (template_id, effective_from, name, category_id,
                                     start_minutes_from_midnight, duration_minutes, rrule, target_count, carry_over)
  VALUES (v_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule, p_target, p_carry_over)
  RETURNING id INTO v_version_id;
  IF p_show_on_holiday THEN
    INSERT INTO public.pattern_version_membership (pattern_id, version_id)
    VALUES (public.schedule_holiday_pattern_id(), v_version_id);
  END IF;
  IF p_replace_single_id IS NOT NULL THEN
    -- 単発の検査はつなぎ直す前に (後だと実績が外れて閉じた日が求まらず、今日より前に閉じた単発も通ってしまう。
    -- 2026-10-14 Swift 側の指摘)。検査は削除と同じ (元の日のまま = p_new_date NULL)
    PERFORM private.schedule_assert_single_editable(p_replace_single_id, NULL, NULL);
    UPDATE public.actual_task
       SET scheduled_task_id = NULL, template_id = v_template_id, occurrence_date = p_date
     WHERE scheduled_task_id = p_replace_single_id;
    PERFORM public.schedule_single_delete(p_replace_single_id);
  END IF;
  RETURN v_template_id;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_template_save_following(p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_rrule text, p_show_on_holiday boolean, p_target integer, p_carry_over boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE v_version_id uuid;
BEGIN
  PERFORM public.schedule_assert_editable(p_date);
  IF p_rrule IS NULL AND NOT p_show_on_holiday THEN
    RAISE EXCEPTION 'series needs weekdays or holiday (use schedule_template_end_to_single)' USING ERRCODE = 'check_violation';
  END IF;
  DELETE FROM public.task_template_version WHERE template_id = p_template_id AND effective_from > p_date;
  -- id を保ったまま書き換える (upsert で id を送ると PK が書き換わる。レビュー §1-1)
  UPDATE public.task_template_version
     SET is_ended = false, name = p_name, category_id = p_category_id,
         start_minutes_from_midnight = p_start, duration_minutes = p_duration, rrule = p_rrule,
         target_count = p_target, carry_over = p_carry_over
   WHERE template_id = p_template_id AND effective_from = p_date
   RETURNING id INTO v_version_id;
  IF v_version_id IS NULL THEN
    INSERT INTO public.task_template_version (template_id, effective_from, name, category_id,
                                       start_minutes_from_midnight, duration_minutes, rrule, target_count, carry_over)
    VALUES (p_template_id, p_date, p_name, p_category_id, p_start, p_duration, p_rrule, p_target, p_carry_over)
    RETURNING id INTO v_version_id;
  END IF;
  DELETE FROM public.pattern_version_membership WHERE version_id = v_version_id;
  IF p_show_on_holiday THEN
    INSERT INTO public.pattern_version_membership (pattern_id, version_id)
    VALUES (public.schedule_holiday_pattern_id(), v_version_id);
  END IF;
  DELETE FROM public.scheduled_task WHERE template_id = p_template_id AND occurrence_date = p_date;
  DELETE FROM public.actual_task a
   USING public.scheduled_task s
   WHERE s.template_id = p_template_id AND s.occurrence_date > p_date AND (s.start_at IS NULL) <> (p_start IS NULL)
     AND a.template_id = p_template_id AND a.occurrence_date = s.occurrence_date AND a.status = 'skipped';
  DELETE FROM public.scheduled_task
   WHERE template_id = p_template_id AND occurrence_date > p_date AND (start_at IS NULL) <> (p_start IS NULL);
  RETURN v_version_id;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_template_end_to_single(p_template_id uuid, p_date date, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_target integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE v_single uuid;
BEGIN
  v_single := public.schedule_single_save(NULL, p_date, p_name, p_category_id, p_start, p_duration, p_target);
  UPDATE public.actual_task
     SET template_id = NULL, scheduled_task_id = v_single
   WHERE template_id = p_template_id AND occurrence_date = p_date;
  PERFORM public.schedule_template_delete_following(p_template_id, p_date);
  RETURN v_single;
END $function$;

CREATE OR REPLACE FUNCTION public.schedule_occurrence_save(p_template_id uuid, p_date date, p_pattern_id uuid, p_name text, p_category_id uuid, p_start integer, p_duration integer, p_target integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  v_start timestamptz := CASE WHEN p_start IS NULL THEN NULL
                              ELSE (p_date + make_interval(mins => p_start)) AT TIME ZONE 'Asia/Tokyo' END;
  v_end timestamptz := v_start + make_interval(mins => p_duration);
  v_version_timed boolean;
  v_id uuid;
BEGIN
  PERFORM public.schedule_assert_editable(p_date);
  IF (p_start IS NULL) <> (p_duration IS NULL) THEN
    RAISE EXCEPTION 'start and duration must be both set or both null' USING ERRCODE = 'check_violation';
  END IF;
  SELECT CASE WHEN is_ended THEN NULL ELSE start_minutes_from_midnight IS NOT NULL END INTO v_version_timed
    FROM public.task_template_version
   WHERE template_id = p_template_id AND effective_from <= p_date
   ORDER BY effective_from DESC
   LIMIT 1;
  IF v_version_timed IS NOT NULL AND v_version_timed <> (p_start IS NOT NULL) THEN
    RAISE EXCEPTION 'occurrence cannot change timed/untimed (use save_following)' USING ERRCODE = 'check_violation';
  END IF;
  UPDATE public.scheduled_task
     SET name = p_name, category_id = p_category_id, pattern_id = p_pattern_id,
         start_at = v_start, end_at = v_end, target_count = p_target
   WHERE template_id = p_template_id AND occurrence_date = p_date
   RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO public.scheduled_task (name, category_id, occurrence_date, start_at, end_at, target_count, template_id, pattern_id)
    VALUES (p_name, p_category_id, p_date, v_start, v_end, p_target, p_template_id, p_pattern_id)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.record_tap_add(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_name text, p_category_id uuid, p_tapped_at timestamp with time zone, p_start timestamp with time zone, p_end timestamp with time zone, p_tap_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  o record;
  v_tap_day date := (p_tapped_at AT TIME ZONE 'Asia/Tokyo')::date;
  v_id uuid;
  v_status text;
BEGIN
  SELECT actual_task_id INTO v_id FROM public.actual_task_tap WHERE id = p_tap_id;
  IF FOUND THEN
    RETURN v_id;
  END IF;
  SELECT * INTO o FROM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF v_tap_day IS NULL OR v_tap_day < o.o_date OR v_tap_day > public.jst_today() THEN
    RAISE EXCEPTION 'tap must be between the occurrence day and today: %', p_tapped_at USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF o.o_timed AND (p_start IS NULL OR p_end IS NULL OR p_end <= p_start) THEN
    RAISE EXCEPTION 'timed occurrence needs planned start and end' USING ERRCODE = 'check_violation';
  END IF;
  IF p_template_id IS NOT NULL THEN
    SELECT id, status INTO v_id, v_status FROM public.actual_task
     WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date;
  ELSE
    SELECT id, status INTO v_id, v_status FROM public.actual_task WHERE scheduled_task_id = p_scheduled_task_id;
  END IF;
  IF v_status = 'skipped' THEN
    RAISE EXCEPTION 'skipped occurrence cannot be tapped (clear the skip first)' USING ERRCODE = 'check_violation';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.actual_task (name, category_id, status, template_id, occurrence_date, scheduled_task_id, start_at, end_at)
    VALUES (p_name, p_category_id, 'done', p_template_id, o.o_date, p_scheduled_task_id,
            CASE WHEN o.o_timed THEN p_start END, CASE WHEN o.o_timed THEN p_end END)
    RETURNING id INTO v_id;
  END IF;
  INSERT INTO public.actual_task_tap (id, actual_task_id, tapped_at) VALUES (COALESCE(p_tap_id, gen_random_uuid()), v_id, p_tapped_at)
  ON CONFLICT (id) DO NOTHING;
  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.record_tap_remove(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_as_of date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  v_id uuid;
  v_status text;
BEGIN
  PERFORM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF p_template_id IS NOT NULL THEN
    SELECT id, status INTO v_id, v_status FROM public.actual_task
     WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date;
  ELSE
    SELECT id, status INTO v_id, v_status FROM public.actual_task WHERE scheduled_task_id = p_scheduled_task_id;
  END IF;
  IF v_id IS NULL THEN RETURN; END IF;
  IF v_status = 'skipped' THEN
    RAISE EXCEPTION 'skipped occurrence cannot be untapped (clear the skip first)' USING ERRCODE = 'check_violation';
  END IF;
  DELETE FROM public.actual_task_tap
   WHERE id = (SELECT id FROM public.actual_task_tap
                WHERE actual_task_id = v_id AND (tapped_at AT TIME ZONE 'Asia/Tokyo')::date <= p_as_of
                ORDER BY tapped_at DESC, id DESC
                LIMIT 1);
  IF NOT EXISTS (SELECT 1 FROM public.actual_task_tap WHERE actual_task_id = v_id) THEN
    DELETE FROM public.actual_task WHERE id = v_id;
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.record_skip_set(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid, p_name text, p_category_id uuid, p_on date)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  o record;
  v_id uuid;
BEGIN
  SELECT * INTO o FROM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF p_on IS NULL OR p_on < o.o_date OR p_on > public.jst_today() THEN
    RAISE EXCEPTION 'skip day must be between the occurrence day and today: %', p_on USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.category WHERE id = p_category_id AND sub_input_kind = 'sleep') THEN
    RAISE EXCEPTION 'sleep is recorded in sleep_record' USING ERRCODE = 'check_violation';
  END IF;
  IF p_template_id IS NOT NULL THEN
    INSERT INTO public.actual_task (name, category_id, status, template_id, occurrence_date, skipped_on)
    VALUES (p_name, p_category_id, 'skipped', p_template_id, o.o_date, p_on)
    ON CONFLICT (template_id, occurrence_date) WHERE template_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = 'skipped',
                  start_at = NULL, end_at = NULL, skipped_on = EXCLUDED.skipped_on
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.actual_task (name, category_id, status, scheduled_task_id, occurrence_date, skipped_on)
    VALUES (p_name, p_category_id, 'skipped', p_scheduled_task_id, o.o_date, p_on)
    ON CONFLICT (scheduled_task_id) WHERE scheduled_task_id IS NOT NULL
    DO UPDATE SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, status = 'skipped',
                  occurrence_date = EXCLUDED.occurrence_date, start_at = NULL, end_at = NULL, skipped_on = EXCLUDED.skipped_on
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.record_skip_clear(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = ''
AS $function$
DECLARE
  o record;
  v_id uuid;
BEGIN
  SELECT * INTO o FROM private.record_occurrence_checked(p_template_id, p_occurrence_date, p_scheduled_task_id);
  IF p_template_id IS NOT NULL THEN
    SELECT id INTO v_id FROM public.actual_task
     WHERE template_id = p_template_id AND occurrence_date = p_occurrence_date AND status = 'skipped';
  ELSE
    SELECT id INTO v_id FROM public.actual_task WHERE scheduled_task_id = p_scheduled_task_id AND status = 'skipped';
  END IF;
  IF v_id IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM public.actual_task_tap WHERE actual_task_id = v_id) THEN
    UPDATE public.actual_task
       SET status = 'done', skipped_on = NULL,
           start_at = CASE WHEN o.o_timed THEN o.o_start END, end_at = CASE WHEN o.o_timed THEN o.o_end END
     WHERE id = v_id;
  ELSE
    DELETE FROM public.actual_task WHERE id = v_id;
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.todo_fetch(p_date date, p_from date, p_count_from date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = ''
AS $function$
  WITH singles AS (
    -- 時刻なしの単発で 回の日 ≤ V かつ 閉じた日が NULL か ≥ V (閉じた日は 1 行に 1 回だけ求める。OFFSET 0 で式の展開を止める)
    SELECT s.*
      FROM public.scheduled_task s
      LEFT JOIN public.actual_task a ON a.scheduled_task_id = s.id
     CROSS JOIN LATERAL (SELECT private.todo_closed_on(a.id) AS closed_on OFFSET 0) c
     WHERE s.template_id IS NULL AND s.start_at IS NULL AND s.occurrence_date <= p_date
       AND (c.closed_on IS NULL OR c.closed_on >= p_date)
  ),
  overrides AS (
    SELECT s.*
      FROM public.scheduled_task s
     WHERE s.template_id IS NOT NULL AND s.start_at IS NULL AND s.occurrence_date BETWEEN p_from AND p_date
  ),
  -- 時刻なしの世代か時刻なしの O を持つ系列 (先に絞る。時刻つきだけの系列の実績で回の中身を求めない。実装後レビュー R8)
  untimed_templates AS (
    SELECT template_id FROM public.task_template_version WHERE start_minutes_from_midnight IS NULL
    UNION
    SELECT template_id FROM public.scheduled_task WHERE template_id IS NOT NULL AND start_at IS NULL
  ),
  -- 時刻なしの系列の回の実績 (回の中身 = O(d) か d に効く世代が時刻なし)
  series_actuals AS (
    SELECT a.*
      FROM public.actual_task a
     CROSS JOIN LATERAL private.todo_occurrence(a.template_id, a.occurrence_date, NULL) o
     WHERE a.template_id IN (SELECT template_id FROM untimed_templates)
       AND a.occurrence_date BETWEEN p_count_from AND p_date
       AND o.o_target IS NOT NULL AND NOT o.o_timed
  ),
  actuals AS (
    SELECT a.* FROM public.actual_task a WHERE a.scheduled_task_id IN (SELECT id FROM singles)
    UNION ALL
    SELECT * FROM series_actuals WHERE occurrence_date >= p_from
  ),
  taps AS (
    SELECT t.*
      FROM public.actual_task_tap t
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
                                FROM public.task_template_exdate x WHERE x.date BETWEEN p_count_from AND p_date), '[]'::jsonb),
    'day_metas',    COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.date)
                                FROM public.day_meta x WHERE x.date BETWEEN p_count_from AND p_date), '[]'::jsonb),
    'older_closed', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.occurrence_date, x.template_id) FROM older_closed x), '[]'::jsonb)
  )
$function$;

-- 新しい人の初期データ (休日パターン・ジムと睡眠の種類)。サインインの直後にアプリが呼ぶ。何度呼んでも同じ結果 (設計 §3)。
-- 名前は本番の今の本人の行と同じ。ON CONFLICT は部分 UNIQUE に合わせて WHERE まで書く (同時に呼ばれても 1 件)
CREATE FUNCTION public.ensure_user_defaults() RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.pattern (name, apply_day) VALUES ('休日', 'Holiday')
  ON CONFLICT (user_id, apply_day) WHERE apply_day IS NOT NULL DO NOTHING;
  INSERT INTO public.category (name, sub_input_kind) VALUES ('ジム', 'gym'), ('睡眠', 'sleep')
  ON CONFLICT (user_id, sub_input_kind) WHERE sub_input_kind IS NOT NULL DO NOTHING;
END $$;

-- ============================================================
-- m. 権限 (設計 §5・計画 §1-3「権限」)。一つずつ並べず ALL ... IN SCHEMA で外す (漏れを防ぐ)。
-- CREATE OR REPLACE は今の権限を保つので、b2 があってもここは要る。service_role は触らない
-- ============================================================
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON ALL TABLES IN SCHEMA public FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.workout_training_day, public.exercise_for_user FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.exercise_preference TO authenticated, service_role;
GRANT SELECT ON public.exercise_for_user TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.ensure_user_defaults() TO authenticated, service_role;

-- private: 公開 RPC の中から呼ばれるので authenticated の USAGE と EXECUTE は残す (0012 の注記)
REVOKE USAGE ON SCHEMA private FROM anon;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon;

-- ============================================================
-- n. RLS (21 表)。policy は 1 表に 1 つ、exercise だけ読みと書きで分ける (共有の行は API からだれも書けない)。計 24
-- ============================================================
ALTER TABLE public.actual_task ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.actual_task_tap ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.body_weight_record ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.category ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.day_meta ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exercise ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pattern ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pattern_version_membership ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.routine ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.routine_exercise ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheduled_task ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sleep_record ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_template_exdate ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_template_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.training_goal ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_entry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_session ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_set ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exercise_preference ENABLE ROW LEVEL SECURITY;

CREATE POLICY own_rows ON public.actual_task FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.actual_task_tap FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.body_weight_record FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.category FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.day_meta FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.pattern FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.pattern_version_membership FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.routine FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.routine_exercise FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.scheduled_task FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.sleep_record FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.task_template FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.task_template_exdate FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.task_template_version FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.training_goal FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.user_profile FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.workout_entry FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.workout_session FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.workout_set FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.exercise_preference FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY exercise_select ON public.exercise FOR SELECT TO authenticated
  USING (user_id IS NULL OR user_id = (SELECT auth.uid()));
CREATE POLICY exercise_insert ON public.exercise FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY exercise_update ON public.exercise FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY exercise_delete ON public.exercise FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ============================================================
-- o. v1 の残りの関数 (SECURITY DEFINER で anon から呼べ、もう無い表を参照している。本番で確かめたシグネチャ)
-- ============================================================
DROP FUNCTION IF EXISTS public.fn_resolve_month_patterns(integer, integer);
DROP FUNCTION IF EXISTS public.sync_did_gym_on_insert();
DROP FUNCTION IF EXISTS public.sync_did_gym_on_delete();
DROP FUNCTION IF EXISTS public.sync_did_study_on_insert();
DROP FUNCTION IF EXISTS public.sync_did_study_on_delete();
DROP FUNCTION IF EXISTS public.update_updated_at();
