-- Life Tracker v2 — 0016 (スミスマシンインクラインベンチプレス) の戻し。番号付きの前進用の migration ではない (supabase/migrations/ の外に置く)
-- 2026-10-23 / 計画: docs/incline-smith-bench-plan.md
--
-- ★ 本人の 10-23 の記録だけをインクラインベンチプレスに戻してから、種目を消す。ほかの記録 (別の日・別の人・プログラム) が
--   この種目に付いていれば、消すところで止まる (外部キー RESTRICT)。そのときは付いた記録をどうするかを先に決める
-- ★ 戻しても supabase_migrations.schema_migrations に 0016 (v2_incline_smith_bench_press) の記録は残る
-- '__OWNER_UID__' は流すときに本人の UID に置き換える (UID は公開の repo に書かない)
-- 流し方: MCP の execute_sql か SQL エディタで 1 回で流す
-- 確かめ: supabase/test/run.sh --rollback 0016 (0015 の後と、0016 → この戻しの後の形が同じ)

WITH target AS (
  SELECT e.id
  FROM public.workout_entry e
  JOIN public.workout_session s ON s.id = e.session_id
  WHERE s.user_id = '__OWNER_UID__'::uuid
    AND s.day = date '2026-10-23'
    AND e.exercise_id = (SELECT id FROM public.exercise WHERE name = 'スミスマシンインクラインベンチプレス' AND user_id IS NULL)
), incline AS (
  SELECT id FROM public.exercise WHERE name = 'インクラインベンチプレス' AND user_id IS NULL
), moved AS (
  UPDATE public.workout_entry SET exercise_id = (SELECT id FROM incline)
  WHERE id IN (SELECT id FROM target)
  RETURNING id
)
UPDATE public.workout_set SET exercise_id = (SELECT id FROM incline)
WHERE entry_id IN (SELECT id FROM moved);

-- 人ごとの設定 (exercise_preference) は ON DELETE CASCADE で一緒に消える
DELETE FROM public.exercise WHERE name = 'スミスマシンインクラインベンチプレス' AND user_id IS NULL;
