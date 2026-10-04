# Life Tracker 構造規約

Agent 実装依頼前に必ず参照する。違反は副作用連鎖の原因になるため、設計確定プロンプトに該当項目を引用する。

v1 の Round 3〜10 で発見した構造レベルの不具合パターンを抽象ルールとして明文化したもの (v2 に継承)。新規規約は運用しながら追記する。

**v1 由来の R-番号根拠は `~/dev/life-tracker-archive/` の Round 履歴を参照可** (Round 4-10 の UX audit / review docs に詳細あり)。

---

## 規約発火タイミング (どの Round から効くか)

| 区分 | 発火 Round | 内容 |
|------|----------|-----|
| **DB / データ取得層** | Round 1 から | C-9, D-2, D-3 (DDL 投入時から強制) |
| **Pure function / Service** | Round 1-2 から | DayBuilder pure function 契約、責務分担 |
| **SwiftUI View 階層** | View 着手 Round から | A-1〜A-6, B-1, C-1〜C-8, E-1 |

Round 1 (DDL + DayBuilder) では View 規約 A-B-C-1〜C-7 は未発火。**親レビューで「該当 grep が 0 件 hit」を「規約準拠 OK」と誤判定しない**こと。

---

## A. SwiftUI View 階層

### A-1. NavigationLink の label には static な Label のみ
**ルール**: `NavigationLink { DetailView } label: { ... }` の label に `Button` / `Toggle` / `DatePicker` / `TextField` / `Menu` 等の interactive controls を置かない。

**Why**: SwiftUI の label 内 interactive controls は「タップが interactive 側に吸われる / 競合する / 順序不定」の不安定挙動が iOS バージョン依存で発生する (R9-1 / R8-3 根拠)。

**OK パターン**: static な表示専用 View (例: Row 系コンポーネント) を label に入れる。

**NG パターン**: Container 全体を NavigationLink でラップして内部の DatePicker と遷移タップを共存させる。

**v1 適用例**: `UnifiedTaskRowLabel` / `LogSummaryRow` を label に入れた構造。

---

### A-2. 子画面トーストは独自 @State で持つ (親 VM の Binding を共有しない)
**ルール**: push された子画面で save フィードバックを出す場合、`@Binding var saveSuccessMessage: LTToastMessage?` で親 VM から受け取らない。子画面は `@State var localToast: LTToastMessage?` を独自に持ち、必要なら親 VM の状態を `.onChange` で子 local に反映する。

**Why**: NavigationStack は push 中も親 View を body ツリーに残すため、親 overlay と子 overlay が同時発火して**同じトーストが 2 個重ねて出る** (R9-3 根拠)。

**OK パターン**: 子独自 VM (例: v1 `WorkoutViewModel.saveSuccessMessage`) で実装する。

**NG パターン**: 親 VM の `@Published saveSuccessMessage` を `@Binding` で子に渡して `.ltToast` overlay する。

---

### A-3. 複合カードは外側で `.ltCard()` 1 回だけ
**ルール**: ヘッダ + ボディの複合カード UI は親 VStack の外側で**一度だけ** `.ltCard()` を適用する。Header と Body をそれぞれ別カードにしない。

**Why**: Header が「裸の行 (padding のみ)」・Body が「独立した .ltCard()」の二枚構造になると、他カードの「単一カード内に Header + 子要素」規約から逸脱する (R10-1 根拠)。

**OK パターン**:
```swift
VStack {
    CardHeader(...)
    CardBody(...)
}
.ltCard()
```

**NG パターン**:
```swift
CardHeader(...)
CardBody(...).ltCard()  // Body だけ個別カード化
```

**v1 適用例**: `HomeSleepCard` の Header + Body 統合。

---

### A-4. 読み取り専用モードは disabled + allowsHitTesting + accessibilityTraits 切替、opacity は外側
**ルール**: read-only モードを実装する際は以下の 3 点セット:
- `.disabled(isReadOnly)`
- `.allowsHitTesting(!isReadOnly)`
- `.accessibilityAddTraits(isReadOnly ? .isStaticText : [])` または `.accessibilityRemoveTraits(.isButton)` 相当

opacity の低減は**外側の VStack / HStack に委ねる** (compound 回避)。

**Why**: View modifier を多重適用すると `.disabled` が内部 compound で期待通り効かない挙動がある。opacity を同じ View に付けると SwiftUI の diff で副作用が出る (R10-2 根拠)。

---

### A-5. 権限 UI 共通化時は連動機能セクションの if ガードも棚卸し
**ルール**: 権限共通化コンポーネントを導入する際、その権限に連動する全機能セクションの条件ガード (`if isXxxAuthorized { section }`) を全て棚卸しし、`.disabled(!isAuthorized)` + footer 説明文に置き換える。

**Why**: 権限セクションを残しても、連動する機能セクションが `.denied` で消えると「消える UI 禁止」原則の目的が達成されない (R8-8 / 項目 25 根拠)。

**v1 適用例**: `PermissionSectionView` 導入時の HealthKit / Notification 連動セクション棚卸し。

---

### A-6. ViewModifier で見た目統一したら操作モードも揃える
**ルール**: `ltCardHeader` / `ltCard` 等の ViewModifier で外観を統一した際は、同時に**親行タップ可否・遷移先・インライン編集領域の併存ルール**も揃える。

**Why**: 見た目は統一されても「特定カードだけ親行タップ不可」のような操作モードの乖離が残ると UX が不統一になる (R7-6 / 項目 17 根拠)。

---

## B. 共通ユーティリティ / 置換

### B-1. ユーティリティ導入時は旧実装を grep で全数置換
**ルール**: 共通ユーティリティを新設する PR では:
1. 旧実装を grep で全数リストアップ
2. 全箇所を新ユーティリティに置換
3. 置換が完了しない場合は旧実装を `@available(*, deprecated)` マーク

**Why**: 「60% 展開」状態で PR が閉じると、新ユーティリティがデッドコード化し、旧直書きが残存する (R8-32 / 項目 27 根拠)。

**v1 適用例**: `LTHaptic` 導入時、`UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` の全数置換。

---

## C. 情報アーキテクチャ

### C-1. 機能廃止時は「編集 UI 消す」と「read UI 消す」を区別
**ルール**: 子画面を廃止して「ホーム完結」化する判断時は、以下を必ずチェック:
- 過去日でも**個別項目の read** が可能か
- 「編集 UI ごと消す」と「read UI ごと消す」を別問題として扱う (過去日 write 禁止と過去日 read 禁止は別)

**Why**: v1 で `MealLogView` 廃止時に過去日の `MealQuickPill × 3` を非表示にした結果、過去日の朝 / 昼 / 夕を閲覧できない状態が発生 (R9-6 / 項目 29 根拠)。

---

### C-2. 情報移譲時は取得 / 表示 / 更新の 3 経路全てで過去日対応
**ルール**: 情報フィールドをカード A からカード B に移譲する際は:
1. 取得経路 (fetch): 過去日でも取得されるか (`guard isToday else { return }` が read 経路に付いていないか)
2. 表示経路 (display): 過去日でも表示されるか
3. 更新経路 (write): ガード条件 `isToday` は write 経路のみに限定

**Why**: v1 で sleepScore 移譲時に fetch 経路に `isToday` ガードが残り、過去日の子画面で情報減少が発生 (R9-7 / 項目 30 根拠)。

---

### C-3. 親子画面の情報深化方向
**ルール**: push された子画面は親より情報量が多い、または親と同じ情報をより詳細なレイアウトで見せる必要がある。「親と同機能をレイアウト違いで見せているだけ」の子画面は廃止または情報移譲を検討する。

**Why**: 階層遷移は情報の深化で正当化される。同機能を 2 画面で提供すると階層遷移の意義が破壊される (項目 26 根拠)。

**監査観点**: 子画面で push された各ページについて「ホームで見えない情報は何か」を 1 行で答えられるか確認。

---

### C-4. CRUD 対称性マトリクス
**ルール**: 同種エンティティ群 (食事 / 睡眠 / 勉強 / 運動のログ等) に対して Create / Read / Update / Delete が揃っているかをマトリクスで明示的に確認。

**Why**: 「他が編集可能だからこれも編集可能だろう」という暗黙仮定が盲点になる。「スワイプ削除だけ」は「削除しかできない」のシグナル (項目 14 根拠)。

---

### C-5. read-only 対応は引数追加 + 全編集要素に実効 + デフォルト引数なし
**ルール**: read-only モードを View に導入する際:
1. `isReadOnly: Bool` 引数を追加 (**デフォルト引数は付けない** — 必須化で呼び忘れを型エラーに)
2. 画面内の全編集要素 (Button / `.onDelete` / `sheet` / TextField) を `if !isReadOnly { ... }` で包む
3. toolbar / NavigationBar の追加アクションも個別にガード

**Why**: 「引数だけ追加してツールバー一箇所だけガード」では過去日に新規記録を差し込める脆弱性が残る (R6-1 / 項目 20 根拠)。

---

### C-6. 派生元データと同期カラムの二重管理は禁止 (v2 では同期カラム廃止)
**ルール**: 状態の真実 (source of truth) を「**手動トグル UI**」と「**派生元データ**」で二重管理しない。

**v2 での扱い**: v2 では `actual_task` + `gym_actual_input` / `sleep_actual_input` の構造で（2026-10-03: `sleep_actual_input` は廃止し睡眠は独立の表 `sleep_record`。派生元だけ持つ方針は同じ）「派生元データのみ持つ」設計に切り替えた (v1 の `daily_logs.did_*` 同期カラムは廃止)。本規約は将来同種の問題が再燃した場合の指針として継承。

**Why**: 手動トグルと派生元データの並立は「親未チェックなのに詳細は 1 件」のような状態乖離バグの温床 (項目 13 根拠)。詳細な v1 OK / NG パターンは `~/dev/life-tracker-archive/` 参照。

---

### C-7. 同一機能ボタンの並置禁止
**ルール**: 同じ機能・挙動を発火するボタンを隣接 / 並列に置かない。1 つに絞り、片方はインタラクティブでない状態表示にする。

**Why**: 「発見性向上のため両方残す」は誤判断。並置すると操作が二重化する (項目 2a 根拠)。

---

### C-8. plan / actual 独立表示パターン (UI レイヤー、v1 R-PlanA-7 確立)
**ルール**: plan (`scheduled_task`) と actual (`actual_task`) を扱う View は、以下の優先順位で独立に表示モードを決定する:

1. `currentActual` あり → **actual 駆動表示**。ラベル・カテゴリ・アイコン・経過時間は **actual** から取る。plan は「次ラベル」等の補足情報のみ参照。操作は `complete(actualId:)`
2. `currentActual` なし かつ `currentScheduledTask` あり → **plan 駆動表示**。操作は `start(scheduledTaskId:)`
3. `currentScheduledTask` なし かつ `nextScheduledTask` が 30 分以内 → **plan 予告表示**。操作なし
4. 上記以外 → **非表示**

共通除外: dismiss 済 plan (UI dismissal)、`category.sub_input_kind == 'sleep'` の plan は plan 駆動 / 予告で表示しない (sleep は actual 生成なし、dismiss 済は本人宣言で非表示が自然)。

**Why**: plan と actual は DB レベルで完全独立 (FK なし)。UI で「どの plan に紐づく actual か」を推定する運用は誤判定を生む (例: 8-9 workout plan を 7:55-8:50 で実施時の overlap)。actual を一次情報として扱い、plan は補助に徹する。

**v2 適用範囲**: 当日進行中タスクカード相当 (Phase 5 で構築) で発火。Calendar / TimelineView / LA 関連 View は本パターンを踏襲する。

**経過時間テキスト採用**: ring 系部品は「plan の時間帯全体に対する残り時間」を可視化する部品。actual 駆動表示では plan と時間帯が一致しないため使わない (誤解を生む)。経過時間テキスト (「開始 X から N 分経過」) で代替する。

---

## D. データ取得 / 状態管理

### D-1. 週ヒートマップ系は「表示範囲」と「ロード範囲」の一致を監査
**ルール**: `selectedDate` を起点にセル計算する View では、週次データ再取得が `selectedDate.didSet` / `.task` / `.onAppear` それぞれで何をロードするかをマトリクスで確認。

**Why**: 過去週閲覧で全セル progress: 0 = 「過去週は全部未記録」と偽表示するバグの温床 (R7 / 項目 19 根拠)。

---

### D-2. HealthKit 読み取り権限判定に authorizationStatus を使わない
**ルール**: HealthKit 読み取り可否は「実際にクエリを投げて成功 / 失敗で判定」する。`HKHealthStore.authorizationStatus(for:)` を UI 判定に使ってはならない。

**Why**: authorizationStatus は読み取り型に対して許可後も `.sharingDenied` を返す仕様 (プライバシー保護) (R6-13 / 項目 8 根拠)。

---

### D-3. 独立 Toggle を AND 結合しない
**ルール**: 「役割分離」を謳って独立 Toggle を導入した直後、guard 節で両方を AND 結合しない。独立性を保つなら OR 結合または個別評価にする。

**Why**: 独立 Toggle を AND 結合して特定マスが実装上到達不能になった事例 (R7 / 項目 18 根拠、v1 例: `isTimelineEnabled` && `isLiveActivityEnabled`)。

---

### D-4. plan / actual は DB で完全独立、UI 層で結合
> **2026-09-30 改訂（本人承認・段階 2 チェックイン C1）**: `actual_task` は予定の回を**緩く参照**してよい（`template_id`＋`occurrence_date`／`scheduled_task_id`、FK は ON DELETE SET NULL）。予定を消しても実績は残り、つながりだけ外れる。予定を変えても過去の実績は変わらない。予定側の RPC が実績に触れてよいのは「つながりの列（単発↔繰り返しの変換でのつなぎ直し）」と「skipped の行の削除」だけ。下の NG 例 1 は、この緩い参照に限って解除。NG 例 2〜4（事前 join の View・集計キャッシュ・トリガーでの相互更新）は引き続き禁止。経緯は `docs/day-cycle-walkthrough.md` 段階 2
> **2026-10-03 例**: 睡眠の記録 `sleep_record` は予定・予定の種類と**参照を持たない完全独立**の例（トレーニングの表示時判定と同じ）。予定タブの睡眠の行とは UI 層で時刻の重なりで結ぶ（OK 例 1・2）。経緯は `docs/sleep-design/synthesis.md`
**ルール**: `scheduled_task` (plan) と `actual_task` (actual) は DB 永続層で完全独立させる。UI 層に限り「表示・derived 判定・Service computed property」での結合を許容する。

**OK 例 (UI 層結合の許容)**:
1. UI 層の derived 判定 (`isMissed(plan)` 等、category + 時刻 overlap で actual 不在判定)
2. UI 層の結合表示 (当日進行中タスクカード / TimelineView 2 レーン等、両方を同時にレンダリングする View)
3. Service の computed property が両方を raw data として参照 (`currentActual` / `nextScheduledTask` / `isMissed` etc)
4. Service 側で「dismissal Set + actual + plan」を横断する predicate helper

**NG 例 (永続層結合の禁止 — Round 1 DDL から発火)**:
1. ~~`actual_task` に `scheduled_task_id` 列や FK を追加する~~（2026-09-30 改訂で、ON DELETE SET NULL の緩い参照に限り可）
2. SQL View / RPC で plan + actual を事前 join する
3. `scheduled_task` に actual 側の集計キャッシュ列を追加する
4. DB トリガーで一方が他方を INSERT / UPDATE / DELETE する

**Why**: 「予定と実績は時間軸に対して独立に記録される」思想。DB レベルで紐付けると plan 再生成や actual 編集時に整合性破綻が連鎖する。UI 層で「overlap + 同 category」等の柔軟 matching を可能にすることで、plan 8-9 workout を 7:55-8:50 で実施した時でも missed 誤判定にならない。

**運用**: 新規結合導入時は必ず本節の OK / NG どちらかに追記する。判断に迷う場合は「DB schema 変更が必要か?」で切り分け (不要なら OK 側候補)。

**関連**: C-8 (plan / actual 独立表示パターン、本規約の UI レイヤー実装例)、`docs/domain-model.md` データモデル原則「予実紐付けなし」

---

### D-5. DayBuilder pure function の入力契約
**ルール**: DayBuilder は副作用を持たず、入力は `DayBuilderContext` 構造体に閉じる。Builder 内で DB / 永続層 / Singleton にアクセスしない。Service 層で fetch + 当日絞り込み済みの context を渡す。

**Why**: pure function 化により DayBuilder 単体テストが容易になり、表示結果の再現性が保たれる (`feedback_re_walkthrough_before_implementation` の TOCTOU 対策)。

**関連**: `docs/domain-model.md` の `DayBuilderContext` 定義

---

## E. iOS システム連携

### E-1. Live Activity / Settings の deep link は目的地と案内文言を一致
**ルール**: `UIApplication.openSettingsURLString` は `Settings > [App]` を開くのみ。`Settings > Face ID とパスコード > Live Activities` 等の上位階層には到達不能。誘導ボタンの deep link 先と UI 文言は必ず一致させる。

**Why**: deep link で到達不能な場所を案内すると迷子誘導になる (R8 / 項目 24 根拠)。

---

## 運用ルール

### 規約違反の検出 (Round 別 grep)

**Round 1 (DDL + DayBuilder) から常時実施**:
- `actual_task` の DDL に `scheduled_task_id` / `plan_id` 列が追加されていないか (D-4)
- SQL View / RPC で `JOIN scheduled_task.*actual_task` していないか (D-4)
- DB トリガーで plan ↔ actual を相互更新していないか (D-4)
- DayBuilder 関数内で DB クライアントを直接呼んでいないか (D-5)
- `category.sub_input_kind` の CHECK 制約が想定値リストと一致するか

**View 着手 Round から実施 (該当 View 規約発火時のみ)**:
- `NavigationLink` の label 内に `Button|Toggle|DatePicker|TextField|Menu` (A-1)
- `@Binding var saveSuccessMessage` / `@Binding var.*Toast` が子画面で定義 (A-2)
- `if isXxxAuthorized` ガードが残存 (権限 UI 共通化後、A-5)
- `UIImpactFeedbackGenerator|UINotificationFeedbackGenerator` がユーティリティ外部に残存 (B-1)
- `isReadOnly: Bool = false` のデフォルト引数 (C-5)

### 新規規約の追加

監査・実装で新しい構造パターンが見つかったら、本ファイルの該当セクションに追加する。規約は「ルール」「Why (R 番号根拠)」「OK/NG パターン」「v1 / v2 適用例」の順で書く。

---

## 関連ドキュメント
- `docs/agent-delegation-template.md` — Agent 依頼時のプロンプトテンプレ
- `docs/domain-model.md` — v15 ドメインモデル
- `docs/spec.md` — v2 コア定義・スコープ
