-- 人ごとのデータ・RLS・権限の確かめ (計画 §1-5 の 1〜10。11 は 0015 のトレーニングの日。docker で毎回全部流す。本番には流さない)
-- run.sh が 0014 と plpgsql_check の後に流す。この後に checks.sql (10 の残り・11) が続く
-- 人: A・B (残す)、C (8 で作って消す)、本人 '__OWNER_UID__' (run.sh が auth_stub.sql の owner か --owner に置き換える)。人の切り替えは test.become (SET ROLE と request.jwt.claims。設計 §9)
-- 失敗は test.ok / test.fails が例外にし、ON_ERROR_STOP で止まる。結果の行は捨て、見出しだけ出す
\o /dev/null
\set A '00000000-0000-4000-8000-0000000000a1'
\set B '00000000-0000-4000-8000-0000000000b1'
\set C '00000000-0000-4000-8000-0000000000c1'
INSERT INTO auth.users VALUES (:'A'), (:'B'), (:'C');

-- ============================================================
-- 道具 (schema test。最後に消す)
-- ============================================================
CREATE SCHEMA test;
GRANT USAGE ON SCHEMA test TO anon, authenticated;

-- 人を切り替える。NULL = anon、'postgres' の代わりは test.reset()。SET ROLE は関数を出た後も残る
CREATE FUNCTION test.become(p_user uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims',
    CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, false);
  EXECUTE CASE WHEN p_user IS NULL THEN 'SET ROLE anon' ELSE 'SET ROLE authenticated' END;
END $$;
CREATE FUNCTION test.reset() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', false);
END $$;

CREATE FUNCTION test.ok(p_cond boolean, p_msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_msg; END IF;
END $$;

-- p_sql が SQLSTATE p_state で失敗することを確かめる (成功しても、別のエラーでも FAIL)
CREATE FUNCTION test.fails(p_sql text, p_state text, p_msg text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text; v_text text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_text = MESSAGE_TEXT;
    IF v_state = p_state THEN RETURN; END IF;
    RAISE EXCEPTION 'FAIL: % (expected %, got %: %)', p_msg, p_state, v_state, v_text;
  END;
  RAISE EXCEPTION 'FAIL: % (expected %, but succeeded)', p_msg, p_state;
END $$;

-- 文が変えた行の数
CREATE FUNCTION test.affected(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_n bigint;
BEGIN
  EXECUTE p_sql;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE FUNCTION test.n(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_n bigint;
BEGIN
  EXECUTE 'SELECT count(*) FROM (' || p_sql || ') x' INTO v_n;
  RETURN v_n;
END $$;

-- public の表 (21)
CREATE FUNCTION test.tables() RETURNS SETOF text LANGUAGE sql AS $$
  SELECT relname::text FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' ORDER BY 1
$$;

-- 今の人の行が全表にある (write_all.sql の最後)
CREATE FUNCTION test.all_tables_have_mine() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_t text;
BEGIN
  FOR v_t IN SELECT * FROM test.tables() LOOP
    PERFORM test.ok(test.n(format('SELECT 1 FROM public.%I WHERE user_id = auth.uid()', v_t)) > 0, 'no own row in ' || v_t);
  END LOOP;
END $$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA test TO anon, authenticated;

\echo '== 1. A が全表に書く (公開の RPC 19 個を全部・9 の SET CONSTRAINTS の経路を含む)'
SELECT test.become(:'A');
\i /work/test/write_all.sql

\echo '== 3. 既定値: A の書き込みの user_id が全部 A / postgres で user_id を書かない INSERT は 23502'
SELECT test.reset();
DO $$
DECLARE v_t text;
BEGIN
  FOR v_t IN SELECT * FROM test.tables() LOOP
    PERFORM test.ok(test.n(format('SELECT 1 FROM public.%I WHERE user_id IS NOT NULL AND user_id NOT IN (%L::uuid, %L::uuid)',
                                  v_t, '00000000-0000-4000-8000-0000000000a1', '__OWNER_UID__')) = 0,
                    'rows of an unexpected user in ' || v_t);
  END LOOP;
END $$;
SELECT test.fails($$INSERT INTO public.category (name) VALUES ('x')$$, '23502', 'postgres の user_id の入れ忘れ');

\echo '== 1. B からは A の行が見えず、変えられない'
SELECT test.become(:'B');
DO $$
DECLARE v_t text;
BEGIN
  FOR v_t IN SELECT * FROM test.tables() LOOP
    IF v_t = 'exercise' THEN
      PERFORM test.ok(test.n('SELECT 1 FROM public.exercise WHERE user_id IS NOT NULL') = 0, 'B sees custom exercise');
    ELSE
      PERFORM test.ok(test.n(format('SELECT 1 FROM public.%I', v_t)) = 0, 'B sees rows in ' || v_t);
    END IF;
    PERFORM test.ok(test.affected(format('UPDATE public.%I SET user_id = user_id', v_t)) = 0, 'B updates rows in ' || v_t);
    PERFORM test.ok(test.affected(format('DELETE FROM public.%I', v_t)) = 0, 'B deletes rows in ' || v_t);
  END LOOP;
  PERFORM test.ok(test.n('SELECT 1 FROM public.workout_training_day') = 0, 'B sees workout_training_day');
  PERFORM test.ok(test.n('SELECT 1 FROM public.exercise_for_user WHERE name = ''テスト種目（自作）''') = 0, 'B sees A''s custom exercise in the view');
  PERFORM test.ok(test.n('SELECT 1 FROM public.exercise_for_user WHERE is_archived OR note IS NOT NULL') = 0, 'A''s preference leaks into B''s view');
END $$;
-- A からは見える (B の DELETE で消えていない)
SELECT test.become(:'A');
SELECT test.all_tables_have_mine();
SELECT test.ok((SELECT count(*) FROM public.workout_training_day) = 1, 'A の workout_training_day');

\echo '== 1. A は自分の行を B に渡せない (RLS の WITH CHECK。UPDATE で書き換える・INSERT で B を明示する)'
SELECT test.become(:'A');
DO $$
DECLARE v_t text;
BEGIN
  FOR v_t IN SELECT * FROM test.tables() LOOP
    PERFORM test.fails(format('UPDATE public.%I SET user_id = %L WHERE user_id = auth.uid()', v_t, '00000000-0000-4000-8000-0000000000b1'),
                       '42501', 'A gives own rows to B in ' || v_t);
  END LOOP;
  -- 自作の種目を共有に (user_id を NULL に) もできない
  PERFORM test.fails('UPDATE public.exercise SET user_id = NULL WHERE user_id = auth.uid()', '42501', 'A makes own exercise shared');
END $$;
SELECT test.fails(format('INSERT INTO public.category (name, user_id) VALUES (%L, %L)', 'B のふり', :'B'), '42501', 'A inserts a row for B');
SELECT test.fails(format('INSERT INTO public.sleep_record (start_at, end_at, user_id) VALUES (now() - interval ''30 days'', now() - interval ''29 days 20 hours'', %L)', :'B'),
                  '42501', 'A inserts a sleep record for B');

\echo '== 2. anon: 全表・view の SELECT と全関数が 42501'
-- 前提: anon は public の USAGE を持つ (無いと、表・関数の権限ではなくスキーマで 42501 になり、確かめにならない。SQL レビュー S4)
SELECT test.reset();
SELECT test.ok(has_schema_privilege('anon', 'public', 'USAGE'), 'stub: anon に public の USAGE');
SELECT test.become(NULL);
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT relname FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'v') LOOP
    PERFORM test.fails(format('SELECT 1 FROM public.%I LIMIT 1', r.relname), '42501', 'anon select ' || r.relname);
  END LOOP;
  FOR r IN
    SELECT format('SELECT %I.%I(%s)', n.nspname, p.proname,
                  (SELECT string_agg('NULL::' || format_type(t, NULL), ', ') FROM unnest(p.proargtypes) t)) AS call
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'private')
  LOOP
    PERFORM test.fails(r.call, '42501', 'anon ' || r.call);
  END LOOP;
END $$;

-- 5 は 4 より前に流す (4 で B が同じ日の day_meta・進行中のセッションを持つと、ここの UPDATE が外部キーより先に一意で止まる)
\echo '== 5. 持ち主の食い違い: 子の行の user_id を B にすると外部キーで止まる (19 本)'
SELECT test.reset();
DO $$
DECLARE
  r record;
  v_ctid tid;
  v_state text;
  v_con text;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT c.conrelid::regclass AS child, c.conname,
           (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]) AS col
    FROM pg_constraint c
    JOIN pg_attribute u ON u.attrelid = c.conrelid AND u.attname = 'user_id'
    WHERE c.connamespace = 'public'::regnamespace AND c.contype = 'f'
      AND c.confrelid <> 'auth.users'::regclass AND u.attnum = ANY (c.conkey)
  LOOP
    EXECUTE format('SELECT ctid FROM %s WHERE user_id = %L AND %I IS NOT NULL LIMIT 1',
                   r.child, '00000000-0000-4000-8000-0000000000a1', r.col) INTO v_ctid;
    PERFORM test.ok(v_ctid IS NOT NULL, 'no A row for ' || r.conname);
    BEGIN
      -- この外部キー以外を一時的に外さずに確かめるため、失敗した制約の名前は問わない (どれかの組で止まればよい)。
      -- 19 本すべてが user_id を含む組であることは checks.sql が見る
      EXECUTE format('UPDATE %s SET user_id = %L WHERE ctid = %L', r.child, '00000000-0000-4000-8000-0000000000b1', v_ctid);
      RAISE EXCEPTION 'FAIL: % accepted a row pointing to another user''s parent', r.conname;
    EXCEPTION WHEN foreign_key_violation THEN
      v_n := v_n + 1;
    END;
  END LOOP;
  PERFORM test.ok(v_n = 19, format('composite fks tested: %s', v_n));
END $$;
-- 親の側からも: A の種類を B に移すと、A の子が指したままなので止まる
SELECT test.fails(format('UPDATE public.category SET user_id = %L WHERE name = %L AND user_id = %L', :'B', 'テスト', :'A'), '23503', 'A の親を B に移す');

\echo '== 4. 一意と重なりは人ごと (B は A と同じ物を持てる。A の中では今までどおりぶつかる)'
SELECT test.become(:'B');
SELECT public.ensure_user_defaults();
SELECT public.jst_today() AS today \gset
INSERT INTO public.body_weight_record (recorded_on, weight_kg) VALUES (:'today', 60);
INSERT INTO public.day_meta (date) VALUES (:'today');
INSERT INTO public.training_goal (weekly_target, effective_from) VALUES (2, date_trunc('week', :'today'::date)::date);
INSERT INTO public.sleep_record (start_at, end_at)
VALUES ((:'today'::date - 1 + time '23:30') AT TIME ZONE 'Asia/Tokyo', (:'today'::date + time '06:30') AT TIME ZONE 'Asia/Tokyo');
-- B のセッションは昨日の 20 時 (0015 の時刻の窓: 下の昨日のセットがこのセッションの日の中に入るように)
INSERT INTO public.workout_session (started_at) VALUES ((:'today'::date - 1 + time '20:00') AT TIME ZONE 'Asia/Tokyo');
INSERT INTO public.user_profile (sex, birth_date) VALUES ('female', DATE '1995-05-05');
SELECT test.ok((SELECT count(*) FROM public.pattern WHERE apply_day = 'Holiday') = 1, 'B の休日パターン');
SELECT test.ok((SELECT count(*) FROM public.category WHERE sub_input_kind IS NOT NULL) = 2, 'B のジムと睡眠');
-- B にも昨日のセットを 1 つ。A の workout_training_day にその日が出ない (view の分離。SQL レビュー S9)
SELECT id AS b_sess FROM public.workout_session WHERE ended_at IS NULL \gset
SELECT id AS b_ex FROM public.exercise WHERE user_id IS NULL ORDER BY name LIMIT 1 \gset
INSERT INTO public.workout_entry (session_id, exercise_id, sort_order) VALUES (:'b_sess', :'b_ex', 1) RETURNING id AS b_entry \gset
INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at)
VALUES (:'b_sess', :'b_ex', :'b_entry', 1, 5, (:'today'::date - 1 + time '20:30') AT TIME ZONE 'Asia/Tokyo');
SELECT test.ok((SELECT count(*) FROM public.workout_training_day) = 1, 'B の workout_training_day は昨日だけ');
SELECT test.become(:'A');
SELECT test.fails(format('INSERT INTO public.body_weight_record (recorded_on, weight_kg) VALUES (%L, 61)', :'today'), '23505', 'A の同じ日の体重');
SELECT test.fails(format('INSERT INTO public.day_meta (date) VALUES (%L)', :'today'), '23505', 'A の同じ日の day_meta');
SELECT test.fails(format('INSERT INTO public.training_goal (weekly_target, effective_from) VALUES (4, %L)', date_trunc('week', :'today'::date)::date), '23505', 'A の同じ週の目標');
SELECT test.fails($$INSERT INTO public.pattern (name, apply_day) VALUES ('休日2', 'Holiday')$$, '23505', 'A の 2 つ目の休日パターン');
SELECT test.fails($$INSERT INTO public.category (name, sub_input_kind) VALUES ('ジム2', 'gym')$$, '23505', 'A の 2 つ目のジム');
SELECT test.fails(format('INSERT INTO public.sleep_record (start_at, end_at) VALUES (%L::timestamptz, %L::timestamptz)',
                         (:'today'::date + time '01:00') AT TIME ZONE 'Asia/Tokyo', (:'today'::date + time '02:00') AT TIME ZONE 'Asia/Tokyo'),
                  '23P01', 'A の睡眠の重なり');
SELECT test.fails(format('INSERT INTO public.workout_session (started_at) VALUES (%L::timestamptz)', (:'today'::date + time '10:00') AT TIME ZONE 'Asia/Tokyo'),
                  '23505', 'A の同じ日の 2 つ目のセッション');
SELECT test.ok((SELECT count(*) FROM public.workout_training_day) = 1
               AND NOT EXISTS (SELECT 1 FROM public.workout_training_day WHERE day = :'today'::date - 1), 'A の view に B の昨日が出ない');
-- B のセットを A の entry に付けられない (workout_set_entry_fk の組。SQL レビュー S2)
SELECT id AS a_entry FROM public.workout_entry LIMIT 1 \gset
SELECT test.become(:'B');
SELECT test.fails(format('INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps) VALUES (%L, %L, %L, 9, 1)',
                         :'b_sess', :'ex', :'a_entry'), '23503', 'B のセットを A の entry に付ける');
SELECT test.become(:'A');
SELECT test.fails($$INSERT INTO public.user_profile (sex, birth_date) VALUES ('male', DATE '2000-01-01')$$, '23505', 'A の 2 つ目のプロフィール');

\echo '== 6. upsert (アプリと同じく user_id を送らず ON CONFLICT)。2 回目は更新'
SELECT test.become(:'A');
INSERT INTO public.user_profile (sex, birth_date) VALUES ('male', DATE '1991-02-02')
ON CONFLICT (user_id) DO UPDATE SET sex = EXCLUDED.sex, birth_date = EXCLUDED.birth_date;
INSERT INTO public.body_weight_record (recorded_on, weight_kg) VALUES (:'today', 71.25)
ON CONFLICT (user_id, recorded_on) DO UPDATE SET weight_kg = EXCLUDED.weight_kg;
INSERT INTO public.training_goal (weekly_target, effective_from) VALUES (5, date_trunc('week', :'today'::date)::date)
ON CONFLICT (user_id, effective_from) DO UPDATE SET weekly_target = EXCLUDED.weekly_target;
SELECT test.ok((SELECT count(*) = 1 AND bool_and(birth_date = DATE '1991-02-02') FROM public.user_profile), 'upsert プロフィール');
SELECT test.ok((SELECT count(*) = 1 AND bool_and(weight_kg = 71.25) FROM public.body_weight_record), 'upsert 体重');
SELECT test.ok((SELECT count(*) = 1 AND bool_and(weekly_target = 5) FROM public.training_goal), 'upsert 週の目標');
SELECT test.become(:'B');
SELECT test.ok((SELECT bool_and(weight_kg = 60) FROM public.body_weight_record), 'A の upsert が B に効かない');

\echo '== 7. 種目: 共有は全員に見え、設定と自作は人ごと。共有の行は API から書けない'
SELECT test.reset();
SELECT count(*) AS shared FROM public.exercise WHERE user_id IS NULL \gset
SELECT test.ok(:shared >= 159, 'shared exercises');
SELECT test.become(:'A');
SELECT test.ok((SELECT count(*) FROM public.exercise_for_user) = :shared + 1, 'A の view = 共有 + 自作');
SELECT test.ok((SELECT count(*) FROM public.exercise_for_user WHERE is_archived AND note = 'メモ') = 1, 'A の view にアーカイブとメモ');
SELECT test.fails(format('INSERT INTO public.exercise_preference (user_id, exercise_id) VALUES (%L, %L)', :'B', :'ex'), '42501', 'A が B の設定を書く');
SELECT test.become(:'B');
SELECT test.ok((SELECT count(*) FROM public.exercise_for_user) = :shared, 'B の view = 共有だけ');
SELECT test.fails($$INSERT INTO public.exercise (name, muscle_group, metric_kind, user_id) VALUES ('共有に足す', 'chest', 'weight_reps', NULL)$$, '42501', '共有の種目を足す');
SELECT test.ok(test.affected('UPDATE public.exercise SET name = name') = 0, '共有の種目を変える');
SELECT test.ok(test.affected('DELETE FROM public.exercise') = 0, '共有の種目を消す');
-- 自作は B も同じ名前で持てる (人ごとの一意)。共有の名前とは別の一意
INSERT INTO public.exercise (name, muscle_group, metric_kind) VALUES ('テスト種目（自作）', 'back', 'reps_only');
SELECT test.fails($$INSERT INTO public.exercise (name, muscle_group, metric_kind) VALUES ('テスト種目（自作）', 'back', 'reps_only')$$, '23505', 'B の同じ名前の自作');

\echo '== 8. ensure_user_defaults と、人を消したときの CASCADE'
SELECT test.become(:'C');
SELECT public.ensure_user_defaults();
SELECT test.ok((SELECT count(*) FROM public.pattern) + (SELECT count(*) FROM public.category) = 3, 'C の初期データ 3 行');
SELECT public.ensure_user_defaults();
SELECT test.ok((SELECT count(*) FROM public.pattern) + (SELECT count(*) FROM public.category) = 3, 'C の 2 回目で増えない');
-- 本人 (付け替え済み) では休日パターンが増えない
SELECT test.become('__OWNER_UID__');
SELECT public.ensure_user_defaults();
SELECT test.ok((SELECT count(*) FROM public.pattern WHERE apply_day = 'Holiday') = 1, '本人の休日パターンが 1 件のまま');
-- C が全表に書いてから、auth.users から消す → C の行が全表で 0 (子の RESTRICT の組があっても止まらない)
SELECT test.become(:'C');
\i /work/test/write_all.sql
SELECT test.reset();
DELETE FROM auth.users WHERE id = :'C';
DO $$
DECLARE v_t text;
BEGIN
  FOR v_t IN SELECT * FROM test.tables() LOOP
    PERFORM test.ok(test.n(format('SELECT 1 FROM public.%I WHERE user_id = %L', v_t, '00000000-0000-4000-8000-0000000000c1')) = 0,
                    'C rows left in ' || v_t);
  END LOOP;
END $$;

\echo '== 10. 既定の権限: これから作る関数と表が anon に開かない (捨ての物を作って消す)'
SELECT test.reset();
BEGIN;
CREATE FUNCTION public._probe_default_acl() RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE TABLE public._probe_default_acl (x int);
SELECT test.ok(NOT EXISTS (SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
                           WHERE p.oid = 'public._probe_default_acl()'::regprocedure AND a.grantee = 0)
               AND (SELECT proacl IS NOT NULL FROM pg_proc WHERE oid = 'public._probe_default_acl()'::regprocedure),
               '新しい関数に PUBLIC の EXECUTE が無い');
SELECT test.ok(NOT has_function_privilege('anon', 'public._probe_default_acl()', 'EXECUTE'), '新しい関数を anon が呼べない');
SELECT test.ok(has_function_privilege('authenticated', 'public._probe_default_acl()', 'EXECUTE'), '新しい関数を authenticated が呼べる');
SELECT test.ok(NOT has_table_privilege('anon', 'public._probe_default_acl', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'), '新しい表に anon の権限が無い');
SELECT test.ok(has_table_privilege('authenticated', 'public._probe_default_acl', 'SELECT')
               AND NOT has_table_privilege('authenticated', 'public._probe_default_acl', 'TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'),
               '新しい表は authenticated に読み書きだけ');
ROLLBACK;

\echo '== 11. トレーニングの日 (0015): 日はトリガーが埋める・前の日に翌日 2:00 まで・1 人 1 日 1 つ・日と種目 1 回分の食い違い'
SELECT test.become(:'A');
-- D = 10 日前 (A のほかのセッションと重ならない日)。D の 20:00 に始め、日を送らない → D
SELECT (:'today'::date - 10) AS d \gset
INSERT INTO public.workout_session (started_at) VALUES ((:'d'::date + time '20:00') AT TIME ZONE 'Asia/Tokyo') RETURNING id AS d_sess, day AS d_day \gset
SELECT test.ok(:'d_day'::date = :'d'::date, 'セッションの日をトリガーが started_at の JST の日で埋める');
INSERT INTO public.workout_entry (session_id, exercise_id, sort_order) VALUES (:'d_sess', :'ex', 1) RETURNING id AS d_entry \gset
-- 翌日の 0:30 に D へ ✓ (日を送らない → セッションの日)。view は D を返し、D+1 は返さない
INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at)
VALUES (:'d_sess', :'ex', :'d_entry', 1, 5, (:'d'::date + 1 + time '00:30') AT TIME ZONE 'Asia/Tokyo') RETURNING day AS d_set_day \gset
SELECT test.ok(:'d_set_day'::date = :'d'::date, 'セットの日をトリガーがセッションの日で埋める');
SELECT test.ok(EXISTS (SELECT 1 FROM public.workout_training_day WHERE day = :'d'::date)
               AND NOT EXISTS (SELECT 1 FROM public.workout_training_day WHERE day = :'d'::date + 1), '0:30 のセットは前の日として view に出る');
-- セットの窓: 翌日 1:59:59 は通り、翌日 2:00 ちょうどと D の 0:00 より前は 23514
INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at)
VALUES (:'d_sess', :'ex', :'d_entry', 2, 5, (:'d'::date + 1 + time '01:59:59') AT TIME ZONE 'Asia/Tokyo');
SELECT test.fails(format('INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at) VALUES (%L, %L, %L, 3, 5, %L::timestamptz)',
                         :'d_sess', :'ex', :'d_entry', (:'d'::date + 1 + time '02:00') AT TIME ZONE 'Asia/Tokyo'), '23514', '翌日 2:00 のセット');
SELECT test.fails(format('INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at) VALUES (%L, %L, %L, 3, 5, %L::timestamptz)',
                         :'d_sess', :'ex', :'d_entry', ((:'d'::date + time '00:00') AT TIME ZONE 'Asia/Tokyo') - interval '1 second'), '23514', 'D の 0:00 より前のセット');
-- セッションの窓: 前の日 (D-1) を送って D の 1:59 に始めるのは通り (送った日は変えない)、D-2 を送って D-1 の 2:00 に始めるのは 23514
INSERT INTO public.workout_session (day, started_at) VALUES (:'d'::date - 1, (:'d'::date + time '01:59') AT TIME ZONE 'Asia/Tokyo') RETURNING id AS p_sess, day AS p_day \gset
SELECT test.ok(:'p_day'::date = :'d'::date - 1, '送った日はトリガーが変えない');
SELECT test.fails(format('INSERT INTO public.workout_session (day, started_at) VALUES (%L, %L::timestamptz)',
                         :'d'::date - 2, (:'d'::date - 1 + time '02:00') AT TIME ZONE 'Asia/Tokyo'), '23514', '翌日 2:00 に始める前の日のセッション');
-- 1 人 1 日 1 つ。前の日と今日は同時に開いていてよい
SELECT test.fails(format('INSERT INTO public.workout_session (started_at) VALUES (%L::timestamptz)', (:'d'::date + time '22:00') AT TIME ZONE 'Asia/Tokyo'),
                  '23505', '同じ日の 2 つ目のセッション');
SELECT test.ok((SELECT count(*) FROM public.workout_session WHERE ended_at IS NULL AND id IN (:'d_sess', :'p_sess')) = 2, '前の日と今日のセッションが同時に開いている');
-- 食い違い: セットの日 ≠ セッションの日・前の日のセッションのセットを D の種目 1 回分に付ける → 外部キーで 23503 (どちらも窓の中の時刻)
SELECT test.fails(format('INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at, day) VALUES (%L, %L, %L, 3, 5, %L::timestamptz, %L)',
                         :'d_sess', :'ex', :'d_entry', (:'d'::date + time '01:00') AT TIME ZONE 'Asia/Tokyo', :'d'::date - 1), '23503', 'セットの日がセッションの日と違う');
SELECT test.fails(format('INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at) VALUES (%L, %L, %L, 3, 5, %L::timestamptz)',
                         :'p_sess', :'ex', :'d_entry', (:'d'::date + time '01:00') AT TIME ZONE 'Asia/Tokyo'), '23503', '別の日のセッションのセットを D の種目 1 回分に付ける');
-- B は A のセッションの日を読めない (トリガーは呼んだ人の権限) → 日が埋まらず 23502
SELECT test.become(:'B');
SELECT test.fails(format('INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at) VALUES (%L, %L, %L, 9, 1, %L::timestamptz)',
                         :'d_sess', :'ex', :'d_entry', (:'d'::date + time '21:00') AT TIME ZONE 'Asia/Tokyo'), '23502', 'B のセットを A のセッションに付ける');
-- postgres (MCP の手入力) でも日が埋まる
SELECT test.reset();
INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at, user_id)
VALUES (:'d_sess', :'ex', :'d_entry', 3, 5, (:'d'::date + time '21:00') AT TIME ZONE 'Asia/Tokyo', :'A') RETURNING day AS pg_set_day \gset
SELECT test.ok(:'pg_set_day'::date = :'d'::date, 'postgres の書き込みでも日が埋まる');

-- 後片付け (A・B の行は残す。checks.sql が「user_id が NULL なのは共有の種目だけ」を見る)
SET client_min_messages = warning;
DROP SCHEMA test CASCADE;
RESET client_min_messages;
\o
\echo '== multiuser_test: 全部通った'
