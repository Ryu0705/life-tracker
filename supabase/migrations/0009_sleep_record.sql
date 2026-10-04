-- Life Tracker v2 — 睡眠の記録 (専用の表)
-- 2026-10-03 / 設計: docs/sleep-design/ (implementation-plan.md が正。土台は synthesis.md §3-1)
-- 適用方法: Supabase MCP apply_migration (name: v2_sleep_record) / supabase-cli は使わない
-- 本番適用: 2026-10-04 本人 OK で適用 (MCP apply_migration v2_sleep_record)
--
-- 睡眠は予定の実績 (actual_task) から外し、就寝・起床の時刻で記録する (本人決定 2026-09-30・10-01)。
-- 予定とはつながない (つながりの列を持たない)。予定タブの睡眠の行は、予定の時間帯と重なる記録を表示時に探す
-- (ジムを workout_set から表示時に判定しているのと同じ形。規約 D-4 の「完全独立」側)。
-- 「どの夜の睡眠か」は保存しない。就寝の時刻から端末で計算する (SleepRules.nightKey。INV-5: 導出値を永続化しない)
-- 種別 (通常の睡眠 / 仮眠) は本人が記録のときに選ぶ値なので列 kind に持つ (本人決定 2026-10-03。時刻からは判定しない)
-- 0007 (予定の実績) とは独立。どちらを先に当てても壊れない
-- 冪等: 何度流しても同じ状態になる (IF NOT EXISTS・旧表の DROP は存在を見てから)

-- ============================================================
-- 睡眠の記録
-- ============================================================
CREATE TABLE IF NOT EXISTS sleep_record (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  start_at   TIMESTAMPTZ NOT NULL,              -- 就寝 (床に就いた時刻。本人の申告)
  end_at     TIMESTAMPTZ NOT NULL,              -- 起床
  kind       TEXT NOT NULL DEFAULT 'sleep',     -- sleep = 通常の睡眠 / nap = 仮眠
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sleep_record_time_chk  CHECK (end_at > start_at),
  CONSTRAINT sleep_record_span_chk  CHECK (end_at - start_at <= interval '24 hours'),
                                              -- 日付の取り違え (起床の日を 1 日先にした等) を止める砦
  CONSTRAINT sleep_record_kind_chk  CHECK (kind IN ('sleep','nap')),
  -- 同じ時間に 2 つの睡眠は無い (重なりの禁止。種別に依らない)。同じ夜に 2 件 (中途覚醒で分けた・仮眠) は重ならなければ可
  CONSTRAINT sleep_record_no_overlap EXCLUDE USING gist (tstzrange(start_at, end_at) WITH &&)
);

-- 一覧・推移は起床で範囲を取る
CREATE INDEX IF NOT EXISTS sleep_record_end_at_idx ON sleep_record (end_at);

-- ============================================================
-- 旧 sleep_actual_input (0001。actual_task に 1:1 のスコア) を消す
-- 本番は 0 件 (2026-09-30 段階 2 レビューで actual_task・sleep_actual_input とも 0 件を確認。
-- commit 済みのビルドは actual_task に書かず、書き込む RPC (0007) も未適用)。
-- 念のため 1 件でもあれば止める (データを黙って捨てない)
-- ============================================================
DO $$
BEGIN
  IF to_regclass('public.sleep_actual_input') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM sleep_actual_input) THEN
      RAISE EXCEPTION 'sleep_actual_input has rows; move them to sleep_record before dropping';
    END IF;
    DROP TABLE sleep_actual_input;
  END IF;
END $$;

-- 表の権限は 0005 (training_goal) と同じく Supabase の既定の権限に任せる (GRANT は書かない。RLS 無効)
