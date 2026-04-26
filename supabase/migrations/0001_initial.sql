-- Life Tracker v2 — initial schema
-- Round 1 / S-DB-1 (2026-04-26)
-- Source of truth: docs/domain-model.md v15
-- 適用方法: Supabase MCP `apply_migration` (name: "v2_initial_schema") / supabase-cli は使わない

-- ============================================================
-- Extensions (gen_random_uuid 依存)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================
-- ENUM
-- ============================================================

CREATE TYPE apply_day_enum AS ENUM (
  'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday','Holiday'
);

-- ============================================================
-- マスタ
-- ============================================================

CREATE TABLE category (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT NOT NULL,
  sub_input_kind TEXT CHECK (sub_input_kind IN ('gym','sleep'))
                                              -- NULL 許容。Phase 2 で 'learning' 追加時は CHECK 拡張 (ALTER TABLE 1 行)
                                              -- sub_input_type マスタは作らない (二重管理回避)
);

CREATE TABLE pattern (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name      TEXT NOT NULL,
  apply_day apply_day_enum                  -- NULL = 手動適用専用ストック (隔週 MTG / 月一通院 等)
);

-- 曜日/祝日デフォルトは 1 値 = 1 pattern (排他)
CREATE UNIQUE INDEX pattern_apply_day_unique
  ON pattern (apply_day) WHERE apply_day IS NOT NULL;

-- ============================================================
-- タスク雛形
-- ============================================================

CREATE TABLE task_template (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                        TEXT NOT NULL,
  category_id                 UUID NOT NULL REFERENCES category (id) ON DELETE RESTRICT,
  start_minutes_from_midnight INT  NOT NULL CHECK (start_minutes_from_midnight BETWEEN 0 AND 1439),
  duration_minutes            INT  NOT NULL CHECK (duration_minutes > 0 AND duration_minutes <= 1440),
                                              -- 1440 ジャストで丸 1 日 / 日跨ぎ (23:00→翌07:00 等) も表現可
                                              -- 業界差分: Todoist の duration ≤ 24h 制約は採らない
  rrule                       TEXT            -- NULL = 通常時に出ない、pattern membership 経由のみ
);

CREATE TABLE task_template_exdate (
  template_id UUID NOT NULL REFERENCES task_template (id) ON DELETE CASCADE,
  date        DATE NOT NULL,
  PRIMARY KEY (template_id, date)
);

CREATE TABLE pattern_template_membership (
  pattern_id  UUID NOT NULL REFERENCES pattern (id) ON DELETE CASCADE,
  template_id UUID NOT NULL REFERENCES task_template (id) ON DELETE CASCADE,
  PRIMARY KEY (pattern_id, template_id)
);

-- ============================================================
-- 予定実体
-- ============================================================
-- B-X 由来識別の不変条件:
--   pattern_id NOT NULL  => template_id も NOT NULL  (CHECK 制約で固定)
--   pattern_id NULL, template_id NOT NULL = rrule 由来編集
--   両方 NULL                              = 単発手動追加
-- scheduled_task_origin_chk により第 4 状態 (template_id NULL かつ pattern_id NOT NULL) を構造的に排除

CREATE TABLE scheduled_task (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  category_id UUID NOT NULL REFERENCES category (id) ON DELETE RESTRICT,
  start_at    TIMESTAMPTZ NOT NULL,
  end_at      TIMESTAMPTZ NOT NULL CHECK (end_at > start_at),
  template_id UUID REFERENCES task_template (id) ON DELETE RESTRICT,
                                              -- ON DELETE RESTRICT: 「すべて削除」は論理削除 (rrule NULL + UNTIL) で吸収
  pattern_id  UUID REFERENCES pattern (id) ON DELETE RESTRICT,
                                              -- ON DELETE RESTRICT: pattern 物理削除前に day_meta / scheduled_task の処理を強制
  CONSTRAINT scheduled_task_origin_chk
    CHECK (pattern_id IS NULL OR template_id IS NOT NULL)
);

-- Z 案 hybrid (Phase 1 では未発火 / Phase 2+ iv 範囲先読み導入時の重複物理化保護)
-- 同一 template の同日 (JST) の重複 INSERT を防ぐ
CREATE UNIQUE INDEX scheduled_task_template_day_unique
  ON scheduled_task (template_id, ((start_at AT TIME ZONE 'Asia/Tokyo')::date))
  WHERE template_id IS NOT NULL;

-- ============================================================
-- 実績実体
-- ============================================================

CREATE TABLE actual_task (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  category_id UUID NOT NULL REFERENCES category (id) ON DELETE RESTRICT,
  start_at    TIMESTAMPTZ NOT NULL,
  end_at      TIMESTAMPTZ NOT NULL CHECK (end_at > start_at)
);

-- ============================================================
-- day 単位の独立属性
-- ============================================================

-- day_meta 状態の意味論 (3 状態):
-- (1) レコードなし: pattern 自動判定 (apply_day マッチ + 祝日判定) で動的決定
-- (2) レコードあり、applied_pattern_id NOT NULL: その pattern 適用 (ユーザー選択 or 自動判定後の上書き)
-- (3) レコードあり、applied_pattern_id NULL: 「何もしない日」(明示的、pattern なし、rrule のみ)
-- レコードの存在自体が「ユーザーが意図的に操作した日」のマーカー
CREATE TABLE day_meta (
  date               DATE PRIMARY KEY,        -- JST のカレンダー日
  applied_pattern_id UUID REFERENCES pattern (id) ON DELETE RESTRICT
                                              -- ON DELETE RESTRICT: pattern 物理削除で「何もしない日」に化けるのを防ぐ
);

-- ============================================================
-- サブ入力 (種別専用テーブル、actual_task と 1:1)
-- ============================================================

CREATE TABLE gym_actual_input (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actual_task_id UUID NOT NULL UNIQUE REFERENCES actual_task (id) ON DELETE CASCADE,
  exercise       TEXT NOT NULL,
  weight         NUMERIC(6,2),               -- kg。NUMERIC で浮動小数誤差を回避 (集計・閾値判定の再現性)
  reps           INT,
  sets           INT
);

CREATE TABLE sleep_actual_input (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actual_task_id UUID NOT NULL UNIQUE REFERENCES actual_task (id) ON DELETE CASCADE,
  sleep_score    INT
);
