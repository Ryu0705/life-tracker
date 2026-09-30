# Life Tracker v2 実装ロードマップ (Phase 5 成果物)

Phase 1 範囲 (`spec.md`「Phase 1 で実装する範囲」) を **11 Round** (Round 8 は 8a/8b に分割) に分解する。Round 3 完了で minimum viable (個人運用開始可能)。

各 Round の S 級件数は 3〜5 件 (v1 R10 直列 4 件で機能した規模感)。S 級は **直列**、B/C 級は並列 Wave 可 (`agent-delegation-template.md` 参照)。

---

## 全体方針

- **順序の根拠**: 副作用分離 (`feedback_side_effect_prevention`) と「最小スライスで早く運用開始」の両立。詳細は本ファイル末尾「Round 順序の決定根拠」参照
- **Round 完了条件**: 当該 Round の Acceptance を全件 OK + 親レビュー (`agent-delegation-template.md` チェックリスト) + ユーザー実機確認 (S 級含む Round のみ)
- **事前壁打ち**: 各 Round 着手前に選択肢形式で再壁打ち (`feedback_re_walkthrough_before_implementation`)。QA 粒度は構造に影響する論点のみ (`feedback_qa_granularity_for_implementation_round`)
- **規約発火タイミング**: Round 1 は D-4 / D-5 のみ。Round 2 以降は A / B / C / E 全規約発火 (`structural-conventions.md` 「規約発火タイミング」表)。`CLAUDE.md` は「Round 1-2」一括表記だが、本ロードマップでは Round 1 / 2 に細分化 (Round 2 から View 規約発火)
- **磨き込み Round (Round 8) は機能 Round と分離**: `feedback_polish_vs_feature_cadence` に従い S 級採用は 5-7 件上限

---

## Round 一覧

> **2026-08-31 改訂**: Round 3 以降を再編。トレーニング記録を minimum viable に前倒しした。
> 判断根拠は `training-domain-design.md`。旧 Round 3-8 は 5 以降へ繰り下げ (スコープ自体は不変)。

| Round | スコープ | S 級件数 | 状態 |
|-------|---------|---------|-----|
| 1 | DB 基盤 + DayBuilder pure function | 3 | ✅ 完了 (2026-04-28) |
| 2 | 当日表示 (read-only、後続 Round 用 slot 確保) | 3 | ✅ 完了 (2026-05-01) |
| 3 | **トレーニング記録 (セッション + セット単位)** | 3 | 実装中 (S-DB-2 済 2026-08-31 / S-Pure-3・S-View-3 2026-09-30〜、`round-3-work-plan.md`) ← **minimum viable** |
| 4 | ルーティン管理 + 進捗可視化 + 継続の仕組み | 3 | 一部前倒し済（2026-09-30: プログラム登録・週分析・継続の仕組み＝`continuity-design.md`） |
| 5 | actual 記録 (チェックイン) ※ここで day-cycle と合流 | 3 | 未着手 |
| 6 | pattern 切替 / day_meta | 3 | 未着手 |
| 7 | 過去日表示 (read-only) | 3 | 未着手 |
| 8a | テンプレ管理 UI + exdate 編集 | 3 | 未着手 |
| 8b | パターン・カテゴリ管理 UI | 4 | 未着手 |
| 9 | 個別実体編集 (E-A / F-A 3 択) | 4 | 未着手 |
| 10 | 磨き込み + α | S 級 5-7 件上限 / B-C 主体 | 未着手 |

### 新 Round 3: トレーニング記録 (minimum viable)

**S 級内訳**:
- **S-DB-2**: migration `0003_training_domain.sql` + `0004_exercise_seed.sql` (種目 159 件) 適用
- **S-Pure-3**: `WorkoutDataSource` protocol + Supabase / Mock 実装 + モデル
  (Round 1 で保留された「write 系を `DayDataSource` 拡張か別 protocol か」の再決定 = **別 protocol** で確定)
- **S-View-3**: セッション記録画面 (ルーティン or 種目選択 → セット入力 → 前回セッション参照)

**Acceptance に必ず含める**:
- [ ] 片手・立位でセット記録を 1 件追加できる (タップ数 / 誤タップしないタップ領域を実機確認)
- [ ] 前回同種目の重量 x レップが入力画面上で見える (= 「読むために書く」構造の成立確認)
- [ ] セット毎に異なる重量 (60x10 / 65x8 / 65x6) が記録・再表示できる
- [ ] 有酸素 (`duration_distance`) と自重 (`reps_only`) で入力欄が切り替わる

休憩タイマー等のセッション中 UX の作り込みは Round 4 以降。

> **2026-09-30 改訂 (本人フィードバック)**: 「開始ボタンが嫌。単純に何をしたのかを記録したいし、成長推移が見たい」を受けて Round 3 のスコープを変更した。詳細・経緯は `round-3-work-plan.md`
> - セッションの開始・終了操作を廃止 (その日最初のセット記録で当日の `workout_session` を自動作成、日付が変わったら自動で閉じる。DDL 変更なし)
> - **進捗の可視化を Round 4 から前倒し**: 種目ごとの推移グラフ (ウェイト = 最高重量 / 推定1RM / ボリュームの切替、自重 = 最多回数、時間 = 最長時間、有酸素 = 距離 / 時間) + ベスト表示 + 日ごとの履歴
> - ルーティンから開始する UI は外した (ルーティン管理と合わせて Round 4 で再検討)
> - 2026-09-30 追記: プログラム（= ルーティン）の登録・編集・削除・呼び出しは Round 3 に前倒しして実装済み（`gymwork-alignment-design.md`「変更 1」）。目標値（target_sets 等）は未使用
> - Round 4 に残るもの: ルーティンの目標値、部位別バランス、連続週数などの継続の仕組み、セットの編集 (C-4)
> - **2026-09-30 Gymwork 寄せ (記録画面以外、SSOT `gymwork-alignment-design.md`)**: 週帯＋過去日 read-only・今日の合計バー・カード見出し e1RM・前回の組み合わせ読み込み・週分析 (push) を追加。トレーニング Round 4 で過去日の編集を足すときは `PastDayView` に `isReadOnly` を**必須引数**として導入して差し込む (C-5。差し込み位置は PastDayView のコメントで予約)
> - **記録画面は Gymwork 型 (同日、本人「使いづらい。Gymwork を参考に」+ 操作録画)**: 種目カード × セット行 (セット | 前回 | kg | 回 | ✓)、行は前回の値で埋まり ✓ で記録。行タップで入力シート (± 刻み・残りのセットに適用・セット完了)、休憩タイマー 3:00、推定1RM 自己ベスト通知、部位チップ＋複数選択の種目追加。重量刻みはプレート系 1.25kg / 5kg・ダンベル系 2kg / 4kg (本人指定)

---

## Round 1: DB 基盤 + DayBuilder pure function

**目的**: 物理基盤と pure ロジックの最下層を構築。UI 着手前にユニットテストで検証可能にする。

**着手前事前壁打ち確定事項** (2026-04-26、memory `project_life_tracker_v2_core` 参照):

| # | 論点 | 確定 |
|---|-----|-----|
| 1 | Xcode プロジェクト構成 | **単一 app target + `Sources/{Models, Services, DayBuilder, Views}` + `LifeTrackerTests`**。マルチターゲット分割は不採用 (個人開発規模で overkill)。サブディレクトリは Round 進行に応じて追加可 (例: `Sources/Views/Home/`、`Sources/Services/Sync/`)、初期 4 ディレクトリは固定 |
| 2 | 祝日ライブラリ | **`HolidayJp` SwiftPackage (`holiday-jp/holiday_jp-swift`) 採用** (Phase 2 持ち越しから Round 1 に昇格)。`DayBuilderContext.holidayChecker` に注入 (注入例: `holidayChecker: { date in HolidayJp.isHoliday(date) }`、具体 API は SwiftPackage 採用版に従う)。hardcode テーブル案は祝日改訂時の手動更新リスク + Phase 1 期間 4-6 ヶ月でも本人運用上の信頼性が下がるため却下、内閣府 CSV 直読み案は parser コスト + キャッシュ設計の追加発生で却下 |
| 3 | DayDataSource / Service 抽象化 | **D 中間案: `DayDataSource` service-level protocol のみ** (entity 別 protocol なし)。`SupabaseDayDataSource` (本番) と `MockDayDataSource` (テスト) の 2 実装で DayBuilder ユニットテストの注入点を確保。entity 別 protocol は Phase 2 で data source 差替え (HealthKit 等) が発生したタイミングで切り出し。**Round 3 以降の write 系 (actual UPSERT / scheduled 一括削除 / template 等 CRUD) は `DayDataSource` を拡張するか別 service protocol を切り出すかを Round 3 着手前に再決定する (Phase 2 持ち越しではなく Phase 1 内で発生する別軸)** |
| 4 | Migration 運用 | **`mcp__supabase-personal__apply_migration` only** (Supabase CLI 不採用)。本人 1 環境前提、CLI セットアップコスト削減。**Round 5 完了 = 本人実運用開始以降の DDL 変更は `mcp__supabase-personal__create_branch` で branch 検証してから main 適用に運用切替** (実データを抱えた本番 DB 直叩きを避ける) |

判断根拠詳細 (B 案 → 仕様変更耐久性指摘 → 2 種類分解 → D 中間案着地) は memory `feedback_change_durability_decompose` 参照。

**スコープ**:
- Xcode プロジェクト初期化 (単一 target + 上記ディレクトリ構造)
- DDL 投入: `domain-model.md` の v15 全 DDL (`category` / `task_template` / `task_template_exdate` / `pattern` / `pattern_template_membership` / `scheduled_task` / `actual_task` / `day_meta` / `gym_actual_input` / `sleep_actual_input`)
- 祝日チェッカー: `HolidayJp` SwiftPackage を SPM 依存に追加、`DayBuilderContext.holidayChecker` クロージャ内で呼び出し
- DayBuilder pure function (`domain-model.md` 入力契約に従う)
- `DayDataSource` protocol + `SupabaseDayDataSource` 実装 + `MockDayDataSource` 実装 (テンプレ / パターン / scheduled / actual / day_meta フェッチ + 当該日 scoping)

**S 級内訳** (依存順序: S-DB-1 と S-Pure-1 (Mock 注入) は並列可、S-Pure-2 の Supabase 実装は S-DB-1 完了後):
- S-DB-1: migration `0001_initial.sql` (全 DDL + index + partial unique + CHECK) を MCP `apply_migration` で適用
- S-Pure-1: DayBuilder + DayBuilderContext + DayTask 拡張 (現在ブロック特定 / origin 識別)
- S-Pure-2: `DayDataSource` protocol + `SupabaseDayDataSource` (Supabase Swift SDK で実装) + `MockDayDataSource` (テスト用、固定データ返却)

**Acceptance**:
- [ ] Xcode プロジェクトが `Sources/{Models, Services, DayBuilder, Views}` + `LifeTrackerTests` 構造で生成済 (`xcodeproj` ファイル + 各ディレクトリ存在)
- [ ] `HolidayJp` SwiftPackage が Xcode の Package Dependencies に追加済 (`grep -r "HolidayJp" *.xcodeproj/project.pbxproj` で確認可能)
- [ ] supabase に migration 適用済 (`mcp__supabase-personal__list_tables` / `list_migrations` で確認)
- [ ] DayBuilder ユニットテスト pass (`MockDayDataSource` 経由):
  - [ ] rrule デフォルト合成 (平日 / 土日 / 祝日 — 祝日ケースは元日 2027-01-01・建国記念の日 2027-02-11 等、Phase 1 期間 (2026-04-26〜) に到来する祝日 2-3 件で `HolidayJp` 実日付検証)
  - [ ] pattern overlay (overflow 込み) — **全置換セマンティクス**
  - [ ] exdate 除外 (`task_template_exdate`)
  - [ ] scheduled_task 実体優先 (B-X 由来識別 + 編集済み実体固定)
  - [ ] DayMembership 判定 (primary / spillover / overflow)
- [ ] DayBuilder 出力拡張:
  - [ ] **`Day.currentBlock(at: Date) -> DayTask?`** API 提供 (spillover 抑制規約付き、`feedback_derived_state_no_transition_event` 適用)
  - [ ] **`DayTask.origin` enum (`rrule | pattern | manual`) 付与** — Round 7 の F-A 3 択 / 2 択判定で必要
- [ ] `DayDataSource` protocol が定義され、`SupabaseDayDataSource` / `MockDayDataSource` の 2 実装が存在 (`grep -rn "protocol DayDataSource" Sources/` で 1 件 + `grep -rn ": DayDataSource" Sources/` で 2 件 hit)
- [ ] `MockDayDataSource` に DayBuilder ユニットテスト用の fixture (平日 / 土日 / 祝日 / pattern 適用日 / exdate 除外日 を網羅、上記テストケース駆動) が定義済
- [ ] 初期データ投入 (MCP 経由で平日 / 休日 pattern を最低 1 セット手動 INSERT) → `SupabaseDayDataSource` 経由で DayBuilder で当日 Day 構造体が正しく合成

**規約発火**: D-4 (DB 層: plan/actual 完全独立) / D-5 (DayBuilder 入力契約)

**View 規約は未発火**: 親レビューで grep 0 件 hit でも「規約準拠 OK」と誤判定しない (`CLAUDE.md` Round 別の規約参照範囲)

---

## Round 2: 当日表示 (read-only、Round 3 用 slot 確保)

**目的**: 「今日のスケジュールを見る」UX を完成。書き込み機能なし。**Round 3 の書き込み機能差し込み用 slot を Round 2 で確保**することで、Round 3 着手時に Round 2 の View 構造を再修正しない (副作用分離)。

**スコープ**:
- HomeView (当日 read-only)
- DayBuilder の出力 Day を時刻順表示
- 現在ブロックハイライト (`Day.currentBlock(at:)` 利用、Round 1 提供)
- pattern バッジ (rrule デフォルト = 「デフォルト」表示 / pattern 適用済 = pattern 名表示。Round 4 まで切替不可)
- ClockTick (1 分 timer、`scenePhase` で起動 / 停止、`feedback_swift_singleton_timer_bootstrap` 適用)
- **Round 3 用 slot**: HomeView 内に `CheckInActionLayer` (Round 2 では空 View) を構造として配置、Round 3 で中身を実装する形にする

**S 級内訳**:
- S-Pure-1: TodayDataLoader (Round 1 `DayDataSource` を当日 scoping で wrap、Singleton timer 起動連携)
- S-View-1: HomeView 構造 + Day 表示 + `CheckInActionLayer` slot (空 View)
- S-View-2: 現在ブロックカード (時刻ベースハイライト)

**Acceptance**:
- [ ] アプリ起動 → 今日のスケジュールが時刻順に表示
- [ ] 現在時刻のブロックがハイライト (色 / 枠で識別可能)
- [ ] pattern バッジが正しく表示 (rrule 由来時 = 「デフォルト」)
- [ ] 1 分後に表示が自動更新 (clockTick 動作、`scenePhase` で停止 / 再開)
- [ ] `CheckInActionLayer` が HomeView 内に構造として配置済 (空 View でも grep で確認可能)

**規約発火**: A / B / C-1〜C-8 / E (View 着手 Round から発火)

---

## Round 3: actual 記録 (minimum viable)

**目的**: 「予定をやった / やらなかった」を記録できるようにする。**ここで個人運用開始可能**。

**Round 2 で確保した `CheckInActionLayer` slot に書き込み機能を差し込む**。HomeView 自体の structural な変更は最小化。

**スコープ**:
- actual_task 作成 / 完了 / スキップ / 削除
- チェックイン UI (タップで完了マーク) → `CheckInActionLayer` に実装
- gym / sleep サブ入力 sheet (`category.sub_input_kind` 分岐)
- 予実差分の即時反映 (DayBuilder 再計算)

**S 級内訳**:
- S-Pure-1: ActualService (UPSERT + サブ入力分岐、`feedback_upsert_side_effects` 適用 = 部分 UPDATE / フィールド別分離)
- S-View-1: CheckInActionLayer 実装 (Round 2 slot 差し替え)
- S-View-2: SubInputSheet (gym / sleep 切り替え + 入力)

**Acceptance**:
- [ ] 当日タスクをタップで完了マーク → actual_task INSERT
- [ ] gym / sleep ブロックでサブ入力 → 対応する `*_actual_input` INSERT
- [ ] 予実差分が表示 (scheduled の上に actual を重ね、未完 / 完了が一目で識別可能)
- [ ] 削除すると actual_task が DB から消える
- [ ] サブ入力種別 (`category.sub_input_kind`) が `gym|sleep` 以外のカテゴリではサブ入力 sheet が出ない
- [ ] HomeView の View 構造は Round 2 から変更されていない (CheckInActionLayer 内部のみ変更、grep で structural-conventions.md A-1〜A-6 違反なし確認)

### Round 3 で minimum viable とする意思決定根拠

Round 1〜3 期間中 (Round 4 完了まで推定 2〜3 週間) は土日も平日と同じ予定が表示され、平日タスクが「missed 表示」される副作用が発生する。本人運用シナリオでは以下の理由で **許容**:
- 個人ツールであり (`project_life_tracker_positioning`)、見た目の違和感は本人が把握していれば運用可能
- Round 4 (pattern 切替) を最優先で続けることで違和感期間を短縮 (磨き Round 化しない)
- 「土日は missed 抑制 flag を category 側で持つ」等の最小回避策は副作用分離原則に反する (Round 3 のスコープを超え、後続 Round の前提を壊す可能性)

Round 3 完了 → Round 4 着手まで間を空けない運用とする。

**規約発火**: D-4 (UI 層: plan/actual 結合発火) / A / B / C / E

---

## Round 4: pattern 切替 / day_meta

**目的**: 「今日は休日パターン」「今日は何もしない」操作を完成。

**スコープ**:
- DayMetaSheet (pattern 選択 / 「何もしない日」/「デフォルトに戻す」)
- 切替時の scheduled_task 全置換セマンティクス (`domain-model.md` 「day_meta upsert / scheduled_task 一括削除の運用」)
- day_meta バッジの当日反映

**S 級内訳**:
- S-Pure-1: PatternApplyService (day_meta upsert + scheduled_task 削除 / 全置換、`feedback_upsert_side_effects` 適用 = 部分 UPDATE)
- S-View-1: DayMetaSheet UI
- S-View-2: バッジ統合 (HomeView)

**Acceptance**:
- [ ] 当日に pattern 切替 → scheduled_task が pattern membership に置き換わる (DB 直接確認: `mcp__supabase-personal__execute_sql` で `SELECT * FROM scheduled_task WHERE start_at AT TIME ZONE 'Asia/Tokyo' BETWEEN ...`)
- [ ] 「何もしない日」 → scheduled_task 0 件 + day_meta `applied_pattern_id IS NULL` で記録
- [ ] 「デフォルトに戻す」 → day_meta 削除 + scheduled_task 全削除 → rrule デフォルト復帰
- [ ] バッジで「ユーザー操作済み日」が一目で分かる
- [ ] 切替前に actual_task が存在する場合、actual は保持される (D-4: DB 層完全独立検証、`mcp__supabase-personal__execute_sql` で actual_task 行の保持を確認)

**規約発火**: 同上

---

## Round 5: 過去日表示 (read-only)

**目的**: 履歴を振り返れるようにする。

**スコープ**:
- 日付ナビゲーション (前日 / 翌日 / カレンダー UI)
- 過去日 read-only HomeView
- 過去日の scheduled_task / actual_task / day_meta 取得
- 未来日は範囲外 (`spec.md` Phase 1 範囲外、UI 上で押下不可 or グレーアウト)
- **`isReadOnly` 横断機能の導入**: 環境値 (`@Environment`) または View modifier として導入し、Round 7 編集 UI を当日 / 過去日で共通化する際に再利用可能にする (`structural-conventions.md` C-5 適用)
- ClockTick 停止: 過去日表示中は ClockTick を停止 (`scenePhase` 起動条件 + `selectedDate == today` を AND 条件化)

**S 級内訳**:
- S-Pure-1: PastDayLoader (date 指定フェッチ、当該日 scoping)
- S-View-1: 日付ナビゲーション UI
- S-View-2: PastDayHomeView (read-only 派生 + `isReadOnly` 横断機能導入)

**Acceptance**:
- [ ] 過去日を選択 → その日のスケジュール / 実績が見える
- [ ] 編集 UI が出ない (`isReadOnly` 経由で抑制)
- [ ] 過去日 pattern バッジが正しい
- [ ] 未来日は押下不可 or 表示しない
- [ ] 過去日表示中に ClockTick が停止 (実機で 2 分以上経過観察 / または Singleton state 確認)
- [ ] 過去日タップ時にサブ入力 sheet / 編集 sheet が出ない (実機確認)
- [ ] structural-conventions.md C-5 (read-only 横断引数) / C-2 (情報移譲時の過去日対応) 違反なし (親レビュー grep)

**規約発火**: 同上 + 過去日 read-only 規約 (主: C-5、従: C-2)

---

## Round 6a: テンプレ管理 UI + exdate 編集

**目的**: テンプレ追加 / 編集 / 削除 / exdate 編集をアプリ内で完結させる。

**スコープ**:
- TemplateListView / TemplateEditView (rrule 編集含む)
- exdate 編集 UI (テンプレから除外日追加)

**S 級内訳**:
- S-Pure-1: TemplateService (CRUD + exdate 操作)
- S-View-1: TemplateListView + TemplateEditView
- S-View-2: ExdateEditView

**Acceptance**:
- [ ] アプリ内でテンプレ CRUD ができる (rrule 編集含む)
- [ ] exdate 追加 / 削除ができる
- [ ] ON DELETE RESTRICT が効いて、参照中の `template_id` を持つテンプレは削除不可 (UI 側でエラー表示)
- [ ] 削除 RESTRICT エラーが UI から識別可能 (Round 1-5 期間中は MCP レスポンスで表面化していた挙動を UI 表示化)

**規約発火**: 同上

---

## Round 6b: パターン・カテゴリ管理 UI

**目的**: パターン追加 / 編集 / 削除 / membership 編集 / カテゴリ管理をアプリ内で完結させる。

**スコープ**:
- PatternListView / PatternEditView (membership 編集)
- CategoryEditView (Settings 配下に配置)

**S 級内訳**:
- S-Pure-1: PatternService / CategoryService (CRUD)
- S-View-1: PatternListView + PatternEditView (membership 含む)
- S-View-2: CategoryEditView (Settings 配下)
- S-View-3: 設定画面ハブ (Settings View、CategoryEditView の親)

**Acceptance**:
- [ ] アプリ内でパターン CRUD ができる (membership 編集含む)
- [ ] カテゴリ追加 / sub_input_kind 切り替えができる
- [ ] ON DELETE RESTRICT が効いて、参照中の `pattern_id` / `category_id` を持つパターン / カテゴリは削除不可 (UI 側でエラー表示)
- [ ] Settings View から CategoryEditView 動線到達可能

**規約発火**: 同上

---

## Round 7: 個別実体編集 (E-A / F-A 3 択)

**目的**: 「特定の日だけ予定を変える」「特定の予定だけ削除する」UX を完成。

**トレーニングタブの週帯との役割分担 (2026-09-30 `gymwork-alignment-design.md` J5)**: トレーニングタブの週帯は「トレーニング実施日の閲覧・過去日の read-only 表示」専用。今日タブの日付ナビを作るときは週帯と連動させない・二重化しない (役割分担をこの Round で決め直す)

**スコープ**:
- 当日 scheduled_task をタップで編集 → 編集済み実体固定 (E-A、`domain-model.md` 「個別タスク編集 / 追加」)
- 削除 3 択ダイアログ (この日のみ / 今日以降 / 全て削除、`domain-model.md` 「タスク削除の意味論 (F-A 採用)」)
- 仮想タスク → 物理 INSERT 化のフロー (Round 1 で付与した `DayTask.origin` enum で由来分岐)
- 影響範囲計算 (今日以降 = exdate 一括追加 / 全て = template 削除 + RESTRICT 制約に応じた scheduled_task 処理)

**S 級内訳**:
- S-Pure-1: EditService (E-A 編集済み実体固定、仮想 → 物理 INSERT)
- S-Pure-2: DeleteService (F-A 3 択 → exdate 操作 / template 削除)
- S-View-1: TaskEditSheet
- S-View-2: DeleteDialog (3 択 + 影響範囲プレビュー)

**Acceptance**:
- [ ] 仮想タスクをタップで編集 → 当日のみ反映、翌日以降は元のテンプレに従う
- [ ] 削除 3 択が `DayTask.origin` で正しく分岐 (rrule = 3 択 / pattern = 2 択 / manual = 1 択)
- [ ] 「今日以降」削除 → 今日以降の exdate に template_id を一括追加
- [ ] 「全て削除」 → template が消え、参照中の scheduled_task は ON DELETE RESTRICT でエラー (or 事前に scheduled_task を全削除する UX)
- [ ] pattern 由来タスクは 2 択 (この日のみ / pattern から外す)
- [ ] **Round 4 リグレッション**: pattern 切替 / 「何もしない日」/「デフォルトに戻す」が全件再現可能 (実機 + DB 確認)

**規約発火**: 同上 + F-A 削除セマンティクス

---

## Round 8: 磨き込み + α

**目的**: Round 1-7 で見送った微修正を集約。年数回 / 機能節目のみ実施 (`feedback_polish_vs_feature_cadence`)。

**スコープ (確定後)**:
- ビジュアル磨き込み (色 / 余白 / タイポ)
- アクセシビリティ
- リグレッション一掃
- rrule 編集 UI の UX 詰め (曜日チェック / N 日おきプリセット等、Round 6a で最低限実装した分の磨き)
- ~~過去日ヒートマップ / リング等のモチベーション仕掛け~~ → **2026-09-30 スコープ外**。習慣化の見せ方は既製アプリ Grit に任せる (`spec.md`「習慣化の境界線」)。トレーニング進捗の可視化 (Round 4) は対象のまま
  - ⚠ 2026-09-30 本人訂正: 「Grit は参考にと言っただけで、使っていないし使わない」。案A′の前提（頻度だけの習慣を Grit で管理する）は成り立たない。境界線・「習慣化専用の見せ方は作らない」・INV-6 を続けるかは本人判断待ち。このスコープ外扱いも前提が崩れている

**運用**: B/C 級主体。**S 級採用は 5-7 件上限** (`feedback_polish_vs_feature_cadence`)。超過する場合は Round 8 を分割。

---

## Round 順序の決定根拠

### 論点 1: pattern 切替 (Round 4) の位置

- **採用 (Round 3 後)**: actual 単体検証 → pattern 追加。副作用分離 (`feedback_side_effect_prevention`)
- 不採用 (Round 3 統合): Round 3 が S 級 5-7 件に肥大、actual と pattern の副作用が混ざる
- 不採用 (Round 2 直後): actual 不在で pattern 切替 = 「切替えても記録できない」中途半端

Round 1〜3 期間中の cosmetic 違和感 (土日も平日と同じ予定が表示) は許容 (Round 3 意思決定根拠参照)。Round 4 で解消。

### 論点 2: テンプレ管理 UI (Round 6a/6b) を後回し

- **採用 (Round 6a/6b)**: Round 1〜5 期間中は MCP 直 INSERT で運用 (`reference_supabase_accounts` の personal MCP)。Round 6 を 6a (テンプレ + exdate) / 6b (パターン + カテゴリ) に分割し各 3〜4 件に収める
- 不採用 (Round 2 前): read-only より前に CRUD UI が出るのは構造的に違和感
- 不採用 (Phase 2 持ち越し): 個人運用なら MCP で耐えられるが、本人運用継続性のため Phase 1 内に含める

**ON DELETE RESTRICT の挙動について**: Round 1 DDL 投入時点で `template_id` / `pattern_id` / `category_id` の RESTRICT が効くため、Round 1〜5 期間中に MCP 経由でテンプレ削除を試みれば RESTRICT エラーが MCP レスポンスとして返る (= 想定通り、本人が把握していれば許容)。Round 6a/6b で UI 表示化する。

### 論点 3: 個別実体編集 (Round 7) の独立性

- **採用 (Round 7 集約)**: E-A / F-A は仮想実体 → 物理 INSERT 化のフローで独自の検証点が多く、事前壁打ち対象が大きい
- 不採用 (Round 3 統合): Round 3 が 6+ 件で肥大

Round 7 は Round 4 の PatternApplyService と同じ DB 領域 (`scheduled_task` 全置換 / 一括削除) を触るため、Round 7 Acceptance に Round 4 リグレッション項目を必須化。

---

## Phase 2 以降の持ち越し (再掲)

`spec.md` および `domain-model.md` 「Phase 2 以降の持ち越し」と一致 (出典項目別):

`spec.md` 由来:
- Apple Watch / Live Activity / Dynamic Island
- HealthKit 連携 (sleep_actual_input INSERT、endDate + 18:00 境界)
- Mac mini サーバー連携 (`project_mac_mini_server`)
- iCalendar export / EventKit 同期
- learning_actual_input (PMBOK 計画統合の要件確定後)
- 未来日表示 / 未来日 pattern プレビュー

`domain-model.md` 由来:
- actual_task の派生元 (`source_template_id`)
- iCalendar export 時の pattern → VEVENT 翻訳方針
- HealthKit sleep の DayMembership 別ロジック注入
- EventKit / Google からのインポート時の RECURRENCE-ID マッピング
- iCalendar export 時の DTSTART 変換

---

## 関連ドキュメント

- `docs/spec.md` — v2 コア定義 / Phase 計画
- `docs/domain-model.md` — DDL / データモデル原則 / DayBuilder 入力契約 / Phase 2 持ち越し論点
- `docs/structural-conventions.md` — 構造規約 / 規約発火タイミング
- `docs/agent-delegation-template.md` — Agent 依頼テンプレ / 親レビューチェックリスト / ユーザー実機確認依頼テンプレ
- `CLAUDE.md` — 起動時ルール / Round 別の規約参照範囲
