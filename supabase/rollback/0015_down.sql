-- Life Tracker v2 — 0015 (トレーニングの日) の戻し。番号付きの前進用の migration ではない (supabase/migrations/ の外に置く)
-- 2026-10-23 / 計画: docs/training-day-implementation-plan.md §1
--
-- ★ 戻すと、前の日に記録した 0:00 以降のセットは、また次の日に数えられる (view とアプリの集計が completed_at の JST の日に戻る)。
--   セッションとセットの行は消さない
-- ★ 開いているセッションが 1 人 2 つ以上 (前の日と今日) なら、古い方を閉じてから「進行中は 1 人 1 件」を戻す
--   (閉じる時刻は最後のセットの時刻。セットが無ければ始めた 1 秒後)
-- ★ 戻しても supabase_migrations.schema_migrations に 0015 (v2_training_day) の記録は残り、list_migrations では適用済みに見える
-- 流し方: 今のビルド (0015 の前のアプリ) を入れ直すのと一緒に。MCP の execute_sql か SQL エディタで 1 回で流す
-- 確かめ: supabase/test/run.sh --rollback 0015 (0014 の後と、0015 → この戻しの後の形が同じ)
--
-- 順序 (0015 の逆): view → 外部キー → 一意 → 開いているセッションの片付け → 進行中 1 件の一意 → 索引 → トリガー → CHECK → 列

-- ============================================================
-- view を completed_at の JST の日に戻す (day の列を消す前に)
-- ============================================================
CREATE OR REPLACE VIEW public.workout_training_day WITH (security_invoker = true) AS
SELECT DISTINCT (completed_at AT TIME ZONE 'Asia/Tokyo')::date AS day
FROM public.workout_set
WHERE completed_at IS NOT NULL;

-- ============================================================
-- 外部キーを 0014 の形に
-- ============================================================
ALTER TABLE public.workout_set
  DROP CONSTRAINT workout_set_session_id_fkey,
  ADD CONSTRAINT workout_set_session_id_fkey FOREIGN KEY (session_id, user_id)
    REFERENCES public.workout_session (id, user_id) ON DELETE CASCADE;

ALTER TABLE public.workout_entry ADD CONSTRAINT workout_entry_id_exercise_id_user_id_key UNIQUE (id, exercise_id, user_id);
ALTER TABLE public.workout_set
  DROP CONSTRAINT workout_set_entry_fk,
  ADD CONSTRAINT workout_set_entry_fk FOREIGN KEY (entry_id, exercise_id, user_id)
    REFERENCES public.workout_entry (id, exercise_id, user_id);
ALTER TABLE public.workout_entry DROP CONSTRAINT workout_entry_id_session_id_exercise_id_user_id_key;

ALTER TABLE public.workout_session
  DROP CONSTRAINT workout_session_id_user_id_day_key,
  DROP CONSTRAINT workout_session_user_id_day_key;

-- ============================================================
-- 開いているセッションを 1 人 1 件に (いちばん新しく始めたものを残す)
-- ============================================================
UPDATE public.workout_session s
   SET ended_at = greatest((SELECT max(w.completed_at) FROM public.workout_set w WHERE w.session_id = s.id),
                           s.started_at + interval '1 second')
 WHERE s.ended_at IS NULL
   AND EXISTS (SELECT 1 FROM public.workout_session n
                WHERE n.user_id = s.user_id AND n.ended_at IS NULL AND (n.started_at, n.id) > (s.started_at, s.id));

CREATE UNIQUE INDEX workout_session_single_in_progress ON public.workout_session (user_id) WHERE ended_at IS NULL;
DROP INDEX public.workout_set_day_idx;

-- ============================================================
-- トリガーと関数・CHECK・列
-- ============================================================
DROP TRIGGER workout_set_fill_day ON public.workout_set;
DROP TRIGGER workout_session_fill_day ON public.workout_session;
DROP FUNCTION private.workout_set_fill_day();
DROP FUNCTION private.workout_session_fill_day();

ALTER TABLE public.workout_set DROP CONSTRAINT workout_set_day_window_chk;
ALTER TABLE public.workout_session DROP CONSTRAINT workout_session_day_window_chk;
ALTER TABLE public.workout_set DROP COLUMN day;
ALTER TABLE public.workout_session DROP COLUMN day;
