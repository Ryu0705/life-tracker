-- Life Tracker v2 — 同じ種目を 2 回・記録画面での種目の並べ替え (その日の種目 1 回分 = workout_entry)
-- 2026-10-04 / 設計: docs/gymwork-design-duplicate-and-reorder.md §4.1 (Q1「A」・Q2「a」・Q3「A」本人決定)
-- 適用方法: Supabase MCP apply_migration (name: v2_workout_entry) / supabase-cli は使わない。1 トランザクションで適用する
-- 本番適用: 2026-10-04 本人 OK で適用 (MCP apply_migration v2_workout_entry)。適用後は旧ビルドで記録 (✓) できない (workout_set.entry_id NOT NULL)。読み取りは通る。
--   適用したらすぐ新ビルドを入れる (§12-8)
--
-- 冪等: 何度流しても同じ状態になる (IF NOT EXISTS・WHERE entry_id IS NULL・DROP IF EXISTS → ADD・CREATE OR REPLACE)
-- 競合時の upsert 構文は使わない (DEFERRABLE な UNIQUE は対象にできない)

-- ============================================================
-- その日 (セッション) に実施した種目 1 回分 = 記録画面のカード。同じ種目を 2 回やれば 2 行。
-- sort_order は「実施した順番」(2026-10-04 本人決定)。並べ替えで直す。予定の並びは持たない (未記録のカードは行を作らない)
-- ============================================================
CREATE TABLE IF NOT EXISTS workout_entry (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  UUID NOT NULL REFERENCES workout_session (id) ON DELETE CASCADE,
  exercise_id UUID NOT NULL REFERENCES exercise (id) ON DELETE RESTRICT,
  sort_order  INT  NOT NULL CHECK (sort_order > 0),
  CONSTRAINT workout_entry_session_id_sort_order_key UNIQUE (session_id, sort_order) DEFERRABLE INITIALLY IMMEDIATE,
  CONSTRAINT workout_entry_id_exercise_id_key UNIQUE (id, exercise_id)   -- 下の複合 FK 用
);
CREATE INDEX IF NOT EXISTS workout_entry_session_idx ON workout_entry (session_id);

-- ============================================================
-- 既存データ: (session, exercise) ごとに entry を 1 行。実施順の初期値は最初の completed_at 順
-- ============================================================
ALTER TABLE workout_set ADD COLUMN IF NOT EXISTS entry_id UUID;

INSERT INTO workout_entry (session_id, exercise_id, sort_order)
SELECT g.session_id, g.exercise_id,
       COALESCE((SELECT max(e.sort_order) FROM workout_entry e WHERE e.session_id = g.session_id), 0)
         + row_number() OVER (PARTITION BY g.session_id ORDER BY g.first_at NULLS LAST, g.exercise_id)
  FROM (SELECT session_id, exercise_id, min(completed_at) AS first_at
          FROM workout_set WHERE entry_id IS NULL GROUP BY session_id, exercise_id) g;

-- 同じ (session, exercise) の entry が複数ある場合 (再実行時に新しく増えた NULL 行) は sort_order の小さい方へ
UPDATE workout_set s
   SET entry_id = (SELECT e.id FROM workout_entry e
                    WHERE e.session_id = s.session_id AND e.exercise_id = s.exercise_id
                    ORDER BY e.sort_order LIMIT 1)
 WHERE s.entry_id IS NULL;

ALTER TABLE workout_set ALTER COLUMN entry_id SET NOT NULL;

-- entry と set の exercise_id が食い違わないことを複合 FK で担保する (トリガー不要)。
-- ON DELETE は既定 (NO ACTION): 単独で非空の entry を消すと失敗する (セットを守る)。
-- セッション削除の CASCADE (set と entry が同じ文で消える) が通ることはコンテナで確認済み (§15)
ALTER TABLE workout_set DROP CONSTRAINT IF EXISTS workout_set_entry_fk;
ALTER TABLE workout_set ADD CONSTRAINT workout_set_entry_fk
  FOREIGN KEY (entry_id, exercise_id) REFERENCES workout_entry (id, exercise_id);
CREATE INDEX IF NOT EXISTS workout_set_entry_idx ON workout_set (entry_id);

-- ============================================================
-- set_index の一意性を entry 単位に (2 枚目のカードは 1 から)
-- ============================================================
ALTER TABLE workout_set DROP CONSTRAINT IF EXISTS workout_set_session_id_exercise_id_set_index_key;
ALTER TABLE workout_set DROP CONSTRAINT IF EXISTS workout_set_entry_id_set_index_key;
ALTER TABLE workout_set ADD CONSTRAINT workout_set_entry_id_set_index_key
  UNIQUE (entry_id, set_index) DEFERRABLE INITIALLY IMMEDIATE;

-- ============================================================
-- routine_exercise: 同じ種目を 2 行持てるように PK を (routine_id, sort_order) へ。
-- saveRoutine は全 DELETE → 1..n で INSERT なので並び = PK で足りる。念のため欠番・重複を詰めてから付け直す
-- ============================================================
ALTER TABLE routine_exercise DROP CONSTRAINT IF EXISTS routine_exercise_pkey;
UPDATE routine_exercise r
   SET sort_order = x.n
  FROM (SELECT ctid, row_number() OVER (PARTITION BY routine_id ORDER BY sort_order, exercise_id) AS n
          FROM routine_exercise) x
 WHERE r.ctid = x.ctid AND r.sort_order <> x.n;
ALTER TABLE routine_exercise ADD CONSTRAINT routine_exercise_pkey PRIMARY KEY (routine_id, sort_order);

-- ============================================================
-- セットの削除 (スワイプの削除・✓ の取り消し)。0008 の置き換え: 詰め直しの単位を entry に。
-- 残りが 0 件になった entry は消し、同じセッションの sort_order を 1..n に詰める。
-- 無い id は何もしない (応答だけ失われた削除のやり直しでエラーにしない)
-- ============================================================
CREATE OR REPLACE FUNCTION workout_set_delete(p_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
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
END $$;

-- ============================================================
-- 種目の並べ替え (実施した順を直す・最初の ✓ で entry を画面の位置に差し込む)。
-- 配列順に sort_order = 1..k、配列に無いそのセッションの entry は旧 sort_order 順で k+1.. に。
-- 他のセッションの id・重複した id は無視する (重複は最初の位置を使う)
-- ============================================================
CREATE OR REPLACE FUNCTION workout_entry_reorder(p_session uuid, p_entry_ids uuid[]) RETURNS void
LANGUAGE plpgsql
AS $$
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
END $$;

-- RLS 無効・anon キーで使う構成 (docs/continuity-design.md) に合わせて実行権限を明示する。
-- 表 workout_entry の権限は Supabase の既定権限 (0005・0009 と同じ扱い)
GRANT EXECUTE ON FUNCTION workout_set_delete(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION workout_entry_reorder(uuid, uuid[]) TO anon, authenticated;
