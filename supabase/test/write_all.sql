-- 今の人 (request.jwt.claims) で、全 21 表に行を残し、公開の RPC 19 個をすべて呼ぶ (multiuser_test.sql の 1・8・9 が \i で使う)
-- 列に user_id は書かない (アプリと同じ。既定値の auth.uid() で入る)。呼び方は 0006・0007・0012 と SupabaseDayDataSource.swift に合わせた
-- 19 本の組の外部キーのそれぞれに、列が NULL でない子の行が残るようにする (multiuser_test.sql の 5)

SELECT public.ensure_user_defaults() \gset _
SELECT public.jst_today() AS today \gset
SELECT id AS ex FROM public.exercise WHERE user_id IS NULL ORDER BY name LIMIT 1 \gset
INSERT INTO public.category (name) VALUES ('テスト') RETURNING id AS cat \gset
SELECT id AS gym FROM public.category WHERE sub_input_kind = 'gym' \gset
SELECT public.schedule_holiday_pattern_id() AS hol \gset

-- ---------- 筋トレ (9: SET CONSTRAINTS の経路を search_path = '' で) ----------
INSERT INTO public.routine (name) VALUES ('テストのルーティン') RETURNING id AS rt \gset
INSERT INTO public.routine_exercise (routine_id, exercise_id, sort_order) VALUES (:'rt', :'ex', 1);
-- 時刻は今日の 9 時台に固定 (0015 の時刻の窓。now() だと 0 時台に流したとき前の日のセッションになり、日の一意の確かめが揺れる)
INSERT INTO public.workout_session (started_at, routine_id) VALUES ((:'today'::date + time '09:00') AT TIME ZONE 'Asia/Tokyo', :'rt') RETURNING id AS sess \gset
INSERT INTO public.workout_entry (session_id, exercise_id, sort_order) VALUES (:'sess', :'ex', 1) RETURNING id AS e1 \gset
INSERT INTO public.workout_entry (session_id, exercise_id, sort_order) VALUES (:'sess', :'ex', 2) RETURNING id AS e2 \gset
INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at) VALUES (:'sess', :'ex', :'e1', 1, 10, (:'today'::date + time '09:10') AT TIME ZONE 'Asia/Tokyo') RETURNING id AS s1 \gset
INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at) VALUES (:'sess', :'ex', :'e1', 2, 8, (:'today'::date + time '09:12') AT TIME ZONE 'Asia/Tokyo') RETURNING id AS s2 \gset
INSERT INTO public.workout_set (session_id, exercise_id, entry_id, set_index, reps, completed_at) VALUES (:'sess', :'ex', :'e2', 1, 5, (:'today'::date + time '09:14') AT TIME ZONE 'Asia/Tokyo') RETURNING id AS s3 \gset
-- ✓ の取り消し・セットの削除 (残りの set_index が詰まる) → 種目の並べ替え → 最後のセットの削除 (種目ごと消え、順が詰まる)
SELECT public.workout_set_delete(:'s1') \gset _
SELECT test.ok((SELECT set_index FROM public.workout_set WHERE id = :'s2') = 1, 'workout_set_delete: set_index が詰まる');
SELECT public.workout_entry_reorder(:'sess', ARRAY[:'e2', :'e1']::uuid[]) \gset _
SELECT test.ok((SELECT sort_order FROM public.workout_entry WHERE id = :'e2') = 1, 'workout_entry_reorder');
SELECT public.workout_set_delete(:'s2') \gset _
SELECT test.ok(NOT EXISTS (SELECT 1 FROM public.workout_entry WHERE id = :'e1'), 'workout_set_delete: 最後のセットで種目ごと消える');

-- ---------- 種目 (自作と、共有の種目の設定) ----------
INSERT INTO public.exercise (name, muscle_group, metric_kind) VALUES ('テスト種目（自作）', 'chest', 'weight_reps') RETURNING id AS myex \gset
INSERT INTO public.exercise_preference (exercise_id, is_archived, note) VALUES (:'ex', true, 'メモ');

-- ---------- プロフィール・体重・週の目標・睡眠・日のメタ ----------
INSERT INTO public.user_profile (sex, birth_date) VALUES ('male', DATE '1990-01-01');
INSERT INTO public.body_weight_record (recorded_on, weight_kg) VALUES (:'today', 70.5);
INSERT INTO public.training_goal (weekly_target, effective_from) VALUES (3, date_trunc('week', :'today'::date)::date);
INSERT INTO public.sleep_record (start_at, end_at)
VALUES ((:'today'::date - 1 + time '23:00') AT TIME ZONE 'Asia/Tokyo', (:'today'::date + time '07:00') AT TIME ZONE 'Asia/Tokyo');
INSERT INTO public.day_meta (date, applied_pattern_id) VALUES (:'today', :'hol');

-- ---------- 予定 (公開の RPC を全部) ----------
SELECT public.schedule_template_create(:'today'::date, '系列', :'cat', 540, 60, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR', true, NULL, 1, false) AS tpl \gset
SELECT public.schedule_template_save_following(:'tpl', :'today'::date, '系列2', :'cat', 600, 30, 'FREQ=DAILY', true, 1, false) \gset _
SELECT public.schedule_occurrence_save(:'tpl', :'today'::date, :'hol', '回の上書き', :'cat', 600, 45, 1) \gset _
SELECT public.checkin_set(:'tpl', :'today'::date, NULL, 'done', '系列2', :'cat',
                          (:'today'::date + time '10:00') AT TIME ZONE 'Asia/Tokyo',
                          (:'today'::date + time '10:45') AT TIME ZONE 'Asia/Tokyo') \gset _
SELECT public.checkin_set(:'tpl', :'today'::date, NULL, 'skipped', '系列2', :'cat', NULL, NULL) \gset _
SELECT public.checkin_clear(:'tpl', :'today'::date, NULL) \gset _
SELECT public.schedule_occurrence_delete(:'tpl', :'today'::date) \gset _

SELECT public.schedule_single_save(NULL, :'today'::date, '単発', :'cat', 720, 30, 1) AS single \gset
SELECT public.schedule_single_save(:'single', :'today'::date, '単発2', :'cat', 720, 45, 1) \gset _
SELECT public.checkin_set(NULL, NULL, :'single', 'done', '単発2', :'cat',
                          (:'today'::date + time '12:00') AT TIME ZONE 'Asia/Tokyo',
                          (:'today'::date + time '12:45') AT TIME ZONE 'Asia/Tokyo') \gset _
SELECT public.checkin_clear(NULL, NULL, :'single') \gset _
SELECT public.schedule_single_delete(:'single') \gset _

SELECT public.schedule_single_save(NULL, :'today'::date, 'やること', :'cat', NULL, NULL, 2) AS todo1 \gset
SELECT public.record_tap_add(NULL, NULL, :'todo1', 'やること', :'cat', now(), NULL, NULL, gen_random_uuid()) \gset _
SELECT public.record_tap_remove(NULL, NULL, :'todo1', :'today'::date) \gset _
SELECT public.record_skip_set(NULL, NULL, :'todo1', 'やること', :'cat', :'today'::date) \gset _
SELECT public.record_skip_clear(NULL, NULL, :'todo1') \gset _

SELECT public.actual_save(NULL, '実績', :'cat', now() - interval '2 hours', now() - interval '1 hour') AS act \gset
SELECT public.actual_save(:'act', '実績2', :'cat', now() - interval '3 hours', now() - interval '1 hour') \gset _
SELECT public.actual_delete(:'act') \gset _

SELECT public.schedule_single_save(NULL, :'today'::date, '置き換え元', :'cat', 1320, 30, 1) AS single3 \gset
SELECT public.schedule_template_create(:'today'::date, '置き換え先', :'cat', 1320, 30, 'FREQ=DAILY', false, :'single3', 1, false) \gset _
SELECT public.schedule_template_end_to_single(:'tpl', :'today'::date, '単発化', :'cat', 540, 60, 1) \gset _

SELECT public.schedule_template_create(:'today'::date, '系列のやること', :'cat', NULL, NULL, 'FREQ=DAILY', false, NULL, 3, true) AS tpl2 \gset
SELECT public.schedule_template_delete_following(:'tpl2', :'today'::date) \gset _

-- 過去から続く繰り越しの系列 (関数では過去の日に作れないので直接)。タップの実績を残す (actual_task.template_id・actual_task_tap)
INSERT INTO public.task_template DEFAULT VALUES RETURNING id AS tpl4 \gset
INSERT INTO public.task_template_version (template_id, effective_from, name, category_id, rrule, target_count, carry_over)
VALUES (:'tpl4', :'today'::date - 3, '繰り越し', :'cat', 'FREQ=DAILY', 1, true);
SELECT public.schedule_occurrence_delete(:'tpl4', :'today'::date - 1) \gset _
SELECT public.record_tap_add(:'tpl4', :'today'::date - 2, NULL, '繰り越し', :'cat', now(), NULL, NULL, gen_random_uuid()) \gset _
SELECT test.ok(jsonb_typeof(public.todo_fetch(:'today'::date, :'today'::date - 7, :'today'::date - 30)) = 'object', 'todo_fetch');

-- 残す系列: 休日に出す (pattern_version_membership)・その日だけ変えた回に休日のパターン (scheduled_task.pattern_id)・除外日
SELECT public.schedule_template_create(:'today'::date, '残す系列', :'cat', 480, 30, 'FREQ=DAILY', true, NULL, 1, false) AS tpl5 \gset
SELECT public.schedule_occurrence_save(:'tpl5', :'today'::date + 1, :'hol', '残す回', :'cat', 480, 45, 1) \gset _
SELECT public.schedule_occurrence_delete(:'tpl5', :'today'::date + 2) \gset _

-- 残す単発に ✓ (actual_task.scheduled_task_id)。ジムの実績をセッションにつなぐ (workout_session.actual_task_id)
SELECT public.schedule_single_save(NULL, :'today'::date, '残す単発', :'gym', 780, 30, 1) AS single5 \gset
SELECT public.checkin_set(NULL, NULL, :'single5', 'done', '残す単発', :'gym',
                          (:'today'::date + time '13:00') AT TIME ZONE 'Asia/Tokyo',
                          (:'today'::date + time '13:30') AT TIME ZONE 'Asia/Tokyo') AS act5 \gset
UPDATE public.workout_session SET actual_task_id = :'act5' WHERE id = :'sess';

-- 全 21 表に、この人の行がある
SELECT test.all_tables_have_mine();
