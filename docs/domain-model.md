# Life Tracker v2 — ドメインモデル v16

DDL レベル + 設計判断 + DayBuilder + Phase 2 持ち越し論点を集約した SSOT。

**v16 (2026-08-31)**: トレーニング・サブドメインを追加し `gym_actual_input` を撤去。判断根拠は `training-domain-design.md`。

スコープ・コア定義は `spec.md`、構造規約は `structural-conventions.md` を参照。
決定経緯・代替案・却下理由は memory `project_life_tracker_v2_core.md` 参照。

---

## 共通前提

- **タイムゾーン**: `timestamptz` で保存、day 計算時のみ JST (`Asia/Tokyo`) へ変換 (`AT TIME ZONE 'Asia/Tokyo'`)
- **DATE 型カラム** (`day_meta.date`, `task_template_exdate.date`): JST のカレンダー日
- **DB 制約は最後の砦** (`feedback_db_constraints_last_defense`): UNIQUE / CHECK / FK は最後の砦として配置。事前検証は Swift モデル / Service 層で実施し、業務フローで例外 catch する設計はしない

---

## DDL (PostgreSQL / Supabase)

```sql
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
  name           TEXT NOT NULL,             -- 例: "ジム", "PMBOK", "朝食"
  sub_input_kind TEXT CHECK (sub_input_kind IN ('gym','sleep'))
                                             -- NULL 許容。Phase 2 で 'learning' 追加時は CHECK 拡張 (ALTER TABLE 1 行)
);

CREATE TABLE pattern (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name      TEXT NOT NULL,                  -- 例: "通常月曜", "在宅月曜", "歯医者ある日"
  apply_day apply_day_enum                  -- NULL = 手動適用専用ストック
);
-- 曜日/祝日デフォルトは 1 値 = 1 pattern (排他)
-- Phase 1 では Holiday も 1 種類のみ。振替休日 / 元日 / 通常祝日 を分けたい場合は
-- Phase 2 で apply_day_enum 分解 or (weekday TEXT?, is_holiday BOOL) 2 列分解を検討
CREATE UNIQUE INDEX pattern_apply_day_unique
  ON pattern (apply_day) WHERE apply_day IS NOT NULL;

-- ============================================================
-- タスク雛形
-- ============================================================
-- 時刻は相対 (深夜 0 時起点の分単位)。絶対時刻 (scheduled_task / actual_task) と
-- 型を分けることで rrule 評価時の「当日に投影する」処理が必須化される

CREATE TABLE task_template (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                        TEXT NOT NULL,
  category_id                 UUID NOT NULL REFERENCES category (id) ON DELETE RESTRICT,
  start_minutes_from_midnight INT  NOT NULL CHECK (start_minutes_from_midnight BETWEEN 0 AND 1439),
  duration_minutes            INT  NOT NULL CHECK (duration_minutes > 0 AND duration_minutes <= 1440),
                                              -- 1440 ジャストで丸 1 日 / 日跨ぎ (23:00→翌07:00 等) も表現可
  rrule                       TEXT            -- "FREQ=WEEKLY;BYDAY=MO,TU,..." (RFC 5545 サブセット)
                                              -- NULL = 通常時に出ない、pattern membership 経由のみ
);

-- exdates は配列ではなく別テーブル (重複保護 / index 適用 / 将来 RECURRENCE-ID 例外行追加に拡張可能)
CREATE TABLE task_template_exdate (
  template_id UUID NOT NULL REFERENCES task_template (id) ON DELETE CASCADE,
  date        DATE NOT NULL,
  PRIMARY KEY (template_id, date)
);

-- pattern 適用日に展開する template 集合 (M:N)
CREATE TABLE pattern_template_membership (
  pattern_id  UUID NOT NULL REFERENCES pattern (id) ON DELETE CASCADE,
  template_id UUID NOT NULL REFERENCES task_template (id) ON DELETE CASCADE,
  PRIMARY KEY (pattern_id, template_id)
);

-- ============================================================
-- 予定実体 (day_anchor なし、start_at/end_at の時刻ペアのみで日紐付け)
-- ============================================================
-- B-X 由来識別の不変条件:
--   pattern_id NOT NULL  => template_id も NOT NULL  (CHECK 制約で固定)
--   pattern_id NULL, template_id NOT NULL = rrule 由来編集
--   両方 NULL                              = 単発手動追加

CREATE TABLE scheduled_task (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  category_id UUID NOT NULL REFERENCES category (id) ON DELETE RESTRICT,
  start_at    TIMESTAMPTZ NOT NULL,
  end_at      TIMESTAMPTZ NOT NULL CHECK (end_at > start_at),
  template_id UUID REFERENCES task_template (id) ON DELETE RESTRICT,
                                              -- 「すべて削除」は論理削除 (rrule NULL + UNTIL) で吸収するため
                                              -- 物理 DELETE 動線では既存 scheduled_task を先に剥がす運用 → RESTRICT
  pattern_id  UUID REFERENCES pattern (id) ON DELETE RESTRICT,
                                              -- pattern 物理削除前に day_meta / scheduled_task の処理を強制
  CONSTRAINT scheduled_task_origin_chk
    CHECK (pattern_id IS NULL OR template_id IS NOT NULL)
);

-- Z 案 hybrid: 同一 template の同日 (JST) 重複物理化を防ぐ
-- Phase 1 (D1 完全 lazy) では発生しないが、Phase 2+ で iv (範囲先読み) を入れた時の保護
CREATE UNIQUE INDEX scheduled_task_template_day_unique
  ON scheduled_task (template_id, ((start_at AT TIME ZONE 'Asia/Tokyo')::date))
  WHERE template_id IS NOT NULL;

-- ============================================================
-- 実績実体 (day_anchor なし)
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
-- 「曜日毎の pattern を持つ = day が pattern との結合点を持つ」ため、day 単位の編集状態は構造的に発生する
-- レコードの存在自体が「ユーザーが意図的に操作した日」のマーカー

CREATE TABLE day_meta (
  date               DATE PRIMARY KEY,        -- JST のカレンダー日
  applied_pattern_id UUID REFERENCES pattern (id) ON DELETE RESTRICT
                                              -- NULL = 「何もしない日」(明示的)
                                              -- pattern 物理削除で「何もしない日」に化けるのを防ぐため RESTRICT
);

-- day_meta 状態の意味論:
-- (1) レコードなし: pattern 自動判定 (apply_day マッチ + 祝日判定) で動的決定
-- (2) レコードあり、applied_pattern_id NOT NULL: その pattern 適用 (ユーザー選択 or 自動判定後の上書き)
-- (3) レコードあり、applied_pattern_id NULL: 「何もしない日」(pattern なし、rrule のみ)

-- ============================================================
-- サブ入力 (種別専用テーブル、actual_task と 1:1)
-- Phase 1 で実装: sleep のみ (gym は下記トレーニング・サブドメインへ移行)
-- ============================================================

CREATE TABLE sleep_actual_input (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actual_task_id UUID NOT NULL UNIQUE REFERENCES actual_task (id) ON DELETE CASCADE,
  sleep_score    INT                        -- 主観スコア (1-5 等)
  -- Phase 2 追加候補: 中途覚醒回数 / 夢の有無 / healthkit_sample_uuid (HealthKit 同期時の external id)
);

-- v15 の gym_actual_input は v16 で撤去 (migration 0003)。
--   1 行に (exercise TEXT, weight, reps, sets) を持つ形ではセット毎の差 (60x10 / 65x8 / 65x6) を
--   表現できず、種目が TEXT 直書きのため PR / 推移の集計も成立しなかった。
--   → 下記トレーニング・サブドメインへ置換。
-- Phase 2 以降で追加 (Phase 1 では作らない):
--   learning_actual_input { material, chapter, note, ... } — PMBOK 計画統合想定
-- 新サブ入力種別追加時はテーブル追加 + category.sub_input_kind の CHECK 拡張 + コード対応

-- ============================================================
-- トレーニング・サブドメイン (v16 / migration 0003)
-- ============================================================
-- workout_session は独立アグリゲート。actual_task_id は nullable。
--   actual_task を生成するのはチェックイン機能 (Round 5) であり、1:1 従属させると
--   トレーニングログがチェックイン実装に依存して実装順序が逆流する。
--   単独で記録開始でき、後から当日の actual_task にリンクして day-cycle と合流する。
--   write 系は DayDataSource を拡張せず、別 protocol WorkoutDataSource として切り出す。

CREATE TABLE exercise (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL,
  muscle_group TEXT NOT NULL CHECK (muscle_group IN (
                 'chest','back','traps','shoulders','biceps','triceps','forearms',
                 'quads','hamstrings','glutes','calves','core','cardio','full_body'
               )),
                                            -- 部位別バランス可視化の粒度。'legs'/'arms' 一括だと
                                            -- 「ハムだけ抜けている」が検出できない
  equipment    TEXT CHECK (equipment IN (
                 'barbell','dumbbell','machine','cable','bodyweight','kettlebell','band','other'
               )),
                                            -- スミスマシン→'machine' / EZ バー→'barbell' に寄せる
  metric_kind  TEXT NOT NULL CHECK (metric_kind IN (
                 'weight_reps','reps_only','duration','duration_distance'
               )),
                                            -- 'duration' はプランク / ウォールシット / デッドハング用。
                                            -- duration_distance に寄せると距離入力欄が常時出る UI ワートになる
  note         TEXT,                        -- マシンの使い方 / セッティング (シート高さ等)
  is_archived  BOOLEAN NOT NULL DEFAULT false,
  sort_order   INT
);

CREATE UNIQUE INDEX exercise_name_unique ON exercise (name);
CREATE INDEX exercise_muscle_group_idx ON exercise (muscle_group) WHERE is_archived = false;

-- ルーティン (プッシュの日 / 脚の日)。
-- v2 の pattern / task_template とは別系統 — 1 日のパターンとは別の周期概念であり、
-- 相乗りさせると Round 6a/6b (テンプレ管理 UI) への依存が生まれる。
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

CREATE TABLE workout_session (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actual_task_id UUID UNIQUE REFERENCES actual_task (id) ON DELETE SET NULL,
                                            -- nullable かつ SET NULL:
                                            -- actual_task を消してもトレーニング記録は残す
  routine_id     UUID REFERENCES routine (id) ON DELETE SET NULL,
  started_at     TIMESTAMPTZ NOT NULL,
  ended_at       TIMESTAMPTZ CHECK (ended_at IS NULL OR ended_at > started_at),
                                            -- NULL = 進行中
  note           TEXT
);

CREATE INDEX workout_session_started_at_idx ON workout_session (started_at DESC);

-- 進行中セッションは同時 1 件まで (二重開始を構造で防ぐ)
CREATE UNIQUE INDEX workout_session_single_in_progress
  ON workout_session ((ended_at IS NULL)) WHERE ended_at IS NULL;

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
  is_warmup    BOOLEAN NOT NULL DEFAULT false,   -- PR / ボリューム集計から除外
  completed_at TIMESTAMPTZ,
  UNIQUE (session_id, exercise_id, set_index)
);

CREATE INDEX workout_set_session_idx  ON workout_set (session_id);
CREATE INDEX workout_set_exercise_idx ON workout_set (exercise_id);
```

---

## データモデル原則

- **タスクは 1 行で完結**: 日跨ぎタスク (23:00→翌7:00 就寝 等) も分割せず 1 行
- **day_anchor は持たない**: scheduled_task / actual_task は start_at / end_at の時刻ペアのみ。「どの日のタスクか」はクライアント側で算出。業界標準 (Google Calendar / Apple EventKit / Notion / HealthKit) と一致
- **day 計算は JST 固定**: `start_at AT TIME ZONE 'Asia/Tokyo'` で日付化。`day_meta.date` / `task_template_exdate.date` も JST 基準。将来オフセット起点 (4:00-28:00 等) への切り替えは Builder 関数差し替えで対応 (DB migration 不要)
- **day_meta テーブルは Phase 1 で導入** (H-3 で 1 列に縮退): applied_pattern_id 1 列のみで開始。レコードの存在自体が「ユーザー操作済み」マーカー。memo / コンディション / 睡眠スコア等は必要時に列追加。「task に day FK を持たない」(業界 de facto) と「day 単位の独立属性を永続化」は別レイヤーであり矛盾しない (Notion も task に day を埋め込まないが、特定日のメモは独立 page で持つ)
- **タスクと day は永続的な FK で繋げない**: day はクライアント側のドメイン型 (`Day` struct) として組成
- **時刻型は相対 / 絶対で型分離**:
  - `task_template`: `start_minutes_from_midnight INT + duration_minutes INT` (相対、深夜 0 時起点)
  - `scheduled_task` / `actual_task`: `start_at TIMESTAMPTZ + end_at TIMESTAMPTZ` (絶対)
  - rrule 評価時に「当日に投影する」処理を型システムで強制
- **task_template は rrule + pattern_template_membership の両方で参照される**: rrule で発生日を持つ template は通常日に出る、membership で参照される template は pattern 適用日に出る、両方持つ template は両方の機構で出る (ただし pattern 適用日は rrule 由来は出ず membership のみ)
- **予実紐付けなし**: scheduled_task / actual_task は FK で結ばない。予実比較はクライアント側で `Day.scheduled` vs `Day.actual` を category 別に集計して比較
- **1 タスク 1 種別 + 時刻重複許容**: 横断 (ジム+PMBOK) は同時刻並列で表現、tags の重複集計問題を回避
- **category 正規化**: 文字列直書きせず category マスタ + FK 参照
- **サブ入力種別**: `category.sub_input_kind` の CHECK 列で表現 (sub_input_type マスタは不要、二重管理回避)。Phase 2 で `learning` 追加時は ALTER TABLE 1 行で済む
- **サブ入力データ**: 種別ごとに専用テーブル、actual_task と 1:1 を独立 id PK + UNIQUE 制約で表現
- **サブ入力対象は actual_task のみ**: template / scheduled_task は category だけ持つ。実績時に詳細記入 (入力負荷削減)
- **トレーニングは独立アグリゲート**: `workout_session` は `actual_task` に従属させず nullable FK で緩く結ぶ。1日サイクル側 (チェックイン) の完成を待たずに単独で運用でき、後からリンクして結合分析 (睡眠スコア x 挙上重量 等) に載せられる
- **PR / 推定1RM / ボリューム / ストリーク / 部位別バランスは導出**: 専用テーブルを作らず `workout_set` から集計する (`is_warmup = false` のみ対象)。推定1RM は Epley 式 `weight * (1 + reps / 30)` を既定とし、実装時に確定する
- **週目標回数は DB に置かない**: ストリーク判定の閾値は履歴不要の設定値のため UserDefaults。「当時の目標」を振り返る要件が出た時点で DB へ昇格
- **`metric_kind` と充填列の整合はモデル層で担保**: 別テーブル (`exercise`) 参照が必要で CHECK では表現できないため、`feedback_db_constraints_last_defense` の「DB は最後の砦」の適用外
- **種目 / ルーティンは物理削除しない**: `is_archived` + `ON DELETE RESTRICT` で過去ログの参照先消失を防ぐ
- **1 日境界**: 0:00-24:00 JST カレンダー日。夜更かし混入は本人合意で許容
- **並列タスク**: 予実両方で時刻重複許容 (DB 制約に重複禁止を入れない)
- **B-X 由来識別の不変条件は CHECK 制約**: `scheduled_task_origin_chk` で `pattern_id NOT NULL → template_id NOT NULL` を DB レベルで固定。第 4 状態 (`template_id NULL かつ pattern_id NOT NULL`) を構造的に発生させない
- **template / pattern の物理 DELETE は ON DELETE RESTRICT**: 参照する scheduled_task / day_meta が存在する間は物理削除不可。論理削除 (rrule NULL + UNTIL) と「pattern 切替で日を移送」のフローでカバー
- **sleep day attribution は HealthKit 同型を Phase 2 で採用予定**: 通常タスクは `start_at がこの day に属する` を primary とするが、`sleep_actual_input` については Phase 2 で **HealthKit と同型 (endDate ベース + 18:00 境界)** を採用する。具体的には `DayBuilderContext` に `sleepDayAttribution` 注入点を設けて切替 (Phase 1 の DayBuilder 構造を変えずに後付け可能)。23:00→翌7:00 の睡眠を「翌日の睡眠」としてカードに出す UX を実現

---

## パターン適用方式 (D1 完全 lazy / 契約書方式)

### 物理 INSERT は明示編集時のみ

- rrule 展開された未編集タスクは **DB に書き出さない**
- 表示時に `task_template + rrule + task_template_exdate + pattern_template_membership + day_meta + scheduled_task[編集済み・手動]` から DayBuilder が動的合成
- 業界標準 (Google Calendar / Apple EventKit / Outlook の RECURRENCE-ID 例外化方式と同型)
- DB 軽量 (10 年分の rrule でも 1 行の task_template)、template 編集の波及がほぼゼロ

### template は mutable

- immutable / event sourcing は採用せず
- 過去日の編集済み実体化分は scheduled_task として既に独立保存されているので template 変更で動かない (E-A 採用)

### scheduled_task の由来トレース (B-X)

- `template_id?` + `pattern_id?` を持つ (`scheduled_task_origin_chk` で第 4 状態を排除)
- rrule 由来で編集された分: `template_id NOT NULL, pattern_id NULL`
- pattern 適用日由来で編集された分: `template_id NOT NULL, pattern_id NOT NULL`
- 単発手動追加: `template_id NULL, pattern_id NULL`

### 仮想タスクの ID

- 未実体化分は SwiftUI Identifiable のために `(template_id, start_at)` 合成 ID を UI 内で生成 (DB には乗せない)

### iv (範囲先読み) は Phase 1 では採用しない

- Phase 2 以降で通知 / Live Activity 要件が出た場合に「近未来 N 日のみ事前 INSERT」を後付け可能 (`scheduled_task_template_day_unique` で重複保護済み)

### template / pattern 編集時の遡及範囲

- **自動的に「編集済み実体は固定、未編集は新ルールで再計算」**
- 過去 / 未来の区別は不要
- 実体化済み scheduled_task は変更前の値を保持 (E-A 採用、業界標準と整合)
- 未実体化分は次表示時に新 template / pattern で計算される

---

## 反復ルール + パターン適用ロジック (Z 案 hybrid)

採用案: **rrule をデフォルト機構、pattern を day レベルの全置換 overlay として持つ**。drift 耐性を運用変化にも吸収するため両方の仕組みを併用。X 案 (曜日 pattern only) / Y 案 (rrule only) との比較経緯は memory 参照。

### rrule (反復ルール、task_template 単位)

- `task_template.rrule` で各 task の発生日を表現 (RFC 5545 サブセット)
- UI でラップ: 「曜日チェック」「N 日おき」「月の第 X 曜日」程度の操作で rrule 文字列を生成、ユーザーは rrule 文字列を直接見ない
- `task_template_exdate` テーブルで個別除外日を表現 (RFC 5545 EXDATE)
- rrule NULL の template = 通常時に出ない、pattern membership 経由のみで出る (歯医者 task 等)

### pattern (day レベル overlay)

- `pattern.apply_day` は単一の曜日 or 祝日 or NULL
- `apply_day NOT NULL`: 曜日 / 祝日デフォルト (1 値 = 1 pattern、部分 UNIQUE)
- `apply_day NULL`: 手動適用専用ストック (隔週 MTG / 月一通院 / 在宅日 等)
- 祝日 pattern は曜日 pattern より優先
- `pattern_template_membership` で「pattern 適用日に展開される template 集合」を定義
- **全置換セマンティクス**: pattern 適用日 = pattern 内の template だけ表示、rrule 由来は出さない

### 運用ガイド (rrule vs pattern の使い分け)

- 日常反復 (毎日読書、平日朝食、毎週月曜業務) → rrule で表現
- day レベル切替 (在宅日 / 出社日 / 出張日 / 歯医者ある日) → pattern + membership で表現
- 「pattern 適用日は rrule を完全上書き」のため、pattern 適用日にも出したい task は membership に含める必要あり

---

## DayBuilder 動的合成ロジック

### 1. 判定: pattern 適用状態を決定

当日の day_meta レコードを取得し、pattern 適用状態を決定:
- `day_meta あり, applied_pattern_id NULL` → 「何もしない日」モード
- `day_meta あり, applied_pattern_id NOT NULL` → 該当 pattern 適用モード
- `day_meta なし` → apply_day マッチ + 祝日判定で動的決定 (祝日 > 曜日優先)、結果が NULL なら通常日モード、結果が pattern なら該当 pattern 適用モード

### 2. モード別合成

- **「何もしない日」モード**: 編集済み scheduled_task のみ表示、rrule / pattern からの追加合成なし
- **pattern 適用モード**: pattern_template_membership 経由で template[] 取得、各 template について `task_template_exdate` に当該 date 含めば skip、skip しない分のみ仮想合成 (template_id + pattern_id 両方付与)。**rrule 由来は合成しない (完全上書き)**
- **通常日モード**: 全 task_template の rrule + exdate 評価、マッチする日に仮想合成 (template_id のみ、pattern_id NULL)

### 3. 実体優先

モード問わず、同 (template_id, 同日) の編集済み scheduled_task が存在すれば、仮想を抑制して実体を表示 (E-A 全保持と整合、`scheduled_task_template_day_unique` で重複保護)

### 4. 手動追加 task

`template_id NULL` の scheduled_task はそのまま表示

### 冪等性

DB に書かないので競合なし。表示は pure function で再現可能

### 入力契約 (論点 I)

DayBuilder は pure function、入力は `DayBuilderContext` 構造体に集約:

```swift
struct DayBuilderContext {
  let templates: [TaskTemplate]
  let patterns: [Pattern]
  let memberships: [PatternTemplateMembership]  // 当該日の applied pattern (判定後) に紐づくもののみ。
                                                 // Service 層で fetch 時に絞り込む
  let exdates: [TemplateExdate]                  // 当該日に該当する template_id 分のみ
  let dayMeta: DayMeta?                          // 当該日のもの (なければ nil)
  let scheduledTasks: [ScheduledTask]            // 当該日に overlap するもの
  let actualTasks: [ActualTask]                  // 当該日に overlap するもの
  let holidayChecker: (Date) -> Bool             // 祝日判定 (`HolidayJp` SwiftPackage 注入。Round 1 で確定)
  let calendar: Calendar                         // JST で初期化
  // Phase 2 以降:
  // let sleepDayAttribution: SleepAttributionRule  // HealthKit 同型 endDate + 18:00 境界
}
```

- 祝日判定は関数注入でライブラリ依存を分離 (`HolidayJp` SwiftPackage、DB テーブル持たない。Round 1 で確定)
- `memberships` / `exdates` は当該日に必要なものに **Service 層で絞り込んでから** Builder へ渡す。Builder 内で全件 filter する設計は採らない (fetch コスト最小化 + Builder の責務を「合成」に限定)

---

## 手動操作の動作

### 個別タスク編集 / 追加

- `scheduled_task` INSERT / UPDATE のみ
- day_meta は触らない (実体存在で表現される)

### 個別タスク削除 (F-A 3 択)

- **rrule 由来**: `task_template_exdate` 追加 / `rrule` の `UNTIL` 設定 / 「すべて削除」(論理削除 = `rrule NULL + UNTIL` 設定、template 行は残す)
- **pattern 由来**: `task_template_exdate` 追加 または pattern 編集画面遷移
- **単発手動**: `scheduled_task DELETE`

### day_meta upsert / scheduled_task 一括削除の運用

- `day_meta` upsert は `applied_pattern_id` 単独更新を既定とする
- `scheduled_task` の編集系は部分 UPDATE (`encodeIfPresent` 相当) を既定とする (`feedback_upsert_side_effects` 反映)
- 共通 save での全フィールド UPSERT 汚染を構造的に防ぐ

### pattern 切替

確認ダイアログ後、該当日の **`template_id NOT NULL` の `scheduled_task` を全削除** (rrule 由来 + pattern 由来 両方が対象、手動追加 (`template_id NULL`) は残す) → `day_meta upsert (applied_pattern_id=新 pattern_id)`

### 「何もしない日」

該当日の編集済み scheduled_task 全削除 → `day_meta upsert (applied_pattern_id=NULL)`

### 「デフォルトに戻す」

`day_meta` レコードを DELETE → 次回表示時に apply_day マッチ判定 + rrule 評価で動的再表示 (D1 = 物理 INSERT 不要)

---

## タスク削除の意味論 (F-A 採用)

### rrule 由来タスク (3 択ダイアログ、Google Calendar 同型)

| 選択肢 | 動作 |
|-------|-----|
| このタスクのみ削除 | `task_template_exdate` に当該日付を INSERT (RFC 5545 EXDATE と同型) |
| これ以降全部削除 | `task_template.rrule` に `UNTIL=前日` 追加 (or DTSTART 更新) |
| すべて削除 | **論理削除** (`rrule NULL + UNTIL=DTSTART 直前`)。template 行は残す |

「すべて削除」が論理削除である理由:
- D1 完全 lazy では UNTIL で未来表示は完全に止まるため物理 DELETE 不要
- 物理 DELETE すると過去 scheduled_task が孤立化するが、`scheduled_task.template_id` は `ON DELETE RESTRICT` のためそもそも DB レベルで阻止される (CHECK 制約 `scheduled_task_origin_chk` も第 4 状態を排除)
- Google Calendar も「すべて削除」は実体上シリーズ無効化、template 物理削除でない
- 物理 DELETE は管理画面の別動線へ (関連 scheduled_task を先に剥がす運用)

### pattern 由来タスク (2 択)

| 選択肢 | 動作 |
|-------|-----|
| このタスクのみ削除 | `task_template_exdate` に当該日付を INSERT (rrule と共通の機構、その日付で当該 template が完全に出なくなる) |
| pattern を編集する | pattern 編集画面に遷移 (membership から外す等。「これ以降」「すべて」は pattern 編集相当に統合) |

### 単発手動追加タスク

`template_id NULL` のため通常の DELETE のみ (scheduled_task レコード削除)

### `task_template_exdate` の意味論 (C-2)

- exdate は **rrule・pattern どちらの由来かに関わらず、template 単位の絶対除外** として機能する
- pattern 適用日でも exdate 評価が走り、当該日付の template はスキップされる
- 「その日にこの template は出さない」を統一表現する単一機構

---

## クライアントサイド day 設計

```swift
enum DayMembership {
  case primary               // start_at がこの day に属する
  case spillover(from: Date) // 前日から流入 (end_at がこの day にかかる)
  case overflow(to: Date)    // primary day 視点で翌日へ流出
}

struct DayTask {
  let task: ScheduledTask  // or ActualTask
  let membership: DayMembership
  let visibleRange: DateInterval  // 0:00-24:00 で clip 済 (集計はこの幅で加算)
}

struct Day {
  let date: Date
  let scheduled: [DayTask]
  let actual: [DayTask]

  // 時刻ベース判定。半開区間 [start, end) で評価し、spillover は対象外。
  // Swift 標準 DateInterval.contains(_:) の閉区間 [start, end] とは挙動が異なる点に注意。
  func currentBlock(at moment: Date) -> DayTask? { ... }
}

enum DayBuilder {
  // pure function. context + targetDate -> Day
  // 日跨ぎ clip / DayMembership 付与 / visibleRange 計算をここに集約
  static func build(date: Date, context: DayBuilderContext) -> Day { ... }
}
```

### fetch 戦略

overlap 条件 `WHERE start_at < dayEnd AND end_at > dayStart`。前日 23:00→当日 7:00 の睡眠も `dayStart=当日 0:00 JST` で hit

### 集計

`visibleRange.duration` を加算するだけ (24:00 を超える部分は構築時に clip 済 = 翌日に按分される)

### 流入表示

同じタスクを前日の Day (primary) と当日の Day (spillover) の両方に入れる。UI では `membership` で視覚差分 (例: spillover は半透明)

### 編集 UX

spillover 表示で削除 / 編集を押した時は primary day の実体が変わることを警告

### 責務分担

Service (DB fetch + memberships/exdates 当日絞り込み) → DayBuilder (pure function clip + membership 付与) → ViewModel (`@Observable`、集計は computed) → View (DayTask を ForEach 描画)

### spillover の合成判定規約

- `DayMembership.spillover` は **前日視点の合成結果を継承**する
- 当日が pattern 適用日 (rrule 完全上書きモード) であっても、前日が rrule 通常日で生成した日跨ぎ task は当日に spillover 表示される (当日モードで前日由来の流入を抑制してはいけない)
- 前日の DayBuilder 出力をそのまま当日の流入候補として束ねる

---

## day_meta の UI 表現 (A-1 補強)

- day_meta レコード**なし** = 自動判定で表示 (apply_day マッチ + 祝日判定)、UI 上は「通常表示」
- day_meta レコード**あり** (applied_pattern_id NOT NULL / NULL いずれも) = 「ユーザー操作済みの日」として UI 上に視覚差を付与 (例: 日付ラベル横に「カスタム」バッジ、または控えめなマーカー)
- これにより「土日に曜日 pattern 未登録 → 自動判定でも『何もしない日』」と「ユーザーが明示的に『何もしない日』にした」を UI で区別可能 (DayBuilder 出力は同一でも、由来が分かる)

UI 詳細は Phase 4 / 5 で詰める。

---

## 細部 6 確定事項 (論点 D-G)

| 論点 | 確定内容 |
|-----|--------|
| D | β semantics → **D1 完全 lazy**。物理 INSERT は明示編集時のみ。iv は Phase 2+ |
| F | タスク削除 → **F-A 3 択ダイアログ** (「すべて削除」は論理削除化) |
| E | template 編集波及 → **E-A 編集済み実体固定** (RFC 5545 RECURRENCE-ID 同型) |
| A | DayBuilder 二重ルート → **A-1 暗黙適用 + H3 祝日ライブラリ**。day_meta は手動操作時のみ INSERT |
| B | scheduled_task 由来識別 → **B-X**。`(template_id, pattern_id)` 組み合わせ + CHECK 制約 |
| I | DayBuilder 入力契約 → **DayBuilderContext 構造体**。pure function、祝日判定関数注入 |
| C | EXDATE と pattern → **C-2 共通除外機能**。`task_template_exdate` は rrule・pattern 両方の絶対除外 |
| H | day_meta.manual_override → **H-3 廃止**。day_meta は (date, applied_pattern_id?) の 2 列のみ |
| G | pattern.apply_day=NULL の用途 → **G-1 維持**。stock pattern 必須機能 |

各論点の詳細経緯・代替案・却下理由は memory `project_life_tracker_v2_core.md` 参照。

---

## Phase 2 以降の持ち越し論点

Phase 1 設計では塞いでいないが、Phase 2 着手前に方針を決める必要がある論点。

### iCalendar export 時の pattern → VEVENT 翻訳方針

- pattern 概念は業界に前例なし
- Apple Calendar / Google Calendar 双方向同期時の暫定方針:
  - 内部→外部: 「rrule 由来のみ同期、pattern 由来は単発 VEVENT 化 (or 同期対象外)」
  - 外部→内部: 「単発 VEVENT は scheduled_task に template_id=NULL で落とす」
- 連携実装前に明文化必須

### HealthKit sleep の DayMembership 別ロジック注入

- `DayBuilderContext` に `sleepDayAttribution: SleepAttributionRule` を追加
- `category=sleep` の actual_task に対しては HealthKit 同型 (endDate + 18:00 境界) で primary day を計算
- Phase 1 の DayBuilder pure function 構造はそのまま流用可
- `sleep_actual_input.healthkit_sample_uuid TEXT?` を追加して同期 sample を識別

### EventKit / Google からのインポート時の RECURRENCE-ID マッピング

- 外部の「定期予定の単発編集」をどう scheduled_task に落とすか
- template_id を新規生成して紐づける運用 (外部 template の DB シードロジック) が必要

### iCalendar export 時の DTSTART 変換

- 内部表現は `task_template.start_minutes_from_midnight + duration_minutes` (相対)
- RFC 5545 DTSTART は rrule の最初の発生日
- export 時に「rrule 評価で得た最初の発生日 + start_minutes」で `DTSTART` を生成

### actual_task の派生元 (source_template_id)

- 予実分離 (FK なし) は維持しつつ、同 category 内で複数 template (例: ジム=同 category だが胸/脚) のストリーク集計が必要になった時点で `actual_task.source_template_id` (FK なし、informational hint) を検討

### learning_actual_input の DDL 設計

- PMBOK 計画統合の要件確定後に DB 設計を詰めて追加 (Phase 1 では作らない)
- `category.sub_input_kind` の CHECK に `'learning'` を追加する ALTER TABLE と同時に投入

---

## 業界標準との整合性

v2 設計は以下と一致 (memory `project_life_tracker_v2_industry_research.md` 参照):

- **day カラムをタスクに焼かない** (Google Calendar / Apple EventKit / Notion / HealthKit 全員一致)
- **日跨ぎ 1 レコード保持** (業界全員一致)
- **「0:00-24:00 で按分集計」** (RescueTime / 時間スライス流派)
- **タスクと day を永続的 FK で繋げない** (HealthKit の sample / Health UI 構造と同じ)
- **編集済み実体固定** (Google Calendar / RFC 5545 RECURRENCE-ID 例外イベント方式)
- **「すべて削除」= 論理削除** (Google Calendar 同型、template 物理削除でない)

避けたアンチパターン:
- タスクに `day_id` FK 直結 (Toggl の started-on 流派)
- 日跨ぎ物理 2 レコード分割 (業界に前例なし、編集 UX 崩壊)
- Todoist の duration ≤ 24h 制約 (不要、`duration_minutes <= 1440` で日跨ぎ表現)

---

## 関連ドキュメント

- `docs/spec.md` — v2 コア定義・スコープ・構造原則
- `docs/structural-conventions.md` — SwiftUI View 階層・情報アーキテクチャ規約
- `docs/agent-delegation-template.md` — Agent 依頼時のプロンプトテンプレ
- memory `project_life_tracker_v2_core.md` — 細部 1-6 の決定経緯詳細・代替案・却下理由
- memory `project_life_tracker_v2_industry_research.md` — 業界標準調査結果
