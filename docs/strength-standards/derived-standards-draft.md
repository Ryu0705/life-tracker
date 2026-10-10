# 換算基準の下書き（Strength Level に基準が無い種目）

- 作成: 2026-10-08（AI 下書き）。2026-10-10 本人確認済み（前提 6 問・対象外 4 件）で、実装は `Resources/strength_mapping.json`（`build_mapping.py` が生成）。この下書きは根拠の記録として残す。設計 SSOT: `docs/body-strength-and-heatmap-period.md`「級の計算」節と「本人の指摘（2026-10-08）」
- 本人の指示（2026-10-08 原文）: 「対応するものがない場合は、相当レベルの物を算出するべき。」
- 級の計算規則は設計どおりで、ここでは変えない。セットの値は weight_reps = Epley 推定 1RM、reps_only = 回数、duration = 秒。閾値は beginner=1 … elite=5 の線形補間で、体重行の範囲外は端の行を使う
- 数値は `strength_level_standards.json`（2026-10-06 取得）から `python3 -I` で計算した。全 18 件 × 男女 × 全体重行で「閾値が行内で非減少」を確認した（崩れ 0 行）
- 表記: 【事実】= 出典にある数値・記述。【仮定】= AI が置いた前提。【推定】= 関連部位からの類推

## 1. 要約

| 区分 | 件数 | 種目 |
|---|---|---|
| 方法 1（同じ単位の近い種目の表に係数） | 7 | アシストチンニング・ステップアップ・Vシット・ケトルベルスイング・ターキッシュゲットアップ・ボックスジャンプ・バックキック |
| 方法 2（記録単位の換算） | 2 | マウンテンクライマー・ロシアンツイスト |
| 方法 3（外部の目安表） | 4 | デッドハング・ウォールシット・ホローホールド・ハンドグリップ |
| 方法 4（関連部位の表からの推定・推定止まり） | 4 | バンドプルアパート・デッドバグ・バードドッグ・トーソローテーション |
| 対象外を推奨（心肺扱い。予備案は方法 4） | 1 | バトルロープ |

- 確信度: 中 8 件／低 10 件。高は無い（どれも Strength Level の実測ではないため）
- 方法 3 の静止系 3 件は、外部の目安（Endura）をそのまま使わず、両方にある**プランクで Strength Level の尺度に校正**した（§2 の注 1）。これで体重差・性別差も Strength Level のプランクの表から引き継げる
- 近似 12 件: 係数を掛けるのは 2 件（インクラインチェストプレス・ケーブルフロントレイズ。どちらも Strength Level 内の同型の種目ペアの比が根拠）。対応先を変える提案が 1 件（ウォーキングランジ → dumbbell-lunge）。残り 9 件は 1.0（§3）

本人確認が要る前提（結果が大きく変わる順）:
1. **ダンベル・ケトルベルの kg 欄は 1 本（片手）の重さか**。Strength Level のダンベルの表は 1 本の重さ【事実】。合計を入れていると級が 1 段以上高く出る（ステップアップ・ウォーキングランジ・ロシアンツイスト・ケトルベル 2 件に効く）
2. **アシストチンニングの kg 欄はアシスト量（軽くしている量）か**。カウンターウェイトの表示とアシスト量が一致する機種かどうかも
3. **ハンドグリップ・バンドプルアパートの器具の強さ**（ハンドグリップの表示 kg、バンドの色・張力）。記録が回数だけなので、器具の強さを固定値で持たないと換算できない
4. **マウンテンクライマーの数え方**（左右それぞれ 1 回と数える前提で 1 秒 1.5 回と置いた）
5. **Vシットは V 字の上げ下ろし（V-up）を回数で記録しているか**（静止の V 字キープなら duration に直すべき）
6. **バトルロープを強さから外して心肺扱いにするか**

## 2. 種目ごとの換算

- 閾値の列は「男性 70kg の Beginner / Novice / Intermediate / Advanced / Elite」。参考に女性 60kg も添える
- 「元の表」はすべて `strength_level_standards.json` の slug。体重・性別の差は元の表の行をそのまま使う（方法 3 のハンドグリップだけ体重差なし）

### A. Strength Level に無い 15 件

| 種目 | metric_kind | 方法 | 元の表・出典 | 係数・仮定 | 男性 70kg の閾値（女性 60kg） | 確信度 | 本人に確認したいこと |
|---|---|---|---|---|---|---|---|
| アシストチンニング（マシン） | weight_reps | 1 | `pull-ups` の加重の表（`added_weight_kg`。マイナス = アシスト） | 【仮定】kg 欄 = アシスト量。値 = (体重 − アシスト)×Epley − 体重 を加重の表に当てる。係数 1.0 | 加重換算 −2 / 13 / 31 / 50 / 71 kg（女 −16 / −4 / 9 / 23 / 38）。10 回できるアシスト量に直すと Beginner = 19kg・Novice = 8kg、Intermediate 以上はアシスト 0 でも届かない | 中 | kg 欄にアシスト量を入れているか、機種の表示はアシスト量か |
| バンドプルアパート | reps_only | 4 | `dumbbell-reverse-fly`（1 本の kg） | 【仮定】片手にかかる張力 T = 7kg（中程度のバンドを想定。出典なし）。値 = T×Epley(回数) を kg の表に当てる | 1RM 換算 2 / 7 / 15 / 26 / 39 kg（女 2 / 6 / 13 / 23 / 35）。T = 7kg なら回数で 0 / 0 / 34 / 81 / 137 回 | 低 | 使っているバンドの強さ（色・表示 kg） |
| デッドハング | duration | 3 | Endura の Dead Hang 目安（20〜29 歳）を `plank` で校正 | 注 1 の比（男 0.5 / 0.5 / 0.5 / 0.667 / 0.6）を `plank` の表に掛ける | 6 / 20 / 40 / 84 / 105 秒（女 6.7 / 16 / 34 / 64 / 92） | 中 | 両手・順手のぶら下がりで記録しているか |
| ハンドグリップ | reps_only | 3 | 文部科学省 体力・運動能力調査 令和 5 年度の握力（20〜24 歳）を、Strength Level の百分位の定義（5 / 20 / 50 / 80 / 95%）で 5 段に割り当て | 【仮定】握力の分布は正規分布。【仮定】器具の表示 kg を R とし、値 = R×Epley(回数) を握力の閾値に当てる。体重差なし | 32 / 38 / 44 / 50 / 56 kg（女 19 / 23 / 27 / 31 / 34）。R = 30kg なら回数で 2 / 8 / 14 / 20 / 26 回 | 低 | 使っているハンドグリップの表示 kg（固定なら 1 つの値で足りる） |
| ステップアップ | weight_reps | 1 | `dumbbell-lunge`（1 本の kg） | 係数 1.0（片脚ずつの動作で近い。係数の根拠なし・近似のまま）。【仮定】kg 欄 = 1 本 | 8 / 16 / 27 / 41 / 57 kg（女 6 / 11 / 18 / 28 / 39） | 中 | kg 欄は 1 本か合計か、台の高さは膝くらいか |
| ウォールシット | duration | 3 | Endura の Wall Sit 目安（両脚・太もも水平・20〜29 歳）を `plank` で校正 | 注 1 の比（男 0.75 / 0.75 / 0.75 / 0.833 / 0.8） | 9 / 31 / 61 / 105 / 140 秒（女 13 / 33 / 60 / 93 / 129） | 中 | 両脚・太もも水平で記録しているか |
| Vシット | reps_only | 1 | `lying-leg-raise`（回数） | 係数 1.0（脚を上げる動作が共通。V-up の方がきつい可能性はあるが根拠なし・近似のまま） | 1 / 12 / 31 / 54 / 79 回（女 1 / 9 / 27 / 48 / 71） | 低 | V-up（上げ下ろし）の回数か、V 字キープか |
| デッドバグ | reps_only | 4 | `bicycle-crunch`（回数。左右交互の体幹種目） | 【推定】係数 1.0。デッドバグの方が負荷は軽いので級が低めに出る見込み | 1 / 16 / 42 / 73 / 109 回（女 1 / 19 / 48 / 84 / 124） | 低 | 左右で 1 回か、片側 1 回か |
| バードドッグ | reps_only | 4 | `back-extension`（回数。脊柱起立筋） | 【推定】係数 1.0。負荷の性質が違う（バードドッグは安定性の種目） | 4 / 15 / 30 / 47 / 66 回（女 1 / 13 / 30 / 48 / 69） | 低 | 左右で 1 回か、片側 1 回か |
| ホローホールド | duration | 3 | Endura の Hollow Body Hold 目安（30 歳未満）を `plank` で校正 | 注 1 の比（男 0.5 / 0.5 / 0.5 / 0.528 / 0.467） | 6 / 20 / 40 / 66 / 82 秒（女 8.3 / 21 / 37 / 57 / 74） | 中 | 腕を頭上に伸ばした形か（腕を体側に置く形なら楽になる） |
| トーソローテーション（マシン） | weight_reps | 4 | `machine-seated-crunch`（kg。マシンの体幹種目） | 【推定】係数 1.0。動きの面が違う（ひねりと屈曲） | 25 / 44 / 70 / 102 / 138 kg（女 21 / 39 / 64 / 94 / 129） | 低 | 機種の kg 表示の目安（重さの段の刻み） |
| ケトルベルスイング | weight_reps | 1 | `dumbbell-romanian-deadlift`（1 本の kg） | 係数 1.0（KB 1 個 = DB 1 本として当てる）。裏取りは注 2 | 16 / 26 / 39 / 55 / 72 kg（女 12 / 21 / 33 / 48 / 65）。32kg×10 回 = 3.2（Intermediate） | 中 | 両手スイングか片手か、1 セットの回数（20 回超だと Epley が高めに出る） |
| ターキッシュゲットアップ | weight_reps | 1 | `dumbbell-shoulder-press`（1 本の kg） | 係数 1.0（片手で頭上に保持する点が共通）。裏取りは注 2 | 12 / 19 / 27 / 37 / 48 kg（女 10 / 15 / 23 / 32 / 43）。32kg×5 回 = 4.0（Advanced） | 中 | 回数は片側か左右合計か |
| ボックスジャンプ | reps_only | 1 | `squat-jump`（回数） | 係数 1.0（跳ぶ動作が共通。台の高さは記録に無いので反映できない・近似のまま） | 1 / 13 / 34 / 59 / 87 回（女 1 / 12 / 35 / 63 / 94） | 低 | 台の高さはほぼ一定か |
| バトルロープ | duration | 対象外を推奨（予備 4） | 予備案: `plank`（秒） | 推奨: 有酸素と同じく心肺として扱い、強さの級は出さない。予備案は【推定】係数 1.0（全身で続ける時間として類推するだけ） | 予備案 12 / 41 / 81 / 126 / 175 秒（女 11 / 43 / 86 / 136 / 190） | 低 | 心肺扱いにしてよいか |

### B. 単位が合わない 3 件

| 種目 | metric_kind | 方法 | 元の表・出典 | 係数・仮定 | 男性 70kg の閾値（女性 60kg） | 確信度 | 本人に確認したいこと |
|---|---|---|---|---|---|---|---|
| バックキック（マシン） | weight_reps | 1 | `cable-kickback`（kg。アプリの「ケーブルキックバック」が exact で対応している臀部の種目） | `glute-kickback`（回数の表）はやめ、kg の表へ切り替える。係数 1.0（マシンとケーブルの差の根拠なし・近似のまま） | 5 / 19 / 44 / 80 / 123 kg（女 3 / 15 / 39 / 72 / 114） | 中 | 片脚ずつの記録か |
| マウンテンクライマー | duration | 2 | `mountain-climbers`（回数）。速さの目安は Daily Burn の 30 秒あたりの回数 | 【仮定】1 秒 1.5 回（左右それぞれ 1 回）。秒の閾値 = 回数の閾値 ÷ 1.5。根拠: Daily Burn の「普段から運動する人」が 30 秒で片脚 22〜30 回 = 両脚で 1.5〜2 回/秒【事実】の下端。Strength Level 側の数え方は未確認 | 0.7 / 13 / 33 / 59 / 87 秒（女 0.7 / 14 / 37 / 65 / 97） | 低 | 速さは普通か全力か、左右で 1 回と数える前提でよいか |
| ロシアンツイスト | weight_reps | 2 | `russian-twist`（回数） | 加重 0 → 回数をそのまま当てる。加重あり → 【仮定】ひねりで動かす上半身の負荷 S = 体重×0.3 と置き、相当回数 = ((S + 加重)×(1 + 回数/30) ÷ S − 1)×30。自重種目の「体重＋加重」の式と同じ形 | 1 / 18 / 43 / 73 / 107 回（女 1 / 20 / 48 / 82 / 120）。例: 70kg・5kg×20 回 → 相当 32 回 = 2.6（Novice） | 低 | kg 欄はダンベル 1 個の重さか、左右で 1 回か |

### 注 1: 静止系をプランクで校正する理由と式

- 【事実】Endura の 20〜29 歳男性の目安（秒、Novice / Intermediate / Advanced / Elite）: プランク 60 / 120 / 180 / 300、デッドハング 30 / 60 / 120 / 180、ウォールシット 45 / 90 / 150 / 240、ホローホールド 30 / 60 / 95 / 140。女性はプランク 45 / 90 / 140 / 220、デッドハング 20 / 45 / 90 / 150、ウォールシット 40 / 80 / 130 / 210、ホローホールド 25 / 50 / 80 / 120。Endura に Beginner の段は無く、閾値は体重で変わらない
- 【事実】Strength Level のプランク（男性 70kg）は 12 / 41 / 81 / 126 / 175 秒。Endura の同じ名前の段より 3〜4 割短い。Endura の数値をそのまま当てると、Strength Level 由来の種目より厳しく出て部位の平均が歪む
- 式: 種目 X の閾値[段] = Strength Level の `plank` の閾値[段]（性別・体重行ごと）× Endura の X[段] ÷ Endura のプランク[段]。Beginner の比は Novice の比を使う【仮定】
- 裏取り: 校正後のデッドハング男性 Intermediate = 40 秒。Gripp がまとめた一般の中央値（男性 40 秒・女性 28 秒）と合う。Strength Level の Intermediate の定義は「50% より強い」【事実】なので整合する
- TopEnd Sports のウォールシットの目安は片脚の版で、作者の経験則と明記されているため使わない

### 注 2: ケトルベル 2 件の裏取り

- 【事実】StrongFirst の Simple & Sinister の基準: Simple は男性スイング 32kg・ゲットアップ 32kg、女性 24kg・16kg。Sinister は男性 48kg・48kg、女性 32kg・24kg（スイング 100 回を 5 分、ゲットアップ 10 回を 10 分）
- 男性 70kg の当てはめ:

| 例 | 推定 1RM | 級の値 |
|---|---|---|
| スイング 24kg × 10 回 | 32kg | 2.5 |
| スイング 32kg × 10 回（Simple） | 43kg | 3.2 |
| スイング 48kg × 10 回（Sinister） | 64kg | 4.5 |
| ゲットアップ 16kg × 5 回 | 19kg | 2.0 |
| ゲットアップ 32kg × 5 回（Simple） | 37kg | 4.0 |
| ゲットアップ 48kg × 5 回（Sinister） | 56kg | 5.0 |

- Simple が Intermediate〜Advanced、Sinister が Advanced〜Elite に落ちる。「Simple は数年かけて届く中上級の目標」という位置づけと矛盾しない。ここは AI の解釈で、StrongFirst が Strength Level の段と対応づけているわけではない

### 注 3: アシストチンニングの境界の扱い

- 加重の表の Beginner はマイナス（男性 70kg で −2kg）なので、設計の「beginner 未満は 0〜1 に比例」をそのまま当てると負の数どうしの比になり壊れる
- 提案: 比例は「体重＋値」の総負荷で取る。例: 70kg・アシスト 30kg × 10 回 → 値 = 40×1.333 − 70 = −16.7kg → 総負荷 53.3 ÷ (70 − 2) = 0.78
- アシスト 0 は自重の懸垂と同じ（既存の 4 種目の「加重 0 → 回数の表」に合わせる）
- アシストマシンだけで出せる上限は、アシスト 0・10 回で男性 70kg なら 2.6 程度。それ以上は「チンニング」の記録で出る

## 3. 近似 12 件の係数判断

| 種目 | 代用元 | 判断 | 根拠 |
|---|---|---|---|
| インクラインチェストプレス（マシン） | `chest-press` | **係数あり**: `chest-press` × (`incline-bench-press` ÷ `bench-press`)、性別・体重行ごと | Strength Level 内のバーベルのインクライン ÷ フラットの比は男性 70kg で 0.87〜0.88 と段によらず安定している【事実】。女性は 0.74〜0.86。男性 70kg の閾値 29 / 46 / 71 / 98 / 129 kg |
| ケーブルクロスオーバー | `cable-fly` | 1.0 | 同じ動作。根拠なしではなく差が無いと判断 |
| ローケーブルフライ | `cable-fly` | 1.0 | 下から上の軌道の方が軽い可能性はあるが、数値の根拠なし・近似のまま |
| ワイドプッシュアップ | `push-ups` | 1.0 | 手幅を広げた版の表は無い。根拠なし・近似のまま |
| ラットプルダウン（パラレルグリップ） | `close-grip-lat-pulldown` | 1.0 | 同じ握りの型。根拠なし・近似のまま |
| ビハインドネックプルダウン | `lat-pulldown` | 1.0 | 首の後ろへ引く方が軽い可能性はあるが、数値の根拠なし・近似のまま |
| ケーブルプルオーバー | `straight-arm-pulldown` | 1.0 | 同じ動作（肘を伸ばしたまま引き下ろす） |
| ケーブルフロントレイズ | `dumbbell-front-raise` | **係数あり**: `dumbbell-front-raise` × (`cable-lateral-raise` ÷ `dumbbell-lateral-raise`)、性別・体重行ごと | ケーブルとダンベルの差を、同じレイズ系のペアの比で写す。比は段で変わる（男性 70kg で 0.5〜1.16）。男性 70kg の閾値 1.5 / 6.2 / 14 / 26 / 40 kg。【仮定】片手で引く記録。両手でバーを引くなら kg は約 2 倍になるので、この係数は使えない |
| ドラッグカール | `barbell-curl` | 1.0 | バーを体に沿わせる分軽くなる可能性はあるが、数値の根拠なし・近似のまま |
| プリーチャーカール（マシン） | `machine-bicep-curl` | 1.0 | マシンのカールは多くが台に腕を乗せる型。根拠なし・近似のまま |
| ウォーキングランジ | `walking-lunge` | **対応先の変更を提案**: `dumbbell-lunge` × 1.0 | アプリの器具は dumbbell。`walking-lunge` は器具の区分が未確認で、値が `dumbbell-lunge` の 1.4〜1.9 倍ある。`dumbbell-lunge` は 1 本の重さと明記されている【事実】ので、kg 欄 = 1 本なら単位がそろう。歩く・その場の差は近似のまま |
| ヒップスラスト（マシン） | `hip-thrust`（バーベル） | 1.0 | 機種で負荷の掛かり方が違うが、数値の根拠なし・近似のまま（レビュー §2 の指摘どおり） |

## 4. バンドル用の提案形式

対応表に `match = derived` の行を足し、換算の中身は別ファイル（例: `derived_standards.json`）に種目名で持つ。画面の 1 語の印は `label` を出す。

係数型（アシストチンニング。値の変換と境界の扱いを持つ例）:

```json
{
  "name": "アシストチンニング（マシン）",
  "type": "coefficient",
  "label": "換算（pull-ups の加重の表・アシストはマイナス）",
  "base_slug": "pull-ups",
  "base_table": "added_weight_kg",
  "coefficient": 1.0,
  "value_transform": "assist_to_added",
  "below_beginner": "total_load_ratio",
  "assumptions": ["kg 欄 = アシスト量"],
  "confidence": "medium"
}
```

- `coefficient` は数値なら全セル同じ倍率、`{"ratio_of": ["incline-bench-press", "bench-press"]}` なら性別・体重行・段ごとに比を取る（§3 の 2 件）、`[r1, ..., r5]` なら段ごとの倍率（注 1 の静止系 3 件。`base_slug` は `plank`）
- `value_transform` は `assist_to_added`（(体重 − kg)×Epley − 体重）／`seconds_to_reps`（秒 × 1.5）／`weighted_reps_equivalent`（ロシアンツイストの式）／`load_times_epley`（器具の固定 kg × Epley(回数)）のどれか。無ければ設計どおりの値をそのまま使う

外部目安型（ハンドグリップ。体重行を持たない例）:

```json
{
  "name": "ハンドグリップ",
  "type": "external",
  "label": "換算（握力の全国調査・器具 30kg と仮定）",
  "unit": "kg",
  "value_transform": "load_times_epley",
  "fixed_load_kg": 30,
  "thresholds": {
    "male":   [31.8, 37.8, 44.1, 50.4, 56.4],
    "female": [19.2, 22.9, 26.8, 30.7, 34.5]
  },
  "bodyweight_dependent": false,
  "source": "文部科学省 体力・運動能力調査 令和5年度 表1-1 握力 20-24歳（平均±z×標準偏差、z = -1.645 / -0.842 / 0 / 0.842 / 1.645）",
  "fetched_on": "2026-10-08",
  "confidence": "low"
}
```

- 読み込み時の検証は既存の基準と同じ（5 値・非減少）。`external` は体重行が無いので「5kg 刻み」の検証は外す
- 静止系 3 件は外部の数値を使うが、体重行は `plank` から作るので `coefficient` 型（段ごとの倍率）で持てる。`source` に Endura の URL と取得日を書く

## 5. 出典一覧（取得日はすべて 2026-10-08）

| 出典 | URL | 使った箇所 |
|---|---|---|
| Strength Level 基準 JSON（2026-10-06 取得済み） | `docs/strength-standards/strength_level_standards.json` | 全件の元の表 |
| Strength Level ベンチプレスのページ（段の百分位の記述だけ写した） | https://strengthlevel.com/strength-standards/bench-press/kg | ハンドグリップの割り当て・注 1 の裏取り |
| Strength Level ダンベルベンチのページ（「1 本の重さ」の記述だけ写した） | https://strengthlevel.com/strength-standards/dumbbell-bench-press/kg | ダンベル系の前提 |
| Endura Dead Hang | https://endura.coach/dead-hang-strength-standards-calculator/ | デッドハング |
| Endura Wall Sit | https://endura.coach/wall-sit-strength-standards-calculator/ | ウォールシット |
| Endura Hollow Body Hold | https://endura.coach/arch-body-hold-vs-hollow-body-hold-strength-standards-calculator/ | ホローホールド |
| Endura Forearm Plank Hold | https://endura.coach/forearm-plank-hold-vs-rkc-plank-hold-strength-standards-calculator/ | 注 1 の校正 |
| Gripp（デッドハングの中央値） | https://www.gripp.fit/blog/how-long-should-you-be-able-to-dead-hang-the-complete-benchmark-guide | 注 1 の裏取り（検索結果の要約で確認。本文は未取得） |
| TopEnd Sports Wall Sit（片脚版。不採用） | https://www.topendsports.com/testing/tests/wall-sit.htm | 不採用の理由 |
| e-Stat 体力・運動能力調査 令和 5 年度 表 1-1 | https://www.e-stat.go.jp/stat-search/files?layout=dataset&toukei=00402102&tstat=000001088875&tclass1=000001222265&stat_infid=000040216148 | ハンドグリップ（20〜24 歳 男 平均 44.1kg・標準偏差 7.49、女 26.8kg・4.65） |
| Lift Vault（Simple & Sinister の基準） | https://liftvault.com/programs/strength/simple-sinister-kettlebell-program-spreadsheet-pavel/ | 注 2 |
| Daily Burn（マウンテンクライマーの回数の目安） | https://dailyburn.com/life/health/how-many-mountain-climbers-should-you-do-a-day-benchmarks-by-fitness-level/ | マウンテンクライマーの速さの仮定 |

未取得: Endura のケトルベルの数値（計算機の中にだけあり、ページ本文に無い）／バンドの張力・ハンドグリップの表示 kg と実際の力の関係／Strength Level の mountain-climbers の数え方
