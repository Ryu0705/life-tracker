# 段階 2（チェックイン＝予実の記録）設計レビュー — UI から DB まで

作成: 2026-09-30 / 対象: `docs/day-cycle-walkthrough.md`「段階 2 チェックイン」「段階 2 確定仕様」（C1〜C6 は本人決定。覆さない。見るのは決定を実現する AI の詰め＝列・制約・RPC・画面の振る舞い）
読んだもの: 同ファイルの「段階 1 確定仕様」「段階 1 実装メモ」、`supabase/migrations/0001・0003・0005・0006`、`Sources/DayBuilder/*`、`Services/ScheduleStore.swift`・`SupabaseDayDataSource.swift`・`InMemoryScheduleDataSource.swift`・`ScheduleDataSource.swift`、`Views/Home/HomeView.swift`・`ScheduleEntryEditView.swift`・`ScheduleListView.swift`、`Models/ScheduleOperation.swift`・`ActualTask.swift` ほか Models、`LifeTrackerApp.swift`、トレーニング側 store（`WorkoutSessionStore` / `WorkoutHistoryStore` / `SupabaseWorkoutDataSource`）、`ScheduleStage1Tests.swift`、`structural-conventions.md`、`domain-model.md`、段階 1 の 2 本のレビュー
検証方法:
- 本番 DB は **読み取りだけ**（MCP `execute_sql` の SELECT）: 制約名・索引・関数一覧・件数。actual 系（actual_task・scheduled_task・sleep_actual_input・workout_session・workout_set）は 0 件、task_template 2・世代 2・pattern 1・category 2・exdate 0・day_meta 0 を確認
- **手元の使い捨て Postgres 16**（docker `postgres:16-alpine`、終了後に破棄）に 0001→0002→0003→0005→0006 を流し、本番と同じ 2 件を入れたうえで、確定仕様の DDL を**書かれたとおり**に当てて 9 場面を試した（下の【検証済み】はその結果。スクリプトは scratchpad `stage2_check.sql`）
- コード・DB・migration は書き換えていない
表記: 【事実】= コード・文書・DB で確かめたこと。【検証済み】= 使い捨て DB で実行した結果。【推測】= 確かめていない見立て。**本人判断** = 決定の文言に関わる／好みの問題

## 0. 先に結論

- **骨格（実績に「系列 id＋回の日」、状態の列、丸 1 タップ、ジムは表示時判定、＋メニュー）は成立する**。DDL は書かれたとおりに Postgres に通り、SET NULL で CHECK 違反になって削除が失敗することは**ない**（§2、検証済み）
- ただし **このまま実装に入ると 4 つ踏む**（重大度 高）
  1. **単発 ↔ 繰り返しの変換で実績のつながりが外れる**（§1-2、検証済み）。今日「読書」に丸を付けてから曜日を付けると、丸が空に戻り、下に同じ読書が「予定外の実績」として並ぶ。逆（繰り返しをやめる）も同じ。→ 段階 1 の RPC 2 本で実績を**つなぎ直す**
  2. **スキップ行が孤児になる**（§2-2、検証済み）。系列ごと削除・単発削除の SET NULL で「状態 = スキップ・つながりなし・時刻なし」の行が残り、一覧に出せず消せない。→ 予定の行を消す RPC はスキップ行を**先に消す**＋「スキップはつながり必須」の CHECK を足して砦にする
  3. **時刻の重なりで actual_task を取る今の取得条件では、スキップ行（時刻 NULL）と、0 時過ぎに寝た睡眠の実績（回の日 ≠ 開始の日）が取れない**（§3-1）。→ `occurrence_date` を全行必須にして「一覧に出る日」の意味で持ち、`occurrence_date IN (D-1, D)` で取る
  4. **`ActualTask.startAt/endAt` が non-optional のままだとスキップ行 1 件でその日の読み込み全体が失敗する**（§1-4）
- 決定文言と規約の食い違いが 1 つ: C1 は `structural-conventions.md` D-4「actual_task に scheduled_task_id 列や FK を追加しない／RPC で一方が他方を書かない」と `domain-model.md`「予実紐付けなし」に反する。決定は本人のものなので**規約側を書き換える**（本人に報告。§7）
- 本人判断が要るのは実質 2 点だけ（§8）。残りは AI の詰めで直せる

## 1. 実績と回のつなぎ（特に見てほしい点 1）

記法: T = 系列（task_template.id）、D = 日（JST）、O(D) = その日だけ変えた回の実体、X(D) = 除外日、S = 単発（scheduled_task, template_id NULL）、A(T,D) = 実績（template_id = T, occurrence_date = D）、A(S) = 実績（scheduled_task_id = S）

### 1-1. 【確認 OK】段階 1 の操作の後もつながりが保たれるもの
| 段階 1 の操作 | 実績への影響 | 一覧 |
|---|---|---|
| この予定で保存（`schedule_occurrence_save`、O(D) の作成／書き換え） | A(T,D) はそのまま。O(D) の id は使わない（設計どおり template_id＋日でつなぐ） | 新しい予定時刻の下に「実績 6:45–7:30」が出る。妥当 |
| これ以降で保存（`schedule_template_save_following`、名前・時刻だけ） | O(D) が消えるが A(T,D) は無関係。世代の id も使わない | 変わらない |
| これ以降で削除・終了の世代が残る場合 | T は残る。A(T, d ≥ D) のうち done は残る。回は出なくなる | done は「予定外の実績」として出る（設計どおり）。skipped は §1-3 |
| これ以降で削除・系列ごと消す場合（最初の世代 ≥ D） | FK SET NULL で A(T,D).template_id = NULL、occurrence_date は残る | done は予定外の実績として出る（設計どおり）。skipped は §2-2 の孤児 |
| この予定で削除（X(D)） | A(T,D) は残る（T は生きている） | done は予定外の実績として出る。skipped は設計どおり消す（RPC に追加が要る） |
| 単発の書き換え（`schedule_single_save` の UPDATE） | id が変わらないので A(S) はそのまま。日付も変えない（実装メモ） | 変わらない |
| 単発の削除 | SET NULL | done は予定外の実績。skipped は孤児（§2-2） |

【事実】`0006_template_version.sql:210-212, 227-229, 234, 298-300` の DELETE はすべて scheduled_task か task_template に対するもので、actual_task には触れない。上の表はそこから追った

### 1-2. 【高・検証済み】単発 → 繰り返し、繰り返し → 単発の変換で実績のつながりが外れる
- **手順 A（単発 → 系列）**: 今日 ＋ で単発「読書 14:00–15:00」→ 丸を押す → A(S) ができる（done）。夕方、行を開いて曜日を付けて保存 → `SchedulePlanner.save` は `.createSeries(replacingSingle: S)`（`ScheduleOperation.swift:146-149`）→ RPC `schedule_template_create(p_replace_single_id = S)` が `schedule_single_delete(S)` を呼んで単発を消す（`0006:160-162`）
- **結果 A**【検証済み D】: A(S).scheduled_task_id が SET NULL で落ち、template_id も無い → **予定外の実績**になる。新しい系列 T の今日の回（仮想）は A(T, 今日) が無いので**丸が空**。一覧には「読書 14:00–15:00 ›（空の丸）」と「読書 14:00–15:00（塗りの丸・予定外）」が 2 行並ぶ
- **手順 B（系列 → 単発）**: 今日の系列の回に丸 → A(T,今日)。曜日を全部外して保存 →「繰り返しをやめる」→ `schedule_template_end_to_single` = `delete_following(T, 今日)` ＋ `single_save`（`0006:252-260`）
- **結果 B**【検証済み E】: 最初の世代が今日以降なら系列ごと消え SET NULL、そうでなければ終了の世代が残り A(T,今日) は「回の無い done」。どちらでも**新しい単発 S′ にはつながらない** → 単発の丸は空、旧実績は予定外として 2 行
- **なぜ**: 決定 C1「予定が消えても実績は残し、つながりだけ外す」を FK の SET NULL だけで実現している。変換は「予定が消える」のではなく「同じ回の持ち方が変わる」ので、外すのではなく**つなぎ直す**のが決定の趣旨に合う
- **直し方（AI の詰め）**: 段階 2 の migration で 2 関数を `CREATE OR REPLACE`
  - `schedule_template_create`: `p_replace_single_id` があるとき、**単発を消す前に** `SELECT id INTO v_actual FROM actual_task WHERE scheduled_task_id = p_replace_single_id`、系列を作った後に `UPDATE actual_task SET scheduled_task_id = NULL, template_id = v_template_id, occurrence_date = p_date WHERE id = v_actual`（SET NULL が先に走ると行を見失うので順序が要る）
  - `schedule_template_end_to_single`: `delete_following` を呼ぶ前に `SELECT id INTO v_actual FROM actual_task WHERE template_id = p_template_id AND occurrence_date = p_date`、単発を作った後に `UPDATE actual_task SET template_id = NULL, scheduled_task_id = v_single WHERE id = v_actual`（occurrence_date は残す）。`delete_following` がスキップ行を消す処理（§2-2）を持つと A が消えてしまうので、**つなぎ直す行は消す対象から外す**（done も skipped も）
  - モック（`InMemoryScheduleDataSource.apply` の `.createSeries` / `.endSeriesToSingle`）にも同じ規則。テスト: 「変換の前後で D の行数 1・丸の状態が保たれる」を done / skipped の両方で
- 本人への注記: 決定 C1 の「つながりだけ外す」は「予定そのものが無くなったとき」に限り、変換では「つなぎ直す」と読む（§8-2）

### 1-3. 【中】「これ以降」保存で曜日・祝日を変えて今日の回が出なくなったときのスキップ行
- **手順**: 火曜の朝、ジムを右スワイプでスキップ → A(T,今日) = skipped。夕方、行を開いて曜日を「月・水・金」に変える（確認なしで「これ以降」）→ 今日（火）のジムは出なくなる
- **結果**: A(T,今日) は skipped のまま残るが、それを付ける回が無い。一覧は「回がある行にだけ丸を付ける」ので出ない（実害なし）。分析が skipped を数えると「無い回を未達」に数える
- **直し方**: `save_following` で skipped を消すのは **やらない**（同じ RPC を名前・時刻だけの変更でも使う。そのとき今朝のスキップが黙って消えるほうが害が大きい。曜日・祝日の評価を SQL でやるのは HolidayJp が無いので無理）。代わりに **読む側の規則**を 1 つ決めて書く: 「skipped は、その日の組み立てに回があるときだけ意味を持つ。回が無い skipped は一覧にも分析にも出さない」。同じ規則で X(D) の後の skipped も扱えるが、`schedule_occurrence_delete` は T と D を知っているので設計どおり消してよい（安い）
- 本人への注記: 決定 C2 補足「スキップの行は消す（予定のないスキップは意味がない）」の適用範囲を「予定の行を消す操作（単発削除・系列ごと削除・この予定の削除）」に限り、曜日変更で回が出なくなった場合は読む側で無視、と読み替える（§8-2）

### 1-4. 【高】Swift 側: `ActualTask` の時刻が non-optional のままだと、スキップ行 1 件でその日の読み込みが全部失敗する
- 【事実】`Models/ActualTask.swift:3-9` は `startAt: Date` / `endAt: Date`。`SupabaseDayDataSource.loadDayContext` は 7 本を `try await (…)` でまとめる（`SupabaseDayDataSource.swift:76-84`）ので、actual_task の decode が 1 行でも失敗すると `days[day]` が入らず「読み込みに失敗しました」になる
- 【事実】今の本番ビルド（段階 1 まで）は時刻の重なりで取る（`:69-74`）ので、NULL 時刻の行はそもそも取れず壊れない。壊れるのは新ビルドで取得条件を変えた後（§3-1）
- **直し方**: `startAt` / `endAt` を optional にし、新列（`status` / `templateId` / `occurrenceDate`（`@DateOnly`）/ `scheduledTaskId`）を足す。`DayBuilder.build` の actual の合成（`DayBuilder.swift:85-102`）は done 行だけを対象にし、skipped は別の経路（§5-1）。`MockDayDataSourceTests.swift:81` の `ActualTask(...)` 初期化子と `LifeTrackerTests` の actual を使う T テストは、引数追加で直す（既存テストの期待値は変えない）

### 1-5. 【低】回の同一性の定義を 1 か所に固定する
- 回のキー = 繰り返しなら `(task.templateId, calendar.startOfDay(task.startAt))`、単発なら `task.id`。仮想の行（`isVirtual`）でも O(D) でも同じ式で出る（O(D) は `p_date + minutes` で作るので start_at の JST 日 = D。`0006:272-285`）。前日から続く行は startAt が D-1 なのでキーの日も D-1 になり、「丸は前日の回」が自動で満たされる
- 【推測】SQL 側の `(start_at AT TIME ZONE 'Asia/Tokyo')::date` と Swift 側の `startOfDay`（Asia/Tokyo の Calendar、`HomeView.swift:175-179`）は同じ日を返す（日本に夏時間は無い）
- pure 関数 1 つ（例 `CheckInKey.of(row)`）にして、店（store）・行・RPC 引数の 3 か所がそれを使う。テストで「仮想／O(D)／前日継続／単発／祝日パターン経由」の 5 種でキーが期待どおりであることを固定する

## 2. 制約と FK（特に見てほしい点 2）

### 2-1. 【検証済み】SET NULL と CHECK の組み合わせで削除は失敗しない
- 確定仕様の CHECK 3 本は、SET NULL で列が NULL になる方向に対してすべて真になる: `occurrence_chk` は `template_id IS NULL OR …` なので template_id が NULL になれば通る。`link_chk` も同じ。`time_chk` は template_id / scheduled_task_id を見ない
- 【検証済み C2・D・E】系列ごと削除・単発削除の SET NULL は skipped 行・done 行のどちらでも成功した
- 【検証済み A2】確定仕様の `ALTER TABLE`（列追加・NOT NULL 解除・CHECK 追加を 1 文）はそのまま通る。1 文の中で追加した `status` を後半の CHECK が参照しても問題ない
- 【検証済み B】既存 CHECK `end_at > start_at` を残したままでも、時刻 NULL のスキップ行は入る（CHECK は NULL を通す）。つまり残しても壊れないが、冗長なので消す（§6-2）

### 2-2. 【高・検証済み】失敗しないことが問題: スキップ行が「つながりなし・時刻なし」の孤児になる
- **手順**: 今日から始まる系列（勉強）を作り、今日の回を右スワイプでスキップ。同じ日に「これ以降」で削除（最初の世代 = 今日なので系列ごと消える）
- **結果**【検証済み C2】: actual_task に `status = skipped, template_id = NULL, scheduled_task_id = NULL, start_at = NULL` の行が残る。一覧の「予定外の実績」は時刻順に並べるが時刻が無く、丸で消すにも回が無い。**見えない・消せない行**が本番に積もる。単発の削除でも同じ（A(S) が skipped のとき）
- **直し方（AI の詰め。2 段）**:
  1. 予定の行を消す RPC はスキップ行を**先に**消す: `schedule_single_delete` に `DELETE FROM actual_task WHERE scheduled_task_id = p_id AND status = 'skipped'`（ただし §1-2 の変換経由では呼び出し側でつなぎ直す行を除く＝関数を分けるか、引数で「保持する actual id」を渡す）。`schedule_template_delete_following` に `DELETE FROM actual_task WHERE template_id = p_template_id AND occurrence_date >= p_date AND status = 'skipped'`（系列ごと消す前・終了の世代を作る前のどちらでも）。`schedule_occurrence_delete` に `… AND occurrence_date = p_date AND status = 'skipped'`
  2. 最後の砦として CHECK を 1 本足す: `CONSTRAINT actual_task_skip_needs_link CHECK (status <> 'skipped' OR template_id IS NOT NULL OR scheduled_task_id IS NOT NULL)`。これを入れると、1 を忘れた経路（MCP の直接 DELETE を含む）では SET NULL の瞬間に CHECK 違反で**削除が止まる**＝孤児は構造的にできない。「DB 制約は最後の砦」の方針どおり。代償は「skipped が残っていると task_template / scheduled_task を直接消せない」だが、それは望む挙動
- モックにも同じ規則（`deleteSingle` / `deleteFollowing` / `.deleteOccurrence` でスキップを消す・変換では残す）

### 2-3. 【中】`occurrence_date` を全行必須にする（`occurrence_chk` の置き換え）
- 今の案は「template_id があれば occurrence_date 必須」だけ。scheduled_task_id の行と予定外の行は日を持たない。§3-1 のとおり取得を日で行うには全行に要る
- **直し方**: `occurrence_date DATE NOT NULL`。意味は「一覧に出る日（JST）」= 繰り返しの回はその回の日、単発は単発の日、予定外は開始時刻の JST 日（`actual_unplanned_save` が `(p_start AT TIME ZONE 'Asia/Tokyo')::date` で入れる）。`occurrence_chk` は不要になる。SET NULL は occurrence_date に触れないので、つながりが外れた後も同じ日に出続ける（決定 C1「実績は残す」のとおり）
- 索引: `(occurrence_date)` を 1 本（日ごとの取得用）。FK の SET NULL は部分一意索引 `(template_id, occurrence_date)` / `(scheduled_task_id)` の先頭列で引けるので追加不要

### 2-4. 【確認 OK】一意制約と CASCADE
- 【検証済み C1】`actual_task_occurrence_unique` は同じ回の 2 行目を止める。【検証済み H】`sleep_actual_input` の `sleep_score_range` は 6 を止め、actual_task の DELETE で CASCADE する（`0001:138-142` の FK）
- 【事実】`workout_session.actual_task_id`（`0003:79`）は C4「実績の行は書かない」により**当面使わない**。列は残してよい（消すと後で「セッションと実績を結ぶ」余地が減る）。`domain-model.md` に「段階 2 では未使用」と書く

### 2-5. 【低】RPC 側の砦（CHECK で書けないもの）
- `checkin_set` の先頭で: (a) `(p_template_id IS NULL) = (p_scheduled_task_id IS NULL)` なら例外（つながりは丁度 1 つ。予定外は別関数）、(b) `p_scheduled_task_id` が `template_id NOT NULL` の scheduled_task（= O(D)）を指していたら例外（O(D) は template_id＋日でつなぐ決まり。クライアントのバグで単発扱いにすると「これ以降」保存の O(D) 削除でつながりが落ちる）、(c) `p_occurrence_date > jst_today()` なら例外（UI は明日以降に丸を出さないが、端末時計のずれを止める）、(d) `p_status = 'skipped'` なら時刻を NULL に正規化してから INSERT（クライアントが時刻を送っても `time_chk` で落とさない）、(e) `p_sleep_score` は種類の `sub_input_kind = 'sleep'` のときだけ受け、それ以外は例外。skipped なら sleep_actual_input を消す
- 【検証済み F/F2】`INSERT … ON CONFLICT (template_id, occurrence_date) WHERE template_id IS NOT NULL DO UPDATE` と `ON CONFLICT (scheduled_task_id) WHERE scheduled_task_id IS NOT NULL DO UPDATE` は SQL 側では書ける（PostgREST の upsert が書けないだけ）。段階 1 の UPDATE → INSERT より短く、2 端末の競合でも一意違反にならない

## 3. 前日から続く睡眠・日付をまたぐ回・JST（特に見てほしい点 3）

### 3-1. 【高】取得条件を「時刻の重なり」から「回の日」に変える
- 【事実】今の取得は `start_at < D+1 0:00 AND end_at > D 0:00`（`SupabaseDayDataSource.swift:69-74`、モックは `InMemoryScheduleDataSource.swift:61`）
- 取れないもの 2 つ:
  1. **スキップ行**（時刻 NULL。NULL の比較は偽）
  2. **0 時過ぎに寝た睡眠**: 9/30 の睡眠の回（23:00–7:00、occurrence_date = 9/30）を「就寝 0:30・起床 7:30」で記録 → start_at は 10/1 0:30。9/30 の一覧（9/30 に重なる実績）には出ず、9/30 の睡眠の丸が空のまま。10/1 の一覧には「前日から継続」行の丸として付くべきだが、キーは (T, 9/30) で 9/30 の実績なので、10/1 側で時刻の重なりから取っても回と結び付かない
- **直し方**: `occurrence_date IN (D-1, D)` で取る（§2-3 で全行に日を持たせる前提）。D-1 の分は「前日から続く行」の丸と、予定外の実績の流入（`computeMembership` で clip、重ならなければ落ちる）に使う。時刻の重なり条件は外す
- モックも同じ条件に（`loadDayContext` の `actualTasks` の filter）

### 3-2. 【中】実績の時刻入力: 時計の時刻（hh:mm）を、どの日の時刻と解釈するかの規則が無い
- 【事実】編集画面の時刻は `DatePicker(.hourAndMinute)` で 0 時からの分を持つ（`ScheduleEntryEditView.swift:244-255`）。予定側は「終了 ≤ 開始なら翌日」で済む（`ScheduleRepeat.duration`）が、実績は**開始が翌日に落ちる**ことがある（上の 0:30 就寝）
- 起きること: 9/30 の睡眠の実績欄に開始 0:30 と入れると、素直な実装は 9/30 0:30（その日の朝）にする → 記録が 23 時間ずれる。終了 7:30 は「開始より後」なので 9/30 7:30 → 実績が 0:30–7:30 の**朝**になる。誤りに気づけない
- **直し方（AI の詰め・pure 関数＋テスト）**: 実績の開始 = 予定の開始 ±12 時間の窓で、その時計の時刻に最も近い時刻（予定 9/30 23:00・入力 0:30 → 10/1 0:30。入力 22:30 → 9/30 22:30。予定 6:45・入力 5:30 → 同日 5:30）。終了 = 開始より後で最初にその時計の時刻になる時刻（24 時間以内）。開始 = 終了は保存不可（予定と同じ）。予定外の実績は「見ている日 D の時刻」を基準に同じ規則。画面の footer に「翌日」を出す（予定の `timeSummary` と同じ）

### 3-3. 【確認 OK】JST
- 【事実】Swift は Asia/Tokyo の Calendar と `DateOnly.formatter`（JST）、SQL は `jst_today()` と `AT TIME ZONE 'Asia/Tokyo'`。【検証済み I】セッション TZ が UTC でも `jst_today()` は JST の日を返す。端末が海外にあってもアプリは JST で動く（設計どおり）
- 実績の時刻は絶対時刻（timestamptz）で送る。RPC で「日＋分」から組み立てない（実績は回の日をまたぐため）。JSON は `supabaseTimestampFormatter`（UTC・Z・小数秒）で送ればそのまま timestamptz に入る

### 3-4. 【低】今日の一覧には睡眠の丸が 2 つ並ぶ
- 朝の一覧: 最上段「0:00–7:00 睡眠 前日から継続」（丸 = 昨夜 = 9/29 の回）と最下段「23:00–7:00 睡眠 翌日へ継続」（丸 = 今夜 = 9/30 の回。「今日のこれからの回は押せる」（AI 既定）により押せる）。今夜の分に朝から丸を付けても意味は無く、誤タップの余地がある
- 仕様どおりなので変えなくてよいが、**本人に一言確認**（§8-3）。押せるままにするなら、2 行目の「前日から継続」「翌日へ継続」の印（既存）で見分ける

### 3-5. 【低】明日以降を見ているときの「前日から続く」行（今夜の回）
- 「明日以降は丸なし」（C3）と「丸は前日の回」（C5）がぶつかる: 10/1 を見ると最上段は 9/30 23:00 の回（今日の回）。丸を出すか。**AI 既定案: 丸の有無は見ている日ではなく回の日で決める**（回の日 ≤ 今日なら出す）。これなら 10/1 の朝の行だけ丸が出て、今日の一覧の最下段と同じ状態を指す。文で 1 行明記する

## 4. ジムの表示時判定と手動の実績の共存（特に見てほしい点 4）

### 4-1. 【中】予定タブにトレーニングのデータ経路が無い
- 【事実】`HomeView` は `DayDataSource` と `ScheduleDataSource` だけ受ける（`HomeView.swift:18-24`、`LifeTrackerApp.swift:18-24`）。`ScheduleStore` は workout_set を読まない。`WorkoutHistoryStore` は週単位で `fetchSets(completedFrom:to:)` を持つ（`WorkoutHistoryStore.swift:44-63`）が、トレーニングタブの `WorkoutView` が別に作る store で共有されていない
- **直し方**: `loadDayContext` に 8 本目として `workout_set` を `completed_at >= D 0:00 AND < D+1 0:00`（既存 `fetchSets(completedFrom:to:)` と同じ形。件数は 1 日ぶん）で取り、`DayBuilderContext` に `workoutSetTimes: [Date]`（completed_at だけ）を足す。集計（あるか・最初〜最後）は pure 関数。PostgREST の集計（min/max）は使わない（Supabase 既定では無効【推測】。行を取って端末で計算する）
- `-mock-day` のモックにセットを持たせる（例: 2 日前の平日 6:50〜7:35 に 3 セット、今日はセットなし）。`-mock-workout` と `-mock-day` は独立の引数なので、`-mock-day` だけのときは予定側モックのセットを使う、と決めて `LifeTrackerApp.swift:68-80` に書く
- **タブ切替後の古さ**: トレーニングタブで ✓ を押しても予定タブの今日はキャッシュのまま（`ScheduleStore.days`）。丸が空のまま見える → 予定タブに戻ったとき（`.task(id:)` / `onAppear`）に**今日だけ**読み直す（過去日はキャッシュのまま）。`refreshable` は既にある

### 4-2. 【低】判定の細則（AI 既定を文で固定する）
- 「セットがある」= その日（JST）に `completed_at` を持つ workout_set が 1 件以上（ウォームアップも含む。`workout_training_day` の view と同じ数え方）
- 時刻 = 最初の `completed_at` 〜 最後の `completed_at`。セット 1 件なら「実績 6:50–6:50」になるので、1 件のときは時刻を出さない（トレーニングの `timeRangeText` は 2 件以上で出す。`WorkoutSummary.swift:26-33` と同じ）。`workout_session.started_at` を開始に使う案もあるが、最初の ✓ の時刻で作られる（`WorkoutSessionStore.swift:255-269`）ので差はほぼ無い
- 手動 done 行とセットの併存: 表示はセット優先（設計どおり）。丸は disabled（A-4 の 3 点セット。「押しても変わらない Button」を置かない）。手動行はそのまま残る（記録時の後始末はしない＝C4 の B 案の却下理由と整合）
- 同じ日にジムの回が 2 つ（系列＋単発など）: 両方に同じ時刻が付く（設計どおり）。近いほうに寄せる細工はしない
- **分析で必要になる優先順（今書いておく）**: ジムの回の状態 = セットあり → done（時刻はセット）／セットなし → 実績の行（done / skipped）／どちらも無し → 記録なし。**skipped の行があってもセットがあれば done**（設計の「スキップ後にセットがあればやった」を分析にも適用）

## 5. 画面（特に見てほしい点 5）

### 5-1. 【中】行の構造: 今の行は `Button` 1 個で、丸を中に入れると入れ子になる
- 【事実】`HomeView.row` は行全体を `Button { editing = target } label: { ScheduleRow }.buttonStyle(.plain)` にし、trailing の `swipeActions` に削除（`HomeView.swift:129-153`）。行は `accessibilityElement(children: .combine)`（`ScheduleListView.swift:50`）
- 入れ子の Button は「外側の押下ハイライトが内側のタップでも出る」「VoiceOver で丸が行に溶ける」が起きる【推測。A-1 は NavigationLink の話だが同種】
- **直し方**: 行を `HStack { 丸の Button(.borderless) ; 本体 }` にし、本体側だけを編集の入口にする（本体は `Button` のまま `.buttonStyle(.plain)`、丸は `.buttonStyle(.borderless)` で別々に反応させる）。accessibility は `.combine` をやめ、丸に `accessibilityLabel("やった／記録なし／スキップ")`、本体は今のまま。丸の当たり判定は 44pt。シミュレータでは idb の `ui tap` で確かめる（Toggle は効かなかったが Button は効く。memory）
- 丸の状態表示は pure 関数（回 → 記録なし／やった／スキップ／セットあり）にしてテストする

### 5-2. 【中】過去日の行は今 `Button` でない。段階 2 では押せる必要がある
- 【事実】`SchedulePlanner.editTarget` は過去の回で nil を返し（`ScheduleOperation.swift:186-202`）、nil なら行は `content` だけ（`HomeView.swift:150-152`）
- 段階 2 の「過去日は同じ画面で予定の欄は読むだけ・実績欄だけ入力可」には、過去の回を開く別の対象が要る。`ScheduleEditTarget.kind` に `.readOnlyOccurrence` / `.readOnlySingle` を足すか、`ScheduleEditTarget` に `canEditPlan: Bool` を持たせる。**C-5 の「デフォルト引数なし」**を適用（編集画面は `canEditPlan` を必須引数で受け、名前・種類・時刻・繰り返し・削除の 5 要素をすべてゲート）
- 前日から続く行を過去日で押したとき: 「前日の回の実績を開く」（設計）。今の `editTarget` は前日が過去なら「同じ系列のその日の回」を開く（U-2）。段階 2 では**実績の対象は前日の回**、予定の欄は前日の回を読むだけ、で 1 画面。題名は「9/29(火) の予定」

### 5-3. 【中】`ScheduleStore.perform` は保存中の 2 回目を黙って捨てて「成功」を返す
- 【事実】`guard !isSaving else { return nil }`（`ScheduleStore.swift:116`）。戻り値 nil は呼び出し側で成功扱い（`HomeView.run`、`ScheduleEntryEditView.run`）
- 段階 1 では保存ボタンが disabled なので踏まない。段階 2 の丸は「押す → もう一度押して戻す」が自然な操作で、1 回目の RPC 中に 2 回目が来る → 2 回目が捨てられ、丸は「やった」のまま。ユーザーには「戻らない」に見える
- **直し方**: チェックインは `perform` と別の軽い経路にする: (1) 丸を押した瞬間に表示を先に変える（楽観更新）、(2) RPC、(3) 失敗なら戻して footer に赤字、(4) 読み直しは**見ている日だけ**（前日継続の丸は D-1 の実績なので D の読み直しで足りる。`occurrence_date IN (D-1, D)` で取るため）。同じ回への連続タップは直列化（Task を回ごとに持つ）か、応答までその丸だけ disabled。`isSaving` の guard に入ったときは nil でなくエラーを返す

### 5-4. 【低】丸・左右スワイプ・行タップの割り当て
| 行 | 丸（左） | 左→右スワイプ（leading） | 右→左スワイプ（trailing） | 本体タップ |
|---|---|---|---|---|
| 今日の回 | 記録なし⇄やった | スキップ／スキップを取り消す | 削除（この予定／これ以降） | 編集（＋実績欄） |
| 今日の前日から続く行 | 前日の回 | 前日の回のスキップ（**出す**。対象が丸と同じで曖昧でない。段階 1 の「出さない」は削除の話） | なし（段階 1 どおり） | 今夜の回を開く（段階 1 どおり）。実績欄は？ → **前日の回の実績**を同じ画面の実績欄に出す（今夜の回の実績欄は空）。分かりにくければ、前日継続の行のタップは「前日の回を読むだけ＋実績欄」にする（本人の好み。AI 既定は前者） |
| 過去日の回 | 記録なし⇄やった | スキップ | **なし** | 読むだけ＋実績欄 |
| 明日以降の回 | なし | なし | 削除 | 編集 |
| 予定外の実績（どの日でも） | 塗り・disabled | なし | 削除（`actual_delete`） | 名前・種類・時刻の編集 |
| ジムでセットあり | 塗り・disabled | なし（スキップしてもセット優先で意味が無い） | 今日・未来なら削除 | 編集 |
- SwiftUI の `List` は leading / trailing の `swipeActions` を同時に持てる。`allowsFullSwipe: false` を両方に（トレーニングと同じ）
- **iOS リマインダーとの整合【事実は本人の録画と一般知識、leading スワイプの標準挙動は未検証】**: 「左の丸 1 タップで完了、もう一度で戻す」「本体タップで編集」は同じ。違い: リマインダーは完了した項目を既定で隠す（Life Tracker は 1 日の一覧なので隠さない＝正しい）。「スキップ」はリマインダーに無い独自の操作。**予定外の実績の丸が塗りで押せない**のは「丸 = 状態の表示」としては通るが、押せる丸と押せない丸が混ざる。予定外の行は丸の代わりに「実績」の小さな印にする案もある（本人の好み。AI 既定は塗り・disabled のまま）

### 5-5. 【低】右上 ＋ とその他
- 【事実】＋ は `.disabled(!canEdit)`（`HomeView.swift:39-46`）。過去日で「やったことを記録」を出すには disabled を外し、`Menu`（今日）／直接（明日以降・過去日）の 3 分岐にする。過去日の空の一覧の文言「この日の予定はありません」に「＋ でやったことを記録できます」を足す
- 予定外の実績の編集・削除 RPC は `actual_unplanned_*` でなく **`actual_save` / `actual_delete`（つながりの有無を問わない）**にする。理由: X(D) の後や終了の世代の後の done 行は template_id が残ったまま「予定外」として出る（§1-1）。その行をスワイプで消すとき、つながりの検査があると消せない。編集ではつながり列に触れない（名前・種類・時刻だけ UPDATE）
- 予定外の実績の名前・種類は必須（実績の CHECK では担保できないので `ScheduleStore.validate` と同じ検査）
- 週帯の点は段階 2 でも出さないか、「実績（done）のある日」に使うか（U-15）。任意。出すなら「トレーニングの点 = 記録がある日」と意味が揃う
- 「現在進行中」カード・ウィジェット・Live Activity は変えない（設計どおり）。C-8 の「actual 駆動表示」はまだ使わない

## 6. RPC の引数と PostgREST・migration の順序（特に見てほしい点 6）

### 6-1. 【中】RPC の引数設計
```sql
-- 回の実績を作る／書き換える。戻り値 = actual_task.id
checkin_set(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid,
            p_status text, p_name text, p_category_id uuid,
            p_start timestamptz, p_end timestamptz, p_sleep_score int) RETURNS uuid
-- 回の実績を消す (記録なしに戻す)。キーで消す (id でなく) = 端末のキャッシュが古くても冪等
checkin_clear(p_template_id uuid, p_occurrence_date date, p_scheduled_task_id uuid) RETURNS void
-- 予定外 (つながりの有無を問わない)。p_id NULL = 新規。occurrence_date は開始の JST 日
actual_save(p_id uuid, p_name text, p_category_id uuid, p_start timestamptz, p_end timestamptz) RETURNS uuid
actual_delete(p_id uuid) RETURNS void
```
- 落とし穴: (a) 同名の関数を複数作らない（PostgREST は引数の集合で関数を選ぶ。NULL を含む JSON で曖昧になる）。(b) NULL も明示して送る（既存の `ScheduleRPC.Params` がそうしている。`SupabaseDayDataSource.swift:157-174`）。`Value` に `.date` / `.timestamp` を足すか、`.string` で ISO8601 を送る。(c) `p_start` / `p_end` は timestamptz（実績は回の日をまたぐ。§3-3）。(d) `checkin_set` は `INSERT … ON CONFLICT … DO UPDATE`（§2-5）で 1 文。sleep_actual_input は `ON CONFLICT (actual_task_id) DO UPDATE`、score NULL か skipped なら DELETE。(e) 過去日の検査は**しない**（設計どおり）、未来日は拒む（§2-5）。(f) 実行権限を anon / authenticated に（0006 と同じ。`0006:304-316`）。`CREATE OR REPLACE` した段階 1 の関数は GRANT を保つ
- クライアント側: `ScheduleOperation` に足さず、`CheckInOperation` を別 enum にする（`SchedulePlanner` の網羅 switch と、`InMemoryScheduleDataSource.apply` の「D ≥ 今日」の検査を混ぜないため）。`ScheduleDataSource` に `applyCheckIn(_:)` を足す

### 6-2. 【中】migration `0007_actual_checkin.sql` の順序と冪等性
1. `ALTER TABLE actual_task DROP CONSTRAINT IF EXISTS actual_task_check, ADD COLUMN IF NOT EXISTS …`: 既存 CHECK の名前は **`actual_task_check`**（本番 DB で確認【事実】。0001 の無名 CHECK の自動命名。使い捨て DB でも同名）。残しても壊れない（§2-1）が消す。`ADD CONSTRAINT` には IF NOT EXISTS が無いので `DO $$ … IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = '…') …$$` で包む（`apply_migration` が 1 トランザクションか未確認【推測】のため、段階 1 と同じく途中で止まっても続きを流せる形にする）
2. `occurrence_date` を NOT NULL で足す（0 件なので DEFAULT 不要）、`actual_task_skip_needs_link`（§2-2）、部分一意索引 2 本（`IF NOT EXISTS`）、`(occurrence_date)` の索引
3. `sleep_actual_input` の CHECK
4. 新関数 4 本
5. 段階 1 の関数 5 本を `CREATE OR REPLACE`（`schedule_single_delete` / `schedule_template_create` / `schedule_template_delete_following` / `schedule_template_end_to_single` / `schedule_occurrence_delete`）。**1 の後**でないと新列を参照できない。引数と戻り値の型は変えない（変えると OR REPLACE できず DROP が要る）
6. GRANT（新関数だけ）
- 適用後: 段階 1 と同じく PostgREST 経由で 1 通り（`checkin_set` → `checkin_clear` → 予定外 → 変換 2 種 → 系列ごと削除でスキップが消える）。新関数が見つからなければ `NOTIFY pgrst, 'reload schema'`
- **番号の付け替え**: 「0007 = 旧列と pattern_template_membership の削除」と書いてある箇所が 4 つ残る（`day-cycle-walkthrough.md:160, 196, 226, 258`、`0006_template_version.sql:8-9, 163`）。段階 2 で 0007 を使うなら全部「0008」に直す（0006 のコメントはファイルを書き換えず、walkthrough に「0006 のコメントの 0007 は 0008 のこと」と注記でもよい）
- 旧ビルド（本人の実機に入っている段階 1 のビルド）への影響: 旧ビルドは actual_task を時刻の重なりで読むので、新列・NULL 時刻の行は見えない。0007 を当てても旧ビルドは壊れない【推測: 決め手は §1-4 の decode 条件で、旧ビルドは NULL 行を取らない】

### 6-3. 【低】use-once の確認項目（完了条件に足す）
- 0007 を使い捨て Postgres で 0001→0006 の後に流し、§2-2 の C2・§1-2 の D/E が**直っている**こと（同じスクリプトで前後比較できる）
- `pg_get_functiondef` で本番の関数本体がファイルと一致（段階 1 と同じ手順）

## 7. 規約・文書との整合（本人に報告する）

- 【事実】`structural-conventions.md` D-4「NG 例: 1. `actual_task` に `scheduled_task_id` 列や FK を追加する／2. RPC で plan + actual を事前 join する／4. DB トリガーで一方が他方を書く」、`domain-model.md:279`「予実紐付けなし」、`:603-605`「`source_template_id`（FK なし・informational hint）を検討」。決定 C1 と、§1-2・§2-2 の「段階 1 の RPC が actual_task を書く」はこれに反する
- D-4 の Why「plan 再生成や actual 編集時に整合性破綻が連鎖する」は、まさに §1-2（変換でつながりが落ちる）の予言。決定を覆さず、**規約を次のように書き換える**: 「実績は回への参照（template_id＋occurrence_date／scheduled_task_id）を informational に持つ。予定側の RPC は実績の**つながり列と skipped 行**だけを触ってよい（中身＝名前・種類・時刻・状態 done は触らない）。表示の結合（丸の状態・ジム判定）は UI 層」。`domain-model.md` の「予実紐付けなし」を「FK は SET NULL の緩い参照」に改め、`source_template_id` の持ち越し論点は C1 で解消と書く
- `spec.md` / `implementation-roadmap.md` の Round 5 の記述は段階 2 の完了時に更新

## 8. 本人判断が要るもの（1 問ずつ）

1. **規約 D-4 と「予実紐付けなし」の書き換え**（§7）: 決定 C1 の帰結。承認だけ（現状 → 採用後: 規約が「FK で結ばない」→「緩い参照を持ち、予定側 RPC はつながり列と skipped 行だけ触る」）
2. **決定文言の読み方 2 点**（§1-2・§1-3。AI 既定で進めてよければ確認だけ）: (a) 単発 ↔ 繰り返しの変換では実績を「外す」でなく「つなぎ直す」。(b) skipped を消すのは「予定の行を消す操作＋この予定の削除」のときだけ。曜日・祝日の変更で回が出なくなった skipped は残して読む側で無視
3. **今夜の睡眠の丸を朝から押せるままにするか**（§3-4。C3 の AI 既定「今日のこれからの回は押せる」の睡眠への適用）: 現状案 = 押せる（一覧に睡眠の丸が 2 つ）→ 代案 = 睡眠（sub_input_kind = sleep）だけ、終了が未来の回は丸を出さない。どちらでも DB は変わらない

## 9. 指摘の一覧（重大度順）

| # | 重大度 | 節 | 要点 | 本人判断 |
|---|---|---|---|---|
| 1 | 高 | §1-2 | 単発 ↔ 系列の変換で実績のつながりが外れ、丸が空・二重表示（検証済み） | 読み方の確認（§8-2a） |
| 2 | 高 | §2-2 | 系列ごと削除・単発削除でスキップ行が孤児（検証済み）。RPC で先に消す＋CHECK を砦に | 不要 |
| 3 | 高 | §3-1 / §2-3 | 時刻の重なりの取得ではスキップ行と 0 時過ぎ就寝の実績が取れない。occurrence_date を全行必須にして日で取る | 不要 |
| 4 | 高 | §1-4 | `ActualTask` の時刻が non-optional → スキップ 1 件でその日の読み込み全体が失敗 | 不要 |
| 5 | 中 | §1-3 | 曜日変更で回が消えたときの skipped の扱い（残す・読む側で無視） | 読み方の確認（§8-2b） |
| 6 | 中 | §3-2 | 実績時刻の入力で「0:30」をどの日にするかの規則（予定の開始 ±12h で最も近い） | 不要 |
| 7 | 中 | §4-1 | 予定タブにトレーニングのデータ経路が無い・モックのセット・タブ切替後の古いキャッシュ | 不要 |
| 8 | 中 | §5-3 | `perform` の `isSaving` が 2 度目のタップを黙って成功扱い。楽観更新＋回ごとの直列化＋見ている日だけ読み直す | 不要 |
| 9 | 中 | §5-1 / §5-2 | 行の Button 入れ子・accessibility・過去日の行を押せる対象・C-5 の必須引数 | 不要 |
| 10 | 中 | §6-2 | 旧 CHECK `actual_task_check` の DROP・冪等化・OR REPLACE の順序・0007/0008 の番号付け替え（4 か所＋0006 コメント） | 不要 |
| 11 | 中 | §7 | 規約 D-4／domain-model「予実紐付けなし」との矛盾 → 規約を書き換える | 要（承認。§8-1） |
| 12 | 低 | §3-4 / §3-5 | 睡眠の丸が朝の一覧に 2 つ／明日の view の前日継続行の丸は「回の日」で決める | 3 のみ（§8-3） |
| 13 | 低 | §4-2 | ジム判定の細則と分析の優先順（セット > 実績の行、skipped でもセットがあれば done、1 セットは時刻を出さない） | 不要 |
| 14 | 低 | §5-4 / §5-5 | 前日継続行の leading スワイプは出す・予定外の丸は塗り disabled・`actual_save/delete` はつながりを問わない・＋の 3 分岐 | 好みがあれば |
| 15 | 低 | §2-5 / §6-1 | RPC の砦（未来日拒否・skipped の時刻正規化・O(D) を単発扱いさせない・score は sleep だけ・ON CONFLICT で 1 文） | 不要 |
| 16 | 低 | §1-5 / §2-4 | 回のキーを pure 関数 1 つに固定・`workout_session.actual_task_id` は未使用と明記 | 不要 |

## 10. このまま実装に入ってよいか

- **入る前に確定仕様へ写す**: #1〜#4（DDL の差分 = `occurrence_date NOT NULL`・`skip_needs_link` の CHECK・`occurrence_chk` の撤去、段階 1 の RPC 5 本の変更点、取得条件、`ActualTask` の optional 化）、#5・#6 の規則、#10 の migration 手順。§8 の 3 問は 1 問ずつ聞く（1 と 2 は「はい」で済む形）
- **実装の順**: (1) 使い捨て Postgres で 0007 を流し §2-2・§1-2 の場面が直っていることを SQL で確認 → (2) Swift のモデル・取得・キー・丸の状態の pure 関数とテスト（`ScheduleStage1Tests` と同じ harness、今日 = 9/30） → (3) モックの規則（変換のつなぎ直し・skipped の削除・セット）とテスト → (4) 画面 → (5) `-mock-day` で確認 → (6) 本番適用は本人 OK 後・PostgREST 経由で 1 通り
- 完了条件（walkthrough:337-340）に足すもの: 「変換 2 種で丸の状態が保たれる」「系列ごと削除で skipped が消え done が予定外として残る」「0:30 就寝の実績が前日の回に付く」「セットありのジムの丸が disabled」「2 度目のタップで戻る」
