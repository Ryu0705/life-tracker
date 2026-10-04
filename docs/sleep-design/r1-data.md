# Round 1 データ担当: 睡眠の記録の持ち方と移行

作成: 2026-10-02 / 担当: データ担当（opus）/ 状態: 案（本人未確認）

読んだもの: `README.md`、`../day-cycle-walkthrough.md`（段階 1・段階 2 の確定仕様・レビュー反映・実装メモ・保留）、`supabase/migrations/0001〜0007`、`../structural-conventions.md`（D-4・D-5）、`../domain-model.md`（サブ入力・sleep day attribution・INV）、`../continuity-design.md`、`../day-cycle-review-2026-09-30-stage2.md`（本番の件数）、Swift の `SupabaseDayDataSource`・`InMemoryScheduleDataSource`・`ScheduleDataSource`・`ActualTask`・`CheckIn`・`DayBuilder/*`・`ScheduleEntryEditView`（`SleepActualSection`）・`WorkoutDataSource`・`ScheduleStage2Tests`・`git status`/`git diff --stat`

確かめ方: 使い捨ての Postgres 16（docker `postgres:16-alpine`、終了後に破棄）に 0001→0006 と本番と同じ 2 系列を入れ、**睡眠を抜いた 0007** と **0008 案** をそれぞれ 2 回流した（冪等）。スクリプトと結果は scratchpad `sleep/verify_sleep.sql`・`verify_sleep.out`、0007 の差分は `sleep/0007_sleep_removed.diff`。本番 DB・コード・git には触れていない

表記: 【事実】= ファイル・SQL の実行で確かめた／【推測】= 確かめていない

---

## 0. 結論（推奨）

| 論点 | 推奨 |
|---|---|
| 表 | `sleep_record(id, start_at=就寝, end_at=起床, score 1〜5 任意, created_at)`。予定へのつながりの列は持たない。重なりを DB で禁止（EXCLUDE） |
| 昼寝 | 同じ表に入れる。種類の列は持たず、就寝の時刻で表示時に分ける（就寝 18:00〜翌 6:00 = 夜の睡眠、それ以外 = 昼寝など） |
| メモ・出所（HealthKit） | 今は持たない。後から `ALTER TABLE … ADD COLUMN` 1 行で足せる（既存の行は既定値で埋まる） |
| どの夜に属するか | **保存しない**。表示時に計算: 夜の睡眠は「就寝 − 12 時間」の JST 日（= 予定の回の日と同じ数え方。0:30 就寝は前日の夜）。同じ夜の複数件は 1 夜にまとめる |
| 予定タブの行との対応 | 予定の行の時間帯（予定の本来の範囲）と**時刻が重なる**記録を、その行の実績として表示する。夜の日のキーでは結ばない |
| 書き込み | RPC にせず、PostgREST の直接 insert / update / delete（トレーニングと同じ。1 行で完結し、検査は CHECK と EXCLUDE で足りる） |
| 推移 | Swift の pure 関数で計算（view は作らない）。ウィジェットへの共有は今は不要 |
| 0007 | 睡眠の分岐（`p_sleep_score`・`sleep_score_range`・スコアの行の書き込み）を抜き、代わりに「睡眠の種類は actual_task に書けない」検査を `checkin_set`・`actual_save` に足す。他はそのまま |
| 旧 `sleep_actual_input` | 0008 で DROP（本番 0 件の記録あり。1 件でもあれば止まる砦を付ける） |
| migration | `0007_actual_checkin.sql` を書き換え（未適用・未 commit なので履歴の問題なし）＋新規 `0008_sleep_record.sql`（apply 名 `v2_sleep_record`）。**旧列の削除は 0008 → 0009 に繰り下げ** |

---

## 1. 新しい表の DDL 案（使い捨て Postgres で確認済み）

```sql
CREATE TABLE IF NOT EXISTS sleep_record (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  start_at   TIMESTAMPTZ NOT NULL,              -- 就寝 (床に就いた時刻。本人の申告)
  end_at     TIMESTAMPTZ NOT NULL,              -- 起床
  score      SMALLINT,                          -- 主観スコア 1〜5。任意
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sleep_record_time_chk  CHECK (end_at > start_at),
  CONSTRAINT sleep_record_span_chk  CHECK (end_at - start_at <= interval '24 hours'),  -- 起床の日の取り違えを止める
  CONSTRAINT sleep_record_score_chk CHECK (score IS NULL OR score BETWEEN 1 AND 5),
  -- 同じ時間に 2 つの睡眠は無い。同じ夜に 2 件 (中途覚醒で分けた・昼寝) は重ならなければ可
  CONSTRAINT sleep_record_no_overlap EXCLUDE USING gist (tstzrange(start_at, end_at) WITH &&)
);
CREATE INDEX IF NOT EXISTS sleep_record_end_at_idx ON sleep_record (end_at);  -- 推移・一覧は起床で範囲を取る
```

列ごとの判断:

| 列・制約 | 判断 | 理由 |
|---|---|---|
| `start_at` / `end_at` | 既存の `actual_task`・`scheduled_task` と同じ名前（Swift では `bedtime` / `wakeTime` と呼んでよい） | 重なりの取得・判定のコードと SQL を他の表と同じ形で書ける。HealthKit の startDate / endDate とも対応する。`bed_at` / `wake_at` も可（どちらでも費用は同じ。推奨は既存と揃える方） |
| `score SMALLINT` | 1〜5・NULL 可 | 旧 `sleep_actual_input.sleep_score` と 0007 の `sleep_score_range` と同じ範囲 |
| `created_at` | 持つ | `training_goal` と同じ。記録が遅れて入ったか（朝に入れたか夜にまとめて入れたか）を後で見られる。`updated_at` は持たない（使い道がない） |
| `time_chk` / `span_chk` | 持つ | 0 時をまたぐ入力で起床の日を 1 日先にすると 31 時間になる。24 時間を超える睡眠は実在しないので DB で止める（DB は最後の砦） |
| `no_overlap`（EXCLUDE） | 持つ | 一意制約（1 夜 1 件）は昼寝・分割睡眠を禁じてしまうので入れない。代わりに「時間が重なる 2 件」を禁じる。**Supabase の素の Postgres でも `btree_gist` 拡張なしで作れた【事実】**（範囲型だけの EXCLUDE は gist 標準の演算子で足りる）。半開区間 `[)` なので 7:30 起床の直後 7:30 から寝直した記録は通る【事実】 |
| 未来の時刻の禁止 | DB では持たない（アプリで検査） | CHECK に `now()` を入れるのは不変でない式で、復元時に壊れる。トリガーは規約で避けている。アプリの検査で十分（入力は本人 1 人） |
| 予定へのつながり（template_id 等） | 持たない | 本人決定「予定タブの睡眠の行は実績を表示するだけ（ジムと同じ形）」。持つと 0007 の「予定の RPC が実績に触れる」規則（skipped 削除・つなぎ直し）に睡眠も巻き込まれる |
| メモ `note` | 持たない | 入力の手間を増やさない（memory `feedback_input_ux`）。要るなら `ALTER TABLE sleep_record ADD COLUMN note TEXT;` 1 行、既存の行は NULL |
| 出所 `source` / `external_id` | 今は持たない | 後から `ADD COLUMN source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','healthkit'))`・`ADD COLUMN external_id TEXT UNIQUE` の 2 行で、既存の行は `manual` になる。今入れても後で入れても同じ結果で、今は使い道がない。**注意**: 取り込みを入れるときは EXCLUDE と当たる（手入力と同じ夜の HealthKit の記録）。そのときに「HealthKit を入れたら手入力を置き換えるか」を決める（取り込みは 1 夜を 1 件にまとめて入れる前提。Apple Watch の段階ごとのサンプルは入れない） |
| 昼寝の種類の列 `kind` | 持たない（下の §2-3） | |

権限: 0005（`training_goal`）と同じく GRANT を書かない（Supabase は public の新しい表に anon / authenticated の権限を既定で付ける【推測。0005 適用後に anon で読み書きできたという記録はある】）。素の Postgres では権限が付かないことを確認した【事実】。**本番適用後に anon で insert / select を 1 回試す**

## 2. 「どの夜に属するか」

### 2-1. 候補の比較（使い捨て Postgres で同じ 5 件を当てた結果【事実】）

| 記録（JST） | N0 就寝の日 | **N1 就寝 − 12h の日** | N2 起床の日 | N3 起床＋18 時境界（domain-model の旧予定・Apple ヘルスケア型） |
|---|---|---|---|---|
| 9/30 23:40 → 10/1 7:10（普通の夜） | 9/30 | 9/30 | 10/1 | 10/1 |
| 10/2 0:30 → 7:30（0 時過ぎの就寝） | 10/2 ✕ | 10/1 | 10/2 | 10/2 |
| 10/1 14:00 → 15:00（昼寝） | 10/1 | 10/1（※） | 10/1 | 10/1 |
| 9/30 17:00 → 18:30（夕方の昼寝） | 9/30 | 9/30（※） | 9/30 | **10/1 ✕** |
| 9/30 8:00 → 13:00（徹夜明けの朝寝） | 9/30 | 9/29（※） | 9/30 | 9/30 |
| （例）22:00 → 23:50 と 0:30 → 7:00 の分割 | 別の日 ✕ | **同じ夜** | **別の日 ✕** | 同じ日 |

※ 推奨案では昼寝・朝寝は「夜の睡眠」に入れないので、N1 の日付は使わない（§2-3。開始の日で出す）

- N0 は 0 時過ぎの就寝が翌日になる（不可）
- N2 は分かりやすい（「起きた日の睡眠」）が、早寝して 0 時前に一度起きた夜が 2 日に割れる
- N3（domain-model の「Phase 2 で HealthKit 同型」）は夕方の昼寝が翌日に入る。ヘルスケアの数え方と揃うのは利点だが、取り込みは今は範囲外
- **N1**（夜の日 = 就寝 − 12 時間の JST 日）は、0 時過ぎの就寝・分割した夜を同じ夜にまとめられ、**予定の回の日と同じ数え方**（9/30 23:00 の予定は 9/30 の回。段階 2 の「前日から続く睡眠は前日の回」とも同じ）。昼寝には向かないので、§2-3 の分類と組み合わせる

### 2-2. 保存するか、表示時に計算するか

| 案 | 中身 | コスト | リスク |
|---|---|---|---|
| **A 表示時に計算（推奨）** | 規則は Swift の pure 関数 1 つ（例 `SleepNight.key(for:)`）。DB は時刻だけ | 関数 1 つ＋テスト | 規則を変えても migration・backfill 不要。HealthKit の取り込みも日付を計算しなくてよい。DB で「1 夜 1 件」を強制できないが、そもそも 1 夜 1 件にしない（昼寝・分割） |
| B 列 `night_date DATE` を保存 | 書き込み時に計算して入れる（RPC かアプリ） | 列＋計算の置き場（RPC にすると直接 insert できない） | 時刻を直したのに日付を直し忘れる不整合が起きる（INV-5「導出値を永続化しない」に反する）。規則を変えたら backfill |
| C 予定の回に結ぶ（0007 と同じ `template_id`＋`occurrence_date`） | 予定の回のキーを持つ | 0007 の分岐を残す | 本人決定（予定とは表示だけで結ぶ）に反する。予定の無い夜・除外日の記録が置き場を失う |

取得は日付の列が無くても困らない: 推移は `end_at` の範囲、予定タブは時刻の重なりで取る（§3）。

### 2-3. 昼寝の扱い

| 案 | 中身 | コスト | リスク |
|---|---|---|---|
| **P1 同じ表・列なし・時刻で分類（推奨）** | 就寝が JST 18:00〜翌 6:00 = 夜の睡眠（夜の日 = N1）、それ以外 = 昼寝など（開始の日に出す）。境界は pure 関数の定数 | 関数の分岐 1 つ | 夜勤のような生活では外れる（本人の生活では起きにくい【推測】）。外れても定数を変えるだけ、データは変わらない |
| P2 列 `kind`（'night' / 'nap'）を本人が選ぶ | 入力に切り替え 1 つ（既定は時刻から） | 列＋入力の UI | 毎回の入力が 1 つ増える。後から足すなら `ADD COLUMN kind TEXT NOT NULL DEFAULT 'night'`＋時刻の規則で昼寝を UPDATE（数百行） |
| P3 昼寝は記録しない | 夜だけ | なし | 昼寝を残したくなったら P1 か P2 へ。EXCLUDE があるので後から入れても困らない |

### 2-4. 場面ごとの扱い（推奨案）

| 場面 | 睡眠タブ・推移（夜の日 N1） | 予定タブの行（時刻の重なり。§3） |
|---|---|---|
| 0 時過ぎの就寝（0:30〜7:30） | 前日の夜 | 前日から続く行（昨夜の回 23:00–7:00）に重なる → その行の実績【事実: SQL で確認】 |
| 予定の無い夜（予定を消した・その日だけ消した＝除外日） | 普通に 1 夜 | 行が無いので出ない。予定外として予定タブに出すかは UI 担当の判断（データはどちらでも出せる） |
| 世代で予定の時刻が変わった夜 | 影響なし（予定を見ない） | その日の行は DayBuilder がその日の世代で組み立て済み（前日の分は前日の世代）。重なりはその組み立てた範囲で判定するので、追加の処理は要らない |
| 昼寝（14:00–15:00） | 昼寝としてその日に出る（夜の睡眠の合計に入れない） | 睡眠の予定の行に重ならない → 行の実績にならない【事実: SQL で確認】 |
| 同じ夜に 2 件（23:30–3:00 と 3:30–7:00） | 1 夜にまとめる: 就寝 = 最初、起床 = 最後、睡眠時間 = 合計（間の 30 分は入れない）、スコア = 最後に付いたもの | 両方が行に重なる → 行には「23:30–7:00（7時間・2 件）」のようにまとめて出す（睡眠時間は 3時間30分＋3時間30分の合計。文言は UI 担当） |
| 重なる 2 件 | DB が止める（23P01）【事実】 | — |
| 1 件が 2 つの行に重なる（22:00 → 翌 23:30 のような長い記録） | — | 重なりが長い方の行だけに付ける（同じなら早い行）。24 時間の上限があるので 3 行にはならない |
| 今夜の回で、まだ就寝の予定時刻前 | — | 記録が無ければ何も出さない（段階 2 の AI 既定と同じ。時刻の規則は今の `acceptsActual` の睡眠分岐を移す） |

## 3. 予定タブへの渡し方

- **取得**（`SupabaseDayDataSource.loadDayContext`。今の 8 本に 1 本足す）: `sleep_record` を `start_at < D+2 0:00 AND end_at > D-1 0:00` で取る。D の一覧に出る予定の行は、前日から続く行（開始 ≥ D-1 0:00）から今夜の行（終了 ≤ D+1 24:00。duration ≤ 1440 のため）までなので、この範囲で漏れない【事実: SQL で 3 件取れ、D の行に付くのは昨夜の回の 1 件だけと確認】。余分に取れた記録（前日の一覧の分・昼寝）は端末の重なり判定で落ちる。数行なので索引は気にしなくてよい
- **DayBuilder**: `DayBuilderContext.sleepRecords: [SleepRecord] = []`（既定値付き＝既存テストは無変更）→ `Day.sleepRecords` にそのまま渡す（`workoutSetTimes` と同じ扱い。`Day.actual` には混ぜない＝`actual_task` だけのまま）。DayBuilder の合成は変えない（規約 D-5: DB を呼ばない pure のまま）
- **行への対応付け**: pure 関数 1 つ（例 `SleepMatch.records(for row: DayScheduledTask, in day: Day) -> [SleepRecord]`）。対象は `category.sub_input_kind == 'sleep'` の行。判定は「記録の [就寝, 起床) と行の予定の本来の範囲（clip 前）が重なる」、複数行に重なる記録は重なりが長い行へ。今の `CheckInPlanner.actualLine` の睡眠分岐はこの結果から文言を作る形に差し替える
- **読み直し**: 睡眠タブで書いた後、予定タブに戻ったときに今日を読み直す（段階 2 で入れた `onAppear` の今日の読み直しがそのまま効く）。睡眠タブの書き込みで予定タブの日のキャッシュを捨てるかは store の担当（昨日を見ていた場合は古いまま。段階 2 の「タブ復帰で今日だけ」と同じ割り切り）

## 4. 推移・ウィジェット

- **取得**: 睡眠タブは `end_at` の範囲（例: 直近 26 週）で取る。1 年で約 400 行【推測: 夜 1 件＋たまに昼寝】なので半年は 1 リクエスト（PostgREST 上限 1000 行）に収まる。長い期間を出すときは `fetchSets(completedFrom:to:)` と同じページング
- **集計**: Swift の pure 関数（例 `SleepStats`）。夜ごとの睡眠時間・就寝時刻・起床時刻・スコア、週の平均。view は作らない（行数が小さく、夜のまとめ方・昼寝の分類の規則を端末の 1 か所に置くため。INV-5 は「読み取り時の集計は view でも可」なので、遅くなったら view に移せる）
- **使い捨て Postgres での確認**: 起床の日ごとの合計・最長・スコアが 1 本の SELECT で出る【事実。`verify_sleep.out` §F】＝将来 view に移すのも容易
- **ウィジェット**: 今は不要（本人の決定に睡眠のウィジェットは無い）。作るなら継続の仕組みと同じく App Group の UserDefaults に「直近の夜のまとめ」を書く形で、DB の変更は要らない

## 5. 0007 の扱い

### 5-1. 抜くもの・足すもの（`0007_sleep_removed.diff`。睡眠以外は 1 文字も変えない）

| 箇所 | 変更 |
|---|---|
| 制約の DO ブロック | `sleep_score_range`（`sleep_actual_input` への CHECK）を削除 |
| `checkin_set` | 引数 `p_sleep_score int` を削除（9 引数 → 8 引数）。スコアの検査と、最後の `sleep_actual_input` の DELETE / INSERT を削除。代わりに **種類が睡眠なら例外**（`'sleep is recorded in sleep_record'`） |
| `actual_save` | **種類が睡眠なら例外**を追加（予定外の「やったことを記録」で睡眠を選べないように） |
| `checkin_clear` のコメント | 「スコアの行は CASCADE」を削除 |
| GRANT | `checkin_set(…, timestamptz, timestamptz)` の 8 引数に |

- 使い捨て Postgres で 2 回流して冪等・`checkin_set` は 8 引数の 1 本だけ（古い 9 引数の重複なし）・睡眠は 2 本とも拒否・ジムは通る、を確認【事実】
- 睡眠の拒否を入れる理由: 予定タブの睡眠の行は丸を出さないので通常は書かれないが、予定外の記録で種類「睡眠」を選べてしまう。入れておくと「睡眠の記録が 2 か所にある」状態を DB が作らせない（`category` を見る検査はもともと関数の中にあったので、費用は同じ）。入れない案も可（アプリの種類の選択肢から睡眠を外すだけ）
- **0007 はまだ適用していないので、9 引数版が本番に残る心配はない**。もし先に今の 0007 を当ててしまった場合は、`DROP FUNCTION checkin_set(uuid, date, uuid, text, text, uuid, timestamptz, timestamptz, int);` を 0008 に足す（重複のままだと PostgREST が引数で関数を選べず失敗する【推測】）

### 5-2. 旧 `sleep_actual_input`

- 本番は 0 件【記録上の事実: 段階 2 レビュー（2026-09-30）で MCP の SELECT により `actual_task`・`sleep_actual_input` とも 0 件】。その後も増えていないと判断できる根拠: commit 済みのビルドは `actual_task` を読むだけで書かない【事実: `git grep` で書き込み 0 件】、書き込む RPC（0007）は未適用、`sleep_actual_input` は `actual_task_id NOT NULL` なので actual_task が 0 件なら 0 件
- 0008 で DROP する。**1 件でもあれば例外で止める砦**を付けた（データを黙って捨てない。使い捨て Postgres で、行があると止まり、空なら消えることを確認【事実】）
- commit 済みのビルドは `sleep_actual_input` を参照しない【事実】ので、消しても今入っているアプリは壊れない
- `category.sub_input_kind = 'sleep'` は残す（予定タブで睡眠の行を見分けるのに使う）

### 5-3. migration の番号・名前（規約: `NNNN_<slug>.sql`、apply 名 `v2_<slug>`）

| 案 | 中身 | コスト | リスク |
|---|---|---|---|
| **M1（推奨）** | `0007_actual_checkin.sql` を書き換え＋新規 `0008_sleep_record.sql`（`v2_sleep_record`）。旧列の削除は **0009** に繰り下げ | walkthrough・memory の「旧列削除は 0008」を 0009 に直す | 2 本は独立（0008 は表を足して空の表を消すだけ）なので、どちらを先に当てても壊れない |
| M2 | 0007 に sleep_record も入れる | 1 本で済む | ファイル名（actual_checkin）と中身がずれる。睡眠だけ先に当てる・戻すができない |
| M3 | 0007 は今のまま、0008 で睡眠の分岐を消す | 0007 を触らない | 未適用のものを一度入れてから消す二度手間。9 引数の関数の DROP が要る |

## 6. 書き込み: RPC か直接か

| 案 | コスト | リスク |
|---|---|---|
| **直接 insert / update / delete（推奨）** | `SupabaseWorkoutDataSource` と同じ書き方。関数なし | 未来の時刻の検査はアプリだけ（本人 1 人の入力なので十分）。エラーは PostgREST の code で分ける: `23P01` = 他の記録と重なる、`23514` = 時刻・スコアの CHECK |
| RPC `sleep_save(p_id, p_start, p_end, p_score)`／`sleep_delete(p_id)` | 関数 2 本＋GRANT | 段階 1・2 が RPC にしたのは「複数の行を 1 トランザクションで」「D ≥ 今日の検査」のため。睡眠は 1 行で完結し、過去日も直せるので RPC にする理由が無い |

既存の慣習との対応: 予定（複数行の操作・日付の検査）= RPC、トレーニング（1 行ずつ）= 直接。睡眠は後者。

## 7. Swift 側の変更点と作り直しの範囲

### 7-1. 新しく作るもの

| ファイル | 中身 |
|---|---|
| `Models/SleepRecord.swift` | `SleepRecord`（id・startAt・endAt・score・createdAt。Codable は既存の snake_case decoder でそのまま）、新規・更新用の Encodable |
| `Shared/SleepNight.swift`（アプリのみなら `Models/` でも可） | pure: 夜の睡眠／昼寝の分類、夜の日（N1）、1 夜へのまとめ、予定の行との重なりの対応付け、入力した時計の時刻 → 日時（起床 = 選んだ日のその時刻、就寝 = 起床より前で 24 時間以内の最初のその時刻。`CheckInPlanner.end(minutes:after:)` の逆向き）、推移の集計 |
| `Services/SleepDataSource.swift` | protocol: `fetchSleepRecords(endingFrom:to:)`・`saveSleepRecord(id: UUID?, start:end:score:)`・`deleteSleepRecord(id:)` |
| Supabase 実装 | `SupabaseDayDataSource` の extension（`ScheduleDataSource` と同じ置き方。client の受け渡しを増やさない） |
| メモリ上の実装 | `InMemoryScheduleDataSource` に `State.sleepRecords` と `SleepDataSource` の extension。**`-mock-day` で睡眠タブの書き込みが予定タブに出るように同じ state を共有する**（ジムの `workoutSetTimes` が `-mock-workout` と別データになっている既知の問題を睡眠では作らない）。重なり・24 時間・スコアの検査も同じ規則で持つ |
| `Services/SleepStore.swift`・`Views/Sleep/*` | 睡眠タブ（UI 担当の案に従う） |
| テスト | `SleepNightTests`（N1・分類・まとめ・重なりの対応付け・世代が変わった夜・除外日・2 件・時計の時刻の解釈）、InMemory の書き込みの規則 |

### 7-2. 未 commit の段階 2 実装で作り直す範囲（ファイル単位）

| ファイル | 変更 |
|---|---|
| `Models/ActualTask.swift` | `sleepScore` と `sleep_actual_input` の埋め込みの decode / encode を削除（約 20 行） |
| `Models/CheckIn.swift` | `CheckInOperation.set` の `sleepScore` を削除、`CheckInRuleError.scoreNotSleep` → 「睡眠は睡眠タブで」に置き換え、`acceptsActual` の睡眠分岐（睡眠は実績欄を出さない＝false に）、`CheckInSlot.isSleep`、`actualLine` の睡眠分岐（`SleepNight` の結果から作る形に）。`showsCircle`・`circleStyle` の睡眠（丸なし・幅だけ取る）は残す |
| `Services/SupabaseDayDataSource.swift` | 実績の select を `*` に、`p_sleep_score` を削除、`sleep_record` の取得を 1 本足す |
| `Services/InMemoryScheduleDataSource.swift` | スコアの検査 → 睡眠の拒否（`checkin_set`・`actual_save` と同じ）、`-mock-day` の初期データの睡眠の実績（一昨日の夜 23:40–7:10・スコア 4）を `sleepRecords` へ |
| `Services/ScheduleStore.swift` | `.set` の `sleepScore` 引数（1 か所） |
| `DayBuilder/Day.swift`・`DayBuilderContext.swift`・`TemplateVersions.swift`（`context(...)` の引数） | `sleepRecords` を足す（既定値付き） |
| `Views/Home/ScheduleEntryEditView.swift` | `SleepActualSection`（約 50 行）と睡眠のスコア・就寝起床の state・保存の分岐を削除。睡眠の行を開いたときの実績の見せ方は UI 担当の案 |
| `Views/Home/ScheduleListView.swift`・`HomeView.swift` | 睡眠の行の 3 行目を `SleepNight` の結果から |
| `Views/Home/ActualEntryEditView.swift` | 種類の選択肢から睡眠を外す |
| `LifeTrackerTests/ScheduleStage2Tests.swift` | `SleepCheckInTests` の 3 件（0 時過ぎの就寝・今夜の回・睡眠の記録を消す）を睡眠の新しいテストへ移す（`nearestAndEnd` は睡眠に依らないので残す）、スコアの拒否のテストを睡眠の拒否に、**睡眠の行をチェックインの例に使っている場面（予定の削除で done が予定外に残る・「これ以降」削除で skipped が消える、240・289〜290 行あたり）は種類をジム等に替える**（睡眠の拒否で落ちるため） |
| docs | walkthrough（段階 2 確定仕様の睡眠・旧列削除 0009）、`domain-model.md`（サブ入力の `sleep_actual_input` を消し `sleep_record` を足す、「sleep day attribution は HealthKit 同型を Phase 2 で採用予定」を N1＋分類に書き換え）、`structural-conventions.md` D-4（睡眠は予定とつながない側＝完全独立の例） |

段階 2 の睡眠以外（丸・スキップ・予定外・ジム・予定の RPC の実績の扱い）は変えない。

## 8. コストとリスクのまとめ

| 項目 | コスト | リスク・未確認 |
|---|---|---|
| sleep_record（EXCLUDE 付き） | migration 1 本（約 45 行） | Supabase で gist の EXCLUDE が作れるか【推測: 素の Postgres 16 で拡張なしに作れたので作れる】。PostgREST が 23P01 をどの HTTP 状態で返すか（409 の想定【推測】）は本番適用後に 1 回確かめる |
| 夜の日を保存しない | pure 関数とテスト | 境界（18:00 / 6:00 / −12h）は本人の生活に合わせた既定。外れたら定数を変えるだけ |
| 予定タブの重なり判定 | 取得 1 本＋pure 関数 | 予定の時間帯から完全に外れた睡眠（徹夜明けの朝寝など）は予定の行の実績に出ない（昼寝扱い）。出したいなら「行の前後 N 時間まで広げる」に変える（データは同じ） |
| 0007 の書き換え | 差分 約 30 行 | 先に旧 0007 を当てた場合の 9 引数の DROP（§5-1） |
| 旧表の DROP | 砦付き | 砦が働いたら（行があったら）データを sleep_record に移す手順を足してから流し直す |
| 作り直し | §7-2 の 12 ファイル＋テスト | 単体テスト 169 件のうち睡眠を例に使ったものが落ちる。直してから全件を流す |

## 9. 本人に聞く論点（データ側から。統合で 1 問ずつにする）

1. 昼寝も記録するか（P1 同じ表で時刻から分ける・推奨／P2 毎回選ぶ／P3 記録しない）
2. 夜の睡眠を何日の分として並べるか（N1「9/30 の夜」= 予定と同じ数え方・推奨／N2「10/1 に起きた分」）。表示の文言だけの違いにもできる（どちらも保存しないので後で変えられる）
3. 予定の時間帯から外れた睡眠（例: 徹夜明けの 8:00〜13:00）を予定タブの睡眠の行の実績に出すか（出さない・推奨／前後に広げて出す）
