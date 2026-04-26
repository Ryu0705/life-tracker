-- Life Tracker v2 — initial schema corrections
-- Round 1 / S-DB-1 review fix (2026-04-26)
-- Source of truth: docs/domain-model.md v15
-- 適用方法: Supabase MCP `apply_migration` (name: "v2_initial_corrections")
--
-- 0001_initial.sql 適用後の review 指摘を既存 Supabase インスタンスへ追従させる補正:
--   - gym_actual_input.weight: REAL → NUMERIC(6,2) (浮動小数誤差回避)
--   - pgcrypto extension は 0001 ファイルに追記済 (新環境向け)。Supabase 既存環境は既に enabled のため本 migration では不要
-- 新環境で 0001 から流す場合は本 0002 不要 (0001 が NUMERIC で作成する)。
-- 既存環境追従用の idempotent 補正。

ALTER TABLE gym_actual_input
  ALTER COLUMN weight TYPE NUMERIC(6,2);
