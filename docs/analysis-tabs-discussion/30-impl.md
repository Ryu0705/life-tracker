# 分析画面の分割 — データ・実装の観点（2026-10-10）

担当: データ・実装。コードは読んだだけで、変更していない。シミュレータは触っていない。
この文書は「どの形態が良いか」の UX 判断はしない（推奨は UX/システム観点で決める方針のため）。各形態の実装上の地雷とコストを出し、UX 側の判断材料にする。

読んだもの: `WeekAnalysisView.swift` / `BodyStrengthViews.swift` / `ContinuityViews.swift` / `MonthHeatmapView.swift` / `PeriodNavigator.swift` / `WorkoutView.swift` / `BodyDiagramView.swift` / `SleepTrendView.swift`（前例）/ `WorkoutHistoryStore.swift` / `ProfileStore.swift` / `ContinuityStore.swift` / `StrengthLevels.swift`（StrengthPeriod）/ `LifeTrackerTests/*` / `docs/structural-conventions.md` / `docs/gymwork-alignment-design.md` J6・R-5 / memory feedback_swiftui_*。

---

## 1. 現状の構造（事実）

### 1-1. 画面とナビゲーション
- `WorkoutView` が `NavigationStack(path: $path)` を持つ。destination はルートに 3 つ登録されている: `UUID`（種目詳細 `ExerciseDetailView`）、`AnalysisRoute`（分析）、`ProgramsRoute`（プログラム一覧）。`AnalysisRoute` はフィールドなしの struct
- 分析は 1 枚の `List`（スタイル指定なし = insetGrouped）。中身は上から:
  - `BodyStrengthSections`（Section「強さ」＋ Section「心肺」）
  - `AnalysisContinuitySection`（Section「継続」）
  - `Section { weekNavigation }` ＋ 総ボリューム ＋ 本番セット数 ＋ 種目ごとの推移（`NavigationLink(value: exercise.id)` で種目詳細へ）
- リポジトリ内に `.listStyle` 指定は 0 件。`TabView` はアプリのルート（予定・トレーニング・睡眠）だけで、画面内の TabView(.page) の前例はない
- 前例として、睡眠の「推移」（`SleepTrendView`）が 1 つの Section 内に「週｜月」の segmented Picker と ‹ › ナビを並べている

### 1-2. 状態（@State）の置き場所
| 状態 | 持ち主 | 初期値 | いつ消えるか（現状） |
|---|---|---|---|
| 週 `weekStart: Date?` | WeekAnalysisView | nil = 今週 | 分析から戻ると消える |
| 強さの期間 `period: StrengthPeriod` | BodyStrengthSections | `.recent` | 同上 |
| 部位シート `selected` / プロフィール `sheet` | BodyStrengthSections | nil | 同上 |
| ヒートマップ `range: HeatmapRange` | AnalysisContinuitySection | `.halfYear` | 同上 |
| 1 か月のページ `monthPage: Int` | AnalysisContinuitySection | 0 | 同上。`range` を変えると 0 に戻す |

どれも子 View の中に閉じている。親は子の状態を知らない。

### 1-3. ロード（ensureLoaded）
| 誰が | 何を | トリガー |
|---|---|---|
| WorkoutView `.task` | 直近 5 週＋表示中の週 | 起動時・セッション変更時（`invalidate()` 後） |
| WeekAnalysisView `.task(id: shownWeek)` | 表示中の週＋前週 | 週の移動 |
| WeekAnalysisView `.task` | 種目の記録有無（`loadRecordedExerciseIds`） | 分析を開くたび（キャッシュなし。毎回 1 リクエスト） |
| WeekAnalysisView `.task` | 直近 26 週（ヒートマップ用の先読み） | 分析を開くたび（読み済みの週は飛ばす） |
| BodyStrengthSections `.task(id: period)` | 30 日期間を含む週（5〜6 週） | 期間の移動 |
| BodyStrengthSections `.task` | プロフィール・体重（未ロード時のみ） | 初回 |
| AnalysisContinuitySection `.task(id: monthPage)` | 1 か月表示の 5 週 | ページ移動（`range == .month` の間だけ存在） |

`WorkoutHistoryStore.ensureLoaded` の仕様（`WorkoutHistoryStore.swift:41-64`）:
- 「未ロード かつ 取得中でない」週だけを 1 リクエストで取る
- **取得中の週を要求されたら、その取得の完了を待たずに即 return する**（`inFlight` で除外するだけ）
- 取得が キャンセル されると、`defer` で `inFlight` から外し、`weeks` には何も入れない。キャンセルのエラーは表示しない

強さは「期間の週が全部読めるまで級を出さず『読み込み中…』」（A-6）。ヒートマップには読み込み中の表示がなく、未ロードの日は「記録なし」の色になる。

---

## 2. どの形態でも効く地雷（共通）

### 地雷 1（重要）: 取得中の週を待たない ensureLoaded × 画面の出入り → 「読み込み中…」が消えない／ヒートマップが空で出る
現状でも潜在しているが、ページを出し入れする形態（A・B、C の実装次第）で踏みやすくなる。

再現の筋道（コードから組み立てた推測。実機では未確認）:
1. ページ X の `.task` が週 W1〜W26 を取得中（`inFlight` に入っている）
2. ページを切り替える → X が消え、X の `.task` がキャンセルされる。ただし `defer`（inFlight から外す処理）は await が戻ってから走るので、少し遅れる
3. 同じトランザクションで出てきたページ Y の `.task` が W1〜W26 を要求 → まだ `inFlight` にあるので除外 → 即 return（Y の task は終了）
4. X の取得がキャンセルで終わり、`weeks` には何も入らない
5. Y はもう task を再実行しないので、強さは「読み込み中…」のまま、ヒートマップは全部「記録なし」の色のまま（structural-conventions D-1「過去週は全部未記録と偽表示」と同じ型）。期間を ‹ › で動かすか、画面を出直すまで直らない

対策（どちらか、または両方）:
- (a) 先読みの `.task` は、ページを切り替えても消えない層（分析のコンテナ = 今の WeekAnalysisView のルート）に置く。ページ側の `.task` は「そのページで期間を動かしたとき」だけにする
- (b) store を直す: `inFlight` を `[Date: Task<Void, Never>]` にして、取得中の週を要求されたらその Task を await する。キャンセルされた取得は呼び出し元ごとに取り直す。`WorkoutHistoryStoreTests` に「取得中に同じ週を要求した側は、取得完了後に読めている」「先行の取得がキャンセルされても後続の要求で読める」のテストを足せる（今のテストは「2 回呼んでもフェッチ 1 回」「invalidate 後は再フェッチ」のみ）
- (b) は日跨ぎの `invalidate()` と分析の同時進行にも効く。規模は store 1 ファイル＋テスト 2 件程度

### 地雷 2: ヒートマップの閾値が読み込み途中で動く（ちらつき）
- 色の閾値は `TrainingHeatmap.windowThresholds`（今日から 26 週の窓の、読めている日だけで 4 分位）
- WorkoutView が直近 5 週を先に読んでいるので、分析を開いた直後は「5 週分の閾値」で塗られ、26 週の先読みが終わると閾値が変わって色が変わる
- 1 枚の画面だと継続が画面の中ほどにあり目立たない。継続を独立ページにすると、開いた瞬間に目の前で色が変わる
- 対策: 継続ページでは 26 週が全部読めるまで（`isLoaded` が全部 true になるまで）色を出さない／「読み込み中」を出す。強さの A-6 と同じ扱いに揃える。ヒートマップに A-6 相当の判定を足すだけで、DB・store は変えない

### 地雷 3: List の Section に `.sheet` / `.task` を付けると各行に配られる（memory feedback_swiftui_sheet_keyboard_and_nested_menu）
- 今は強さの `.sheet` 2 つと `.task` 2 つを、Section 先頭の PeriodNavigator の行に付けて避けている（`BodyStrengthSections.swift:31-41`）
- ページを分けるときに「ページ単位の List に付け直す」のは安全（List の外側なので配られない）。逆に「Section に付け替える」と再発する。移すなら List の外側か 1 行に
- 継続の `.task(id: monthPage)` も 1 行（PeriodNavigator）に付いている。同じ扱い

### 地雷 4: `.task` を EmptyView に畳まれる分岐に付けない（memory feedback_swiftui_task_emptyview）
- ページを `switch tab { case ...: ... }` で出し分け、外側に `.task` を付ける形にすると、どこかのブランチが「空」（データなし時に EmptyView を返す等）になった瞬間に `.task` が発火しない恐れがある
- 今の分析のブランチはすべて List 等の具体 View を返すので問題はないが、「データがないページは何も出さない」実装にすると踏む。空のページも List＋「記録はありません」の行を返す形に統一する

### 地雷 5: Button label の色（memory feedback_swiftui_button_label_tint）
- 新しく作るハブの行・ページ見出しを Button にする場合、label の色は `Color.primary` / `Color.secondary` を明示する（`.primary` だと青くなる）。既存の MuscleRow・weightLabel はすでに対策済み

### 共通: 下ごしらえとして先にやると、どの形態にも効くこと
1. 3 つのページ View に切り出す: `StrengthPage`（強さ＋心肺）/ `ContinuityPage`（連続日数・ヒートマップ）/ `TrainingVolumePage`（週ナビ＋総ボリューム＋本番セット数＋種目ごとの推移）。中身は今の Section をそのまま移すだけ
2. 週ナビ（`weekNavigation`）を `PeriodNavigator` に置き換える。今は同じ見た目を 2 回書いている（B-1「ユーティリティ導入時は旧実装を全数置換」の取りこぼし）。分割で週ナビがページ先頭に来ると、他のページの ‹ › と見た目・ヒット領域を揃える必要が出る
3. 地雷 1 の (a) か (b)
4. 地雷 2 の「読み終わるまで色を出さない」

これだけでも縦に 1 枚のまま「見出しと期間ナビの重なり」は整理できない（それは分割の形の問題）が、どの形態を選んでも作業の 6〜7 割はここになる。

---

## 3. 形態ごとの比較

### (A) 分析画面の上部に segmented Picker、3 ページを切り替える

置き場所の選択肢:
- A-1: ナビバーの中央（`ToolbarItem(placement: .principal)`）。「分析」のタイトルは消える（Picker がタイトル代わり）
- A-2: List の先頭行（睡眠の推移と同じ形）。スクロールすると Picker も流れていく
- A-3: `.safeAreaInset(edge: .top)` で List の上に固定

**状態の保持/リセット**
- `switch` で出し分けると、見えていないページの View は破棄され、中の @State（期間・range・monthPage）は**ページを切り替えるたびに初期値に戻る**。「強さで 2 つ前の 30 日を見ていた → 継続を見て戻ると直近 30 日に戻っている」
- 保持したいなら、状態を WeekAnalysisView に引き上げて Binding で渡す（`period`・`range`・`monthPage`・`weekStart` の 4 つ。シート用の `selected` / `sheet` はページ内に残してよい）。5〜10 行の変更
- 戻る（分析を閉じる）とすべて消えるのは今と同じ
- 選んでいたページ（tab）も、分析を閉じると消える。次に開いたとき何を出すかは UX 側の決めごと（最後に見たページを覚えるなら `@SceneStorage` か `@AppStorage`。DB は不要）

**ロードとちらつき**
- ページ側に `.task` を持たせると、地雷 1 を一番踏みやすい形（切替のたびに出入りする）。先読みはコンテナに置く（地雷 1 (a)）
- 先読みをコンテナに置けば、最初にどのページを開いても 26 週を読み始めるので、ページ切替時のちらつきは「最初の 1 回の読み込み中」だけになる
- `loadRecordedExerciseIds` は中身ページでしか使わない。コンテナに残しても害はない（1 リクエスト）

**NavigationStack との干渉**
- 種目詳細の push（`UUID` の destination）はルート登録なので、どのページから押しても今まで通り動く
- 種目詳細から戻ると、分析の View は破棄されていない（push 中も下に残る）ので、選んでいたページ・期間は残る。ここは心配ない
- A-1（principal に Picker）の場合、push 先の種目詳細はタイトル「種目名」に置き換わるだけで、干渉はない

**sticky header / スクロール位置**
- insetGrouped の List では Section 見出しは固定されない（plain スタイルだけが固定される）。「ページ切替を常に見せたい」なら A-1 か A-3 にする必要がある。A-2 は下までスクロールすると切替が見えなくなる
- ページごとに別の List にすると、切替のたびにスクロール位置は先頭に戻る（View が作り直されるため）。1 つの List の中で Section を出し分けると、スクロール位置が中途半端に残り、短いページに切り替えたとき空白が見える。**ページごとに別の List**を推す（実装上の安定性の理由）
- ページごとにスクロール位置を保持したい場合は `ScrollPosition`（iOS 18+）を ページ×1 個持つ必要があり、手間が増える。今回は「切替で先頭に戻る」で十分と考える（UX 側で要否を判断）

**アクセシビリティ**
- segmented Picker は VoiceOver で「強さ、1/3、選択済み」のように読まれ、標準で扱える。追加作業はラベル付け程度
- A-1 の principal 配置は Dynamic Type が大きいと 3 文字×3 でも狭くなる（「トレーニングの中身」のような長い名前は入らない。ラベルは「強さ｜継続｜中身」程度の短さが前提）

**テスト**
- 単体テストは View を見ていない。`StrengthPeriod`・`TrainingHeatmap.thresholds/level` の静的関数のテストは、型名を変えなければそのまま通る
- UI テスト（`LifeTrackerUITests`）は分析を参照していない。影響なし

**規模**: 共通の下ごしらえ＋コンテナ（Picker と switch）。新規ファイル 0〜1、変更 4〜5 ファイル

### (B) 分析トップをハブにして、各画面へ push

**状態の保持/リセット**
- 各画面は push のたびに新しく作られ、戻ると状態は消える。「強さで期間を戻して → 戻る → また強さを開く」で直近 30 日に戻る
- 保持したいなら状態を WorkoutView（NavigationStack の持ち主）か、新しい小さな ObservableObject（`AnalysisState`）に置く必要がある。A より 1 段遠い
- ハブそのものの状態はない

**ロードとちらつき**
- 各画面が自分で必要な週を読む形になる。強さは今も自分で読めている（`.task(id: period)`）。継続は 26 週の先読みを継続画面に移す。中身は今のまま
- ハブに要約（例: 「Intermediate 3 部位」「🔥 45 日」「今週 12,400kg」）を出すなら、**ハブを開いた時点で 26 週・プロフィール・30 日期間を全部読む**ことになる。今の 1 枚と同じロード量。要約を出さないハブにすると、ハブが単なるメニューになる（structural-conventions C-3「子画面は親より情報が深い」の観点では成立するが、ハブ自身は情報ゼロ）
- 画面ごとに `.task` が完結するので、地雷 1 は「画面を開いてすぐ戻り、すぐ別の画面を開く」場合にだけ当たる。A よりは踏みにくいが、ゼロではない

**NavigationStack との干渉**
- ルートに destination を 3 つ足す（`StrengthRoute` / `ContinuityRoute` / `VolumeRoute`、または `AnalysisRoute` に enum を持たせて 1 つで振り分け）。`AnalysisRoute` に `page` を持たせる形なら登録は増えない
- 深さ: トレーニング → 分析 → 中身 → 種目詳細 の 3 段 push。戻るのに 3 回。今は 2 段
- ハブの行を `NavigationLink(value:)` にし、label に要約を出す場合、label 内に ‹ › ナビや Picker を置くと A-1（label は static のみ）違反。要約は表示だけにする
- ツールバーの「分析」をハブにせず `Menu`（強さ／継続／中身）にする変形もあり得る。その場合ハブ画面は不要で、push は 2 段のまま。ただし Menu は 1 タップ増え、中身が見えないまま選ぶ形になる（UX 判断）

**sticky header / スクロール**: 各画面が独立した List なので問題なし。戻ると前の画面のスクロール位置は保たれる（push の標準動作）

**アクセシビリティ**: 標準の push と戻るなので問題なし。ハブの要約行は `accessibilityElement(children: .combine)` などで 1 行として読ませる作業が要る

**テスト**: A と同じ（影響なし）

**規模**: 共通の下ごしらえ＋ハブ画面（要約を出すなら要約の計算。強さの要約は `StrengthLevels.summarize` を呼べば出るので新しい計算はない）＋ルート。新規 1〜2 ファイル、変更 5〜6 ファイル。要約付きハブなら A の 1.3〜1.5 倍

### (C) TabView(.page) の横スワイプ

**状態の保持/リセット**
- TabView のページは、隣のページへ移っても破棄されないことが多く、@State は概ね残る。ただしページの生成・破棄のタイミングは SwiftUI 任せで、公式には保証されていない（このリポジトリでは未検証）
- 選択ページは `TabView(selection:)` で持てる

**ロードとちらつき**
- 隣のページが先に作られ、見えていないページの `.task` が走ることがある（いつ走るかは実装任せ）。ロード自体は早まるのでちらつきは減る方向だが、「見えていないページの `.task` が途中で止まる → 地雷 1」を一番予測しにくい形。先読みはコンテナ（TabView の外）に置くのが前提
- 3 ページ分の body が常に評価されうるので、`mergeToday` × 26 週のセットの組み合わせ計算が 3 か所で回る（記録の ✓ のたびに）。今の 1 枚でも同じ計算は 1 回ずつ走っているので、増えるのは評価の重なり分。データ量（個人の数百〜数千セット）では体感しないと推測

**NavigationStack との干渉 / ジェスチャー**
- 画面左端からの横スワイプ（戻る）と、ページ送りの横スワイプがぶつかる。1 ページ目で右スワイプすると戻るのか、何もしないのかが不安定になりやすい
- ページの中に ‹ › の期間ナビ（強さ・継続・中身の 3 つすべて）がある。「横スワイプ = ページ（種類）を替える」と「‹ › = 期間を替える」が同じ横方向に並び、指の動きが紛らわしい（これは UX 側の論点だが、ジェスチャーの衝突として実装側からも挙げておく）
- 人体図は `onTapGesture` だけで、ドラッグはない。Swift Charts も選択（`chartXSelection`）を使っていない。今の中身では横ドラッグと競合する部品はない。将来チャートにドラッグ選択を足すと衝突する
- 種目詳細の push は、ルート登録なので動く

**sticky header / スクロール**
- ページごとに List が入るので縦スクロールは独立。ただし TabView の中の List は、ナビバーのスクロール連動（iOS 26 の scroll edge effect・ナビバーの背景の出し入れ）が効かない／不安定なことがある（一般に知られた挙動。このアプリでは未検証）
- ページインジケータ（点）が下に重なるので、最下部の「種目ごとの推移」の行に被らないよう余白が要る
- ページ切替の見える手がかり（どのページがあるか）は点だけになる。結局、上に segmented Picker を足して A＋スワイプになる例が多い

**アクセシビリティ**: VoiceOver ではページ送りが 3 本指スワイプになり、気づきにくい。ページの存在を伝えるには Picker 等の見える切替が別に要る

**テスト**: A と同じ（影響なし）。ただし挙動確認はシミュレータでのスクショ・操作確認が必須（コードからは保証できない部分が多い）

**規模**: コード量は A とほぼ同じ。検証の手間が A・B より大きい（ジェスチャー衝突・ナビバー連動・`.task` の発火タイミング）

### 3 形態の比較表（実装の観点のみ）
| 観点 | A segmented | B ハブ＋push | C ページスワイプ |
|---|---|---|---|
| 期間の状態を保つには | 4 つを WeekAnalysisView に引き上げ（小） | WorkoutView か共有オブジェクトへ（中） | 概ね自然に残る（保証なし） |
| 地雷 1（ロード待たず） | 最も踏みやすい → 先読みをコンテナへ | 踏みにくい | 予測しにくい → 先読みをコンテナへ |
| 種目詳細 push との干渉 | なし | push が 3 段になる | 戻るスワイプと衝突 |
| 切替を常に見せる | principal か safeAreaInset なら可 | 不要（画面ごと） | 点のみ。Picker 併用が多い |
| アクセシビリティ | 標準 | 標準 | 追加の手当てが要る |
| 既存テスト | 影響なし | 影響なし | 影響なし |
| 規模（共通の下ごしらえ込み） | 中 | 中〜やや大 | 中（検証は大） |
| アプリ内の前例 | 睡眠の推移（Picker＋‹ ›） | 睡眠（推移・すべての記録の push） | なし |

---

## 4. DB 変更の要否
- **不要**。読むデータ（セット・entries・記録済み種目 id・プロフィール・体重・トレーニング日・週の目標）は今と同じで、集計はすべて表示時に計算している（INV-5「導出値を永続化しない」とも整合）
- 「最後に見たページを覚える」をするなら端末側（`@SceneStorage` / `@AppStorage`）で足りる。DB に持たせる理由はない
- ハブの要約を出す場合も、既存の計算（`StrengthLevels.summarize`・`Continuity.status`・`WorkoutSummary.weekTotals`）の呼び出しで足り、RPC・View の追加は要らない

## 5. 変更ファイル一覧と規模感（A を想定。B・C の差分は括弧内）
| ファイル | 変更 | 目安 |
|---|---|---|
| `Views/Workout/WeekAnalysisView.swift` | コンテナ化（ページの切替・状態の引き上げ・先読みの集約）。中身ページを切り出す | 180 行 → コンテナ 60〜80 行 |
| `Views/Workout/TrainingVolumeView.swift`（新規、名前は仮） | 週ナビ（PeriodNavigator に置換）＋総ボリューム＋本番セット数＋推移一覧 | 120〜140 行（ほぼ移動） |
| `Views/Workout/BodyStrengthViews.swift` | Section 群をページ（List を持つ側は呼び出し元）へ。`period` を Binding に | 10〜20 行 |
| `Views/Workout/MonthHeatmapView.swift`（AnalysisContinuitySection） | `range`・`monthPage` を Binding に。26 週読み終わるまで色を出さない | 15〜25 行 |
| `Views/Workout/WorkoutView.swift` | A: 変更なし（`AnalysisRoute` に初期ページを持たせるなら数行）／B: destination 追加 or `AnalysisRoute(page:)`／C: なし | 0〜15 行 |
| `Services/WorkoutHistoryStore.swift` | 地雷 1 (b) を採るなら: 取得中の週を待つ | 20〜30 行 |
| `LifeTrackerTests/WorkoutHistoryStoreTests.swift` | (b) を採るなら 2 テスト追加 | 30〜50 行 |
| （B のみ）`Views/Workout/AnalysisHubView.swift` 新規 | 要約行 3 つ | 60〜100 行 |
| docs | `docs/body-strength-and-heatmap-period.md`・`docs/continuity-design.md` の「画面」節、`gymwork-alignment-design.md` J6 の補記 | — |

- Xcode プロジェクトは `PBXFileSystemSynchronizedRootGroup` なので、新規ファイルは置くだけでビルドに入る（project.pbxproj の編集は不要）
- 合計で正味の追加は 100〜200 行、残りは移動。1 回の実装で収まる大きさ。リスクの大半はロードの順序（地雷 1・2）とシートの付け場所（地雷 3）で、どちらもスクショと操作で確かめないと完了にできない

## 6. 実装の観点からの所見（判断は UX 側）
- 「期間の単位がページごとに 1 つになる」のは、実装面でもきれいになる: 今は 1 枚の List に ‹ › が 3 つ（30 日・5 週・1 週）あり、`.task(id:)` も 3 系統が 1 画面で同時に動いている。ページに分けると、1 ページ = 1 つの期間 = 1 つの `.task(id:)` になる
- どの形態でも、先読みとロード待ち（地雷 1・2）は先に直しておくべき。現状の 1 枚のままでも、日跨ぎの invalidate と分析の同時進行で同じ型の不具合が起こりうる（推測。未再現）
- 実装の安定性だけで言えば A ≒ B > C。C は今の中身（ページすべてに ‹ › がある）と横方向の操作が重なり、検証項目が一番多い
