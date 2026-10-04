# 継続の仕組み（週 N 回基準の連続・リング・ヒートマップ・ウィジェット）

作成: 2026-09-30 / 状態: 実装済み・9/30 commit 済・本番 DB に migration 0005 適用済（ブランチ feat/round3-training）・実機未確認

## 本人決定（2026-09-30）
- 連続日数・リング・ヒートマップなどの継続の仕組みを**入れる**。INV-6（作らない）は廃止
- 基準は事前に選ぶ「週何回トレーニングするか」。**休息前提の日に休んで連続記録が途切れるのは良くない**
- 連続の単位: **連続日数（休息日も含む）**。Duolingo のように「🔥 45日」。目標を満たした週が続くかぎり休んだ日も数える
- 途切れる時点: **週が終わった時点**（日曜が終わって N 回未満）。それまでは「あと 2 回」と出す
- ヒートマップ: **分析画面に直近半年**。GitHub の草の形（列=週・行=曜日）。色の濃さ=その日のボリューム。トレーニング画面は週帯のまま
- ウィジェット: **ホーム小**（🔥連続＋今週のリング）と**ホーム中**（連続＋リング＋今週 7 日の点）。ロック画面は今回なし
- 経緯・比較: `gymwork-retention-comparison.md`

## AI が決めた既定（本人未確認。違えば直す）
| 論点 | 既定 | 理由 |
|---|---|---|
| トレーニングした日の定義 | その日（completed_at の JST 暦日）にセットが 1 つでもある日。ウォームアップだけの日も含む | 日の基準を既存（週帯の点）と揃える |
| 週の区切り | 月曜始まり | 既存の週帯・週分析と同じ |
| 目標の範囲 | 週 1〜7 回 | |
| 目標を途中で変えたとき | その週から新しい目標。過去の週は当時の目標で判定（目標の履歴を持つ） | 目標を上げた瞬間に過去の連続が消えないように |
| 最初の目標を決める前の週 | 最初の目標で判定する | 設定した日から、過去の実績で連続が出る |
| 連続日数の起点 | 連続している最初の週の、最初のトレーニング日 | 「🔥 1日」はトレーニングした日に始まる |
| 目標未設定のとき | トレーニング画面に「週の目標回数を決める ›」の 1 行。ウィジェットは「目標を設定」 | オンボーディングは作らない（本人決定） |
| 表示場所（アプリ内） | トレーニング画面の週帯の上に 1 行「🔥 45日 ◔ 今週 2/4 · あと2回」。タップで目標の変更 | 1 画面目の縦幅を 1 行だけ使う |

## 設計
### データ（migration `0005_training_goal.sql`）
- `training_goal(id, weekly_target SMALLINT CHECK 1..7, effective_from DATE UNIQUE CHECK 月曜, created_at)`。同じ週に変えたら上書き（upsert）
- `workout_training_day` view: `SELECT DISTINCT (completed_at AT TIME ZONE 'Asia/Tokyo')::date AS day FROM workout_set WHERE completed_at IS NOT NULL`。連続日数は全期間の日付が要るため、セット本体を読まずに日付だけ取る（INV-5: 読み取り時の集計は可）
- 連続日数・リングは保存しない（計算で出す）

### 計算（pure・`Shared/Continuity.swift`。アプリとウィジェットで共有）
- `status(trainingDays:goals:today:calendar:) -> ContinuityStatus?`（目標なしは nil）
  - 前週から遡り、目標を満たした週が続く最古の週を探す。前週が未達なら今週が起点
  - 起点の週以降の最初のトレーニング日から今日までの日数 = 連続日数（トレーニング日がなければ 0）
  - 今週: 回数・目標・あと何回・残り日数・今週 7 日のトレーニング有無
- `heatmap`（アプリのみ）: 直近 26 週 × 7 日のボリューム → 5 段階

### ウィジェット
- App Group `group.com.ryunosuke.LifeTracker` の UserDefaults に「トレーニング日一覧＋目標の履歴」を書く（アプリが読み込み・記録・目標変更のたびに更新し、`WidgetCenter.reloadAllTimelines()`）
- ウィジェットは同じ pure 関数で計算する。タイムラインは今から 7 日ぶんの 0:00 ごと（アプリを開かなくても日付・週の切り替わりで数字が進む／途切れる）
- 既存の RestTimerWidget 拡張に同居させる（WidgetBundle に追加）

## 完了条件
- [x] migration を書く（`supabase/migrations/0005_training_goal.sql`）。2026-09-30 本人 OK で本番 DB に適用（MCP apply_migration `v2_training_goal`。適用直後は目標 0 件・トレーニング日 0 件、anon から読み書き可・RLS 無効は既存テーブルと同じ）
- [x] pure 関数のテスト（`ContinuityTests` 9 件: 休息日で途切れない・週末で途切れる・目標変更・目標前の週・今週未達でも継続・0 件・ヒートマップの段階・目標の上書き）。単体テスト全体も成功
- [x] モック（`-mock-workout`）でシミュレータ確認（2026-09-30）
  - 目標未設定で「週の目標回数を決める ›」→ 週 2 回で保存 →「🔥17日 ◯ 今週 2/2 · 達成」（モックの記録から手計算した値と一致）
  - 分析の先頭に連続＋直近 26 週のヒートマップ
  - ホーム画面ウィジェット 小・中 がアプリと同じ値（中は今週 7 日の点つき）
- [ ] 実機確認は本人（ウィジェットの App Group の署名を含む）

## 実装メモ
- 置き場: 計算 `Shared/Continuity.swift`・表示部品 `Shared/StreakViews.swift`（アプリとウィジェットで共有）、`Services/ContinuityStore.swift`、`Views/Workout/ContinuityViews.swift`（1 行・目標シート・ヒートマップ）、`RestTimerWidget/StreakWidget.swift`
- App Group `group.com.ryunosuke.LifeTracker` の entitlements をアプリ（`LifeTracker/LifeTracker.entitlements`）とウィジェット（`RestTimerWidget.entitlements`）に追加
- 途中で見つけた不具合: 目標シートから `(Int) async -> Error?` のクロージャで値を渡すと、保存側に壊れた値（10218280256）が届いた（シート内では 2）。原因は特定していない。ProgramEditView と同じく store を直接渡す形に変えて解消
