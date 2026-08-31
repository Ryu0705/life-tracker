# トレーニング・サブドメイン設計 (2026-08-30)

**状態**: 設計提案（未承認・未適用）
**位置づけ**: 本ファイルは*判断根拠*の記録。承認後、DDL 本体は `domain-model.md` v16 に取り込み、本ファイルからは DDL を削除して根拠のみ残す（`feedback_doc_hierarchy_single_source`）。

---

## 1. 背景と決定

### 決定 1: v2 を作り直さない（2026-08-30）

再開にあたり「現行を編集するか作り直すか」を検討。**編集で進める**。

**根拠**:
- 引き金は「設計の誤り」でも「計画の重さ」でもなく **現行設計が届いていない機能がある** ことだった
- v2 のコア（1日サイクル / 予実分離 / パターン）はトレーニング機能と矛盾しない。spec の対象に「健康記録（睡眠/食事/**運動**/体調）」が明記済み
- 実測: `gym_actual_input` への Swift コードからの参照 **0件**（唯一の接点は `Category.swift` の `enum SubInputKind { case gym }` 2行）。DB 実データも空
- → **壊すのは10テーブル中1テーブルのDDLのみ**。1日サイクル側は無傷。作り直しの範囲を「アプリ全体」から「1テーブル」に縮小できる
- 作り直した場合、day-cycle 部分を再度書き直す作業は純損。かつ **専用アプリに対する唯一の優位（睡眠・食事・スケジュールと同一DBにセット単位ログが乗る＝原則1「1日 = 全結合の影響グラフ」）** を一から作り直すことになる

### 決定 2: Round 3（minimum viable）をトレーニング先行に再定義

**根拠**:
- v2 は 2026-05-01 以降 120日起動されていない一方、ジム習慣は継続している
- トレーニングログは「**読むために書く**」データ（前回の重量を見ないと今日のセットが組めない）。1日サイクルの予実記録は「書いても読む理由が薄い」。継続の構造的強度が違う（仮説）
- 実際に起動される確率が最も高いスライスを minimum viable に置く

### スコープ（本人選択 2026-08-30）

採用: **記録の解像度** / **進捗の可視化** / **ルーティン・メニュー** / **継続したくなる仕組み**
非選択: セッション中の体験（休憩タイマー等）—— ただし後述の制約参照

### 参照アプリと期待値の調整

Liftoff は "Ranked Gym Workouts" で、売りは**他ユーザーとのランキング比較**を含むゲーミフィケーション。
本プロダクトは個人ツール方針（公開・マネタイズ視野外 / `project_life_tracker_positioning`）のため **他者比較は構造的に実装不能**。
実装対象は **自分比較のゲーミフィケーション**（PR更新 / 連続週数 / ボリューム推移 / 部位別バランス）に限定する。

---

## 2. 現行モデルが届いていない範囲

```sql
-- 現行（0001_initial.sql）
CREATE TABLE gym_actual_input (
  actual_task_id UUID UNIQUE,   -- actual_task と 1:1
  exercise       TEXT NOT NULL, -- 種目名を素の文字列で1つ
  weight         NUMERIC(6,2),
  reps           INT,
  sets           INT
);
```

「ベンチプレス 60kg × 10回 × 3セット」を **1行**で持つ設計。

| 届かないもの | 理由 |
|---|---|
| セットごとの差（`60×10 / 65×8 / 65×6`） | `(weight, reps, sets)` の3つ組が1組しかない＝全セット同一前提 |
| PR / 推移の集計 | `exercise` が TEXT 直書き。表記ゆれで名寄せ不能 |
| 1セッション複数種目 | `actual_task` と 1:1。種目を足すとタスクが増える |
| ルーティン / 前回参照 / 1RM / ボリューム | 概念自体が無い |

→ 機能追加ではなく**サブドメインの作り直し**が必要（ただし範囲は上記1テーブル）。

---

## 3. 構造判断

### 判断 A: `workout_session` は独立アグリゲート。`actual_task_id` は nullable

**これは実装順序から導かれる必然**である。

`actual_task` を生成するのは「チェックイン」機能（元 Round 3 スコープ、未実装）。
もし `workout_session` を `actual_task` に 1:1 で従属させると、**トレーニングログがチェックイン実装に依存し、「トレーニング先行」が成立しない**。

```
却下案: actual_task (1) --- (1) workout_session      … チェックイン未実装だとセッションを作れない
採用案: actual_task (0..1) -- (1) workout_session      … 単独で記録開始でき、後からリンクできる
```

`actual_task_id` を nullable FK にすることで:
- トレーニングログは 1日サイクル側が未完でも単独で動く
- チェックイン実装後（新 Round 5）に、セッションを当日の `actual_task` へ紐づけて day-cycle と合流できる
- 結合（睡眠×重量の相関等）はリンク済みセッションから取れる

**副次的効果**: Round 1 で「Round 3 着手前に再決定」と保留されていた論点（*write 系を `DayDataSource` 拡張にするか別 protocol にするか*）が解ける。workout は独立アグリゲートなので **別 protocol `WorkoutDataSource`** が自然。`DayDataSource` は肥大化させない。

### 判断 B: `exercise` 種目マスタを新設。`metric_kind` でウェイト/自重/有酸素を吸収

TEXT 直書きをやめないと PR も推移も成立しない。
有酸素（ランマシン）を別テーブルに分けるのは種目数が少ない個人ツールでは overkill のため、`metric_kind` による列の使い分けで吸収する（NULL 列は許容）。

### 判断 C: `routine` は v2 の `pattern` / `task_template` とは別系統

「プッシュの日 / 脚の日」は1日のパターンとは別の周期概念。
`task_template` に相乗りさせると Round 6a/6b（テンプレ管理UI）への依存が生まれ、トレーニング先行が崩れる。
将来 `task_template.routine_id` で寄せる余地は残すが、Phase 1 では独立させる。

### 判断 D: PR / 推定1RM / ボリューム / ストリーク / 部位別バランスは**導出**。テーブル追加なし

すべて `workout_set` から集計可能。「継続の仕組み」はデータモデルを膨らませない。

- PR: 種目ごとの最大重量・最大推定1RM（`is_warmup = false` のセットのみ）
- 推定1RM: Epley 式 `weight × (1 + reps/30)`（採用式は実装時に確定）
- ボリューム: `Σ weight × reps`（warmup 除外）
- ストリーク: `workout_session` の日付から週次で導出
- 部位別バランス: `exercise.muscle_group` で集計

**週目標回数**（ストリーク判定の閾値）は履歴不要の設定値のため UserDefaults に置く。DB に1行テーブルを作らない。
※ 将来「当時の目標」を振り返りたくなった場合のみ DB へ昇格。

### 判断 E: `gym_actual_input` は DROP

実データ空・Swift 参照0件のため安全。`category.sub_input_kind` の `'gym'` は維持（意味が `workout_session` への入口に変わる）。
**破壊的操作のため、実行前に接続先をユーザーへ確認する**（`feedback_destructive_ops_confirm`）。

---

## 4. DDL と seed（実ファイル）

DDL の SSOT は既存規約どおり **`domain-model.md` v16**（migration は "Source of truth: docs/domain-model.md" を宣言して従う側）。本節は**そこから読み取れない判断根拠**のみ記す（`feedback_doc_hierarchy_single_source`）。

| ファイル | 役割 |
|---|---|
| `docs/domain-model.md` v16 | **DDL の SSOT**。`exercise` / `routine` / `routine_exercise` / `workout_session` / `workout_set`、および `gym_actual_input` 撤去の記録 |
| `supabase/migrations/0003_training_domain.sql` | v16 を DB へ適用する migration（`DROP TABLE gym_actual_input` を含む） |
| `supabase/migrations/0004_exercise_seed.sql` | 一般的な種目 **159件** の seed |

既存規約に準拠: 単数形テーブル名 / `UUID PRIMARY KEY DEFAULT gen_random_uuid()` / 重量は `NUMERIC` / `TIMESTAMPTZ` / `ON DELETE` を明示。

### 設計改訂（2026-08-31）— seed を書いて判明した3件

seed を具体化した結果、3節の DDL 案では表現しきれない箇所が出たため改訂した。**適用前・実データゼロの時点で検出できたため、修正コストはファイル編集のみ**。

| # | 改訂 | 理由 |
|---|---|---|
| 1 | `muscle_group` を 7 → **14 値**に分割（`legs` → `quads`/`hamstrings`/`glutes`/`calves`、`arms` → `biceps`/`triceps`/`forearms`、`traps`/`full_body` 追加） | 7 値のままだと 159 種目の過半が `legs`/`arms` に落ち、**部位別バランスで「ハムだけ抜けている」が検出できない**。本人が選んだ「進捗の可視化」が機能しなくなる |
| 2 | `metric_kind` に **`duration` を追加**（`weight_reps` / `reps_only` / `duration` / `duration_distance` の4値） | プランク・ウォールシット・デッドハング・ステアクライマー等は時間のみ。`duration_distance` に寄せると**距離入力欄が常時出る UI ワート**になる |
| 3 | `equipment` に `kettlebell` / `band` を追加、`exercise.note`（マシンの使い方・シート高さ等のメモ）を追加 | `note` は `project_gym_habit` に記録された「マシン使い方わからない問題」への直接の受け皿 |

### seed の方針

- 使わない種目は削除せず `is_archived = true` で隠す（`workout_set` からの参照先消失を防ぐため物理削除しない）
- `sort_order` は部位ごとに 100 番台単位で、間に挿入できるよう番号を空けてある
- `ON CONFLICT (name) DO NOTHING` で再適用可能

内訳: 背中20 / 胸19 / 体幹18 / 肩15 / 大腿四頭15 / 有酸素13 / 三頭11 / 二頭10 / 全身9 / ハム8 / 臀部7 / 僧帽5 / 前腕5 / ふくらはぎ4。
metric_kind 別: `weight_reps` 111 / `reps_only` 28 / `duration_distance` 11 / `duration` 9。

### 意図的に入れなかったもの

- **ファーマーズウォーク** — 「重量 × 時間/距離」の組で、4つの `metric_kind` のどれにも当てはまらない。専用の5つ目を1〜2種目のために足す価値がないため除外した。必要になった時点で `weight_duration` を追加する

### その他の設計メモ

- `workout_session.actual_task_id` は `ON DELETE SET NULL`。actual_task を消してもトレーニング記録は残す（記録の方が価値が高い）
- 進行中セッションは部分 UNIQUE INDEX で**同時1件まで**に制限（二重開始を構造で防ぐ）
- `exercise` / `routine` は物理削除せず `is_archived`（`ON DELETE RESTRICT` と組で過去ログを守る）
- `metric_kind` と実際に埋まる列の整合は別テーブル参照が必要で CHECK では表現できないため**モデル層で担保**

---

## 5. Round 再編案

| Round | 旧 | 新 | S級 |
|---|---|---|---|
| 3 | actual記録（チェックイン+サブ入力） | **トレーニング記録** ← minimum viable | 3 |
| 4 | pattern切替 / day_meta | **ルーティン + 進捗可視化 + 継続の仕組み** | 3 |
| 5 | 過去日read-only | actual記録（チェックイン）※ここで day-cycle と合流 | 3 |
| 6以降 | — | 旧 Round 4/5/6a/6b/7/8 を繰り下げ | — |

### 新 Round 3 の S級内訳
- **S-DB-2**: migration `0003_training_domain.sql` 適用 + 初期種目 seed
- **S-Pure-3**: `WorkoutDataSource` protocol + Supabase/Mock 実装 + モデル（判断 A の副次結論）
- **S-View-3**: セッション記録画面（ルーティン or 種目選択 → セット入力 → **前回セッションの参照表示**）

### Acceptance に必ず入れる制約
「セッション中の体験」は本人の優先選択から外れたが、**セット単位入力がジムで実際に回らなければ記録の解像度そのものが絵に描いた餅になる**。
最低限、以下を Round 3 の acceptance に含める:
- [ ] 片手・立位でセット記録を1件追加できる（タップ数と誤タップしないタップ領域を実機で確認）
- [ ] 前回同種目の重量×レップが入力画面上で見える（＝「読むために書く」構造の成立確認）

休憩タイマー等の作り込みは Round 4 以降に置く。

---

## 6. 未確定 / 次アクション

1. 本設計の承認
2. ~~`domain-model.md` を v16 に改訂~~ → **2026-08-31 完了**
3. ~~`implementation-roadmap.md` の Round 表を再編~~ → **2026-08-31 完了**（全11 Round に）
4. ~~`spec.md` の Phase 1 範囲に追記~~ → **2026-08-31 完了**（スコープ基準が「解像度」を判定できない件も注記）
5. ~~ビルド・テストの生存確認~~ → **2026-08-31 完了**。`TEST SUCCEEDED` / 30 tests 全 pass / Xcode 26.3 / iPhone 17 sim 健在。**技術的陳腐化は起きていなかった**
6. ~~初期種目 seed の中身をヒアリング~~ → **2026-08-31 完了**。本人希望により特定メニューに絞らず一般的な種目159件を全投入する方針に変更（使わないものは `is_archived` で隠す運用）
