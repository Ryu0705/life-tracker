-- Life Tracker v2 — プロフィール (性別・生年月日) と体重の記録
-- 2026-10-10 / 設計: docs/body-strength-and-heatmap-period.md「設計（確定）」の DB 節 (レビュー A-9・A-10)
-- 適用方法: Supabase MCP apply_migration (name: v2_profile_body_weight) / supabase-cli は使わない
-- 本番適用: 未 (本人 OK 後)
--
-- 部位ごとの強さの級 (Strength Level の体重比の基準) に使う。級は表示のたびに端末で計算し保存しない (INV-5)。
-- 基準の表 (JSON) はアプリにバンドルし DB には入れない。
-- 体重は日付つきの独立した表にする (体重の推移・食事を後から足しても体重データの移行が要らない形。本人 2026-10-07)。
-- 同じ日は上書き (upsert onConflict: recorded_on)。JST の日は端末で計算する (@DateOnly と同じ規約)。
-- 年齢は生年月日から計算する (保存しない)。RLS は既存の表と同じく無効のまま (8/31 からの未決を引き継ぐ)
-- 0012 (task_template の旧列・pattern_template_membership の削除) とは独立
-- 冪等: 何度流しても同じ状態になる (IF NOT EXISTS)

-- ============================================================
-- プロフィール (1 行だけ)
-- ============================================================
CREATE TABLE IF NOT EXISTS user_profile (
  id         SMALLINT PRIMARY KEY DEFAULT 1,
  sex        TEXT NOT NULL,                     -- 基準の表の性別 (male / female)
  birth_date DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT user_profile_single_chk CHECK (id = 1),  -- 2 行目を止める砦
  CONSTRAINT user_profile_sex_chk    CHECK (sex IN ('male','female'))
);

-- ============================================================
-- 体重 (1 日 1 件)
-- ============================================================
CREATE TABLE IF NOT EXISTS body_weight_record (
  recorded_on DATE PRIMARY KEY,                 -- JST の日。朝晩 2 回が要るなら id + recorded_at へ移す (行は保てる)
  weight_kg   NUMERIC(5,2) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT body_weight_record_range_chk CHECK (weight_kg BETWEEN 20 AND 300)  -- 桁の打ち間違いを止める砦
);
