-- Life Tracker v2 — 種目「スミスマシンインクラインベンチプレス」を足し、本人の 10-23 のインクラインベンチプレスをそれに付け替える
-- 2026-10-23 / 計画: docs/incline-smith-bench-plan.md
-- 適用方法: Supabase MCP apply_migration (name: v2_incline_smith_bench_press) / supabase-cli は使わない。1 つのトランザクションで流れる (BEGIN／COMMIT は書かない)
-- 本番適用: 済 (2026-10-23 05:06 JST・本人「それで進めて。…migrationもして。」。MCP apply_migration v2_incline_smith_bench_press・version 20261022200634。本番に記録された SQL はこのファイルの UID を置き換えたものと md5 が一致 (389a1f89…))
-- 戻し: supabase/rollback/0016_down.sql
-- 確かめ: supabase/test/run.sh (docker)。本番の写しのリハーサルは --grow exercise=1
--
-- '__OWNER_UID__' は流すときに本人の UID に置き換える (UID は公開の repo に書かない。置き換え忘れは ::uuid で止まる)
-- 本人 (2026-10-23): 「今日のインクラインベンチの記録はスミスマシンでのものだからmigrationもして。」

-- ============================================================
-- 共有の種目を 1 件足す (胸の最後。画像のアセット名が sort_order に結びついているので、104 の隣にするための振り直しはしない)
-- ============================================================
INSERT INTO public.exercise (name, muscle_group, equipment, metric_kind, sort_order, user_id)
VALUES ('スミスマシンインクラインベンチプレス', 'chest', 'machine', 'weight_reps', 120, NULL);

-- ============================================================
-- 本人の 10-23 のセッションのインクラインベンチプレスを付け替える (entry の id はそのまま)
-- workout_set_entry_fk (entry_id, session_id, exercise_id, user_id) は DEFERRABLE でないので、entry とセットを 1 つの文で替える
-- (外部キーの確かめは文の終わり)
-- ============================================================
WITH target AS (
  SELECT e.id
  FROM public.workout_entry e
  JOIN public.workout_session s ON s.id = e.session_id
  WHERE s.user_id = '__OWNER_UID__'::uuid
    AND s.day = date '2026-10-23'
    AND e.exercise_id = (SELECT id FROM public.exercise WHERE name = 'インクラインベンチプレス' AND user_id IS NULL)
), smith AS (
  SELECT id FROM public.exercise WHERE name = 'スミスマシンインクラインベンチプレス' AND user_id IS NULL
), moved AS (
  UPDATE public.workout_entry SET exercise_id = (SELECT id FROM smith)
  WHERE id IN (SELECT id FROM target)
  RETURNING id
)
UPDATE public.workout_set SET exercise_id = (SELECT id FROM smith)
WHERE entry_id IN (SELECT id FROM moved);
