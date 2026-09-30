# Gymwork 寄せ（記録画面以外）設計ドキュメント（2026-09-30 着手）

作業途中で会話が要約されても再開できるように、計画・前提・完了条件を先に置く。確定した設計は本ファイルの「設計（確定）」節に書き、実装後に `implementation-roadmap.md` と `round-3-work-plan.md` に反映する。

## 依頼（2026-09-30 本人）
> 入力画面以外にも focus して gymwork アプリに寄せるように。ただし、life-tracker の良いところは潰さないように設計をしっかりと固めてから実装に入って。設計についても複数エージェントでどうすべきかを議論して

## 前提
- 記録画面（種目カード × セット行・入力シート・休憩 3:00・1RM トースト・部位チップ付き種目追加）は Gymwork 型に作り替え済み（`round-3-work-plan.md` 再々設計節）。本設計の対象は**それ以外**
- 維持する本人決定: 開始・終了ボタンなし（「単純に何をしたのかを記録したいし、成長推移が見たい」）/ 推移グラフの指標は切り替えで全部 / 習慣化は Grit（案 A'）（⚠ 2026-09-30 本人訂正: Grit は参考に挙げただけで使っていないし使わない。前提が崩れたため INV-6 を続けるかは本人判断待ち）/ 個人ツールとして完結（課金・ランキング・SNS・オンボーディング不要）
- Gymwork の参考資料: 本人の操作録画（~/Downloads/ScreenRecording_09-30-2026 04-51-15_1.MP4、フレームはセッションの scratchpad `rec/sheet_01〜09.png`）

## 進め方
1. 議論 Round 1（並列）: A=Gymwork 側の画面・パターン棚卸しと採用案 / B=Life Tracker の良いところ（壊してはいけない不変条件）の棚卸し / C=データ・実装面の制約とコスト
2. 議論 Round 2: A と B が互いのレポートに反論・譲歩
3. 統合（deep-task）: 採用・不採用・本人決裁の論点に分けた設計案
4. 親が設計を確定して本ファイルに記録 → 実装 → テスト・シミュレータ確認

## 完了条件
- [x] 本ファイルに「設計（確定）」節（採用・不採用とその理由、LT の不変条件、本人決裁が要る論点）がある
- [x] `xcodebuild test -only-testing:LifeTrackerTests` が TEST SUCCEEDED（2026-09-30 実装後 90 件）
- [x] モックでシミュレータ確認（設計で採用した各画面のスクリーンショット）（2026-09-30 親が確認。下の検証ログ）
- [x] 構造規約 grep 違反なし（§6 の grep・行数・記録画面の差分なしを確認）

## 議論ログ
（Round ごとに要約を追記）

### Round 1（2026-09-30 並列 3 エージェント。詳細は `docs/gymwork-discussion/A-gymwork.md` / `B-lt-guardian.md` / `C-data.md`）
- A（Gymwork 推進）トップ提案: ①今日の合計ヘッダー（総ボリューム・本番セット数・種目数・経過時間=最初〜最新セット、kcal なし）②週カレンダー帯＋過去日を読み取り専用表示 ③種目カード見出しに「今日 kg・e1RM（前回）」＋⋮メニュー ④「前回の組み合わせを読み込む」チップ（名前付きルーティンの代替）⑤週分析画面（push、週総ボリューム前週比・曜日×部位棒グラフ・部位別セット数・週の自己ベスト）⑥メモのその場編集 ⑦部位の経過日数一覧 ⑧＋追加の固定ボタン ⑨時間種目のみストップウォッチ ⑩低: 画像保存・1RM換算表・体重は HealthKit 読みのみ。不採用: 連続日数バッジ・kcal・一括✓
- B（LT 守護）不変条件: INV-1 開始/完了/保存を必須にしない / INV-2 1日=1セッション自動 / INV-3 前回値プリフィル＋✓の最短経路 / INV-4 推移全指標・W除外 / INV-5 集計は計算で出しテーブルを増やさない / INV-6 Grit 境界（汎用ストリーク・リング・ヒートマップ禁止）/ INV-7 今日タブを従属させない / INV-8 workout は actual_task に従属させない / INV-9 課金・シェア等なし / INV-10 本人指定値（刻み・休憩3:00）を守る。破壊パターン D1〜D15 と13項目チェックリスト
- C（データ）: 現データはセッション1・セット4・ルーティン0・RLS無効。横断注意 ①Supabase 1000行上限（fetchRecordedExerciseIds が全セット取得＝約3か月で種目欠落）②週の始まりが未設定（ロケール依存）③今日の store に過去日表示を足すと下書きが消える→読み取り専用の別 store ④日の基準が completed_at と session.started_at の2つ。候補は h 体重（新テーブル要）・g その日×種目メモ（DB要）以外は DB 変更不要。推奨順: 基盤（期間取得 API・上限対策・集計定義関数・読み取り専用 store）→ f サマリー → a+b 週帯＋過去日 → c 週分析 → e/i/ストップウォッチ → d。j 過去日編集は別 Round

### Round 2（反論・譲歩。詳細 `docs/gymwork-discussion/A2-rebuttal.md` / `B2-rebuttal.md`）
- 合意: 完了操作は作らない（ただし結果が DB に影響しない任意の閲覧操作は可）/ 経過時間は動く時計にせず「7:02–7:40」の時刻範囲 / 過去日は読み取り専用の別 store（今日の下書きを守る）/ 日の基準は completed_at の JST 暦日に一本化 / 週カレンダーはトレーニングタブに置く（Round 7 で今日タブの日付ナビと役割分担を決め直す）/ 名前付きルーティンは作らず「前回の組み合わせを読み込む」で代替 / 入れ替えは未記録カードのみ / 今日のメモは最初の✓以降 / まとめ画像・体重・kcal・連続日数は不採用 / 分析は3つ目のタブにしない（push）
- 守護派の追加受け入れ条件: 1画面目に今日のカード先頭行が見える
- 残った対立: 組み合わせチップを本画面に出す条件（A: 今日が空の日だけ本画面、B: 種目追加シート内）/ INV-5 の文言（A: 「導出値を保存しない。DB 側 View/RPC の読み取り集計は可」）/ 部位の経過日数（A: チップに吸収、B: 中立色1行で後回し）/ バッチ分け
- 次: deep-task（fable）が統合・判定（`design/D-synthesis.md`）

## 設計（確定）（2026-09-30 親が D 統合案を採用。変更なし。§番号は下記の通り）

採用の判断: 残った対立 J1〜J7 の判定と、A/B 合意からの変更1件（PastDayView に isReadOnly を置かず Round 4 で必須引数として導入）をそのまま採用。R-1〜R-8 は AI 既定値で実装し、本人に決裁チェックリストとして提示する。

不変条件（守護派 B の INV を確定。INV-5 は R-7 の文言）: INV-1 記録の前後に開始・完了・保存を必須にしない / INV-2 1日=1セッションを記録から自動で作る / INV-3 前回値プリフィル＋✓の最短経路・今日の下書きを壊さない / INV-4 推移は全指標切替・W除外・自分比較 / INV-5 導出値を永続化しない（読み取り時の View/RPC 集計は可、D-4 は別途守る）/ ~~INV-6 汎用ストリーク・リング・ヒートマップを作らない（Grit 境界）~~（**2026-09-30 本人決定で廃止**: 週N回の目標を基準に連続・リング・ヒートマップを入れる。`continuity-design.md`）/ INV-7 今日タブを従属させない / INV-8 workout を actual_task に従属させない / INV-9 課金・広告・シェア・ランキング・kg/lbs なし / INV-10 本人指定値（刻み 1.25/5・2/4、休憩 3:00）を上書きしない。受け入れ条件: 1画面目に今日のカード先頭行が見える

---

### 1. 残った対立点の判定

| # | 論点 | A（推進） | B（守護） | 判定 | 理由 |
|---|---|---|---|---|---|
| J1 | 組み合わせチップを本画面に出す条件 | 今日が空のときだけ本画面。種目が入ったら「前回の組み合わせ ›」の 1 行に畳む。種目追加シート上部にも同じチップ | 種目追加シート内だけ | **【判定】今日が空のとき＝空状態そのものとしてチップを出す（畳んだ 1 行も出さない）。種目が 1 つでも入ったら本画面からは消え、種目追加シート上部のチップだけが残る** | 空の日の最短経路は「タブ → チップ → 読み込む → ✓」の 4 タップで、現行（4＋n）より減る＝チェックリスト 1 で唯一改善する案（A2 R3 の計算は正しい）。一方で種目が入った後は本画面に残す理由がない（畳んだ 1 行でも縦を食い、C-7 の並置に近づく）。「途中で思い出した」用途はシート側で満たせる。空状態は現在も説明 footer を出している場所なので、そこがチップに置き換わるだけで、カード先頭行の位置は一切変わらない |
| J2 | INV-5 の文言 | 「導出値を永続化しない。DB 側 View / RPC の読み取り集計は可」 | 「導出値のためにテーブルを増やさない」 | **【判定】A の言い換えを採用。INV-5 =「導出値を永続化しない（テーブル・カラム・トリガーでキャッシュしない）。読み取り時の集計を DB の View / RPC で行うのは可。ただし D-4（plan/actual の JOIN 禁止）は別途守る」** | training-domain-design 判断 D の趣旨は「集計を保存すると整合が崩れる」であり、読み取り時集計の View はその趣旨に反しない。ただし**今回のバッチでは View / RPC を使わない**（1000 行上限は `.range()` ページングで解く。migration なし＝SSOT 改訂なしで済ませ、View は「セット 5,000 件超で遅くなったら」の次手として `recorded_exercise` を予約） |
| J3 | 部位の経過日数 | チップに「脚 6日前」、週分析の部位別表に最終日列 | 中立色・1 行・後回し可。経過日数順に並べない | **【判定】チップのラベルを「胸・三頭 · 3日前」（その日からの経過日数）にし、これ以外の経過日数 UI は作らない。並びは新しい順・色は中立。週分析の部位別表に「最終日」列は付けない** | チップはもともと日付を持つので相対日に置き換えるだけで「脚が 7 日空いてる」が読める（追加コストほぼゼロ、B の懸念する「さぼりカウンター」化は並び順と色で回避）。週分析は「その週」のスコープなので、全期間の「最終日」を同じ表に混ぜると読み手がスコープを取り違える。補助筋なし（C-k）で精度も粗いので単独 UI は作らない |
| J4 | 経過時間の表示 | 「7:02–7:40」の静的表示 | R-1 決裁まで出さない／時刻表示まで | **【判定】その日の記録が 2 セット以上のとき「7:02–7:40 · 38分」を caption で出す。1 セット以下は出さない。now は使わない（刻まない）** | Gymwork の「運動時間」は開始ボタンの産物だが、「最初と最後のセットの時刻」は開始操作なしで得られる事実で、進行中状態を UI に持ち込まない（D3 回避）。B の「8:12–8:12」は 2 セット未満で非表示にして回避、「昼に 1 セット足すと長くなる」は時刻範囲を併記しているので実態が読める。【AI既定】§5 R-1 |
| J5 | 週カレンダーの置き場 | トレーニングタブ | トレーニングタブに置いてよい。Round 7 で今日タブの日付ナビと役割分担を決め直す義務を roadmap に残す | **【確定】トレーニングタブの上部。役割は「トレーニング実施日の閲覧・過去日の read-only 表示専用」。roadmap の Round 7 に「今日タブの日付ナビと連動しない・二重化しない」を 1 行残す** | 両者合意。点は「記録がある日」の事実だけ。連続日数・ヒートマップへは拡張しない（INV-6） |
| J6 | 分析の置き場 | タブを増やさず push | push（3 つ目のタブ不可） | **【確定】トレーニングタブの右上ツールバー［📊］から push。加えて【判定】現在タブ下部にある「種目ごとの推移」一覧を分析画面の下部に移設する** | 両者合意。移設は B の C-8（推移に 2 タップ以内: 📊 → 種目）を満たし、トレーニングタブを「今日の記録面」だけにできる（D6 の逆方向の担保）。今日のカード見出しタップ → 推移は現状維持（1 タップ）。データが少ない今は週分析だけだと画面が薄いので一覧が内容を補う。【AI既定】§5 R-5 |
| J7 | バッチ分け | 3 バッチ（1: 基盤＋合計＋週帯＋見出し＋組み合わせ／2: 分析・メモ・FAB／3: 任意） | 0 基盤＋1 合計＋2 週帯＋3 組み合わせ＋4 分析＋5 見出し・FAB・入替・メモ | **【判定】今回 1 バッチ = S 級 5 件: S-0 基盤 / S-1 今日の合計＋カード見出し（e1RM・⋮入れ替え）/ S-2 週帯＋過去日 read-only / S-3 前回の組み合わせ読み込み / S-4 週分析（＋推移一覧の移設）。S-4 は他 4 件から独立で、時間切れなら次バッチに落とす。FAB・メモ・ストップウォッチは次バッチ** | 依頼の中心（日付軸・合計・メニュー再利用・分析）を 1 回で揃えないと「Gymwork に寄せた」体験にならない。一方 FAB は現行の［種目を追加］が最後のカード直下にあり実用上の差が小さく、休憩バーと重なる調整が要る。メモは write API 2 本と「セッション未作成時」の扱いが増える。S 級 5 件の上限（B チェック 13）に収めるため落とす |

そのほか A/B 合意事項は本案でもそのまま維持する: 完了・保存の操作は作らない（結果が DB に影響しない閲覧操作は可）/ 過去日は読み取り専用の別 store / 日の基準は completed_at の JST 暦日 / 名前付きルーティンは作らず「前回の組み合わせ」で代替 / 入れ替えは未記録カードのみ / 今日のメモは今回なし / まとめ画像・体重・kcal・連続日数・kg/lbs は不採用。

**A/B 合意からの変更点（1 件）**: B2 が条件にした「過去日 View は `isReadOnly` 必須引数」は採らない。過去日 View（`PastDayView`）は編集要素を一切持たない専用 View として作るため、何もゲートしない引数を置くとレビュー時に「ゲート漏れ」と誤読される。C-5 は「同一 View が編集と閲覧を兼ねる」場合の規約なので、Round 4 で過去日編集を足す時点で `isReadOnly` を必須引数として導入する（差し込み位置を `PastDayView` のコメントで予約）。lead が A/B 合意を優先するなら引数を足しても実害はない。

---

### 2. 今回実装する範囲（1 バッチ・S 級 5 件）

| # | 項目 | 内容 | DB | 依存 |
|---|---|---|---|---|
| S-0 | 基盤 | `fetchSets(completedFrom:to:)`（期間・ページング）/ 既存 2 フェッチのページング化 / pure 関数群 `WorkoutSummary`（日の基準・日合計・週・組み合わせ・カード見出し）/ 読み取り専用 `WorkoutHistoryStore` / Mock 拡張 / テスト | 不要 | なし |
| S-1 | 今日の合計＋カード見出し | `DaySummaryBar`（kg・本番セット・種目・時刻範囲）/ カード見出しに `今日 1,105kg · e1RM 69kg（前回 67.5kg）` / ⋮（未記録カードのみ: 入れ替え・外す）/ store に `replacePlannedExercise` | 不要 | S-0（pure） |
| S-2 | 週帯＋過去日 | `WeekStripView`（月〜日・今日・選択・記録点・‹ ›・未来は無効）/ `PastDayView`（read-only）/ WorkoutView に `selectedDay` と上部固定領域 / タイトル inline | 不要 | S-0 |
| S-3 | 前回の組み合わせ | `CombinationChips`（空状態）/ 種目追加シート上部の同チップ / `CombinationSheet`（種目ごとチェック・追加済みは選べない・読み込む）/ 読み込み後は既存の前回値埋め | 不要 | S-0 |
| S-4 | 週分析 | `WeekAnalysisView`（週ナビ・総ボリューム・前週比・曜日×部位の積み上げ棒・部位別本番セット数）/ 「種目ごとの推移」一覧をここへ移設 / `NavigationPath` 化 | 不要 | S-0, S-2 の history store |

実装順は S-0 → S-1 → S-2 → S-3 → S-4（§3.8）。Fixture の拡充は S-1 の前に行う（スクリーンショットにデータが要る）。

### 2.1 トレーニングタブ（今日・種目あり）

```
┌ トレーニング                                  [📊] ┐ ← navigationBarTitleDisplayMode(.inline)、右上=分析へ push
│ ‹  月   火   水   木   金   土   日   ›              │ ← WeekStripView（safeAreaInset(.top) で固定）
│    28  (29) [30]  1    2    3    4                   │    [30]=今日(塗り) (29)=選択中(枠) 1〜4=未来(淡色・押せない)
│     •    •    •                                       │    •=記録がある日（今日の点は today store から）
├──────────────────────────────────────────────────────┤
│ 9/30(火) 今日                     7:02–7:40 · 38分   │ ← DaySummaryBar（固定）row1: 日付 / 時刻範囲(2セット以上)
│ 1,440kg    6セット    2種目                           │    row2: kg=weight_reps 本番 Σw×r（無い日は kg を省略）
├──────────────────────────────────────────────────────┤
│ ■ ベンチプレス 📈                              ⋮     │ ← 名前タップ=推移(現状維持)。⋮ は未記録カードのみ
│   今日 1,105kg · e1RM 69kg（前回 67.5kg）              │ ← カード見出しのサブ行（§3.2 cardHeadline）
│   セット   前回      kg     回    ✓                   │
│   1        60×10     60     10    ✓                  │ ← ここまでが 1 画面目に入ること（§2.7）
│   2        65×8      65     8     ○                  │
│   [＋ セットを追加]                                    │
│ ■ 懸垂 📈                                      ⋮     │
│   前回 最多 12回                                       │ ← 今日まだ本番セットなし → 「前回 …」だけ
│   ...                                                 │
│ [＋ 種目を追加]                                        │ ← 現状のまま List 内（FAB は次バッチ）
│                                                       │
│ ⏱ 2:58 休憩           [−15] [+15] [スキップ]          │ ← 休憩バー。日付を切り替えても消えない位置に移す
└──────────────────────────────────────────────────────┘
```
削除: 「種目ごとの推移」セクション（→ 分析画面へ移設）、カード見出しの「外す」ボタン（→ ⋮ へ。C-7）。
⋮ のメニュー項目は「種目を入れ替え」「今日から外す」の 2 つだけ。記録済みカードには ⋮ 自体を出さない（できることが無いため）。

### 2.2 トレーニングタブ（今日・空）

```
│ 9/30(火) 今日                                        │
│ まだ記録なし                                          │ ← バーは出したまま（最初の ✓ で数字に変わる。レイアウトが跳ねない）
├──────────────────────────────────────────────────────┤
│ 前回の組み合わせ                                       │ ← CombinationChips（今日に種目が 1 つもないときだけ）
│ [胸・三頭 · 3日前] [背中・二頭 · 5日前] [脚 · 7日前]    │    横スクロール・最大 5・新しい順・中立色
│ [＋ 種目を追加]                                        │
│ 種目を追加すると、前回の重量・回数が入った行が並びます。  │ ← 既存 footer は残す
```
組み合わせが 0 件（初回運用）ならチップ行そのものを出さない。

### 2.3 組み合わせの確認シート（CombinationSheet）

```
┌ 9/27(土) 胸・三頭                            [閉じる] ┐
│ ☑ ベンチプレス          60×5 / 57.5×7 / 57.5×7       │ ← その日の記録（W は "W 40×10" 表記）
│ ☑ インクラインDB        16×15 / 16×15 / 16×15         │
│ ☑ ケーブルPD            25×12 / 25×12                 │
│ ☐ 懸垂   追加済み                                     │ ← 今日すでにある種目は off 固定・選べない
│                      [読み込む（3種目）]               │ ← 選んだ順に plannedExerciseIds へ。行は既存 initialDrafts が
└──────────────────────────────────────────────────────┘    「前回の日」（=その種目の直近の日）で埋める
```
保存操作は無い（毎回の記録そのものが組み合わせ）。名前付きルーティン（routine テーブル）は Round 4。

### 2.4 種目追加シート（既存 ExercisePickerView に 2 点追加）

```
┌ 種目を追加                                    [閉じる] ┐
│ 🔍 種目名                                              │
│ 前回の組み合わせ  [胸・三頭 · 3日前] [背中 · 5日前] …   │ ← 組み合わせが 1 件以上あれば常時。タップで 2.3 を push
│ [すべて] [胸] [背中] [肩] …                            │ ← 既存
│ ベンチプレス                                   胸       │
│                       [3種目を追加]                     │
```
入れ替えモード（⋮ →「種目を入れ替え」）: タイトル「入れ替え: ベンチプレス」、部位チップは同じ部位を初期選択（すべてに切替可）、1 つ選ぶと即 `replacePlannedExercise`。組み合わせチップは出さない。

### 2.5 過去日（PastDayView・読み取り専用）

```
│ ‹  月   火   水   木   金   土   日   ›                │
│   (28)  29  [30]  1    2    3    4                    │
│     •    •    •                                        │
├──────────────────────────────────────────────────────┤
│ 9/28(月)                                    [今日へ]   │ ← DaySummaryBar の過去日モード
│ 1,105kg    3セット    1種目          7:05–7:31 · 26分 │
├──────────────────────────────────────────────────────┤
│ ■ ベンチプレス 📈                                     │ ← 名前タップ=推移（既存 ExerciseDetailView を push）
│   1,105kg · e1RM 69kg                                 │
│   1   60×5                                            │ ← 行は summary 表記のみ。✓・スワイプ・＋セット・⋮ なし
│   2   57.5×7                                          │
│   3   57.5×7                                          │
│ （記録なしの日）この日の記録はありません                │
```
過去日のデータは `WorkoutHistoryStore`（読み取り専用）から。今日の store（下書き・並び・休憩）には触れない。過去日を見ている間も休憩バーと下書きは生きている。

### 2.6 分析（WeekAnalysisView・push）

```
┌ ‹ トレーニング   分析                                  ┐
│ [‹]   今週  9/28(月)〜10/4(日)   [›]                   │ ← › は今週で無効。「n週目」表記は採らない（定義が曖昧）
│ 総ボリューム                                            │
│ 2,545kg          前週比 +12%（前週 2,270kg）             │ ← 前週なし: 「前週の記録なし」
│  ▇                                                     │
│  ▇    ▇         ▇                                      │ ← BarMark 曜日×kg、部位で積み上げ。部位→色は固定マップ
│  月   火   水   木   金   土   日     ■胸 ■背中 ■脚     │    kg のない日（自重・時間のみ）は 0（本番セット数には出る）
│ 本番セット数（部位別）                       計 15       │
│  胸 6 · 三頭 3 · 背中 4 · 二頭 2                        │ ← その週 >0 の部位のみ、多い順。「抜けている部位」は次バッチ
├──────────────────────────────────────────────────────┤
│ 種目ごとの推移                                          │ ← 現在タブ下部にある一覧を移設（記録がある全種目・マスタ順）
│  ベンチプレス                                  胸  ›    │
│  懸垂                                          背中 ›   │
└──────────────────────────────────────────────────────┘
```
出さないもの: 「今週 N 日」「連続 N 週」「目標達成」（INV-6）、kcal、回復度。

### 2.7 1 画面目にカード先頭行が見える条件（数値）

iPhone 17（縦 852pt）で上から: ステータス＋inline ナビ 103 / 週帯 ≤ 64 / 合計バー ≤ 56 / カード見出し 2 行 ≈ 52 / 列見出し ≈ 30 / セット 1 行目 44 → **累計 ≈ 349pt**。下からタブバー 83 ＋休憩バー 70 を引いても 852 − 153 = 699pt が使えるので、余裕は約 350pt。受け入れ条件は「固定領域（週帯＋合計バー）の合計 ≤ 120pt」と「モックで種目 1 件を追加した直後のスクリーンショットに 1 行目の ✓ が写っている」の 2 点で判定する。

---

### 3. 実装設計

### 3.1 追加・変更ファイル

| 種別 | ファイル | 内容 | 目安行数 |
|---|---|---|---|
| 追加 | `Sources/Services/WorkoutSummary.swift` | 日・週・組み合わせ・カード見出しの pure 関数（DB / Singleton に触れない） | ≤ 200 |
| 追加 | `Sources/Services/WorkoutHistoryStore.swift` | 読み取り専用 store（週バケットのキャッシュ） | ≤ 100 |
| 追加 | `Sources/Views/Workout/WeekStripView.swift` | 週帯 | ≤ 120 |
| 追加 | `Sources/Views/Workout/DaySummaryBar.swift` | 日の合計バー（今日 / 過去日の 2 モード） | ≤ 80 |
| 追加 | `Sources/Views/Workout/PastDayView.swift` | 過去日の read-only 表示（`PastExerciseCard` 含む） | ≤ 120 |
| 追加 | `Sources/Views/Workout/CombinationViews.swift` | `CombinationChips` ＋ `CombinationSheet` | ≤ 160 |
| 追加 | `Sources/Views/Workout/WeekAnalysisView.swift` | 週分析＋推移一覧 | ≤ 200 |
| 追加 | `LifeTrackerTests/WorkoutSummaryTests.swift` | pure 関数テスト | — |
| 追加 | `LifeTrackerTests/WorkoutHistoryStoreTests.swift` | history store テスト | — |
| 変更 | `WorkoutDataSource.swift` | protocol に `fetchSets(completedFrom:to:)` 追加、`WorkoutLogic.formatVolume` 追加 | +15 |
| 変更 | `SupabaseWorkoutDataSource.swift` | `fetchAllPages` ヘルパー、新フェッチ、`fetchExerciseSets` / `fetchRecordedExerciseIds` をページング化 | +40 |
| 変更 | `MockWorkoutDataSource.swift` | 新フェッチ（半開区間・completedAt nil 除外）、`fetchRangeCallCount`（テスト用） | +15 |
| 変更 | `WorkoutSessionStore.swift` | `replacePlannedExercise(_:with:)` 追加。`recordedExerciseIds` / `progressExercises` と `fetchRecordedExerciseIds` 呼び出しを削除（history store へ移管） | ±15 |
| 変更 | `WorkoutProgress.swift` | `ProgressMetric.format(.volume)` を桁区切り（"1,440kg"）に | ±3 |
| 変更 | `WorkoutView.swift` | inline タイトル / ツールバー 📊 / `NavigationPath` / `selectedDay` / 上部固定領域 / 今日・過去日の切替 / 空状態チップ / ⋮ / picker モード / 休憩バーの位置 / 推移セクション削除 | 325 → ≤ 450（超えるなら `exerciseCard` を `TodayExerciseCard.swift` に挙動不変で切り出す） |
| 変更 | `ExercisePickerView.swift` | `mode: Mode` 引数（`.add(combinations:)` / `.replace(current:)`。デフォルト引数なし）、チップ行、単一選択 | +50 |
| 変更 | `WorkoutFixtures.swift` | 直近 4 週に「胸の日」「背中の日」「脚の日」を各 2 回＋懸垂・プランク。同じ組み合わせの重複日を含める（dedupe 確認用） | +30 |
| 変更 | docs | `gymwork-alignment-design.md` 設計（確定）節 / `implementation-roadmap.md`（Round 7 の役割分担 1 行、Round 4 の差し込み位置）/ `round-3-work-plan.md` 進捗ログ | — |
| 不変 | `HomeView.swift` / `LifeTrackerApp.swift` / `SetRows.swift` / `ExerciseDetailView.swift` / `ProgressChartView.swift` / DDL | 触らない | — |

### 3.2 pure 関数（`WorkoutSummary`）とテストケース

日の基準は 1 か所: `dayKey(_ date: Date, calendar:) -> Date = calendar.startOfDay(for:)`（`WorkoutProgress.daily` と同じ completed_at の JST 暦日。session.started_at は日の判定に使わない）。集計の定義も 1 か所: ボリューム = `WorkoutProgress.value(of: .volume, in:)`（weight_reps の本番セット Σw×r。種目横断でもそのまま使える＝カード見出しの合計と日合計が必ず一致）、本番セット数 = `!isWarmup` の件数（自重・時間種目も数える）、種目数 = セットが 1 つでもある種目（W のみでも数える）。

| 関数 | 仕様 | テスト（境界含む） |
|---|---|---|
| `dayTotals(_ sets:) -> DayTotals { volume: Double?, workingSets: Int, exerciseCount: Int, totalSets: Int, firstAt: Date?, lastAt: Date? }` | 上記定義。firstAt/lastAt は W 含む全セットの min/max completedAt | 空 → volume nil・0・0・nil / W だけ → volume nil・working 0・exercise 1・total 1 / 混在（60×10, 自重 12 回, プランク 60 秒）→ volume 600・working 3・exercise 3 / 時刻範囲は種目横断の min/max |
| `timeRangeText(_ t: DayTotals, calendar:) -> String?` | totalSets ≥ 2 かつ firstAt/lastAt ありで "7:02–7:40 · 38分"。それ以外 nil。now を使わない | 1 セット → nil / 2 セット同時刻 → "7:02–7:02 · 0分" / 昼に 1 本足した日 → 範囲がそのまま伸びる |
| `weekStart(containing day:, calendar:) -> Date` | **月曜始まりを定数 `firstWeekday = 2` で明示**し、`calendar.firstWeekday` に依存しない（HomeView.defaultCalendar を変えない） | 月 9/28 → 9/28 / 火 9/30 → 9/28 / 日 10/4 23:59 JST → 9/28 / `2026-10-04T15:30:00Z`（=10/5 0:30 JST 月）→ 10/5 / 年またぎ 2027-01-01(金) → 2026-12-28 |
| `weekDays(containing:calendar:) -> [Date]` | 月〜日の 7 日 | 7 件・連続・先頭が weekStart |
| `weekInterval(containing:calendar:) -> (start: Date, end: Date)` | **半開区間 [月 0:00, 翌月 0:00)**。`DateInterval.contains` は閉区間なので使わない（memory feedback_swift_dateinterval_closed_interval） | 翌月曜 0:00:00 のセットは次週 / 日曜 23:59:59 は今週 |
| `shiftWeek(selected:, by: Int, today:, calendar:) -> Date` | 同じ曜日の前後の週へ。未来になるなら today に丸める | 9/24(木) +1 → 10/1 は未来 → 9/30 / 9/30 −1 → 9/23 / 今週で +1 は呼ばれない（View 側で無効） |
| `isSelectable(day:, today:, calendar:) -> Bool` | 未来日は不可 | 今日 true / 明日 false / 昨日 true |
| `recordedDays(_ sets:, calendar:) -> Set<Date>` | dayKey の集合 | UTC 表記で前日 15:30Z（=JST 0:30）は JST の日 |
| `mergeToday(historySets:, todaySets:, today:, calendar:) -> [WorkoutSet]` | history から今日の分を落として today store のセットに差し替える（3 か所の数字を一致させる） | history に古い今日分があっても todaySets が勝つ / today が空なら今日分なし |
| `weekTotals(sets:, exercisesById:, week:, calendar:) -> WeekTotals { volume: Double?, byDayMuscle: [(day, muscle, volume)], workingSetsByMuscle: [(muscle, count)], totalWorkingSets }` | 半開区間で絞る。部位は `exercise.muscleGroup`（1 種目 1 部位の限界は表示で誤魔化さない） | 境界の 2 セットを除外 / 空週 → volume nil・空配列 / 自重のみの日 → byDayMuscle に 0、workingSets に加算 / 部位別は多い順・同数は表示名順 |
| `volumeChange(current:, previous:) -> Int?` | (cur−prev)/prev×100 を四捨五入。prev nil または 0 → nil | (2545, 2270) → 12 / (90, 100) → −10 / (100, nil) → nil / (100, 0) → nil |
| `combinations(sets:, exercisesById:, today:, calendar:, limit: 5) -> [DayCombination { day, exerciseIds: [UUID], muscleGroups: [MuscleGroup], setsByExercise }]` | today より前の日ごと。exerciseIds はその日に最初に記録した順（`WorkoutLogic.groupByExercise`）。muscleGroups は本番セット数の上位 2（同数は出現順）。**同じ種目集合の日は新しい方だけ残す（dedupe）**。新しい順・limit | 胸日 2 回・背中日 1 回・脚日 1 回（古い胸日は落ちる）→ 3 件、順序は新しい順 / 今日は含まない / 1 部位のみ → "胸" / 3 部位 → 上位 2 / limit 5 / 深夜またぎで 2 日に割れた記録は 2 件のまま（既知の制約） |
| `daysSince(day:, today:, calendar:) -> Int` | 暦日差 | 同日 0 / 9/27→9/30 = 3 / 月またぎ 9/28→10/1 = 3 / 9/29 23:30 JST → 9/30 0:30 JST = 1 |
| `combinationLabel(_ c:, today:, calendar:) -> String` | "胸・三頭 · 3日前" | 1 部位 / 2 部位 / 0 日前は出ない（today を含まないため） |
| `cardHeadline(kind:, todaySets:, previousSets:) -> String?` | weightReps: "今日 {volume} · e1RM {x}kg（前回 {y}kg）"。今日に本番セットなし → "前回 e1RM 67.5kg"。両方なし → nil。repsOnly: 最多回数、duration: 最長時間、durationDistance: 距離（`ProgressMetric.available(for:).first` を見出し指標に使う） | 4 種 × (今日あり/なし × 前回あり/なし) の代表 6 ケース / 今日 W だけ → 「今日なし」扱い |
| `WorkoutLogic.formatVolume(_:)` | "1,440" / "402.5"（桁区切り・小数 1 桁まで） | 1440 → "1,440" / 402.5 → "402.5" / 0 → "0" |

テスト総数の目安: 新規 25〜30 件（既存 62 件は無変更で pass させる）。

### 3.3 データ取得（`WorkoutDataSource`）

```swift
/// 期間内 (completed_at の半開区間 [from, to)) の全種目のセット。completed_at IS NULL は含まない。
/// 1 リクエスト上限 (PostgREST max-rows 1000) を越えないよう実装側でページングする
func fetchSets(completedFrom from: Date, to: Date) async throws -> [WorkoutSet]
```
- Supabase: `.gte("completed_at", value: iso(from)).lt("completed_at", value: iso(to)).order("completed_at").order("set_index").order("id")` を `fetchAllPages` に通す。iso は `ISO8601DateFormatter`（`.withInternetDateTime, .withFractionalSeconds`）
- `fetchAllPages(pageSize: 1000)`: `.range(from: offset, to: offset + pageSize − 1)` を件数 < pageSize まで繰り返す private ヘルパー。**`fetchExerciseSets`（1 種目の全セット）と `fetchRecordedExerciseIds`（全セットの exercise_id）にも適用**（C の指摘 1 の根治。order に `id` を足して順序を安定させる）。単体テストは Mock では書けないので、コードレビュー＋実 DB 起動で確認（既存運用どおり）
- Mock: `sets.filter { $0.completedAt.map { from <= $0 && $0 < to } ?? false }`。`fetchRangeCallCount` を持ち、history store のキャッシュテストに使う
- View / RPC は今回作らない（J2）。`recorded_exercise` View は「セット 5,000 件超で体感が落ちたら」の次手として設計メモに残す

### 3.4 読み取り専用 store（`WorkoutHistoryStore`）

```swift
@MainActor final class WorkoutHistoryStore: ObservableObject {
    @Published private(set) var weeks: [Date: [WorkoutSet]] = [:]   // weekStart → その週のセット
    @Published private(set) var recordedExerciseIds: Set<UUID> = []  // 分析画面の推移一覧用（fetchRecordedExerciseIds）
    @Published private(set) var isLoading = false
    @Published var error: Error?
    init(dataSource: WorkoutDataSource, calendar: Calendar)
    func ensureLoaded(weekStarts: [Date]) async     // 未ロードの週だけ fetchSets(completedFrom:to:) を呼ぶ
    func loadRecordedExerciseIds() async
    func invalidate()                               // weeks を空にする（今日の store の session id が変わったとき）
    func sets(on day: Date) -> [WorkoutSet]         // weeks[weekStart(day)] を dayKey で絞る
    func sets(inWeekStarting weekStart: Date) -> [WorkoutSet]
    func isLoaded(weekStart: Date) -> Bool
}
```
- **書き込み API を一切持たない**（受け入れ条件で grep）。今日の store（`WorkoutSessionStore`）に日付選択の状態を持ち込まない（C 注意 4: 過去日を見ただけで下書きが消える事故の回避）
- 今日の分は常に today store から合成する（`mergeToday`）。history store が今日を含む週を持っていても today store が勝つ
- 更新契機: `WorkoutView.task` / `.refreshable` / 週送り / 分析画面表示（当週＋前週）/ 組み合わせ（今日から 28 日前まで＝5 週）。`.onChange(of: sessionStore.session?.id)` で `invalidate()`（23:50 → 0:10 の日跨ぎで昨日分がキャッシュ落ちしないため）
- テスト: 同じ週を 2 回 `ensureLoaded` してもフェッチは 1 回 / `sets(on:)` は JST 暦日で絞る / `invalidate` 後は再フェッチ / エラーはキャンセルなら無視（既存 `isCancellation` を共用）

### 3.5 今日の store（`WorkoutSessionStore`）の変更（加算 1・削除 1）

```swift
/// 未記録のカードの種目を差し替える (Gymwork の ⇄)。位置は保ち、行は差し替え先の前回値で作り直す。
/// 記録済みのカード・すでに今日にある種目への差し替えは何もしない
func replacePlannedExercise(_ oldId: UUID, with newId: UUID) async
```
テスト: 位置が保たれる / 記録済みは拒否 / 既存種目への差し替えは拒否 / drafts が新種目の前回で再生成される。
削除: `recordedExerciseIds` / `progressExercises` / `load()` 内の `fetchRecordedExerciseIds` / `addSet` 内の `recordedExerciseIds.insert`（既存テストはこれらを参照していない＝削除で壊れない。`load()` の並列フェッチは 3 → 2 本）。それ以外は触らない。

### 3.6 WorkoutView の変更点（記録画面の挙動を壊さない範囲）

- 状態追加: `@State private var selectedDay: Date`（初期値 today の dayKey）、`@StateObject historyStore`、`@State private var path = NavigationPath()`（`[UUID]` から変更。`path.append(exercise.id)` はそのまま動く）、`@State private var loadingCombination: DayCombination?`
- 上部固定: `.safeAreaInset(edge: .top) { VStack(spacing: 0) { WeekStripView(...); DaySummaryBar(...) } }`。ナビは inline
- 本文の切替: `selectedDay == today` → 既存 `List`（変更は見出し部分と空状態のみ）/ それ以外 → `PastDayView(day:, sets: historyStore.sets(on:), exercisesById:, onOpenExercise: { path.append($0) })`
- 休憩バー `safeAreaInset(.bottom)` は切替の外側（NavigationStack 直下）へ移す。`.task(id: restEndsAt)` は元から外側
- `exerciseCard` の変更は見出しの HStack 内だけ（サブ行を `cardHeadline` に、「外す」を ⋮ Menu に）。行の ForEach・`complete()`・`editorSheet`・swipe は 1 行も触らない（`git diff` で確認）
- 空状態: `store.todayExerciseIds.isEmpty` のとき「種目を追加」セクションの上に `CombinationChips`
- ツールバー: `ToolbarItem(placement: .topBarTrailing) { NavigationLink(value: AnalysisRoute()) { Image(systemName: "chart.bar") } }` ＋ `navigationDestination(for: AnalysisRoute.self)`
- 週帯の点: `historyStore.recordedDays ∪ (store.sets.isEmpty ? [] : [today])`

### 3.7 ExercisePickerView の変更

`init(exercises:, mode: Mode, onAdd:)`。`enum Mode { case add(combinations: [DayCombination], onLoad: ([UUID]) -> Void); case replace(current: Exercise) }`。`.replace` は単一選択・同部位を初期チップ・ボタン文言「入れ替える」。`.add` はチップ行（組み合わせが空なら非表示）→ `navigationDestination(for: DayCombination.self) { CombinationSheet }` → 読み込むでシートごと閉じる。デフォルト引数は付けない（呼び出し元は WorkoutView の 1 か所）。

### 3.8 実装手順（回帰防止）

0. 着手前に `xcodebuild test … -only-testing:LifeTrackerTests` を実行し 62 件 pass を記録（ベースライン）
1. `WorkoutSummary.swift` ＋ `WorkoutSummaryTests.swift`（UI 無し）→ テスト
2. `WorkoutDataSource` 拡張 ＋ Supabase（ページング）＋ Mock → テスト（既存 + Mock の半開区間テスト）
3. `WorkoutHistoryStore` ＋ テスト
4. `WorkoutFixtures` 拡充（4 週分・3 種の日）
5. S-1: `DaySummaryBar` / `cardHeadline` 適用 / `replacePlannedExercise` ＋ テスト / ⋮ ＋ picker `.replace` → BUILD → モック起動 → 既存フロー（種目追加 → ✓×3 → 休憩 → 1RM トースト → 推移）を再確認しスクリーンショット
6. S-2: `WeekStripView` / `PastDayView` / `selectedDay` 配線 / inline タイトル / 休憩バー移動 → モックで昨日タップ → 今日へ → 下書きが残っていることを確認
7. S-3: `CombinationViews` / picker `.add` → モックで空状態チップ → 読み込む → 3 カードが前回値で埋まる
8. S-4: `WeekAnalysisView` / 推移一覧の移設 / `NavigationPath` → モックで棒グラフ・前週比・一覧 → 種目 → 推移
9. 各ステップの末尾でテスト全件 ＋ 構造規約 grep（§6）。WorkoutView の `git diff` を読み、`exerciseCard` の行・`complete()`・`editorSheet` に差分が無いことを目視
10. docs 反映（gymwork-alignment-design.md 設計（確定）節、roadmap、work-plan 進捗ログ）

---

### 4. 不採用・次回送り

| 区分 | 項目 | 理由 |
|---|---|---|
| 次バッチ（実機運用後） | 追加 FAB（P8） | 現行ボタンは最後のカード直下で実用差が小さい。休憩バーとの重なり調整が要る |
| 次バッチ | 種目メモ・今日のメモ（P6） | write API 2 本＋「今日のメモは最初の ✓ 以降」の条件分岐。今回の 5 件に入らない |
| 次バッチ | 今週の自己ベスト（分析） | 種目ごとの全履歴が要る（期間取得では出ない） |
| 次バッチ | 「抜けている部位」表示（分析） | 直近 4 週で鍛えた部位と今週の差分。組み合わせ用の 5 週ロードを流用できるので次で安い |
| バッチ 3 | 時間種目のストップウォッチ（P9）/ 1RM 換算表 / 休憩既定値の変更 | 任意の磨き。既存シート内で完結 |
| Round 4 | ~~名前付きルーティン（routine CRUD）~~（→ 変更 1 で前倒し。目標値 target の扱いは Round 4 に残す）/ 過去日のセット編集・追加（C-j 高リスク）/ セット編集 | 既存計画どおり。過去日編集は `PastDayView` に `isReadOnly` を必須引数として導入する形で差し込む |
| 本人決裁 | 体重・体組成 | スコープ（Grit / ヘルスケア境界）の判断は本人 |
| 不採用 | 部位の回復 UI（人体図・回復%・単独一覧） | 1 種目 1 部位で補助筋が出ない。事実はチップの「n日前」で足りる |
| 不採用 | まとめ画像・シェア / kcal / 連続日数・運動完了日数バッジ / 完了・保存ダイアログ / 祝福画面 / 最小化バー / ストレッチ / プログラム / ランキング / プロフィール / SNS / AI / 課金 / 広告 / kg/lbs / オンボーディング | 本人の不採用確定・INV-6・INV-9 |
| 不採用 | 目標回数（10-12）・おすすめ重量 | routine の target が無い。おすすめは根拠を示せない（D11） |
| 不採用 | 「9月 5週目」表記 | 定義が曖昧。日付範囲で代替 |
| 不採用 | 種目画像・器具フィルタ・種目の自作 | 効き目が小さい。自作は MCP 登録で代替できている |
| 不採用 | 動く経過時間（「28分」を刻む）/ 3 つ目のタブ「分析」/ 過去日の週帯を今日タブへ | D3・INV-7・J5/J6 |

---

### 5. 本人決裁が要る論点（AI 既定値で実装を進め、後から変えられる形）

実装をブロックする論点は無い。いずれも既定値で進め、実機で違和感があれば変える。

| # | 要点（現状 → 採用後） | エッジケース | 可逆性 | 知識の在り処 | 検討した他の選択肢 |
|---|---|---|---|---|---|
| R-1 経過時間 | 表示なし → 2 セット以上の日に caption「7:02–7:40 · 38分」（刻まない） | 朝 3 セット＋昼 1 セット → 範囲が実態より長く見える（時刻併記で読める）/ 1 セットの日は出ない | `timeRangeText` の呼び出し 1 行を消すだけ | gymwork-alignment-design.md 設計（確定）節 R-1 | a 出さない / c 動く時計（開始なしの思想と衝突→却下） |
| R-2 週の始まり | 端末ロケール依存（ja_JP=日曜）→ 月曜始まりを `WorkoutSummary.firstWeekday = 2` で明示（HomeView は不変） | 日曜深夜のトレは今週に入る / 将来の今日タブの週表示と揃える必要 | 定数 1 か所 | 同上 R-2、コード定数 | 日曜始まり（Gymwork は月〜日なので不採用） |
| R-3 過去日 | 見る手段なし → 読み取り専用（編集は Round 4） | 昨日の記録忘れを足せない（MCP 直 INSERT で逃がす） | 編集の追加は差分で可 | 同上 R-3、roadmap Round 4 | 今回から編集可（日付境界・空セッション・前回キャッシュの 3 点同時＝高リスク→却下） |
| R-4 ルーティン | **2026-09-30 本人指示で変更 →「変更 1: プログラム」**。旧: UI なし → 「前回の組み合わせ」チップ（保存操作なし）。名前付きは Round 4 | 胸＋脚を同日にやると 1 チップになる（確認シートで種目を外せる）/ 深夜またぎで 2 日に割れる | 表示と store 操作のみ | 同上 R-4 | 名前付き routine CRUD を今回（原子性・target 優先順位の決定が要る→Round 4） |
| R-5 分析の置き場と推移一覧の移設 | 一覧はタブ下部 → 📊 push の分析画面の下部へ | 今日にない種目の推移は 2 タップ（📊 → 種目）になる | 一覧を戻すだけ | 同上 R-5 | 一覧をタブに残す（画面が長くなる・分析が薄い）/ 3 つ目のタブ（INV-7） |
| R-6 チップの本画面表示 | なし → 今日が空のときだけ本画面。種目が入ればシート内のみ | 空の日に「今日は組み合わせを使わない」人はチップを無視して［種目を追加］（1 行分下） | 非表示にするだけ | 同上 R-6 | 常時 1 行に畳んで残す（縦を食う・並置） |
| R-7 INV-5 の言い換え | 「テーブルを増やさない」→「導出値を永続化しない。読み取り時の View/RPC 集計は可」 | 将来の `recorded_exercise` View は migration＝SSOT 改訂を伴う | 文言のみ | 同上 不変条件節 | 現文言のまま（1000 行対策の正攻法を封じる） |
| R-8 週帯＋合計バーの固定表示 | なし → 上部に固定（≤ 120pt）、ナビは inline | 5 種目以上で下までスクロールしても「どの日か」「合計」が見える。縦が 120pt 減る | `safeAreaInset` → List 先頭行へ移すだけ | 同上 R-8 | 固定しない（✓ ごとの合計増加が見えない）/ 週帯だけ非固定（過去日閲覧中に日付が見えなくなる） |

---

### 6. 完了条件（機械チェック）

- [x] `cd LifeTracker && xcodebuild test -project LifeTracker.xcodeproj -scheme LifeTracker -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug -only-testing:LifeTrackerTests` が TEST SUCCEEDED。既存 62 件が全件 pass ＋ 新規 ≥ 25 件（`WorkoutSummaryTests` / `WorkoutHistoryStoreTests` / `WorkoutSessionStoreTests.replacePlannedExercise*`）
- [x] `grep -rn "func fetchSets(completedFrom" LifeTracker/LifeTracker/Sources/Services/` = 3 件（protocol＋Supabase＋Mock）
- [x] `grep -c "\.range(from" LifeTracker/LifeTracker/Sources/Services/SupabaseWorkoutDataSource.swift` ≥ 1 かつ `fetchExerciseSets` / `fetchRecordedExerciseIds` / 新フェッチの 3 つが `fetchAllPages` 経由
- [x] `grep -n "addSet\|deleteSet\|startSession\|endSession\|deleteSession" LifeTracker/LifeTracker/Sources/Services/WorkoutHistoryStore.swift` = 0 件（読み取り専用）
- [x] `grep -rn "selectedDay" LifeTracker/LifeTracker/Sources/Services/WorkoutSessionStore.swift` = 0 件（今日の store に日付状態を持ち込まない）
- [x] `grep -rn "firstWeekday" LifeTracker/LifeTracker/Sources/Views/Home/ LifeTracker/LifeTracker/LifeTrackerApp.swift` = 0 件（HomeView / App は不変）、`git diff --stat -- LifeTracker/LifeTracker/Sources/Views/Home LifeTracker/LifeTracker/LifeTrackerApp.swift LifeTracker/LifeTracker/Sources/Views/Workout/SetRows.swift` が空
- [x] 構造規約 grep: `isReadOnly: Bool = false` 0 件（C-5）/ NavigationLink label 内の `Button|Toggle|DatePicker|TextField|Menu` 0 件（A-1）/ `@Binding var.*Toast` 0 件（A-2）/ `UIImpactFeedbackGenerator|UINotificationFeedbackGenerator` 0 件（B-1）
- [x] 行数: `wc -l` で WorkoutView.swift ≤ 450、新規 View ファイル各 ≤ 200、WorkoutSummary.swift ≤ 200
- [x] `git diff LifeTracker/LifeTracker/Sources/Views/Workout/WorkoutView.swift` に `ForEach(Array(completed.enumerated())` 〜 `Button { store.addDraft` の行、`private func complete(`、`editorSheet(` 内部の変更が無い（記録画面の挙動不変）
- [x] モック（`-mock-workout`）でスクリーンショット 7 枚: ①今日・空（チップ）②組み合わせ確認シート ③読み込み後に 3 カードが前回値で埋まった状態（1 画面目に 1 行目の ✓ が写る）④✓×2 後の合計バー（kg・セット・種目・時刻範囲）⑤昨日タップの過去日 read-only ⑥⋮ → 入れ替えシート ⑦分析（棒グラフ・前週比・推移一覧）
- [ ]（1RM トースト以外は確認済み 2026-09-30） 回帰（モック）: 種目追加 → ✓×3 → 休憩 3:00 表示 → 1RM トースト → 名前タップで推移。過去日を見て今日に戻っても未保存の行と休憩バーが残る
- [x] docs: `gymwork-alignment-design.md` に「設計（確定）」節（採用・不採用・不変条件 INV-1〜10（INV-5 は R-7 の文言）・R-1〜R-8）、`implementation-roadmap.md` Round 7 に「トレーニングタブの週帯は実施日の閲覧専用。今日タブの日付ナビと連動・二重化しない」、Round 4 に「過去日編集は PastDayView に isReadOnly 必須引数を導入して差し込む」
- [ ] 実 DB: 本人がシミュレータで起動し、トレーニングタブ・過去日・分析の読み込みがエラーなく完了（書き込み系は既存どおり本人確認待ち）（今日の読み込みは 2026-09-30 親が確認。過去日・分析は実 DB のデータが今日分のみで未確認）

---

### 付記: 既知の制約（受け入れ済み）
- 深夜 0 時またぎのトレは 2 日に分かれる（合計・週帯の点・組み合わせも 2 つに割れる）。本人合意済みのエッジケースと同型
- 1 種目 1 部位（ベンチ＝胸のみ）。週分析の部位別・チップの部位名はこの粒度
- 自重・時間種目だけの日はボリューム無し（kg を省略、棒グラフは 0）。本番セット数には数える
- ページングは線形（3 年運用で `fetchRecordedExerciseIds` が 12 リクエスト程度）。体感が落ちたら `recorded_exercise` View（R-7 で許容）

### 付記: 実装メモ（2026-09-30 S-0〜S-4 実装時。設計からの差分）
- `selectedDay` は `Date?`（nil = 今日）。`Date` で今日を持つと、画面を開いたまま日付をまたいだとき「昨日」を過去日として表示し続けるため
- 結果の値型（`DayTotals` / `WeekTotals` / `DayCombination`）は `Models/WorkoutSummaryModels.swift` に分離（`WorkoutSummary.swift` ≤ 200 行を守るため）。ほか `dayLabel` / `weekdaySymbol` / `recentWeekStarts` / `setsSummary`（過去日カード用）を追加
- `ExercisePickerView.Mode.add` は `context: CombinationContext`（種目名・追加済み・today・calendar）も受け取る（確認シートに今日の種目の「追加済み」表示が要るため）
- 入れ替えモードは §2.4 のとおり 1 つ選んだ時点で確定（§3.7 の「入れ替える」ボタンは置かない）
- 合計バーの時刻範囲は今日・過去日とも 2 行目の右（§2.1 と §2.5 で位置が違ったため揃えた）
- `WorkoutHistoryStore.ensureLoaded` は未ロードの週をまとめて 1 リクエストで取る（組み合わせ用の 5 週も 1 回）
- アーカイブ済み種目（種目マスタに無い）のセットは部位別・組み合わせに出さない（週の総ボリューム・本番セット計には含む）
- 入れ替えのテストは既存 `WorkoutTests.swift` を触らないよう `WorkoutHistoryStoreTests.swift` の `WorkoutSessionStoreReplaceTests` に置いた
- §2 の図の「9/30(火)」は実際は水曜（テストは実際の曜日で書いた）


### 付記: 親の検証ログ（2026-09-30 モック・iPhone 17 シミュレータ）
- テスト 90/90 pass（xcresult で確認）
- ①空状態: 週帯（28・29 に点、30=今日、未来は淡色）＋「まだ記録なし」＋チップ「背中・二頭 · 1日前」「胸・三頭 · 2日前」… ②チップ→確認シート（9/28(月) 胸・三頭、3種目チェック・前回値表示）③読み込む→ベンチ 60×10/65×8/65×6 など 3 カードが前回値で埋まり、1 行目の ✓ は 1 画面目 ④✓×2 → 合計バー「1,120kg 2セット 1種目 · 6:18–6:18 · 0分」、見出し「今日 1,120kg · e1RM 82.3kg（前回 82.3kg）」、休憩 2:58、次行ハイライト ⑤29 タップ→過去日 read-only（懸垂・ラットプル…、[今日へ]、休憩バー維持）→今日へ戻ると未保存行・休憩が残る ⑥⋮→「種目を入れ替え / 今日から外す」→入れ替えシート ⑦📊→分析（今週 5,711kg・前週比 −36%・曜日×部位棒・部位別セット・推移一覧）→ベンチ→推移グラフ
- 確認中の修正: 種目追加・入れ替えシートの種目名がボタンのアクセント色（青）になっていた → `Color.primary` / `Color.secondary` 明示（記録行で既知の落とし穴と同じ）。再ビルドで黒字を確認
- 気づき（未対応・本人判断）: 週の途中では「前週比」が必ず大きくマイナスに出る（水曜時点で −36%）。「前週の同じ曜日まで」と比べるか、今週が終わるまで出さない案がある
- 1RM トーストはこの確認では出していない（complete() は差分なし・既存テストでロジック担保）
- 実 DB 接続でトレーニングタブを起動 → 合計バー「820kg 4セット 2種目 · 4:15–4:34 · 18分」・カード見出しがエラーなく表示（期間取得・ページングの読み取りが実 DB で成立）。過去日・分析の実 DB 確認は本人

## 変更 1: 「前回の組み合わせ」→ プログラム（2026-09-30 本人指示）

本人指示（原文）:「前回の組み合わせは不要。その代わり、自分でプログラムを組んでそれを登録、呼び出しできるようにすべき」。§5 R-4（名前付きルーティンは作らず、前回の組み合わせで代替する）をこの指示で覆す。

### 前提
- DB 変更なし。既存の `routine` / `routine_exercise`（0003_training_domain.sql）をそのまま使う。実データは 0 件（Round 1 の C 調査）
- 画面上の呼び名は「プログラム」（本人の言葉）。DB・コード上は routine のまま

### 設計（AI 既定。後から変えられる）
| # | 論点 | 既定 | 理由 |
|---|------|------|------|
| P-1 | 呼び出し方 | チップ → 確認シート（種目ごとに外せる・前回の記録を併記）→「読み込む」。行は従来どおり**その種目の前回の値**で埋まる | 組み合わせの確認シートの良さ（誤タップ防止・前回が見える）をそのまま残す |
| P-2 | 目標（target_sets/reps/weight） | 使わない（NULL で保存） | LT の強みは「前回の値が入っている行」。目標値と前回値のどちらを優先するかは未決（§4 の「目標回数・おすすめ重量」不採用と整合） |
| P-3 | 削除 | `is_archived = true`（論理削除） | `workout_session.routine_id` の参照を残す。取り消しは DB で戻せる |
| P-4 | 作り方 | 管理画面で「新規」（名前＋種目を選ぶ・並べ替え・外す）と「今日の種目から作成」 | 終了時の保存ダイアログは作らない（開始・終了の儀式を挟まない本人方針）。**9/30 UIレビューで変更（9/30 実装済・commit 済）: 「今日の種目から作成」は一覧から外し、左上「プログラム」Menu の「新しいプログラムに保存」「今日の種目で上書き」へ（final.md D-1）** |
| P-5 | 置き場所 | 呼び出し: 今日が空のときの「プログラム」欄 ＋ 種目追加シート上部（組み合わせチップの位置）。管理: トレーニングのツールバー | 組み合わせと同じ導線に差し替えるだけにして、記録画面を変えない。**9/30 変更（9/30 実装済・commit 済）: ツールバーは文字「プログラム」の Menu に。一覧行はタップで編集（›）＝管理用（final.md D-1/D-2）** |
| P-6 | 保存の原子性 | routine を INSERT/UPDATE → その routine の routine_exercise を DELETE → 並び順で INSERT。途中で失敗したらエラーを出して編集画面を開いたままにし、もう一度保存すれば同じ手順でやり直せる | クライアントからはトランザクションを張れない。個人利用・件数小のため RPC（DB 関数）までは作らない |
| P-7 | セッションとの紐付け | `workout_session.routine_id` は付けない | セッションは最初の✓で裏で作られる。どのプログラムから来たかは今は使い道がない |

### 撤去するもの
- `DayCombination` / `WorkoutSummary.combinations` / `combinationLabel` / `CombinationViews.swift` とそのテスト
- 履歴の先読み（5 週分）は残し、用途をプログラム確認シートの「前回」表示に振り替える（種目ごとの履歴は読み込むまで無いため）

### 実装
- `WorkoutDataSource`: `fetchAllRoutineExercises()` / `saveRoutine(id:name:exerciseIds:)` / `archiveRoutine(id:)`
- `WorkoutProgram`（routine＋種目 id の並び）と `ProgramStore`（今日の store とは別。今日の下書きに触れない）
- View: `ProgramViews.swift`（チップ・確認シート・一覧・編集）。`ExercisePickerView.Mode.add` は組み合わせの代わりにプログラムを受け取る

### 検証（2026-09-30 06:50–06:58）
- テスト 96 件すべて成功（xcresult で確認）。追加: ProgramStore 6 件（新規・編集と重複除去・入力チェック・途中失敗からのやり直し・論理削除・今日の下書きに触れない）、latestDaySets 1 件。削除: 組み合わせ 4 件
- シミュレータ（モック・iPhone 17）で確認: 空状態の「プログラム」チップ → 確認シート（種目＋前回の記録）→ 読み込みで 3 カードが前回値で埋まる / ツールバー左から一覧（今日の種目から作成・3 件）/ ＋ で新規（名前・種目を選んだ順・保存で一覧に追加）/ スワイプ削除で一覧から消える / 種目追加シート上部にプログラムのチップ → 確認シート
- 未解決の観察: 1 回目の新規作成で「2種目を追加」後に 1 種目しか入らず、その後、編集シートが勝手に閉じた。同じ手順（かな入力・候補確定・下の種目から選択を含む）で 3 回やり直しても再現せず。→ 本人「おそらく私がいじってしまった」（確認中に本人がシミュレータを操作していた可能性）。不具合としては扱わない
- 実 DB での書き込み（routine の INSERT・UPDATE・論理削除、routine_exercise の DELETE・INSERT）は未確認。確認すると本人の DB にプログラムが残るので、本人の実機確認で登録するときに併せて見る

### 操作手順（2026-09-30 本人に説明した内容）
- 作成: トレーニングタブ左上の一覧アイコン →「プログラム」一覧 → 右上 ＋ → 名前 →「種目を追加」で複数選択（選んだ順）→「N種目を追加」→ ≡ で並べ替え・左スワイプで外す → 右上「保存」
- 今日の種目から: 今日の画面に種目があると一覧の先頭に「今日の種目から作成（N種目）」→ 名前を入れて保存
- 編集: 一覧の行をタップ / 削除: 行を左スワイプ →「削除」（論理削除）
- 保存できない条件: 名前が空・種目 0（画面下に理由を表示）
- 観察: 実装直後に本人から「どうやってプログラムを保存するの？」と質問があった。入口（左上アイコン）の分かりやすさは本人の実機確認で見る

### UI/UX レビュー（2026-09-30）
- 監査者A（情報アーキテクチャ・Gymwork比較）・B（シミュレータで操作フロー）→レビュアー統合。結果は `docs/ux-review-2026-09-30/`（auditor-a.md / auditor-b.md / final.md）
- すぐ直す F-1〜F-14（合計1日弱）、本人の判断 D-1〜D-4（今日の画面から保存・一覧タップの動き・休憩終了の通知・前週比の週途中比較）。本人決裁済（final.md 末尾）。9/30 実装・シミュレータ確認済（final.md「実装結果」）。commit 済（branch feat/round3-training）・実機未確認

## 変更（2026-09-30 本人指示）: トレーニング画面のプログラム導線
- 本人: 「root 画面に『プログラムを作る』ボタンがあるのは使いづらい。『プログラムから選択』ボタンであるべき。作るのは左上の『プログラム』ボタンから」
- 変更前: 今日が空の日に「プログラム」セクション（プログラムがあればチップ、無ければ「プログラムを作る」→一覧へ）
- 変更後: **「種目を追加」の上に（本人指示）**、**別の枠（つなげない。本人指示）**で「プログラムから選択」ボタン（今日が空の日だけ。**0 件のときは押せない＝灰色**、footer で「左上の『プログラム』から作れます」）。押すと一覧 → 確認シート → 読み込み
- List 内の disabled は文字が黒くなるだけでアイコンが青く残るため、押せないときはラベル全体を灰色にしている
- 左上「プログラム」メニューの先頭に「新しいプログラムを作成」を追加（作成・一覧・今日の種目の保存/上書きはすべてここ）
- 種目追加シート内のプログラムチップはそのまま
- シミュレータ（モック）で確認済み・単体テスト成功・9/30 commit 済
