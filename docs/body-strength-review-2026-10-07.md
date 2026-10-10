# 部位ごとの強さ・心肺・ヒートマップ期間・プロフィール/体重 — 実装前レビュー（2026-10-07）

対象: `docs/body-strength-and-heatmap-period.md`（「本人の回答」「本人の質問への回答」「設計（確定・2026-10-07）」節）。【本人】の決定は前提として覆さない。レビューは AI 既定が中心。
根拠は §6「確認した事実」に集約（JSON の集計は `python3 -I` で実測、コードは行番号つき）。推測・未確認はその旨を書く。

## 1. 要約

- 本人判断が要る指摘 **3 件**（§2）: ①期間の意味（転がる 30 日と暦月の混在）②体重入力の入口（分析画面の奥でよいか）③AI が「近い種目で代用」した 15 件（approx）の扱い。いずれも AI 既定で進めてもよいが、見え方・使い方が変わるので 1 問ずつ。
- AI が直せる指摘 **16 件**（§3）。実装前に必ず直すのは上位 6 件: 単位が合わない対応 3 件の除外、「< 1」で閾値が同値になる行の補間規則、体重行の範囲外、級の計算順序（セット→種目→部位）、自重種目の weight NULL、今日の分の合成と読み込み完了待ち。
- 既存の不変条件（INV-1〜10・R-1〜R-8・D-4・D-5）との衝突は**無い**。ただし gymwork-alignment-design §4 の「不採用: プロフィール／部位の回復 UI（人体図…）」「本人決裁: 体重」と continuity-design の「直近半年・草」に、10/7 本人決定の注記が要る（§3 A-14）。
- migration 0011 は既存 docs 3 ファイル 11 か所＋適用済み migration 0006 のコメント 2 か所（計 13 か所）で「旧列削除」に予約されている（§4）。繰り下げの前例（0007→0008→0010→0011）に従うなら全箇所を 0012 に直す。
- 26 週先読み・ページング・週の月曜始まりは設計どおり成立している（§6）。Epley を体重＋加重に当てる式は回数の表と整合する（検算 §3 末尾）。

## 2. 本人判断が要る指摘（1 問ずつ・推奨を先頭に）

### Q1. 強さの期間: 「直近 30 日（転がる窓）」と「先月・先々月（暦月）」を混ぜるか

- **現状（設計 L78）**: 直近 1 か月 = 今日を含む 30 日、先月・先々月 = 暦月。今日 10/7 なら 9/8〜10/7｜9/1〜9/30｜8/1〜8/31。
- **問題**: 直近と先月の重なりが日によって変わる（10/1 に 29 日、10/7 に 23 日、10/28 に 2 日）。月初は切り替えてもほぼ同じ級が出て、月末は別物になる。「先月の方が記録が多くて級が高い」も月初に起きる。
- **選択肢**（現状 → 採用後の差分）
  - **A（推奨）3 つとも 30 日の転がる窓**: 「直近 30 日 9/8〜10/7｜その前 8/9〜9/7｜さらに前 7/10〜8/8」。重ならず長さが同じなので切り替え＝比較になる。差分: ラベルが月名でなくなる（日付範囲で示す）。期間の規則が 1 つになりテストも 1 系統。
  - B 設計どおり（直近 30 日＋暦月、日付範囲のラベル）: 「先月＝9 月」が名前で分かる。重なりはラベルで読み取る。
  - C 暦月 3 つ（今月 1 日〜今日・先月・先々月）: 月初は今月がほぼ灰（10/2 なら 2 日分）。
- **エッジケース**: 年またぎ（1 月の先々月＝前年 11 月。A は日付演算だけで月長に依らない）、2 月、31 日の月。
- **可逆性**: 期間を返す pure 関数 1 つ（§5 の `StrengthPeriod`）の中身とラベル。UI は同じ。
- **記録先**: `body-strength-and-heatmap-period.md`「期間の意味」節。

### Q2. 体重の入力の入口を分析画面（📊 の奥）に置いてよいか

- **現状（設計 画面 2）**: 体重の行は分析画面の強さブロック先頭。トレーニングタブ → 📊 → 行タップ → 入力、の 2 タップ＋入力。
- **問題**: 本人「体重は高頻度で入力できるようなものが望ましい」。分析は push 先で、トレーニングしない日や朝の計量の動線（睡眠タブ・ホーム）から遠い。習慣になるかは置き場で決まる。
- **選択肢**
  - **A（推奨）設計どおり分析画面**: 本人の「体重の推移・食事は後回し」の範囲で最小。推移・食事を作るときに置き場を決め直す（体の記録が 3 つ揃った時点で 1 か所にまとめる方が座りがよい）。差分なし。
  - B トレーニングタブ上部の継続の行の右端に「72.4kg ›」: 1 画面目の縦幅は増やさない。差分: `ContinuityRow`（Button 1 つ）を 2 ボタン構成に改修、受け入れ条件「1 画面目にカード先頭行」の再確認。
  - C 睡眠タブの「今朝のカード」の近くに 1 行: 朝の計量と同じ時間帯の画面。差分: 睡眠タブに体重が混ざる（睡眠設計の範囲外になる）。
- **エッジケース**: プロフィール未設定のとき（A はプロフィール設定ボタンと同じ場所。B/C は「体重を入力 ›」から設定シートへ）。
- **可逆性**: 行の置き場だけ。入力シートは共通部品にしておけば移動は差分小。
- **記録先**: 同 doc「画面」節。

### Q3. AI が「近い種目で代用」した 15 件（approx）を、印なしで級に使ってよいか

- **現状（設計 L82・L86）**: exact 116 件と approx 15 件を同じ扱いで級に使う。対応付けは AI の判断で「各ページの中身までは見ていない」（同 doc L36）。
- **問題**: 近似の中に負荷の性質が違うものがある。例: レッグプレス → `sled-leg-press`（45° スレッド）。本人の 10/3 の記録 100×10（e1RM 133kg）は、仮に 70kg 男性なら表 [90, 139, 202, 277, 359] で **1.9 = Beginner**。水平・座位のレッグプレスは同じ負荷で比べられない。プリーチャーカール（マシン）→ `machine-bicep-curl`、ヒップスラスト（マシン）→ バーベルの `hip-thrust` も同種。なお approx のうち単位が合わない 2 件（バックキック・マウンテンクライマー。ロシアンツイストは exact）は本人判断に依らず除外（§3 A-1）。
- **選択肢**
  - **A（推奨）approx も使うが、種目の行に「近似」の印と代用元（例「sled-leg-press で代用」）を出す**: 差分: 対応表に match 種別を持たせ、タップシートに 1 語足す。
  - B approx は本人が 1 件ずつ確認するまで「基準なし」: 13 件が平均から外れる（胸 4・背中 3・肩 1・二頭 2・脚 2・臀部 1）。確認後に戻す。
  - C 印なしで exact と同じ。
- **エッジケース**: 同じ slug に 2 種目（`chest-press` に通常とインクライン）。印は種目単位に付く。
- **可逆性**: 対応表の 1 列（sl_match）と表示の有無だけ。
- **記録先**: `strength-standards/mapping-draft.csv` の `note`、同 doc「級の計算」節。

## 3. AI が直せる指摘（重要度順。現状 → 問題 → 修正案）

### A-1. 単位が合わない対応が 3 件ある（設計は 4 件の自重種目しか扱っていない）
- 現状: 設計は「チンニング・チンアップ・ディップス（胸/三頭）」だけを単位違いとして扱う（L59・L81）。
- 問題: 対応表には他に **バックキック（マシン）weight_reps → `glute-kickback`（回数の表）／マウンテンクライマー duration → `mountain-climbers`（回数）／ロシアンツイスト weight_reps → `russian-twist`（回数）** がある（§6 ③）。kg の e1RM や秒を回数の閾値に当てると級が出鱈目になる。
- 修正案: 3 件を「基準なし」に落とす（`sl_match` を none へ、note に理由）。実装側は「種目の metric_kind と表の unit が一致しない対応は基準なし扱い」を規則にして、対応表の整合テスト（§5 T-1）で検出する。

### A-2. 「< 1」を 1 にすると隣り合う閾値が同値になり、線形補間が 0 除算になる
- 現状: 「< 1」の閾値は 1 として扱う（L84）。
- 問題: 「< 1」は回数単位の 27 種目にあり、beginner だけでなく **novice にも**出る（female 41 セル・male 6 セル）。1 に置くと [1, 1, 6, 12, 20]（pull-ups female 60kg）のような同値の隣接閾値が 11 組（slug×性別）・計 74 行できる。同値区間の補間は幅 0。
- 修正案: 補間の規則を「値 ≥ 閾値[i] を満たす最大の i を級の下端とし、閾値[i+1] == 閾値[i] なら i+1 側に倒す」と明文化し、§5 T-2 のケースで固定する。「< 1」は 0 にしても同じ問題が残るので、規則の方で吸収する。

### A-3. 体重行の範囲外・刻みの扱いが書かれていない
- 現状: 「隣り合う体重行の間は線形補間」（L82）のみ。
- 問題: 表は男性 50〜140kg・女性 40〜120kg の 5kg 刻み（全 122 種目で同じ）。範囲外（例 48kg・145kg）の挙動が未定義。女性の表の欠けは無い（§6 ①）。
- 修正案: 範囲外は端の行をそのまま使う（外挿しない）。表の読み込み時に「昇順・5kg 刻み・5 値」を検証し、崩れていれば起動時に assert ではなく「基準なし」に落とす（App.init で落とさない。memory feedback_swiftui_app_init_no_fatalerror）。

### A-4. 級の計算順序を「セット → 種目（最大）→ 部位（平均）」に固定し、体重はセットごとに当てる
- 現状: 「種目の記録値（期間内のベスト）」に体重の表を当てる（L81〜83）。体重は「その記録の日以前で最新」。
- 問題: 期間内に体重が変わると、e1RM の最大を出してから 1 つの体重で引くのと、セットごとに体重を当てて級の最大を取るのとで結果が変わる。自重種目の「両方あれば高い方」も、値（回数と kg）ではなく級で比べないと比較できない。
- 修正案: `level(set, bodyWeight(on: set の日)) → 種目 = max → 部位 = mean` の 1 本に統一する。タップシートの「使った記録」は最大を出したセットとその日の体重を出す。W（isWarmup）は除外（INV-4 と同じ）。アーカイブ済み種目（`exercisesById` に無い）は週分析と同じく除外。

### A-5. 自重 weight_reps の weight が NULL のセットを 0（加重なし）として扱う
- 現状: 「加重なしは 0kg」（L59）。
- 問題: DDL のコメントは「NULL = 自重。0 は加重なしを明示」（domain-model.md L255〜256）。アプリの入力は weightReps で weight を必須にしている（`WorkoutDataSource.swift` L104〜107）が、モックの懸垂は `r(10)` = weight nil（`WorkoutFixtures.swift` L34・L43）、MCP 直 INSERT も NULL になり得る。
- 修正案: 自重種目の級計算では `weight ?? 0` を加重とする。既存の e1RM 指標（weight 0 → 0kg）は変えない（設計どおり）。

### A-6. 今日の分を合成し、期間内の全週が読み込み済みになるまで級を出さない
- 現状: 「半年分の先読みから切り出す」（L98）。
- 問題: 先読み（`WeekAnalysisView.swift` L64〜67）は今日の store と別で、分析の他の数字は `mergeToday` で今日の分を合成している（同 L106・L153）。また 26 週の `.task` は表示と並行に走るので、最初の描画時点では一部の週しか無く、級が後から上がって見える。
- 修正案: 強さ・心肺の入力は `WorkoutSummary.mergeToday(historySets:todaySets:)` を通す。期間に含まれる週頭を列挙し、`historyStore.isLoaded(weekStart:)` が全て true になるまで「読み込み中」を出す（前週比の `isLoaded` ゲート L26 と同じ形）。

### A-7. 部位の状態を 3 値にし、Beginner 未満の表示を決める
- 現状: 色 = 級 5 段階＋灰（期間内に記録なし／基準なし）（L71）。級の名前は 1.0〜1.9 = Beginner … 5 = Elite（L85）。
- 問題: 「記録はあるが基準なし」が「記録なし」と同じ灰だと、前腕（基準あり 3／なし 2）・体幹（13／5）・全身（5／4）で「やったのに灰」になる。0〜1 の値（Beginner 未満）の名前と色も未定義（6 状態目）。
- 修正案: `MuscleState = .noRecord / .noStandard(count) / .level(Double)` の 3 値。一覧の行に「基準なし n 種目」を出す。Beginner 未満は名前「Beginner 未満」、色は最も薄い級色か縞にする。級名は英語 5 段のままで可（JSON の `levels` と一致）。日本語にするなら表示だけ。

### A-8. 種目 → slug の対応の持ち方を決める（名前キーのバンドル）
- 現状: 「JSON をアプリにバンドル」（L87）。種目との対応の持ち方は未記載。
- 問題: `exercise.id` は DB 採番（0004 は id を指定しない INSERT）なので、対応は `exercise.name` でしか引けない。名前は UNIQUE（domain-model.md L203）で、seed 159 件と対応表 159 件は完全一致（§6 ③）。ただし本人が MCP で名前を変えると黙って「基準なし」になる。
- 修正案（推奨）: 対応表（名前 → slug・match 種別）もバンドルし、名前で引く。対応が無い種目は「基準なし」。代替: 0011 で `exercise` に `standard_slug TEXT` を足し MCP から設定できるようにする（新しい種目に既存 slug を当てられる利点はあるが、新 slug はどのみちページ取得＝アプリ更新が要る）。

### A-9. DB の細部（user_profile の 1 行制約・updated_at・体重の DATE PK）
- 現状: `user_profile(id = 1 固定 …, created_at/updated_at)`、`body_weight_record(recorded_on DATE PK, …)`（L90〜91）。
- 問題: 「1 行」は `CHECK (id = 1)` が無いと 2 行目を止められない（DB は最後の砦）。`updated_at` は既存 migration に 1 つも無く、更新トリガーも無い（§6 ⑥）。
- 修正案: `id SMALLINT PRIMARY KEY CHECK (id = 1)`、`sex`・`birth_date` は NOT NULL（初回に 3 つ入力する前提）、`updated_at` はクライアントが送るか持たない。**DATE PK は妥当**: 「同じ日は上書き」が PostgREST の upsert（onConflict: recorded_on）で素直に書け、「記録日以前の最新」も単純。JST 日は端末で計算（`@DateOnly` と同じ規約）。朝晩 2 回が要る場合は `id + recorded_at` に移行（行は保てる）。体重の取得は `fetchAllPages` 経由にする（毎日入れると 1000 行は約 2.7 年で越える）。

### A-10. 初回入力は 2 表への書き込みで非原子。「プロフィールあり・体重なし」を状態として持つ
- 現状: 初回シートで性別・生年月日・体重を入力（L72）。
- 問題: `user_profile` と `body_weight_record` への 2 リクエストで、2 本目が失敗すると人体図は灰のまま理由が無い。
- 修正案: 状態を「未設定 → プロフィールを設定」「プロフィールあり・体重なし → 体重を入力」「両方あり → 描画」の 3 つに分け、失敗はシートに理由を出して再送できる形に（ProgramStore の P-6 と同じ考え方）。体重の store は今日の store と別に作り、`historyStore.invalidate()` を呼ばない（INV-3）。

### A-11. ヒートマップの閾値を「半年分」に固定するなら 26 週の窓で切る
- 現状: 「色の閾値は表示期間に関わらず半年分の記録で計算」（L61・L74）。
- 問題: 今の閾値は渡された `volumes` の 4 分位（`ContinuityViews.swift` L152〜156）で、渡しているのは `historyStore.loadedSets`（`WeekAnalysisView.swift` L105〜109）= ロード済みの全週。週ナビで古い週を読むと 26 週より広がり、切り替えなくても色が動く（既存の挙動）。
- 修正案: 閾値は `today` から 26 週の窓に絞った volumes で計算し、1 か月・半年の両方に同じ閾値を渡す（§5 T-7）。

### A-12. 心肺ブロックの「回数」と W の扱いを定義する
- 現状: 「合計時間・距離・回数」（L73）。
- 問題: 回数がセット数か日数か未定義。既存の時間指標（`totalDuration`）は W を除外する（`WorkoutProgress.swift` L81）。
- 修正案: 回数 = セット数（記録の件数）、時間・距離は本番セットの合計、距離 nil は 0 として足す。日数が欲しければ別途「n 日」。

### A-13. 人体図: Path 手描きの代わりに「正規化座標上の基本図形の集合」で組む
- 現状: SwiftUI の Path で前面・背面のシルエットを手描きし、13 部位を別々の形として持つ（L95）。
- 問題: 座標を手で起こす往復が最大の工数で、小さい部位（前腕・ふくらはぎ・二頭）はタップ領域が 44pt を割る。
- 代案 1（推奨）: 0〜1 の正規化座標に部位ごとの `Capsule`／`RoundedRectangle`／`Ellipse` を置いた定数表で前面・背面を組む（部位 13 × 前後で 20 図形程度、1 ファイル ≤ 150 行）。差分: 座標起こし不要、調整は数値の変更、ダーク/ライトは塗り＋ `.secondary` の輪郭で済む、タップは図形の `contentShape`。見た目は「簡略人体」になる。
- 代案 2: 図は表示専用にし、タップは図の下の部位一覧の行に任せる（NavigationLink ではなく `.sheet`。A-1 規約の label 制約を避ける）。差分: 小部位のタップ問題が消える。前面・背面は横並びで同時表示、肩・前腕・ふくらはぎは両面に出す（設計どおり）。

### A-14. 既存 docs に 10/7 本人決定の注記を足す（衝突ではなく更新漏れ）
- `gymwork-alignment-design.md` §4（L324〜326）: 「本人決裁: 体重・体組成」→ 10/7 決定（手入力・日付つき）、「不採用: 部位の回復 UI（人体図…）」→ 回復は不採用のまま、**強さ**の人体図は採用、「不採用: プロフィール」→ 性別・生年月日・体重の最小プロフィールは採用（SNS/ランキング用のプロフィールは不採用のまま）。
- `continuity-design.md` 本人決定 L10「分析画面に直近半年。GitHub の草の形」→ 10/7 に「1 か月｜半年」の切替を追加。
- `gymwork-retention-comparison.md` 行 3（回復度）・行 10（BIG3 の段階評価）→ 強さの級で部分的に対応。`gymwork-discussion/C-data.md` (h) 体重の「本人決裁」→ 決定済み。
- 不変条件は変えない: INV-5（級は計算で出す・JSON は DB に入れない）、INV-9（kg のみ）、D-4/D-5（予実と無関係・pure 関数に DB を持ち込まない）は設計どおり満たす。

### A-15. ファイル構成・モック・バンドル
- `WeekAnalysisView.swift` は 197 行（≤ 200 の目安）、`WorkoutSummary.swift` は 187 行。強さ・プロフィール・心肺・1 か月ヒートマップは別ファイル（例 `BodyStrengthViews.swift` / `ProfileViews.swift` / `MonthHeatmap`）、pure 関数は `Services/StrengthLevels.swift`。
- `WorkoutDataSource` に profile/体重の 4 API を足すなら `MockWorkoutDataSource`（249 行）と `WorkoutFixtures` にプロフィール・体重 3 件を足す（シミュレータ確認の完了条件に要る）。
- JSON（約 1MB・87,007 行、indent=1）は `LifeTracker/LifeTracker/Resources/` に置く（synced group で自動追加。memory feedback_xcode16_pbxfilesystem_sync）。docs 側と二重に持たない（原本の置き場を 1 つに決める）。`docs/strength-standards/` は現在 **未 commit**（`git ls-files` 空）。
- 体重の保存メッセージは子画面の `@State` で（A-2 規約）。

### A-16. 年齢の表を使わない既定は、現時点では結果に効かない（将来の補正余地だけ記す）
- 事実: 年齢の表は 15〜90 歳の 16 行。squat 男性は 20 歳 [64, 93, 128, 169, 213]、25〜40 歳 [66, 95, 131, 173, 219]、50 歳 [58, 84, 116, 153, 194]。20 代は体重の表に対する年齢補正がほぼ 1。
- 修正案: 既定どおり生年月日は保存だけ。将来は「年齢行 ÷ 25〜40 歳行」の比を体重の表に掛ける補正を候補に書いておく（ページに同時適用の方法が無いのは設計どおり）。

### 検算して「変更不要」と判断したもの
- **Epley を体重＋加重に当てて体重を引く式**（L59）: 男性 80kg、加重 0 で回数の表の閾値回数 [1, 7, 13, 21, 29] を Epley 経路に通すと加重換算 [0, 18.7, 34.7, 56, 77.3]kg → 加重の表 [-2, 14, 33, 54, 75] に当てて級 **1.1 / 2.25 / 3.08 / 4.1 / 5.0**。回数の表の 1 / 2 / 3 / 4 / 5 と整合し、差は +0.1〜0.25（Epley が高回数で過大になる既知の癖）。設計どおり「加重 0 は回数の表、加重ありは Epley、種目は高い方（= max）」でよい。Strength Level 自身が加重 1RM をどう算出しているかは未確認。
- **アシストチンニング（マシン）**: `pull-ups` の加重の表はマイナス（アシスト）を持つ（female 40kg [-14, -5, 6, 17, 30] など）ので、マシンの重さを −加重として当てる案はある。ただし本人が kg 欄に何を入れているか（アシスト量か）未確認。本人 Q2 の「換算の下書き → 本人確認」の枠で扱う。
- **全身種目を一覧行に、cardio を除外**: 設計どおりで問題なし。

## 4. migration 0011 の衝突箇所一覧（「旧列・pattern_template_membership の削除」に予約している記述）

| ファイル | 行 | 記述 |
|---|---|---|
| `docs/domain-model.md` | 4 | 「`task_template` の旧列と `pattern_template_membership` は 0011 で削除予定（… 0010 はトレーニングの workout_entry で使用）」 |
| `docs/day-cycle-walkthrough.md` | 160 | 「**0011（後日・本人 OK 後。…繰り下げ）**: 新しいビルドで確認できてから … を削除」 |
| 同 | 196 | 完了条件「[ ] 0011（旧列・pattern_template_membership の削除。旧 0007 → 0008 → 0010 → 0011）は …」 |
| 同 | 226 | 「0011 で列ごと消す（旧称 0007・0008・0010）」 |
| 同 | 258 | 「0011（旧列と `pattern_template_membership` の削除。旧称 0007・0008・0010）は未作成」 |
| 同 | 293 | 見出し「DB（migration `0007_actual_checkin.sql`。旧列の削除は 0011 に繰り下げ）」 |
| 同 | 346 | 「段階 1 の旧列削除は **0011** に繰り下げ（10/4 にトレーニングの workout_entry が 0010 を使用）」 |
| `docs/gymwork-design-duplicate-and-reorder.md` | 275 | 「migration は 0010、予定の旧列削除は 0011 へ繰り下げ」 |
| 同 | 317 | 「この機能が 0010 を使い、旧列削除を 0011 に繰り下げる案」 |
| 同 | 323 | 「`domain-model.md` v17（DDL・0010/0011 の番号）」 |
| 同 | 370 | 「冒頭の番号予約（0010 → 0011）」 |
| `supabase/migrations/0006_template_version.sql` | 8 | コメント「新しいビルドで実 DB の読み書きを確認できてから 0011 で削除する」 |
| 同 | 163 | コメント「旧列は旧ビルド向けの写し (0011 で削除。旧称 0007・0008・0010)」 |

- 他に無い: `supabase/migrations/` の最大は `0010_workout_entry.sql`、0011 のファイルは無い。`sleep-design/`・`round-3-work-plan.md`・`implementation-roadmap.md`・`continuity-design.md`・`spec.md`・Swift ソースに 0011/0012 の記述は無い（grep）。`body-strength-and-heatmap-period.md` 自身の L89・L103 が 0011 をプロフィール/体重に使う唯一の記述。
- 補足: 0006 は本番適用済みの migration なので中身は変えない前提だが、2 か所はコメントのみ。直すなら「コメントだけ・SQL は不変」と commit message に書く。直さずに docs 側で「0006 のコメントは旧番号」と注記する手もある。
- 代案（参考）: 0011 を旧列削除の予約のまま残し、プロフィール/体重を 0012 にすれば上の 13 か所は無修正で済む。ただし「次の機能が次の番号を取り、削除を繰り下げる」前例（0008・0009・0010）と逆になり、0011 が未作成のまま 0012 が先に本番に入る。前例に従う方を推す。
- `git status`: `docs/domain-model.md` ほか 4 docs に未 commit の差分があるが、0011・体重・人体図・プロフィールの行には触れていない（diff を grep）。上の行番号は作業ツリーのもの。

## 5. テスト観点の追加（pure function として切り出すもの）

既存は Swift Testing（`@Suite`／`@Test`、`ContinuityTests`・`WorkoutSummaryTests`）。新規は `StrengthLevelsTests` を 1 ファイル。

| # | 関数（案） | 追加するケース（設計 L101 に無いもの） |
|---|---|---|
| T-1 | `StrengthStandards.load()`（JSON・対応表の読み込み） | 122 件すべてデコード／対応表の slug が全て JSON にある／**種目の metric_kind と表の unit が一致しない対応は基準なし**（A-1 の 3 件を検出）／体重行が昇順・5kg 刻み・5 値／数値セルが行内で非減少 |
| T-2 | `StrengthStandards.thresholds(slug:sex:bodyWeight:)` | 行の間（72.5kg = 70 と 75 の中点）／範囲外の下（48kg → 50kg 行）・上（145kg → 140kg 行）／女性の範囲（40〜120）／「< 1」を含む行（pull-ups female 60kg [<1, <1, 6, 12, 20]）がそのまま返ること |
| T-3 | `StrengthScore.value(_:thresholds:)`（0〜5 の連続値） | Beginner 未満の比例（閾値の半分 → 0.5）／閾値ちょうど（= 2.0）／中間（線形）／Elite 超 = 5／**同値の隣接閾値**（[1, 1, 6, 12, 20] で 1 回 → 2.0 側）／回数・秒でも同じ |
| T-4 | `BodyweightStrength.level(set:bodyWeight:table:)` | 加重 0 → 回数の表／加重あり → (BW+加重)×Epley − BW → 加重の表／混在はセット単位の max／weight nil = 0／体重未登録 → nil／期間中に体重が変わる（セットごとに別の体重行） |
| T-5 | `BodyWeights.weight(on:records:)` | 同じ日の記録を使う（記録日 ≤ セット日）／以前が無ければ最新（未来の記録）／0 件 → nil |
| T-6 | `MuscleStrength.summarize(...)` | 1 種目だけ → その値／基準なし種目のみ → `.noStandard`／記録なし → `.noRecord`／cardio を除外・full_body は一覧行／アーカイブ済み種目を除外／W 除外／`mergeToday` 後の今日の分が入る／種目の max → 部位の mean の順序（A-4） |
| T-7 | `StrengthPeriod.interval(kind:today:calendar:)` | 直近 30 日 = [today−29 の 0:00, 明日 0:00) JST／前日 23:59 JST と当日 0:00 の境界（UTC 表記のセットで）／暦月（8/31 23:59 と 9/1 0:00）／年またぎ（1 月の先々月 = 前年 11 月）／Q1 で A なら 3 窓が隣接し重ならない |
| T-8 | `CardioSummary.totals(...)` | 時間・距離・件数／距離 nil／W の扱い／期間境界 |
| T-9 | `MonthHeatmap.weeks(today:count:)` | 5 行×7 列／最下行が今週／月曜始まり（火曜・日曜 23:59・月曜 0:30 JST の 3 ケース）／未来日は空／`TrainingHeatmap.thresholds` に 26 週の窓を渡したとき 1 か月・半年で同じ日が同じ level |
| T-10 | 既存 | `ContinuityTests`・`WorkoutSummaryTests` が無変更で pass。`WorkoutHistoryStoreTests` に「体重の保存で `invalidate` が呼ばれない」を 1 件 |

## 6. 確認した事実（根拠）

① **基準 JSON**（`docs/strength-standards/strength_level_standards.json`、`python3 -I` で集計）
- トップ: `source`・`fetched_at`（2026-10-06T16:06:49+09:00）・`levels`（5 段）・`exercises`・`failed`（空）。種目 **122**。unit = kg 93・reps 27・seconds 2（plank・side-plank）。
- 全 122 種目に male・female の `bodyweight` と `age` の表がある（欠け 0）。体重行: male 50〜140kg（19 行）・female 40〜120kg（17 行）、刻みは全て 5kg。年齢行: 15〜90 歳（16 行）、男女とも。
- 「< 1」: 文字列は `< 1` の 1 種類のみ、計 2,244 セル（bodyweight 751・age 1,493）。**reps 単位の 27 種目に限る**（kg・seconds には無い）。bodyweight 表では beginner 704・**novice 47**（female 41・male 6）。「< 1」→ 1 で隣接閾値が同値になる行: pull-ups female 18・chin-ups female 17・nordic-hamstring-curl male 15・dips female 14 ほか計 11 組 74 行。
- `added_weight_kg` を持つのは **chin-ups・dips・pull-ups の 3 件**。例 pull-ups male 80kg: 回数 [1, 7, 13, 21, 29]／加重 [-2, 14, 33, 54, 75]kg。female 60kg: 回数 [<1, <1, 6, 12, 20]／加重 [-16, -4, 9, 23, 38]。
- kg 単位の全列は体重に対して単調増加（崩れ 0）。reps・seconds は体重が増えると減る列がある（240 列。仕様どおり）。データのばらつきの例: chin-ups female の novice は 80kg で 1、85〜95kg で「< 1」。
- 照合（設計 L32 の値）: bench-press male 80kg [56, 75, 98, 124, 151] を JSON で確認。

② **対応表・抽出スクリプト**（`mapping-draft.csv`・`parse.py`）
- 159 行。sl_match = exact 116・approx 15・none 28（cardio 13・それ以外 15）。CSV の slug は 122 種類で JSON と一対一（欠け・余り 0）。
- 部位ごとの（基準あり／なし。対応表の sl_match ベース、A-1 の 3 件を除外する前）: 胸 19/0・背中 19/1・僧帽 5/0・肩 14/1・二頭 10/0・三頭 11/0・**前腕 3/2**・大腿四頭 13/2・ハム 8/0・臀部 7/0・ふくらはぎ 4/0・**体幹 13/5**・有酸素 0/13・**全身 5/4**。
- 同じ slug に複数種目: chest-press・cable-fly・dips・push-ups・lat-pulldown・straight-arm-pulldown・dumbbell-front-raise・barbell-curl・hip-thrust の 9 件。
- `parse.py` は秒の `s` と kg の `+`/` kg` を落とし、数値化できないセルを文字列のまま保持。失敗 0。

③ **種目マスタとの整合**（`supabase/migrations/0004_exercise_seed.sql`）
- seed 159 件と CSV 159 件は名前・部位・器具・metric_kind が**完全一致**。id は seed で指定しない（DB 採番）。
- metric_kind と JSON の unit が一致しない対応 **7 件**: 自重 weight_reps 4 件（ディップス胸/三頭・チンニング・チンアップ。加重の表で解消）と、**バックキック（マシン）weight_reps→reps／マウンテンクライマー duration→reps／ロシアンツイスト weight_reps→reps の 3 件（未解消）**。
- 自重 weight_reps は上の 4 件のみ（equipment = bodyweight かつ weight_reps）。

④ **コード**
- 26 週先読み: `WeekAnalysisView.swift` L64〜67（`TrainingHeatmap.weekCount = 26`、`ContinuityViews.swift` L111）。`WorkoutHistoryStore.ensureLoaded` L41〜64 は未ロード週の最古〜最新を **1 リクエスト**で取り、`SupabaseWorkoutDataSource.fetchSets(completedFrom:to:)` L229〜239 が `fetchAllPages`（L268〜277、`.range` 1000 行ずつ）を通す。entry は 50 セッションずつ（L170〜186）。→ 先々月初日〜今日は最大でも約 92 日、26 週 = 182 日で足りる。
- 週は月曜始まり: `Continuity.weekStart` L28〜32、`WorkoutSummary.firstWeekday = 2` L7・L45〜49。トレーニングタブは 5 週だけ先読み（`WorkoutView.swift` L391）、26 週は分析画面でのみ。
- ヒートマップ: 閾値は渡した volumes の 25/50/75% 分位（`ContinuityViews.swift` L152〜156）、入力は `historyStore.loadedSets`（`WeekAnalysisView.swift` L105〜109 = ロード済み全週 `WorkoutHistoryStore.swift` L36〜38）。
- e1RM: `WorkoutProgress.estimatedOneRM` L124〜126（reps ≤ 1 は weight、weight 0 → 0）。指標は W 除外（L81）。
- 入力: `WorkoutSetInput.validate` は weightReps で weight 必須（`WorkoutDataSource.swift` L104〜107）、負値は拒否（L100）。DDL は `weight NULL = 自重`（`domain-model.md` L255〜256）。モックの懸垂は weight nil（`WorkoutFixtures.swift` L34・L43）。
- Calendar は JST（`HomeView.defaultCalendar` L266〜268、`WorkoutView` L71 で既定）。`@DateOnly` は JST の yyyy-MM-dd（`DateOnly.swift` L28〜35）。
- `WeekAnalysisView` 197 行・`WorkoutSummary` 187 行・`WorkoutView` 514 行・`MockWorkoutDataSource` 249 行。テストは Swift Testing（`@Suite`/`@Test`）。`LifeTracker/LifeTracker/Resources/` が存在。

⑤ **docs**
- `gymwork-alignment-design.md`: INV-1〜10（L43、INV-6 は廃止）、R-1〜R-8（L338〜347）、§4 不採用表 L324〜326（体重 = 本人決裁／回復 UI 不採用／プロフィール不採用）。`continuity-design.md` L10（直近半年・草）。`gymwork-retention-comparison.md` 行 3・行 10。
- 0011 の記述は §4 の表のとおり。

⑥ **DB**
- migration の最大は 0010。`updated_at` 列・更新トリガーは既存 migration に無い（grep 0 件）。`sleep_record`・`training_goal` は `created_at` のみ。RLS は無効のまま（0005・0009・0010 の注記）。
- `docs/strength-standards/`・`docs/body-strength-and-heatmap-period.md` は未 commit（untracked）。ブランチ `feat/round3-training`。

⑦ **未確認**
- Strength Level が加重 1RM をどう算出しているか（ページの計算式は読んでいない）。approx 15 件の各ページの中身（設計 L36 のとおり未確認）。本人の性別・体重（例示は「70kg 男性なら」と仮定して書いた）。実機・シミュレータでの描画は一切していない（レビューのみ）。
