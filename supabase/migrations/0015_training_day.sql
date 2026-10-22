-- Life Tracker v2 — トレーニングの日 (前の日に翌日の 2:00 まで記録できる)
-- 2026-10-23 / 設計: docs/gymwork-alignment-design.md §3.5・計画: docs/training-day-implementation-plan.md §1 (細部はこちらが正)
-- 適用方法: Supabase MCP apply_migration (name: v2_training_day) / supabase-cli は使わない。1 つのトランザクションで流れる (BEGIN／COMMIT は書かない)
-- 本番適用: 済 (2026-10-23 04:31 JST・本人「流して」。MCP apply_migration v2_training_day・version 20261022193108。本番に記録された SQL はこのファイルと md5 が一致 (ef52f9e7…))
-- 戻し: supabase/rollback/0015_down.sql
-- 確かめ: supabase/test/run.sh (docker。multiuser_test.sql の 11・checks.sql)
--
-- 決まり (本人 2026-10-22〜23): 記録する日は、トレーニングのタブの週の帯で選んでいる日。前の日は翌日の 2:00 まで記録できる。
--   アプリが時刻で日を振り分けない。今日 (0:00 以降) に記録があれば 2:00 前でも前の日は閉じる (これはアプリだけで守る)
-- DB で守ること: セッションに日 (day) を持ち、1 人 1 日 1 セッション。セットにも同じ日を写し、セッションの日と外部キーで一致させる
--   (セットは集計でいちばん多く読まれ、日で範囲を取るため)。時刻 (started_at・completed_at) は、その日の 0:00〜翌日 2:00 の窓の中
-- 今のビルド (day を送らない) の書き込みは、トリガーが埋める (セッションは started_at の JST の日、セットはセッションの日)。
--   今のビルドでは、0:00 より前に始めたトレーニングに 2:00 を過ぎて ✓ すると窓の CHECK で止まる (新しいビルドを入れるまでの間だけ)
-- 本番の今のデータ (2026-10-23 01:3x・読むだけの SQL): セッション 11・同じ日の重なり 0・窓の外のセット 0・セッションと違う日のセット 0・
--   開いたままのセッション 0 → 埋めた後も、日ごとの数は今と変わらない
--
-- 順序: 列を足して埋める → 砦 → NOT NULL → CHECK → 一意 → 外部キー → 進行中 1 件の一意を消す・索引 → トリガー → view → 権限

-- ============================================================
-- a. 日の列を足して埋める
-- ============================================================
ALTER TABLE public.workout_session ADD COLUMN day date;
ALTER TABLE public.workout_set ADD COLUMN day date;

UPDATE public.workout_session SET day = (started_at AT TIME ZONE 'Asia/Tokyo')::date;
UPDATE public.workout_set w SET day = s.day FROM public.workout_session s WHERE s.id = w.session_id;

-- ============================================================
-- b. 砦 (下の一意・CHECK・外部キーで止まる前に、何が合わないかを数で出す)
-- ============================================================
DO $$
DECLARE
  v_dup int;
  v_session_out int;
  v_set_out int;
  v_set_day int;
BEGIN
  SELECT count(*) INTO v_dup
    FROM (SELECT user_id, day FROM public.workout_session GROUP BY 1, 2 HAVING count(*) > 1) x;
  SELECT count(*) INTO v_session_out
    FROM public.workout_session
   WHERE NOT (started_at >= (day::timestamp AT TIME ZONE 'Asia/Tokyo')
              AND started_at < (((day + 1) + time '02:00') AT TIME ZONE 'Asia/Tokyo'));
  SELECT count(*) INTO v_set_out
    FROM public.workout_set
   WHERE completed_at IS NOT NULL
     AND NOT (completed_at >= (day::timestamp AT TIME ZONE 'Asia/Tokyo')
              AND completed_at < (((day + 1) + time '02:00') AT TIME ZONE 'Asia/Tokyo'));
  SELECT count(*) INTO v_set_day
    FROM public.workout_set w JOIN public.workout_session s ON s.id = w.session_id
   WHERE w.day IS DISTINCT FROM s.day;
  IF v_dup > 0 OR v_session_out > 0 OR v_set_out > 0 OR v_set_day > 0 THEN
    RAISE EXCEPTION '0015: same-day sessions %, sessions out of window %, sets out of window %, sets on another day %',
      v_dup, v_session_out, v_set_out, v_set_day;
  END IF;
END $$;

ALTER TABLE public.workout_session ALTER COLUMN day SET NOT NULL;
ALTER TABLE public.workout_set ALTER COLUMN day SET NOT NULL;

-- ============================================================
-- c. 時刻の窓 (その日の 0:00〜翌日 2:00)。day::timestamp と固定のタイムゾーンで書く (day::timestamptz は接続のタイムゾーンで変わる)
-- 2:00 の締めと「今日に記録があれば閉じる」はアプリが守る (DB はクライアントの送る時刻で検査するので、窓の外のデータを入れない砦)
-- ============================================================
ALTER TABLE public.workout_session ADD CONSTRAINT workout_session_day_window_chk CHECK (
  started_at >= (day::timestamp AT TIME ZONE 'Asia/Tokyo')
  AND started_at < (((day + 1) + time '02:00') AT TIME ZONE 'Asia/Tokyo'));
ALTER TABLE public.workout_set ADD CONSTRAINT workout_set_day_window_chk CHECK (
  completed_at IS NULL
  OR (completed_at >= (day::timestamp AT TIME ZONE 'Asia/Tokyo')
      AND completed_at < (((day + 1) + time '02:00') AT TIME ZONE 'Asia/Tokyo')));

-- ============================================================
-- d. 1 人 1 日 1 セッション (二重の作成はここで 23505。アプリは日で引き直す)。(id, user_id, day) はセットの外部キーの的
-- workout_session_id_user_id_key (0014) は workout_entry の外部キーが使うので残す
-- ============================================================
ALTER TABLE public.workout_session ADD CONSTRAINT workout_session_user_id_day_key UNIQUE (user_id, day);
ALTER TABLE public.workout_session ADD CONSTRAINT workout_session_id_user_id_day_key UNIQUE (id, user_id, day);

-- ============================================================
-- e. 外部キー (名前と削除のときの動きは今と同じ。user_id を含む組は 19 本のまま)
-- ============================================================
-- セット → セッション: 日も組に入れる (セットの日 = セッションの日)
ALTER TABLE public.workout_set
  DROP CONSTRAINT workout_set_session_id_fkey,
  ADD CONSTRAINT workout_set_session_id_fkey FOREIGN KEY (session_id, user_id, day)
    REFERENCES public.workout_session (id, user_id, day) ON DELETE CASCADE;

-- セット → 種目 1 回分: セッションも組に入れる (前の日の種目に今日のセットが付くのを止める。本番の食い違いは 0)。旧い一意は消す
ALTER TABLE public.workout_entry ADD CONSTRAINT workout_entry_id_session_id_exercise_id_user_id_key UNIQUE (id, session_id, exercise_id, user_id);
ALTER TABLE public.workout_set
  DROP CONSTRAINT workout_set_entry_fk,
  ADD CONSTRAINT workout_set_entry_fk FOREIGN KEY (entry_id, session_id, exercise_id, user_id)
    REFERENCES public.workout_entry (id, session_id, exercise_id, user_id);
ALTER TABLE public.workout_entry DROP CONSTRAINT workout_entry_id_exercise_id_user_id_key;

-- ============================================================
-- f. 進行中のセッションは 1 人 1 件まで、をやめる (前の日と今日が同時に開きうる)。日の範囲で読む索引
-- ============================================================
DROP INDEX public.workout_session_single_in_progress;
CREATE INDEX workout_set_day_idx ON public.workout_set (user_id, day);

-- ============================================================
-- g. day を送らない書き込み (今のビルド・MCP の手入力) の日を埋める。送られた day は変えない
-- 呼んだ人の権限で動く (SECURITY INVOKER)。セットのほうは RLS で自分のセッションだけが見え、他人のセッションでは day が埋まらず NOT NULL で止まる
-- ============================================================
CREATE FUNCTION private.workout_session_fill_day() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.day := (NEW.started_at AT TIME ZONE 'Asia/Tokyo')::date;
  RETURN NEW;
END $$;

CREATE FUNCTION private.workout_set_fill_day() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  SELECT s.day INTO NEW.day FROM public.workout_session s WHERE s.id = NEW.session_id;
  RETURN NEW;
END $$;

CREATE TRIGGER workout_session_fill_day BEFORE INSERT ON public.workout_session
  FOR EACH ROW WHEN (NEW.day IS NULL) EXECUTE FUNCTION private.workout_session_fill_day();
CREATE TRIGGER workout_set_fill_day BEFORE INSERT ON public.workout_set
  FOR EACH ROW WHEN (NEW.day IS NULL) EXECUTE FUNCTION private.workout_set_fill_day();

-- ============================================================
-- h. トレーニングした日 = セットの日 (0:00 以降に前の日へ記録したセットは前の日)。
-- CREATE OR REPLACE は WITH を書かないと security_invoker が外れて全員の日が見えるので、必ず書く
-- ============================================================
CREATE OR REPLACE VIEW public.workout_training_day WITH (security_invoker = true) AS
SELECT DISTINCT day
FROM public.workout_set
WHERE completed_at IS NOT NULL;

-- ============================================================
-- i. 権限 (0014 の決まり: 作ったものの GRANT と REVOKE を書く)
-- ============================================================
REVOKE ALL ON public.workout_training_day FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON public.workout_training_day FROM authenticated;
GRANT SELECT ON public.workout_training_day TO authenticated;

REVOKE EXECUTE ON FUNCTION private.workout_session_fill_day(), private.workout_set_fill_day() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.workout_session_fill_day(), private.workout_set_fill_day() TO authenticated, service_role;
