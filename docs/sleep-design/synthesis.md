# 睡眠の記録 — 統合案（synthesis）

作成: 2026-10-02 / 担当: 統合（deep-task）/ 状態: 本人確認済み（§5 は 10/2、細部は 10/3。冒頭の注記と walkthrough「睡眠（確定仕様）」が正）

読んだもの: `README.md`、`r1-advocate.md`、`r1-guardian.md`、`r1-data.md`、`r2-advocate.md`、`r2-guardian.md`、`alt-no-tab.md`、`../day-cycle-walkthrough.md` 段階 1・2、`../structural-conventions.md`、`../continuity-design.md`、`supabase/migrations/0001〜0007`、scratchpad `sleep/`（`0007_sleep_removed.diff`・`0008_sleep_record.sql`・`verify_sleep.sql`・`verify_sleep.out`）、未 commit の Swift（`CheckIn.swift`・`ScheduleStore.swift`・`SupabaseDayDataSource.swift`・`ScheduleEntryEditView.swift`・`InMemoryScheduleDataSource.swift`・`DayBuilderContext.swift`・`LifeTrackerApp.swift`・`ScheduleStage2Tests.swift`）、supabase-swift の `PostgrestError`（`code: String?` を持つ【事実】）。コード・本番 DB・git には触れていない。

> 2026-10-03 本人決定で一部を変更: 今朝のカードの既定＝予定の就寝＋今（§1-6・§3-2 `cardDefault`・不採用リストの「予定の就寝」を覆す）、時刻はホイールだけ（±なし）、目覚め（score）は作らない、ヘルスケアは手入力のみ。種別は列 `kind`（通常の睡眠／仮眠）を本人が選ぶ（§1-3 の時刻での分類・不採用リストの「種類の列」を覆す。名称は「仮眠」）。推移は本ファイルどおり。正は `../day-cycle-walkthrough.md`「睡眠（確定仕様）」

表記: 【事実】= ファイル・SQL の実行結果で確かめた／【推測】= 確かめていない。「AI 既定」= 本人に聞かず決めたもの（違えば直す）

## 本人の前提（覆さない）
- 睡眠は就寝・起床の時刻で入力する。記録は actual_task から外し専用の表に持つ
- 睡眠タブを足す（10/1 本人選択）。予定タブの睡眠の行は実績を表示するだけ。睡眠の予定（23:00〜8h 毎日）は予定タブに残る
- 入力はスマホ＋選択式、記録の前後に儀式を挟まない（memory `feedback_input_ux`）

## 読んでいて気づいた食い違い（統合の前提に関わるもの）
- **`r1-data.md` と同じ担当の検証物が食い違う**: `r1-data.md` §0・§2 は「夜の鍵 = 就寝 − 12h の JST 日（N1）」を推奨しているが、scratchpad の `0008_sleep_record.sql` の冒頭コメント（「起床時刻から表示時に計算する」「どの日の睡眠か = 起床の日」）と `verify_sleep.sql` §F（起床の日 N2 で集計）、そして `r1-data.md` 自身の §4（「起床の日ごとの合計」）は N2 のまま【事実】。ファイルの更新時刻は scratchpad 10:12〜10:13、`r1-data.md` 10:17 で、本文の §0・§2 が後から書き換わった形。Round 2 の両者は N1 版を読んで応答している。本統合では N1／N2 を独立に評価して決めた（§1-1。結論は N1）ので結果は変わらないが、**実装時は `0008` のコメントを直し、§F の集計を仕様と取り違えない**こと
- 推進派 R1 の昼寝の境界（起床 12:00〜20:00）とデータ担当の境界（就寝 18:00〜翌 6:00）が別物。R2 で推進派が取り下げ済み。採るのは後者 1 つ（§1-3）
- 24 時間の上限: 推進派 `< 24h`、データ担当 `<= 24h`（検証済み）。`<=` に揃える

---

## 1. 合意点と、残った対立への判定

### 1-0. 合意済み（Round 2 で三者が一致。そのまま採る）
| 項目 | 内容 | 根拠 |
|---|---|---|
| 表 | `sleep_record(id, start_at, end_at, score, created_at)`。予定・category への参照なし。導出列（夜の日・種類・起床日）を持たない | 守護派 §3、データ担当 §1、推進派 R2 §1-1 (i) |
| 重複防止 | `EXCLUDE USING gist (tstzrange(start_at, end_at) WITH &&)`。「1 夜 1 件」の一意制約は作らない | 使い捨て Postgres 16 で拡張なしに作れ、重なる insert/update が 23P01 で止まる【事実: `verify_sleep.out` §A・§C】 |
| 予定タブの行との結び | **時刻の重なり**で表示時に判定。日付の規則で結ばない | 守護派 R2 §1-2（1:00〜9:00 の世代・世代の境目で日付の規則は崩れる）、推進派 R2 で取り下げ |
| 0007 | 睡眠の分岐を抜く（`p_sleep_score`・`sleep_score_range`・スコアの行の書き込み）＋ `checkin_set`・`actual_save` で睡眠の種類を拒否 | `0007_sleep_removed.diff`。2 回流して冪等・8 引数 1 本・睡眠 2 本とも拒否・ジムは通る【事実: `verify_sleep.out` §A・§B】 |
| 旧 `sleep_actual_input` | 0008 で DROP（1 件でもあれば止まる砦つき）。旧列削除は 0009 に繰り下げ | 本番 0 件【記録上の事実: `day-cycle-review-2026-09-30-stage2.md` 6 行目】、commit 済みビルドは参照しない【事実: 守護派・データ担当が双方確認】、砦の動作【事実: §G】 |
| 書き込み | RPC にせず直接 insert / update / delete（トレーニングと同じ） | データ担当 §6、守護派 R2 §3-2 で緩めた |
| 入口 | 入力・修正・削除の入口は睡眠タブだけ。予定タブに入力部品を残さない（`SleepActualSection` 削除） | 本人決定「表示するだけ」、守護派 V-1 |
| 時刻の入力 | 時刻（時:分）だけ。起床を先に決め、就寝は「起床より前で 24 時間以内の最初のその時刻」。[−15][+15] ＋ 時刻を押すとホイール（5 分刻み） | 守護派 §2-6、推進派 S4 |
| 過去日 | 過去日も記録・修正・削除できる。未来（起床 > 今）だけアプリで拒否 | 守護派 §2-10、R-3（R2 で「アプリの検査」に修正） |
| タイムゾーン | JST 固定の `Calendar` を注入。`Calendar.current` を使わない | 守護派 §2-8 |
| 読み込み範囲 | 予定タブの日 D は `start_at < D+2 0:00 AND end_at > D−1 0:00` | 【事実: §E で D の一覧に付くのは昨夜の回の 1 件だけ】 |
| `source`・`updated_at`・`kind`・`wake_date` | 持たない | 三者一致（R2） |
| 範囲外 | ヘルスケア取り込み・ウィジェット・予定との差の分析・元に戻す | 三者一致（R2） |

### 1-1. 夜の鍵（どの夜にまとめるか）: **N1 = 就寝 − 12 時間の JST 日**（AI 既定）
- 対立: 推進派 R1 = 起床の日（N2）を列に保存 → R2 で N1 に譲歩。守護派 = (a) 起床の日 か (b) 就寝 −12h、本人に聞く → R2 で N1 を受け入れ。データ担当 = N1（ただし検証物は N2。上の食い違い）。別案 = N2 を列に保存
- 判定の理由（鍵の用途は「睡眠タブの一覧・推移で 1 夜にまとめる」「今朝が記録済みか」の 2 つ。予定タブの結びには使わない）:
  1. 分割した夜（22:00–23:50 と 0:30–7:00）を N2 で扱うと、前半が「前の朝」の側に落ち、その朝の本番（前夜 23:00 → 7:00）と合算して「就寝 23:00・起床 23:50」のような 24 時間超の夜に化ける。N1 なら 1 夜にまとまる【事実: `verify_sleep.out` §D の表で N2 が分割の夜を 2 日に割る】
  2. 0 時過ぎの就寝（0:30 → 7:30）は N1 で前日の夜 = 予定タブの「前日から続く行」の回の日と同じ数え方【事実: §D】
  3. 保存しない（表示時に pure 関数で計算）ので、規則を変えても migration・backfill が要らない（規約 C-6、domain-model INV-5）
- **見出しの呼び方は「鍵 + 1 日の朝」**（例「10/2(金) の朝」）: AI 既定。推進派 R2 §1-3・守護派 R2 §3-1 が一致。入れるのは朝なので「今朝」の見出しの方が迷わない。表示の 1 関数の差なので後で「10/1(木) の夜」に変えられる。本人に聞く論点にはしない（データ・鍵は同じ、文言だけの好み）
- エッジ: 夕方の寝落ち 18:00–23:00（就寝が 18:00 以降なので夜の睡眠・鍵 = その日）は「翌日の朝」の見出しの下に本番の睡眠と並び、合算される（Apple ヘルスケアの 18 時境界と同じ向き【推測: 細部は未確認】）。害は小さいので受け入れる

### 1-2. 予定タブの行との結び: 時刻の重なり・最長の行 1 つ・複数件は 1 行にまとめて出す（合意。細則を確定）
- 候補の行 = `category.sub_input_kind == .sleep` の行。行の時間帯は **clip 前の本来の範囲**（`row.task.startAt ..< row.task.endAt`。前日から続く行でも同じ）
- 記録 `[start_at, end_at)` と行の範囲の重なりが正なら候補。1 件の記録は、その日の一覧の中で**重なりが最長の行 1 つ**にだけ付ける（同じなら早い行）。1 つの行に複数件付いたら「実績 23:30–7:00（7時間 · 2 件）」（就寝 = 最初・起床 = 最後・時間 = 合計）
- 分類（夜／昼寝）は結びに使わない: 徹夜明けの 6:10–12:00 は「昼寝」に分類されても、予定 23:00–7:00 と重なるのでその行に出る（守護派 R2 N-3）。時刻が重ならない記録（14:00–15:00 の昼寝・予定の無い夜）は予定タブに出さない（予定外の行も作らない）
- 世代の境目の朝（D−1 は 23:00〜7:00、D から 1:00〜9:00）: D の一覧に睡眠の行が 2 本並ぶ。記録 0:50–8:30 は前日継続の行と 6 時間 10 分、1:00 の回と 7 時間 30 分重なる → 1:00 の回に付く（テスト項目 V-4）
- **「未入力」は出さない**（AI 既定）: 対立（守護派 R1「出さない」→ R2 で撤回、推進派 R1「出す」→ R2 で取り下げ、と入れ替わった）。出さない理由: ①「表示するだけ」の行に促しを置くと、押しても予定の編集しか開かない行き止まりになる（§5 Q3 でリンクを置かない限り）②ジムの行（セットが無ければ丸が空なだけ）・Apple ヘルスケア（データが無ければ何も出ない）と同じ形 ③「今夜の回は就寝の予定時刻まで出さない」という時刻依存の例外が消える。促しは睡眠タブの今朝のカードが担う。Q3 で B（リンク）を選ぶなら「未入力 ›」を出す形に変えてよい（1 関数）

### 1-3. 昼寝: 同じ表・種類の列なし・就寝の時刻で表示時に分類（推奨。記録するか自体は §5 Q2）
- 対立: 推進派 R1 = 種類の列＋自動選択（取り下げ）。守護派 R1 = 自動判定しない・本人が選ぶ（R2 で緩めた）。データ担当 P1 = 列なし・時刻で分類
- 判定: P1。記録シートに切り替えが増えない（入力の手間が最小）。分類は保存しないので、誤っても定数を変えれば過去分も直る。境界 = **就寝が JST 18:00〜翌 6:00 なら夜の睡眠、それ以外は昼寝**（定数 1 か所。AI 既定）。昼寝の鍵・表示日 = 開始の JST 日
- 本人に聞く理由: 昼寝を記録する導線（＋）と推移の扱いを作るかどうかは、本人が昼寝を残したいかで決まる（守護派 Q2・データ担当 Q1・推進派 R2 が一致して「聞く」）

### 1-4. 重複防止: EXCLUDE ＋ アプリの事前検査 ＋ 保存中は押せない（合意）
- アプリ: 保存前に手元の記録と重なりを検査（同じ関数を InMemory にも使う）。DB の 23P01 は `PostgrestError.code`（supabase-swift に `code: String?` がある【事実】）で見分け、「この時間には記録があります」を出してその記録のシートを開く。23514 は「時刻を確かめてください」
- HTTP の状態コードは見ない（PostgREST が 23P01 を 409 で返すかは【推測】。body の code で足りる）
- 保存ボタンは応答まで disabled（R-10）

### 1-5. 直す・消す（本人が 9/30 に「少し考えたい」とした論点 → §5 Q1。推奨だけ書く）
- 直す: 一覧の行（今朝のカードを含む）を押す → 下から半画面（`.medium`）の記録シート → 時刻・目覚めを直して保存
- 消す: シートの「記録を消す」（確認あり）＋ 一覧の行の左スワイプ「削除」（確認なし・全スワイプは無効 = ボタンを押して消す）。予定外の実績・単発の予定と同じ作法
- 消した後: 今朝なら今朝のカードが未入力に戻る（既定は前回値なので 1 タップで入れ直せる）

### 1-6. 範囲（今回入れる／入れない）
| 項目 | 判定 | 理由 |
|---|---|---|
| 睡眠タブ（1 画面目・記録シート・すべての記録・推移） | 入れる | 本人決定 |
| 今朝のカード（埋まった状態で［記録する］1 タップ） | 入れる | 2 タップ（タブ → 記録する）。守護派の線「2 タップ＋直す分」の内側。段階 2 C3 で本人が「埋まった状態で 1 タップ」を選んでいる |
| **今朝のカードの既定 = 前回値**（就寝 = 直近の夜の就寝の時刻、起床 = 今）。予定は読まない | 入れる（AI 既定。R2 の両者は「予定の就寝 → 直近の記録 → 23:00」の順だったが変えた） | ①トレーニングで本人が正解形とした「前回値で埋めて ✓ だけ」と同じ ②毎日 0:30 に寝る人は予定既定（23:00）だと毎朝 4 タップ直す ③睡眠タブが予定の世代・除外日に依存しなくなる（守護派 §2-3 の趣旨を徹底）④予定既定だと「ずれを直さず押して予定どおりの記録が増える」偏り（守護派 R2 §1-4）が無くなる。初回は 23:00／今 |
| カードの「（予定 8時間 +10分）」 | 入れない | 予定を読まないので出せない。「8時間10分」だけ |
| 目覚め（スコア）1〜5 | 入れる。記録後に 1 行・任意・押せばその場で保存 | 守護派 R-9（任意） |
| 直近 7 朝の一覧＋「未入力 ［記録］」の行 | 入れる。全部の朝（予定の有無を見ない）。最初の記録より前の朝は出さない | 記録し忘れの唯一の導線（R-5） |
| 1 画面目の 1 行「今週 平均 6時間52分 · 記録 4/5」 | 入れる | pure で出せる。「続けているか」が連続なしでも見える |
| 連続日数（トレーニングの「🔥 n日」の睡眠版） | **入れない** | 何を数えるか本人が決めていない新しい方針（守護派 R2 §1-6）。`StreakViews`／`Continuity` をいじるとウィジェットに響く。次の段で聞く（§5 末尾） |
| 推移 | [週\|月] の切り替え、範囲バー（予定の帯なし）、睡眠時間の棒＋7 日平均の線、数字 1 行 | 守護派の線「3 種まで」の内側（2 種＋数字）。6 か月は後（範囲バー 180 本は読めない） |
| ウィジェット・ヘルスケア・予定との差・就寝のばらつきの数字・元に戻す | 入れない | 三者一致。次の段 |
| 予定タブから睡眠タブへのリンク | 入れない（AI 既定。§5 Q3 で B を選べば入れる） | 下の §2 |

---

## 2. 別案（タブなし）との比較

### 2-1. 本人の選択（別タブ）を覆す理由があるか — **ない**
| 別案の主張 | 評価 |
|---|---|
| 朝の入口が 1 タップ近い（最上段の月 → 保存 = 2 タップ） | 統合案の今朝のカードも **タブ → 記録する = 2 タップ**。差はない。アプリ起動時は 1 番目のタブ（予定）が開く【事実: `LifeTrackerApp.swift` の TabView】ので、どちらも「開いて 2 タップ」 |
| 1 日の流れの中に睡眠が見える | 統合案でも予定タブの睡眠の行に実績が出る（表示だけ）。見える情報は同じ |
| 後戻りが安い（push ↔ tab は入れ物の差） | 統合案も同じ。表・pure 関数・シートはタブの有無と独立 |
| 弱い点（別案自身が挙げた）: トレーニングとの非対称、推移が一段深い、予定タブの責務が増える、月と丸の 2 種類の左ボタン、予定の無い日の入口が見つけにくい、将来の睡眠機能の置き場 | すべて別タブ案で解消する。本人の「トレーニングと同様に分けたい」という直感と一致する |
| データの持ち方（`wake_date` 保存・`is_nap` 列・1 日 1 件の一意索引・RPC） | 統合案より弱い（導出列の二重管理、分割した夜を禁じる、規則を変えると backfill）。守護派 R2 §1-3 と同じ指摘が当たる |

### 2-2. 別案から取り込むもの
| 要素 | 取り込み | 形 |
|---|---|---|
| 記録シートは半画面（`.medium`） | **取り込む** | 就寝・起床・目覚め・記録を消す の 4〜5 行なので全画面は要らない。一覧が背後に見える |
| 「月をもう一度押しても消えない」（時刻を入れた記録を 1 タップで失わない） | **取り込む（同じ原則）** | 今朝のカードの［記録する］はトグルではない。消すのはシートかスワイプ |
| 専用の表とタブは別々の決定（表はタブに依らない） | **取り込む（設計の前提）** | §3 の DDL・pure 関数は、将来タブを push に変えても変わらない |
| 予定タブの睡眠の行から入力シートを開く入口 | **今回は取り込まない** | 本人が 10/1 に「両方」を不採用にしている。ただし別案の指摘どおりシートが共通なら追加は数十行なので、実機で「予定タブから直したい」と感じたら足せる。§5 Q3 の B として提示 |
| 未入力の行は「睡眠の予定がある日」だけ | 取り込まない | 睡眠タブは予定を読まない（§1-6）。毎晩寝るので全部の朝でよい |
| 起床日を列に持つ・1 日 1 件の一意索引・20 時間上限 | 取り込まない | §1-0・§1-1 |

---

## 3. 確定案

### 3-1. DDL
**0007 `0007_actual_checkin.sql`（書き換え。未適用・未 commit）**: scratchpad `sleep/0007_new.sql`（差分 `0007_sleep_removed.diff`）をそのまま採る。中身:
- `sleep_score_range` の追加ブロックを削除
- `checkin_set` を 8 引数に（`p_sleep_score` 削除）。スコアの検査と `sleep_actual_input` の DELETE/INSERT を削除。代わりに `category.sub_input_kind = 'sleep'` なら `RAISE EXCEPTION 'sleep is recorded in sleep_record'`（ERRCODE check_violation）
- `actual_save` にも同じ拒否
- `checkin_clear` のコメントから「スコアの行は CASCADE」を削除
- GRANT を 8 引数に
- 睡眠以外は 1 文字も変えない【事実: diff】。使い捨て Postgres で 2 回流して冪等【事実】

**0008 `0008_sleep_record.sql`（新規。apply 名 `v2_sleep_record`）**: scratchpad `sleep/0008_sleep_record.sql` を採る。直す点は冒頭コメントだけ（「起床時刻から表示時に計算」→「どの夜かは就寝の時刻から端末で計算（`SleepRules.nightKey`）」、索引のコメント「= 起床の日」を「一覧・推移は起床で範囲を取る」に）
```sql
CREATE TABLE IF NOT EXISTS sleep_record (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  start_at   TIMESTAMPTZ NOT NULL,   -- 就寝
  end_at     TIMESTAMPTZ NOT NULL,   -- 起床
  score      SMALLINT,               -- 目覚め 1〜5。任意
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sleep_record_time_chk  CHECK (end_at > start_at),
  CONSTRAINT sleep_record_span_chk  CHECK (end_at - start_at <= interval '24 hours'),
  CONSTRAINT sleep_record_score_chk CHECK (score IS NULL OR score BETWEEN 1 AND 5),
  CONSTRAINT sleep_record_no_overlap EXCLUDE USING gist (tstzrange(start_at, end_at) WITH &&)
);
CREATE INDEX IF NOT EXISTS sleep_record_end_at_idx ON sleep_record (end_at);
-- 旧 sleep_actual_input: 行があれば例外で止め、空なら DROP（DO ブロック。scratchpad のまま）
```
- 列名は `start_at`/`end_at`（既存の表・HealthKit の startDate/endDate と揃える。Swift は `SleepRecord.startAt/endAt`、画面の文言は「就寝」「起床」）
- GRANT は書かない（0005 と同じく Supabase の既定に任せる【推測: 0005 で anon から読み書きできた記録あり】。**本番適用後に anon で select/insert を 1 回試す**）
- 未来の時刻は DB では止めない（`now()` は CHECK に書けない・トリガーは規約で避ける）。アプリの検査だけ

**0009（旧 0008。後日・本人 OK 後）**: `task_template` の旧列と `pattern_template_membership` の削除。walkthrough 160・196・226・258 行目の「0008」を 0009 に直し、繰り下げが 2 度目であることを 1 行残す。memory `project_life_tracker_v2_core` の「旧列削除は0008」も直す

適用順: 0007 → 0008（独立。どちらが先でも壊れない【事実: 0008 は表の追加と空の表の DROP だけ】）。先に旧 0007（9 引数）を当ててしまっていた場合だけ、0008 の先頭に `DROP FUNCTION IF EXISTS checkin_set(uuid, date, uuid, text, text, uuid, timestamptz, timestamptz, int);` を足す

### 3-2. Swift の pure 関数（`Models/SleepRules.swift`。ウィジェットで使わないので `Shared/` には置かない）
```swift
struct SleepRecord: Identifiable, Hashable, Codable { let id: UUID; var startAt: Date; var endAt: Date; var score: Int?; let createdAt: Date }
enum SleepKind { case night, nap }
/// 鍵ごとにまとめた 1 夜（表示用。保存しない）
struct SleepNight: Hashable { let key: Date; let records: [SleepRecord]  // 開始順
    var start: Date  // min startAt
    var end: Date    // max endAt
    var total: TimeInterval  // Σ(endAt − startAt)。間の覚醒は入れない
    var score: Int?  // 終了が最も遅い記録のスコア
}
enum SleepRules {
    static let nightBedtimeFrom = 18 * 60, nightBedtimeTo = 6 * 60   // 就寝の時計の時刻 18:00〜翌 6:00 = 夜の睡眠
    static let wakeDefaultWindow = (before: -2 * 3600.0, after: 5 * 3600.0)  // 起床の既定に「今」を使う窓
    static func kind(of r: SleepRecord, calendar: Calendar) -> SleepKind
    /// 夜の睡眠: startOfDay(startAt − 12h)。昼寝: startOfDay(startAt)
    static func nightKey(of r: SleepRecord, calendar: Calendar) -> Date
    /// 見出しの日: 夜 = key + 1 日（「10/2(金) の朝」）、昼寝 = key
    static func displayDay(of r: SleepRecord, calendar: Calendar) -> Date
    /// 鍵ごとにまとめる（夜の睡眠だけ。昼寝はまとめない）
    static func nights(_ records: [SleepRecord], calendar: Calendar) -> [SleepNight]
    /// 今朝の鍵 = startOfDay(today) − 1 日
    static func morningKey(today: Date, calendar: Calendar) -> Date
    static func morning(_ records: [SleepRecord], today: Date, calendar: Calendar) -> SleepNight?
    /// 今朝のカードの既定: 就寝 = 直近の夜の就寝の時計の時刻（無ければ 23:00）を今朝の鍵の夜に当てはめる。
    /// 起床 = 今（5 分切り捨て）ただし「直近の起床の時計の時刻（無ければ 7:00）± 窓」の中だけ。外なら直近の起床の時刻。
    /// 既定の起床が未来なら nil（カードは［記録する］を出さず「起きたら記録」）
    static func cardDefault(previous: SleepNight?, now: Date, calendar: Calendar) -> (start: Date, end: Date)?
    /// 時計の時刻 → 日時。起床 = anchorDay のその時刻、就寝 = 起床より前で 24 時間以内の最初のその時刻。同じ時刻は nil
    static func resolve(bedMinutes: Int, wakeMinutes: Int, anchorDay: Date, calendar: Calendar) -> (start: Date, end: Date)?
    /// 保存前の検査（InMemory も同じ関数）: 終了 > 開始、≤ 24h、終了 ≤ now、他の記録と重ならない（自分は除く）、score nil か 1…5
    static func validate(start: Date, end: Date, score: Int?, now: Date, others: [SleepRecord], excluding: UUID?) -> SleepRuleError?
    /// 予定タブ: その日の睡眠の行（複数）に記録を割り当てる。重なり最長の行 1 つ、同じなら早い行
    static func assign(rows: [DayScheduledTask], records: [SleepRecord]) -> [UUID: [SleepRecord]]  // row.id → 記録（開始順）
    /// 「実績 23:40–7:10（7時間30分）」／2 件以上「実績 23:30–7:00（7時間 · 2 件）」。0 件は nil
    static func planLine(_ records: [SleepRecord], calendar: Calendar) -> String?
    /// 予定タブの読み込み範囲 [D−1 0:00, D+2 0:00)
    static func fetchRange(for day: Date, calendar: Calendar) -> (from: Date, to: Date)
    /// 推移・1 画面目の数字: 平均睡眠時間・平均就寝・平均起床（18:00 起点の分で平均して 0 時またぎを扱う）・目覚め平均・記録 n/N（夜だけ）・7 日移動平均
    static func stats(nights: [SleepNight], period: ClosedRange<Date>, calendar: Calendar) -> SleepStats
    /// PostgREST の code → 文言。"23P01" → 「この時間には記録があります」、"23514" → 「時刻を確かめてください」
    static func message(for error: Error) -> String
}
```
- 睡眠に関わる日付の計算はこの型だけが持つ（守護派 N-1）。`CheckInPlanner` の睡眠分岐 4 か所のうち `actualLine` と `acceptsActual`・`CheckInSlot.isSleep` は消え、`showsCircle`／`circleStyle` の「丸を出さない・幅だけ取る」は残す
- `CheckInPlanner.nearest/end` は睡眠以外で使うので残す。`resolve` は `end(minutes:after:)` の逆向き（起床を固定して就寝を遡る）

### 3-3. データ経路
| 経路 | 中身 |
|---|---|
| protocol `Services/SleepDataSource.swift` | `fetchSleepRecords(endingFrom: Date, to: Date) -> [SleepRecord]`、`insertSleepRecord(start:end:score:) -> SleepRecord`、`updateSleepRecord(id:start:end:score:)`、`deleteSleepRecord(id:)` |
| Supabase | `SupabaseDayDataSource` の extension（`ScheduleDataSource` と同じ置き方。client を増やさない）。直接 `.from("sleep_record").insert/update/delete`。`AppDataSources.sleep` を足し、`-mock-day` では `InMemoryScheduleDataSource` の同じインスタンスを渡す（M-1: 睡眠タブで書いた記録が予定タブに出る） |
| InMemory | `State.sleepRecords`。`SleepRules.validate` を通して同じ規則で拒否。`-mock-day` の初期データ「一昨日の夜 23:40–7:10・スコア 4」を `actualTasks` から `sleepRecords` へ移す |
| 予定タブ | `loadDayContext` に 9 本目: `sleep_record` を `SleepRules.fetchRange(D)` で取る → `DayBuilderContext.sleepRecords: [SleepRecord] = []`（既定値つき = 既存テスト無変更）→ `Day.sleepRecords`（`workoutSetTimes` と同じ扱い。`Day.actual` には混ぜない）→ 行の 3 行目は `SleepRules.assign` ＋ `planLine`。DayBuilder の合成は変えない（D-5） |
| 睡眠タブ `Services/SleepStore.swift` | 1 画面目 = 直近 14 日（7 朝＋まとめ用の余白）、推移 = 期間 ±1 日、すべての記録 = 月ごと（PostgREST 1000 行の上限は年 400 行なら当面不要）。書き込み後は同じ範囲を読み直す。保存中フラグでボタンを disabled |
| **V-7 キャッシュ無効化** | 予定タブに戻ったとき（`HomeView.onAppear`）に `ScheduleStore.refresh` を「見ている日以外のキャッシュを捨て、見ている日を読み直す」に変える。今の「今日だけ読み直す」だと、昨日を見たまま睡眠タブで昨夜を直すと予定タブの昨日に古い実績が残る（守護派 R2 で唯一未解消だった点）。store 間の配線（通知・共有オブジェクト）は作らない |
| 予定タブ側の実績 | `actual_task` の select を `*` に戻す（埋め込み `sleep_actual_input(sleep_score)` を削除）。`ScheduleRPC` の `p_sleep_score` を削除。`ActualEntryEditView` の種類の選択肢から `subInputKind == .sleep` を外す（DB 側の拒否は最後の砦） |

### 3-4. テキストワイヤー

**睡眠タブ 1 画面目（今朝が未入力・7:12 に開いた）**
```
┌ 睡眠                                               [📊] ┐ ← 右上 = 推移へ push（トレーニングの「分析」と同じ）
│ 今週 平均 6時間52分 · 記録 4/5                           │ ← 固定の 1 行（連続は出さない）
├─────────────────────────────────────────────────────────┤
│ 10/2(金) の朝                                            │ ← 一覧の先頭 = 今朝
│ 就寝   [−15]   0:30   [+15]        前回 0:30             │ ← 直近の夜の就寝の時刻（初回 23:00）。時刻を押すとホイール
│ 起床   [−15]   7:10   [+15]        今                    │ ← 開いた時刻（5 分切り捨て）
│ 6時間40分                                                │
│                                      [ 記録する ]        │
├─────────────────────────────────────────────────────────┤
│ 10/1(木) の朝   23:40–7:10   7時間30分   目覚め 4    ›   │ ← 押すとシート
│ 9/30(水) の朝   未入力                        [記録]     │ ← 押すと前回値で埋まったシート
│ 9/29(火) の朝    0:30–7:00   6時間30分   目覚め 3    ›   │
│                 昼寝 13:10–13:40   30分              ›   │ ← Q2 で昼寝を記録する場合だけ
│ …（7 朝まで）                                            │
│ すべての記録 ›                                           │
└─────────────────────────────────────────────────────────┘
```
- 記録した直後の先頭:
```
│ 10/2(金) の朝    0:30–7:10   6時間40分              ›   │ ← 行になる（押すとシート）
│ 目覚め   ①  ②  ③  ④  ⑤                                   │ ← 任意。押せばその場で保存。付けたら数字だけ残る
```
- 0 時過ぎに開いて既定の起床が未来のとき: 「10/3(土) の朝 ・ 起きたら記録できます」と薄く出し［記録する］は出さない
- 週帯は持たない（1 朝 1 行なので一覧の方が短い）。「すべての記録」= 月ごとの一覧、右上に ＋（Q2 で A のとき）

**記録シート（`.medium`。行・［記録］・＋ から）**
```
┌ 10/1(木) の朝の睡眠                  [キャンセル] [保存] ┐
│ 就寝   [−15]   23:40   [+15]        9/30(水)             │ ← 日付は起床の前日になるときだけ右に
│ 起床   [−15]    7:10   [+15]                             │
│ 7時間30分                                                │ ← 2 時間未満は注意色（止めない）。同じ時刻・未来・重なりは赤＋保存不可
│ 目覚め  なし  ①  ②  ③  ④  ⑤                              │
│                                                          │
│ 記録を消す                                               │ ← 既存の記録だけ。確認「睡眠の記録を消しますか？」
└──────────────────────────────────────────────────────────┘
```
- ＋ から開いたときだけ「起床の日」の行（既定 今日）を上に足す。既定の時刻は 終了 = 今（5 分切り捨て）・開始 = その 1 時間前（予定外の実績の既定と同じ考え）
- 重なりで保存が拒否されたら footer に「この時間には記録があります」＋［その記録を開く］

**推移（📊 で push）**
```
┌ ‹ 睡眠   推移                                            ┐
│ [ 週 | 月 ]      [‹]  9/28(月)〜10/4(日)  [›]            │
│ 平均 6時間52分 · 就寝 0:12 · 起床 7:04 · 目覚め 3.6 · 記録 5/7 │
│        20時    0時    4時    8時    12時                  │
│ 月     ░░░░▓▓▓▓▓▓▓▓░░                                     │ ← 範囲バー（夜の睡眠だけ。帯なし）
│ 火     ░░░░░▓▓▓▓▓▓▓░░                                     │
│ 水     （未入力）                                         │
│ …                                                         │
│ 睡眠時間  ▂▅▆▃▆▅▇  ― 7 日平均                              │ ← 棒＋線
└───────────────────────────────────────────────────────────┘
```

**予定タブ（変わる所だけ）**
```
│   睡眠   前日から継続 –7:00                               │
│   実績 23:40–7:10（7時間30分）                             │ ← sleep_record から表示時に結ぶ。無ければ 3 行目なし
…
│   睡眠   23:00–                                           │ ← 今夜の行。何も出さない
```
- 行を押す: 今日・未来 = 予定の編集画面（実績欄なし）。過去日 = 押せない（段階 1）。Q3 で変わりうる
- 丸なし・幅だけ取る・スキップのスワイプなし、は 9/30 のまま

### 3-5. 入力・直す・消すの流れ（タップ数）
| 場面 | 流れ | タップ |
|---|---|---|
| 朝、前回と同じ就寝 | 睡眠タブ → 記録する | 2 |
| 就寝が 30 分ずれた | 睡眠タブ → [+15][+15] → 記録する | 4 |
| 就寝が大きくずれた | 睡眠タブ → 時刻を押す → ホイール → 記録する | 3＋ホイール |
| 目覚めを付ける | 記録後に ①〜⑤ | +1 |
| 昨日入れ忘れた | 睡眠タブ → 未入力の［記録］→（直す）→ 保存 | 3＋直す分 |
| 直す | 行 → シートで直す → 保存 | 2＋直す分 |
| 消す | 行を左スワイプ → 削除（確認なし）／行 → 記録を消す → 確認 | 2／3 |
| 昼寝（Q2 = A） | すべての記録 → ＋ → 時刻 → 保存 | 3＋直す分 |
比較: 今の未 commit 実装は 行 → 「就寝・起床を記録する」→ 時刻 2 つ → 保存 で最短 4（予定の編集画面を経由）

### 3-6. 推移・1 画面目の数字の定義
- 夜 = `SleepRules.nights` の 1 要素（分割した夜は合算）。昼寝は範囲バー・平均に入れない（一覧に行として出すだけ）
- 「今週」= 月曜始まり（既存の週帯と同じ）。「記録 4/5」= 今週の経過した朝（月曜〜今日）のうち夜の記録がある朝
- 平均就寝・平均起床 = 18:00 を 0 とした分で平均（0 時またぎで平均が昼にならないように）
- 7 日平均 = その夜を含む直近 7 夜のうち記録がある夜の平均（未入力は分母に入れない）
- 期間の移動（‹ ›）は未来へ進めない

---

## 4. 不採用リスト
| 案 | 出所 | 理由 |
|---|---|---|
| 起床の日 `wake_date` を列に保存・RPC が入れる | 推進派 R1 S1、別案 | 時刻を直したのに日付を直し忘れる二重管理（規約 C-6・INV-5）。推進派 R2 で取り下げ |
| 夜の睡眠は 1 朝 1 件の一意制約（`UNIQUE (wake_date) WHERE kind='main'`） | 推進派 R1 S2、別案 | 分割した夜を禁じる。誤分類（昼寝と判定された 6:00–8:00）が重なったまま入る（守護派 R2 §1-3）。重なり禁止で足りる |
| 種類の列 `kind` / `is_nap` を持ち、時刻から自動選択・切り替えで変えられる | 推進派 R1 S2、別案 | 入力が 1 つ増える。分類は表示時の定数で足り、誤っても過去分ごと直る |
| 昼寝を自動判定せず本人が毎回選ぶ | 守護派 R1 §2-7 | 守護派自身が R2 で緩めた（分類を保存しないので誤判定はデータを壊さない） |
| 予定の回と「起床日 = 回の日 + 1」で結ぶ | 推進派 R1 S1 | 1:00〜9:00 の世代で 1 日ずれる。世代の境目で日付だけでは決まらない（守護派 R2 §1-2）。推進派 R2 で取り下げ |
| 予定タブの行に「未入力」を出す | 推進派 R1 S8、守護派 R2 §3-1、未 commit 実装 | §1-2。促しは今朝のカード。Q3 で B なら復活可 |
| 予定タブの行に「睡眠タブで直す ›」 | 推進派 R1 S8 | 10/1 本人「両方」不採用。タブ切替＋シート表示の順序制御が要る（守護派 R2 §1-5）。Q3 の B として本人に提示 |
| 今朝のカードの就寝の既定 = その夜の予定の就寝 | 推進派 R1 S3、守護派 R2 A-1 | 睡眠タブが予定（世代・除外日）に依存する。前回値の方が直す回数が少なく、トレーニングの正解形と同じ（§1-6） |
| カードに「（予定 8時間 +10分）」 | 推進派 R1、守護派 R2 §1-4 の条件 | 予定を読まない。前回値既定なら「予定どおりの記録が増える偏り」も起きないので条件の前提が消える |
| 睡眠の連続日数（記録した朝／予定 ±30 分／週 N 夜） | 推進派 R1 S10 | 新しい方針で本人未決。共有部品に触るとウィジェットに響く。次の段で聞く |
| 推移の「予定との差の累計」「就寝のばらつき ±分」「昼寝の週合計」「6 か月」「予定の帯」 | 推進派 R1 S9 | 線の外（予定の読み込みが要る／グラフが増える）。使われ方を見てから |
| 書き込みを RPC（`sleep_save`/`sleep_delete`） | 守護派 R1 §3-5、別案 | 1 行で完結・過去日も可・重なりは EXCLUDE が止める。守護派 R2 で緩めた |
| `sleep_actual_input` の DROP を旧列削除（0009）に同梱 | 守護派 R1 §2-12 | commit 済みビルドは参照しない・本番 0 件・砦つき。分ける理由がない（守護派 R2 で緩めた） |
| `source`/`healthkit_sample_uuid`/`updated_at` を先回りで足す | 推進派 R1 S12・DDL 叩き台、別案 | 使い道のない列。後から `ADD COLUMN` 1〜2 行 |
| `wake_date` を生成列（`GENERATED ALWAYS AS (... AT TIME ZONE ...)`） | 別案 | `AT TIME ZONE` は IMMUTABLE でないので STORED 生成列に使えない見込み【推測】。そもそも保存しない |
| 上限 20 時間 | 別案 | 徹夜明けの長い睡眠を止めうる。24 時間（データ担当・守護派一致） |
| 寝る前に「寝る」を押す（Pillow・Sleep Cycle 型）、朝の全画面シート、起動時に睡眠タブを開く | 推進派 R1 | 儀式（本人 NG）。段階 2 C5 で本人が不採用にした形 |
| 円形ダイヤル（ヘルスケアの睡眠スケジュール型） | 推進派 R1 | 既製部品がなく 5 分精度が出しにくい。± で足りるか実機で見てから |
| 睡眠タブに週帯 | （一貫性の観点） | 1 朝 1 行なので一覧の方が見渡せる。トレーニングと日付の移り方が違うことは認める |
| 削除に「元に戻す」 | 推進派 R1 S6 | 新しい部品。Q1 の C として本人に提示 |
| 睡眠タブに予定タブの `ScheduleStore` を共有して予定を読む | （経路の候補） | 店を App 階層に持ち上げる改修が要り、睡眠タブが予定に依存する。前回値既定で不要 |

---

## 5. 本人に聞く論点（決裁チェックリストの形。推奨を先頭。この順に 1 問ずつ）

### Q1. 睡眠の記録の直し方・消し方（9/30 に本人が「少し考えたい」とした論点）
1. **要点**: 現状（未 commit）= 予定の編集画面の奥の実績欄で時刻を直して保存、「記録を消す」（確認あり）。→ 採用後 = 睡眠タブの一覧の行（今朝の行を含む）を押す → 半画面のシートで就寝・起床・目覚めを直して保存。消す = シートの「記録を消す」（確認あり）＋ 一覧の行の左スワイプ「削除」（確認なし。全スワイプは無効でボタンを押す）
   - **A（推奨）** 上記（予定外の実績・単発の予定と同じ作法）
   - B スワイプの削除にも確認を出す
   - C スワイプの削除は確認なしで消え、5 秒だけ「元に戻す」が出る
   - D スワイプ削除なし。消すのはシートからだけ
2. **エッジケース**: 今朝の記録を誤って消した → 今朝の行が未入力に戻り、既定が前回値で埋まるので 1 タップで入れ直せる（A で実害が小さい根拠）。ただし目覚めの値は失われる
3. **可逆性**: UI だけ。後から B/C/D に変えられる。データは変わらない
4. **記録先**: `day-cycle-walkthrough.md` 段階 2「睡眠（確定仕様）」（新設）、本ファイル §5 に回答を追記
5. **他の選択肢と採らない理由**: B は 予定外の実績（確認なし）と作法が割れ、スワイプの意味が薄れる。C は新しい部品（遅延削除＋トースト）が要り、他の削除と作法が割れる。D は一覧から消せず C-4（CRUD 対称）で不便

**本人回答（2026-10-02）: 「B スワイプにも確認」**（不採用: A 確認なしスワイプ＝予定外の実績と同じ作法だが誤操作に弱い／C 5 秒の元に戻す＝新しい部品／D スワイプ削除なし）。→ 直す＝一覧の行 → 半画面シート。消す＝シートの「記録を消す」（確認あり）＋一覧の左スワイプ「削除」（確認あり）

### Q2. 昼寝（夜以外の睡眠）も同じ表に記録するか
1. **要点**: 現状 = 昼寝は予定外の実績（actual_task）で記録する AI 既定（睡眠を actual_task から外す決定で成立しなくなった）。→ 採用後:
   - **A（推奨）** 記録する。睡眠タブ「すべての記録」の右上 ＋ で任意の記録を足せる。種類の入力はなく、就寝が 18:00〜翌 6:00 なら夜の睡眠、それ以外は昼寝として表示・平均を分ける
   - B 夜だけ。＋ は置かず、今朝の行と未入力の行からだけ記録する
2. **エッジケース**: 徹夜明けに 8:00〜13:00 寝た → A では「昼寝 8:00–13:00」としてその日に出て夜の平均に入らない。予定タブの行には（23:00–7:00 と重ならないので）出ない。B では記録する場所がない
3. **可逆性**: A → B は ＋ を消すだけ。B → A は ＋ を足すだけ。分類の境界は定数 1 つ。DB は同じ
4. **記録先**: 同上
5. **他の選択肢と採らない理由**: 種類を毎回選ぶ（入力が 1 つ増える）、昼寝を別の表（同じ形の表が 2 つ）

**本人回答（2026-10-02）: 「A 記録する（推奨）」**（不採用: B 夜だけ＝昼寝・徹夜明けの睡眠を残す場所がない）

### Q3. 予定タブの睡眠の行を押したとき
1. **要点**: 現状（未 commit）= 今日の前日継続の行 → 今夜の予定の編集画面＋前日の回の実績欄（入力できる）。過去日の行 → 読むだけの予定＋実績欄。→ 採用後:
   - **A（推奨）** 今日・未来の行 → 予定の編集画面だけ（実績欄なし）。過去日の行 → 押せない（段階 1 に戻す）。睡眠の入力・修正は睡眠タブだけ
   - B A ＋ 編集画面の下に読むだけの「実績 23:40–7:10 · 目覚め 4」と「睡眠タブで直す ›」（押すと編集画面を閉じて睡眠タブへ切り替え、その朝のシートを開く）。合わせて行の 3 行目に「未入力 ›」も出す
   - C 過去日の睡眠の行を押すと睡眠タブのその朝へ移る
2. **エッジケース**: 昨夜の記録を直したくて予定タブの行を押した → A では今夜の予定が開くだけ。睡眠タブへ移って行を押す（2 タップ）
3. **可逆性**: どれも UI だけ。シートは共通なので B/C を後から足すのは数十行（別案の指摘どおり）
4. **記録先**: 同上
5. **他の選択肢と採らない理由**: B は入口が 2 つに見え（10/1 本人が「両方」を不採用）、タブ切替とシート表示の順序をテストで固定する手間が要る。C は過去日の行だけ動きが変わり、段階 1 の「過去日は押せない」と割れる

**本人回答（2026-10-02）: 「A 予定の編集だけ（推奨）」**（不採用: B 編集画面に読むだけの実績＋睡眠タブへのリンク＝入口が 2 つに見える／C 過去日は睡眠タブへ移る＝段階 1 の「過去日は押せない」と割れる）

### 今回は聞かない（次の段の論点として残す）
- 睡眠にも連続日数を出すか。出すなら何を数えるか（記録した朝／予定の就寝 ±30 分の夜／週 N 夜）
- ウィジェット（昨夜の時間・未入力なら記録ボタン）
- ヘルスケアからの取り込み（本人がヘルスケアで睡眠を記録しているかが未確認）
- 予定との差（Rise 型の累計）

### AI 既定（本人に聞かない。違えば直す）
| 項目 | 既定 | 戻し方 |
|---|---|---|
| 夜の鍵 | 就寝 − 12h の JST 日。昼寝は開始の日 | `SleepRules.nightKey` 1 関数 |
| 見出し | 「10/2(金) の朝」（鍵 + 1 日） | `displayDay` 1 関数 |
| 昼寝の境界 | 就寝 18:00〜翌 6:00 が夜 | 定数 2 つ |
| 今朝のカードの既定 | 就寝 = 前回値（初回 23:00）、起床 = 今（前回の起床 −2h〜+5h の間だけ。外は前回の起床、初回 7:00） | `cardDefault` 1 関数 |
| 時刻の直し方 | [−15][+15] ＋ ホイール（5 分） | 部品 |
| スコアの名前・形 | 「目覚め」1〜5、記録後に 1 行、任意、数字 | 文言・部品 |
| 予定タブの行 | 結べた記録だけ「実績 …」。未入力は出さない。結びは重なり最長の行 1 つ、複数件はまとめて 1 行 | `planLine`/`assign` |
| 重複 | EXCLUDE ＋ アプリの事前検査 ＋ 保存中は押せない。23P01 →「この時間には記録があります」 | — |
| 書き込み | 直接 insert/update/delete | — |
| 上限 | `end_at − start_at <= 24h` | CHECK |
| 列名 | `start_at`/`end_at`。`kind`/`wake_date`/`source`/`updated_at` なし | — |
| migration | 0007 書き換え（睡眠を抜く＋拒否）、0008 睡眠（旧表 DROP 同梱・砦）、旧列削除は 0009 | — |
| 推移 | [週\|月]、範囲バー（帯なし）、睡眠時間の棒＋7 日平均、数字 1 行 | — |
| タブ | 3 番目「睡眠」、アイコン `bed.double`（既存の `SleepActualSection` のボタンと同じ） | — |
| 1 画面目 | 週帯なし。1 行「今週 平均 · 記録 n/N」＋今朝＋直近 7 朝＋すべての記録 | — |
| シート | `.medium` | — |
| V-7 | 予定タブに戻るたび、見ている日以外のキャッシュを捨てて見ている日を読み直す | `ScheduleStore.refresh` |
| 既定の起床が未来 | ［記録する］を出さず「起きたら記録できます」 | — |

---

## 6. 完了条件（機械的に確かめられるもの）と作り直しの範囲

### 6-1. 単体テスト（`SleepRulesTests.swift` 新設＋既存の更新）
- [ ] `nightKey`/`kind`/`displayDay`: 23:40→7:10（鍵 = 就寝の日・朝 = 翌日）、0:30→7:30（鍵 = 前日）、22:00–23:50 と 0:30–7:00 が同じ鍵、14:00–15:00 は昼寝で鍵 = その日、18:00–23:00 は夜（鍵 = その日）、6:10–12:00 は昼寝
- [ ] `nights`: 分割した夜が 1 夜（start = 22:00・end = 7:00・total = 8:20・score = 後の記録のもの）
- [ ] `morning`/`cardDefault`: 未入力なら前回値（初回 23:00/7:00）、窓の内で「今」（5 分切り捨て）、窓の外で前回の起床、既定の起床が未来なら nil
- [ ] `resolve`: 起床 7:10・就寝 23:40 → 就寝は前日、同じ時刻は nil、24 時間超にならない
- [ ] `validate`: 終了 ≤ 開始、24h 超、未来、重なり（自分を除く）、score 0/6 を拒否。端がくっつく 2 件（7:30 起床と 7:30 就寝）は通る
- [ ] `assign`/`planLine`: 0:30–7:30 が前日継続の行に付く（V-2）、14:00–15:00 はどの行にも付かない、6:10–12:00 は 23:00–7:00 の行に付く（N-3）、世代の境目の朝（行 2 本・0:50–8:30 は 1:00 の回へ）（V-4・N-4）、1 件が 2 日の一覧で同じ回に付く（V-3）、除外日の夜の記録は予定タブに出ず睡眠タブに出る（V-5）、2 件で「（7時間 · 2 件）」
- [ ] `fetchRange`: [D−1 0:00, D+2 0:00)（V-6）
- [ ] `stats`: 平均就寝が 0 時またぎで昼にならない、記録 n/N は夜だけ、7 日平均は未入力を分母に入れない
- [ ] `message(for:)`: `PostgrestError(code: "23P01")` → 「この時間には記録があります」（E-2）
- [ ] InMemory: 睡眠の種類を `checkin_set`/`actual_save` 相当で拒否（S2-6）、`sleepRecords` の insert/update/delete が `validate` と同じ規則で拒否
- [ ] 既存: `ScheduleStage1Tests` 38 件無変更で成功（S1-1〜S1-8）、`ScheduleStage2Tests` の睡眠以外が無変更で成功（S2-1）、`ContinuityTests` 無変更（C-6）、`circleShownByOccurrenceDayNotViewDay` の睡眠の 4 件維持（S2-7）
- [ ] 睡眠を例に使っていたテストは種類を替えて検査を残す（S2-2。消して終わりにしない）: `deletingOccurrenceRemovesSkippedKeepsDone`（240 行目の睡眠 → ジム）、`endingSeriesFromTodayKeepsPastDoneAndRemovesSkipped`（289〜290 行目）、`rulesRejectFutureInvalidAndScoreOutsideSleep`（スコアの拒否 → 睡眠の種類の拒否）、`checkInRPCParams`（`p_sleep_score` を外す）、`skippedRowDecodesWithNullTimes`（`sleep_actual_input` の JSON を外す）、`mockDayFixtureHasCheckInSamples`（`sleepRecords` を見る）。`SleepCheckInTests` 3 件は `SleepRulesTests` へ移す（`nearestAndEnd` は残す）
- [ ] 全件成功（今 169 件。移動と追加で件数が変わるので実行結果の件数を walkthrough に書く）
- [ ] grep: 睡眠のコードに `Calendar.current` が無い（R-8）、`Continuity.swift`/`StreakViews.swift`/`StreakWidget.swift` に差分が無い（X-1）、`SleepActualSection` が無い（V-1）、`sleep_actual_input` の文字列がアプリに無い

### 6-2. SQL（使い捨て Postgres 16。本番には触れない）
- [ ] 0001→0006 → 本番と同じ 2 系列 → 新 0007 を 2 回 → 0008 を 2 回: NOTICE だけで通る（冪等）
- [ ] `verify_sleep.sql` §A〜§G をそのまま流し、`verify_sleep.out` と同じ結果（8 引数 1 本、睡眠の拒否 2 本、制約 4 本、拒否 4 件、分割の 2 件は通る、重なる UPDATE は止まる、砦）
- [ ] 段階 2 の `s2impl/verify_0007.sql` の睡眠以外の項目を流し直して差分なし（S2-3）。睡眠の項目（0 時過ぎ・スコアの CASCADE・6 で止まる）は上の §C に置き換わる
- [ ] 段階 1 の全 RPC（`schedule_*`）を流した前後で `sleep_record` の中身が一致（R-6）
- [ ] 本番適用後（本人 OK 後）: `pg_proc` で `checkin_set` が 8 引数の 1 本（E-1）、`to_regclass('sleep_actual_input')` が NULL、anon で `sleep_record` の select/insert/delete が通る、重なる insert が code 23P01 で返る（HTTP の状態も記録する）

### 6-3. シミュレータ（`-mock-day`）
- [ ] 睡眠タブ: 今朝が未入力で前回値（モックの一昨日 23:40／今）が入っている → 記録する → 行になり目覚めの行が出る → ④ を押すと残る
- [ ] 行を押す → シートで就寝を [−15] → 保存 → 行と予定タブの前日継続の行の「実績 …」が一致（M-1）
- [ ] 左スワイプ → 削除 → 今朝の行が未入力に戻る。シートの「記録を消す」→ 確認 → 消える（Q1 の決定どおりか。X-2）
- [ ] 未入力の朝の［記録］→ 前回値で埋まったシート → 保存 → その朝の行になる
- [ ] 重なる時刻で保存 → 「この時間には記録があります」
- [ ] 予定タブ: 今日の前日継続の行に「実績 …」、今夜の行には何も出ない、丸なしで並びが揃う、行を押しても実績欄が無い、過去日の睡眠の行は押せない（Q3 = A のとき）、予定外の記録の種類に「睡眠」が無い（S2-8）
- [ ] 予定タブで昨日を見る → 睡眠タブで昨夜を直す → 予定タブに戻る → 昨日の実績が新しい（V-7）
- [ ] 推移: 週／月の切り替え、範囲バーと棒、未入力の日が空で出る。未来へ進めない
- [ ] 現在進行中のカード・Live Activity・トレーニングタブに差分なし（V-8・C-7）

### 6-4. 作り直しになる未 commit の実装（ファイル単位）
| ファイル | 変更 |
|---|---|
| `supabase/migrations/0007_actual_checkin.sql` | scratchpad `0007_new.sql` の中身に置き換え（差分 §3-1） |
| `supabase/migrations/0008_sleep_record.sql`（新規） | scratchpad `0008_sleep_record.sql`＋コメント修正 |
| `Models/CheckIn.swift` | `CheckInOperation.set` の `sleepScore` 削除、`CheckInRuleError.scoreNotSleep` → `sleepIsSeparate`（文言「睡眠は睡眠タブで記録します」）、`acceptsActual` の睡眠分岐と `actualLine` の睡眠分岐を削除、`CheckInSlot.isSleep` 削除。`showsCircle`/`circleStyle` の睡眠は残す |
| `Models/ActualTask.swift` | `sleepScore`・`SleepInput`・`sleepActualInput` の decode/encode を削除（約 20 行） |
| `Models/SleepRules.swift`（新規） | §3-2 |
| `Services/SleepDataSource.swift`（新規）・`Services/SleepStore.swift`（新規） | §3-3 |
| `Services/SupabaseDayDataSource.swift` | 実績の select を `*`、`p_sleep_score` 削除、`sleep_record` の取得 1 本、`SleepDataSource` の extension |
| `Services/InMemoryScheduleDataSource.swift` | `scoreNotSleep` → 睡眠の種類の拒否、`State.sleepRecords`、初期データの睡眠を移す、`SleepDataSource` 準拠 |
| `Services/ScheduleStore.swift` | `.set` の `sleepScore`（1 か所）、`refresh` を「見ている日以外を捨てて読み直す」に |
| `DayBuilder/Day.swift`・`DayBuilderContext.swift`・`TemplateVersions.swift` | `sleepRecords` を足す（既定値つき） |
| `Views/Home/ScheduleEntryEditView.swift` | `SleepActualSection`（約 50 行）と睡眠の state・保存の分岐を削除。睡眠の行では `checkIn` を nil に |
| `Views/Home/ScheduleListView.swift`・`HomeView.swift` | 睡眠の行の 3 行目を `SleepRules.planLine` から。過去日の睡眠の行を押せなくする（Q3 = A） |
| `Views/Home/ActualEntryEditView.swift` | 種類の選択肢から睡眠を外す |
| `Views/Sleep/*`（新規）: `SleepView`（1 画面目）・`SleepRecordSheet`・`SleepHistoryView`（すべての記録）・`SleepTrendView` | §3-4 |
| `LifeTrackerApp.swift` | 3 番目のタブ、`AppDataSources.sleep`（`-mock-day` では予定と同じインスタンス） |
| `LifeTrackerTests/ScheduleStage2Tests.swift`・`SleepRulesTests.swift`（新規） | §6-1 |
| docs: `day-cycle-walkthrough.md`（段階 2 の保留 → 「睡眠（確定仕様）」新設、旧列削除 0008 → 0009 の 4 か所）、`domain-model.md`（`sleep_actual_input` → `sleep_record`、「sleep day attribution は HealthKit 同型を Phase 2」→ 就寝 −12h の鍵と重なりでの結び、294・408・585〜590 行目）、`spec.md` 127 行目、`structural-conventions.md`（D-4 に「睡眠は予定とつながない完全独立の例」、C-6 の `sleep_actual_input` の記述、C-8 の sleep 除外はそのまま）、memory `project_life_tracker_v2_core`（旧列削除 0009） | 記録の食い違いを残さない（C-8） |

段階 2 の睡眠以外（丸・スキップ・予定外・ジム・予定の RPC の実績の扱い・楽観更新）は変えない。

### 6-5. 不可逆・外部に伝播するもの（フラグ）
- 本番 DB への 0007・0008 の適用（`sleep_actual_input` の DROP を含む）。砦があるので行があれば止まるが、適用前に `SELECT count(*) FROM sleep_actual_input` と `actual_task` の件数を読んで記録する
- 0007 を先に当ててから直すと `checkin_set` の 9 引数版が残り、PostgREST が関数を選べなくなる【推測】。必ず書き換えた 0007 を当てる
