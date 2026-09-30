-- Life Tracker v2 — 継続の仕組み (週 N 回の目標・トレーニングした日)
-- 2026-09-30 / 設計: docs/continuity-design.md
-- 適用方法: Supabase MCP `apply_migration` (name: "v2_training_goal") / supabase-cli は使わない
-- 破壊的変更なし (テーブルと view の追加のみ)

-- ============================================================
-- 週の目標回数 (その週から有効)。過去の週は当時の目標で判定するため履歴で持つ
-- ============================================================
CREATE TABLE training_goal (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  weekly_target  SMALLINT NOT NULL CHECK (weekly_target BETWEEN 1 AND 7),
  effective_from DATE NOT NULL UNIQUE CHECK (EXTRACT(ISODOW FROM effective_from) = 1),
                                              -- 週頭 (月曜)。同じ週に変えたら upsert で上書き
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- トレーニングした日 (completed_at の JST 暦日)。連続日数は全期間の日付が要るため、
-- セット本体を読まずに日付だけを返す。導出値は保存しない (INV-5: 読み取り時の集計は可)
-- ============================================================
CREATE VIEW workout_training_day AS
SELECT DISTINCT (completed_at AT TIME ZONE 'Asia/Tokyo')::date AS day
FROM workout_set
WHERE completed_at IS NOT NULL;
