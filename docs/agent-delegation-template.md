# Agent 依頼テンプレ

Agent (サブエージェント) に実装を委譲する際のプロンプトテンプレ。S 級 (構造変更を伴う) と B/C 級 (局所修正) で使い分ける。

S 級は対象レイヤで 3 種にバリアント分け: **S-DB 級** (DDL / migration), **S-Pure 級** (DayBuilder / Service), **S-View 級** (SwiftUI View 構造変更)。

v1 で確立した運用ルール (Round 10 で実証済) を v2 に継承。

## 基本方針

- **設計は親が確定する**: 既存コードを Read し、擬似コード＋規約引用を事前に書き出してから Agent に投げる
- **S 級は 1 件ずつ直列**: 並列 Wave に投げない (構造規約の暗黙前提は Wave 跨ぎで伝播しない)
- **親レビュー必須**: Agent の BUILD SUCCEEDED 報告のみで次に進まない。Round 別 grep (`structural-conventions.md` 末尾) で構造規約違反を目視確認
- **実機確認はユーザー依頼**: Agent には実機確認を期待しない (idb は arch 判定バグあり、simctl も install のみ使用)
- **親直接実行時も同じ規律**: 構造変更 / ドメイン判断 / 設計整合性タスクは Agent 委譲せず親が直接実装する (`feedback_delegate_to_subagents`)。その場合も擬似コード + 規約引用 + 影響範囲を事前に書き出す → BUILD 確認 → 規約 grep で自己レビュー、と Agent 委譲時と同じプロセスを踏む。本テンプレ各節の「設計確定」「実装要件」「報告内容」は親自身に対するチェックリストとしても使う

---

## S-DB 級テンプレ (DDL / migration)

DB スキーマ変更を伴うタスクで使う。Round 1 の DDL 投入、index 追加、ENUM 拡張、トリガー追加 (D-4 違反になる場合は親が事前却下) 等。

```
## タスク: <件名>

## 設計確定 (親が事前に判断済み)

### 修正対象
- `migrations/NNNN_<slug>.sql` (新規) — <概要>
- `docs/domain-model.md` — DDL 部分の同期更新 (親が既に修正済 / Agent 側でも同期更新 / どちらか明記)

### 変更後の DDL (擬似 SQL)
```sql
-- 5〜15 行で具体的に
ALTER TABLE ... | CREATE TABLE ... | CREATE INDEX ...
```

### 守る規約 (docs/structural-conventions.md より)
- D-4「plan / actual は DB で完全独立」: <該当する部分を引用>
- (複数あれば列挙)

### 守るデータモデル原則 (docs/domain-model.md より)
- 該当原則を引用 (例: 「DB 制約は最後の砦」「JST 規約」「B-X 由来識別」)

### Supabase 適用手順
- 接続: `supabase-personal` MCP (project: `hyngpesrmqodiegonoze`)
- 適用: `mcp__supabase-personal__apply_migration`
- ロールバック方針: <ロールバック SQL を併記>

### 影響範囲
- 既存テーブルへの破壊的変更: なし / あり (移行手順を明記)
- 既存 scheduled_task / actual_task / day_meta 行への影響: <あり/なし>

## 実装要件
1. 上記 DDL に従って migration ファイル作成
2. Supabase に適用 (適用時のレスポンス全文を報告に含める)
3. `mcp__supabase-personal__list_tables` で適用後のスキーマを確認
4. `docs/domain-model.md` の DDL ブロックと一致するか目視確認
5. 規約違反がないか自己チェック

## 報告内容
- migration ファイル名と内容
- Supabase 適用結果
- list_tables / list_migrations 実行結果
- 規約違反の自己チェック結果
- ロールバック SQL を最終ブロックに記載
```

---

## S-Pure 級テンプレ (DayBuilder / Service / pure function)

副作用なしの関数 / 構造体 / Service 実装で使う。DayBuilder 構築、Service / DayDataSource 層追加、計算ロジック実装等。

```
## タスク: <件名>

## 設計確定 (親が事前に判断済み)

### 修正対象
- `<ファイルパス>` (新規 / 編集) — <概要>

### 変更後の関数シグネチャ / 型 (擬似 Swift)
```swift
// 5〜15 行で具体的に
struct DayBuilderContext { ... }
enum DayBuilder {
    static func build(date: Date, context: DayBuilderContext) -> Day { ... }
}
```

### 責務境界
- この関数 / 型がやること: <1〜3 行>
- やってはいけないこと: <DB 直接アクセス禁止 / Singleton 参照禁止 / グローバル状態 mutate 禁止 等、structural-conventions.md D-5 引用>

### 守る規約 (docs/structural-conventions.md より)
- D-5「DayBuilder pure function の入力契約」: <引用>
- D-4「plan / actual は DB で完全独立、UI 層で結合」: <引用>

### テスト容易性要件
- 入力 context をモック可能か
- 副作用なしで同一入力 → 同一出力が成立するか
- 必要なら追加で test target にユニットテスト 1〜3 件

### 影響範囲
- 呼び出し側: <ファイル一覧>
- 既存テスト / Preview への影響: <あり/なし>

## 実装要件
1. 上記シグネチャに従って実装
2. BUILD 確認 (`xcodebuild -scheme LifeTracker -destination 'platform=iOS Simulator,name=iPhone 17'`)
3. ユニットテスト追加 (テスト容易性確認のため最小 1 件は必須)
4. テスト実行 (`xcodebuild test ...`)
5. BUILD + TEST SUCCEEDED 後に完了報告

## 報告内容
- 変更ファイルと主要変更行
- BUILD 結果 / TEST 結果
- 規約違反の自己チェック結果
- SourceKit 診断エラーが出ていれば列挙 (BUILD 通れば無視可)
```

---

## S-View 級テンプレ (SwiftUI View 構造変更)

構造変更を伴う View タスク (NavigationLink 構造変更 / Binding 関係変更 / カード階層変更 / 共通化 / 情報移譲 等) で使う。

```
## タスク: <件名>

## 設計確定 (親が事前に判断済み)

### 修正対象
- <ファイルパス>:<行番号> — <概要> (親が Read 済み)

### 変更後の構造 (擬似コード)
```swift
// 擬似コードで 5〜10 行。View ツリーまたは関数シグネチャレベル
```

### 守る規約 (docs/structural-conventions.md より)
- 規約 X-N「<タイトル>」: <該当する部分を引用>
- (複数あれば列挙)

### 影響範囲
- 破壊的変更: なし / あり (呼び出し側 N 箇所要更新: <ファイル一覧>)
- 既存テスト / Preview への影響: <あり/なし>

## 実装要件
1. 上記構造に従って実装する
2. 規約違反がないか実装中に確認する
3. BUILD 確認 (`xcodebuild -scheme LifeTracker -destination 'platform=iOS Simulator,name=iPhone 17'`)
4. BUILD SUCCEEDED 後に完了報告する
5. 実機確認は不要 (ユーザーが別途実施)

## 報告内容
- 変更ファイルと主要変更行
- BUILD 結果
- 規約違反の自己チェック結果
- SourceKit 診断エラーが出ていれば列挙 (BUILD 通れば無視可)
```

---

## B/C 級タスク用テンプレ (局所修正)

構造変更を伴わない修正 (文言変更 / 色変更 / 小さなロジック修正 / docs 追加 等) で使う。

```
## タスク: <件名>

### 修正対象
- <ファイルパス>:<行番号> — <概要>

### 変更内容
<1〜3 文で記述>

### 要件
- BUILD 確認 (DDL / コード変更時のみ)
- 構造規約 docs/structural-conventions.md に違反しないこと

### 報告内容
- 変更ファイルと主要変更行
- BUILD 結果 (該当時)
```

B/C 級は並列 Wave で複数 Agent を同時起動可。ただし同一ファイルの編集は直列化する。

---

## 親レビューのチェックリスト

Agent 完了報告を受け取ったら、親が以下を実施 (所要 2〜3 分):

### Round 1 から常時 (全 S/B/C タスクで)
1. BUILD 結果の目視確認 (S-DB 級は migration 適用結果)
2. 主要変更ファイルを Read (変更部分のみ)
3. `docs/domain-model.md` の DDL と migration の差分一致確認 (S-DB 級時)
4. `actual_task` / `scheduled_task` の DDL に相互 FK / 集計キャッシュ列が混入していないか (D-4)
5. DayBuilder / Service 関数内で DB クライアントを直接呼んでいないか (D-5)

### View 着手 Round 以降 (該当 View 規約発火時のみ)
- `NavigationLink { ... } label: { ... }` の label 内に `Button|Toggle|DatePicker|TextField|Menu` (A-1)
- `@Binding var saveSuccessMessage` / `@Binding var.*Toast` の子画面定義 (A-2)
- `if isXxxAuthorized { section }` の残存 (権限 UI 共通化の場合、A-5)
- `UIImpactFeedbackGenerator|UINotificationFeedbackGenerator` の直書き残存 (B-1)
- `isReadOnly: Bool = false` のデフォルト引数 (C-5)

### 共通仕上げ
- 構造規約 `docs/structural-conventions.md` の該当項目違反がないか最終確認
- 違反があれば Agent に再依頼 or 親が直接修正

---

## ユーザー実機確認依頼テンプレ

S 級完了時は以下のフォーマットでユーザーに確認依頼を出す:

```
## 実機確認依頼: <Round 名 / タスク名>

### インストール手順
1. BUILD 物の path: `<DerivedData の .app パス>`
2. `xcrun simctl install booted <app>` でインストール済 (Agent 側で実施済 / 未実施を明記)
3. iPhone 実機への install は Xcode から手動

### Acceptance Criteria (当該 Round で確認すべき項目)
- [ ] <golden path シナリオ 1 — 1 行で>
- [ ] <golden path シナリオ 2>
- [ ] <edge case シナリオ>

### リグレッション観点 (過去 Round 分)
- [ ] <過去 Round で確認済の主要機能 — 影響受けていないか>

### 報告依頼
- 上記 Acceptance / リグレッション の各項目について OK / NG / 再現条件を返す
- スクリーンショット添付歓迎 (NG 時は必須)
```

---

## 付録: v1 での実証履歴 (参考)

### Round 10 S 級 4 件 (2026-04-21 完了、v1)
v1 で本テンプレ前身を使い 4 件直列実装 → 実機確認で問題なし判定:

- R10-1: HomeSleepCard を単一 `.ltCard()` に統合 (規約 A-3)
- R10-2: 過去日 MealQuickPill を read-only 表示 (規約 A-4)
- R10-3: 朝勉強過去日 NavigationLink 追加 (規約 A-1 / C-4)
- R10-4: 過去日 sleepScore 取得 + `.denied` Section 過去日抑制 (規約 C-2)

**効いた点**:
- S 級直列化: 副作用連鎖なし
- 設計確定プロンプト: 規約引用・擬似コード・影響範囲を事前に書き出し、Agent に推測させない
- 親レビュー (Read + grep): BUILD SUCCEEDED のみに頼らず各件 2〜3 分の目視確認

**補足**: Agent 実装直後に SourceKit の "Cannot find type/module in scope" 系エラーが多発したが、xcodebuild は全件 BUILD SUCCEEDED。IDE インデックスの一時エラーのため無視して問題ない。

v2 Round 1-3 が完了したら、本付録を v2 実例で順次置換していく。

---

## 関連ドキュメント
- `docs/structural-conventions.md` — 構造規約本体
- `docs/domain-model.md` — v15 ドメインモデル
- `docs/spec.md` — v2 コア定義・スコープ
- `CLAUDE.md` — 起動時ルール
