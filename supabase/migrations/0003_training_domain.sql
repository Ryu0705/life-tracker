-- Life Tracker v2 — トレーニング・サブドメイン
-- Round 3 / S-DB-2 (2026-08-31)
-- Source of truth: docs/domain-model.md v16 / 判断根拠: docs/training-domain-design.md
-- 適用方法: Supabase MCP `apply_migration` (name: "v2_training_domain") / supabase-cli は使わない
--
-- 破壊的変更: gym_actual_input を DROP する。
--   安全性の根拠 (2026-08-30 実測): Swift コードからの参照 0 件 (接点は Category.swift の
--   enum SubInputKind { case gym } の 2 行のみ) / DB 実データ空。

-- ============================================================
-- 種目マスタ
-- ============================================================

CREATE TABLE exercise (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL,
  muscle_group TEXT NOT NULL CHECK (muscle_group IN (
                 'chest','back','traps','shoulders','biceps','triceps','forearms',
                 'quads','hamstrings','glutes','calves','core','cardio','full_body'
               )),
                                              -- 部位別バランス可視化の粒度。'legs'/'arms' 一括だと
                                              -- 「ハムだけ抜けている」が検出できないため分割 (2026-08-31 改訂)
  equipment    TEXT CHECK (equipment IN (
                 'barbell','dumbbell','machine','cable','bodyweight','kettlebell','band','other'
               )),
                                              -- スミスマシン / EZ バーはそれぞれ 'machine' / 'barbell' に寄せる
  metric_kind  TEXT NOT NULL CHECK (metric_kind IN (
                 'weight_reps','reps_only','duration','duration_distance'
               )),
                                              -- 'duration' はプランク / ウォールシット / デッドハング用。
                                              -- 'duration_distance' に寄せると距離入力欄が常時出る UI ワートになるため分離 (2026-08-31 改訂)
  note         TEXT,                          -- マシンの使い方メモ / セッティング (シート高さ等)
  is_archived  BOOLEAN NOT NULL DEFAULT false,
                                              -- 物理削除しない: workout_set からの参照先消失を防ぐ
  sort_order   INT
);

CREATE UNIQUE INDEX exercise_name_unique ON exercise (name);
CREATE INDEX exercise_muscle_group_idx ON exercise (muscle_group) WHERE is_archived = false;

-- ============================================================
-- ルーティン (プッシュの日 / 脚の日)
-- ============================================================
-- v2 の pattern / task_template とは別系統。
-- 1 日のパターンとは別の周期概念であり、相乗りさせると Round 6a/6b (テンプレ管理 UI) への
-- 依存が生まれてトレーニング先行が崩れるため独立させる (docs/training-domain-design.md 判断 C)。

CREATE TABLE routine (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  note        TEXT,
  is_archived BOOLEAN NOT NULL DEFAULT false,
  sort_order  INT
);

CREATE TABLE routine_exercise (
  routine_id    UUID NOT NULL REFERENCES routine (id) ON DELETE CASCADE,
  exercise_id   UUID NOT NULL REFERENCES exercise (id) ON DELETE RESTRICT,
  sort_order    INT  NOT NULL,
  target_sets   INT  CHECK (target_sets IS NULL OR target_sets > 0),
  target_reps   INT  CHECK (target_reps IS NULL OR target_reps > 0),
  target_weight NUMERIC(6,2) CHECK (target_weight IS NULL OR target_weight >= 0),
  PRIMARY KEY (routine_id, exercise_id)
);

CREATE INDEX routine_exercise_exercise_idx ON routine_exercise (exercise_id);

-- ============================================================
-- セッション (1 回のジム)
-- ============================================================
-- actual_task_id は nullable。
--   actual_task を生成するのはチェックイン機能 (新 Round 5) であり、1:1 従属させると
--   トレーニングログがチェックイン実装に依存して実装順序が逆流する。
--   単独で記録開始でき、後から当日の actual_task にリンクして day-cycle と合流する。
--   (docs/training-domain-design.md 判断 A)

CREATE TABLE workout_session (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actual_task_id UUID UNIQUE REFERENCES actual_task (id) ON DELETE SET NULL,
                                              -- ON DELETE SET NULL: actual_task を消しても
                                              -- トレーニング記録は残す (記録の方が価値が高い)
  routine_id     UUID REFERENCES routine (id) ON DELETE SET NULL,
  started_at     TIMESTAMPTZ NOT NULL,
  ended_at       TIMESTAMPTZ CHECK (ended_at IS NULL OR ended_at > started_at),
                                              -- NULL = 進行中
  note           TEXT
);

CREATE INDEX workout_session_started_at_idx ON workout_session (started_at DESC);

-- 進行中セッションは同時に 1 件まで (誤って二重開始するのを構造で防ぐ)
CREATE UNIQUE INDEX workout_session_single_in_progress
  ON workout_session ((ended_at IS NULL)) WHERE ended_at IS NULL;

-- ============================================================
-- セット明細
-- ============================================================

CREATE TABLE workout_set (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id   UUID NOT NULL REFERENCES workout_session (id) ON DELETE CASCADE,
  exercise_id  UUID NOT NULL REFERENCES exercise (id) ON DELETE RESTRICT,
  set_index    INT  NOT NULL CHECK (set_index > 0),
  weight       NUMERIC(6,2) CHECK (weight IS NULL OR weight >= 0),
                                              -- NULL = 自重。0 は「加重なし」を明示した場合
  reps         INT CHECK (reps IS NULL OR reps > 0),
  duration_sec INT CHECK (duration_sec IS NULL OR duration_sec > 0),
  distance_m   NUMERIC(8,2) CHECK (distance_m IS NULL OR distance_m >= 0),
  rpe          NUMERIC(3,1) CHECK (rpe IS NULL OR rpe BETWEEN 1 AND 10),
  is_warmup    BOOLEAN NOT NULL DEFAULT false,
                                              -- PR / ボリューム集計から除外する
  completed_at TIMESTAMPTZ,
  UNIQUE (session_id, exercise_id, set_index)
);

CREATE INDEX workout_set_session_idx  ON workout_set (session_id);
CREATE INDEX workout_set_exercise_idx ON workout_set (exercise_id);

-- metric_kind と実際に埋まる列の整合 (weight_reps なら weight/reps、duration なら duration_sec) は
-- 別テーブル参照が必要で CHECK では表現できないため、モデル層で担保する。

-- ============================================================
-- 旧サブ入力の撤去
-- ============================================================
-- category.sub_input_kind の 'gym' は維持する (意味が workout_session への入口に変わる)。

DROP TABLE gym_actual_input;
