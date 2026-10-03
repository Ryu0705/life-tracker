-- Life Tracker v2 — セット番号の連番 (記録済みセットの取り消し・削除で後ろを詰める)
-- 2026-10-03 / 設計: docs/gymwork-alignment-design.md「記録済みセットの編集・セット番号の連番」
-- 適用方法: Supabase MCP apply_migration (name: v2_workout_set_renumber) / supabase-cli は使わない
-- 本番適用は本人 OK 待ち (2026-10-03 時点で未適用)。適用前のビルドでは削除・取り消しが失敗する (関数が無い)
--
-- 冪等: 何度流しても同じ状態になる (制約は DROP IF EXISTS → ADD・詰め直しは欠番が無ければ何も変えない・関数は CREATE OR REPLACE)
-- 順序: UNIQUE を外す → 既存の欠番を詰める → UNIQUE を DEFERRABLE で付け直す → 関数 → GRANT
--   (即時検査の UNIQUE のままだと、詰め直しの UPDATE が行の処理順によって途中で重複に当たる)
-- 事前確認 (2026-10-03・読み取りのみ): 制約名は 0003 の無名 UNIQUE の既定名 workout_set_session_id_exercise_id_set_index_key。
--   workout_set を ON CONFLICT で upsert する箇所はアプリ・SQL とも無い (DEFERRABLE な UNIQUE は ON CONFLICT の対象にできない)。
--   workout_set を参照する外部キーも無い。欠番のある セッション×種目 は本番で 1 組 (10/3 のレッグエクステンション 1・3・4)

-- ============================================================
-- UNIQUE (session_id, exercise_id, set_index) を外す
-- ============================================================
ALTER TABLE workout_set DROP CONSTRAINT IF EXISTS workout_set_session_id_exercise_id_set_index_key;

-- ============================================================
-- 既存データの欠番を詰め直す (同じ セッション×種目 で set_index 順に 1..n)
-- ============================================================
UPDATE workout_set s
   SET set_index = r.n
  FROM (SELECT id, row_number() OVER (PARTITION BY session_id, exercise_id ORDER BY set_index, id) AS n
          FROM workout_set) r
 WHERE s.id = r.id AND s.set_index <> r.n;

-- ============================================================
-- UNIQUE を付け直す。普段は即時検査 (INITIALLY IMMEDIATE)、詰め直しの間だけ関数の中で遅らせる
-- ============================================================
ALTER TABLE workout_set
  ADD CONSTRAINT workout_set_session_id_exercise_id_set_index_key
  UNIQUE (session_id, exercise_id, set_index) DEFERRABLE INITIALLY IMMEDIATE;

-- ============================================================
-- セットの削除 (スワイプの削除・✓ の取り消し)。削除と詰め直しを 1 トランザクションで行う
-- (途中で失敗して欠番や重複が残ると、次の記録の「最大＋1」と食い違うため)
-- 無い id は何もしない (応答だけ失われた削除のやり直しでエラーにしない)
-- ============================================================
CREATE OR REPLACE FUNCTION workout_set_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_session  uuid;
  v_exercise uuid;
BEGIN
  SET CONSTRAINTS workout_set_session_id_exercise_id_set_index_key DEFERRED;
  DELETE FROM workout_set WHERE id = p_id
    RETURNING session_id, exercise_id INTO v_session, v_exercise;
  IF FOUND THEN
    UPDATE workout_set s
       SET set_index = r.n
      FROM (SELECT id, row_number() OVER (ORDER BY set_index, id) AS n
              FROM workout_set
             WHERE session_id = v_session AND exercise_id = v_exercise) r
     WHERE s.id = r.id AND s.set_index <> r.n;
  END IF;
  -- 関数の終わりで検査を戻す (重複があればここで失敗し、削除ごと取り消される)
  SET CONSTRAINTS workout_set_session_id_exercise_id_set_index_key IMMEDIATE;
END $$;

-- RLS 無効・anon キーで使う構成 (docs/continuity-design.md) に合わせて実行権限を明示する
GRANT EXECUTE ON FUNCTION workout_set_delete(uuid) TO anon, authenticated;
