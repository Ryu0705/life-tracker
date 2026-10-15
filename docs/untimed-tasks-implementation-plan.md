# 時刻のないやること 実装計画（2026-10-14・opus レビュー 2 回反映済み・本人 OK「実装へ」2026-10-14 → 実装済み・未 commit・本番未適用）

土台: `docs/untimed-tasks-design.md`（要件 1〜8・データの決定 1〜6・レビュー結果）。食い違う所は設計書の本人決定が正、細部はこのファイルが正。

## 前提
- 本番 DB（hyngpesrmqodiegonoze）には触れない。0012 の本番適用・commit・push は本人 OK 後
- 時刻つきの予定・実績・睡眠・ジムの挙動は変えない（既存テストは全件そのまま通る）
- 規則の原本は Swift（`InMemoryScheduleDataSource`・pure の Planner）。SQL はその写し
- 本番の順序（設計書 重大 1）: 新ビルドを作る → 0012 を適用 → すぐ新ビルドを入れる → それから時刻なしを作る。時刻なしを 1 件でも作った後は旧ビルドに戻せない（時刻なしの世代が 1 行あると、旧ビルドは予定タブ全体を読めない。時刻なしの done（時刻 NULL）の実績は旧ビルドでも読める＝ status は増やさない。目標 2 以上の時刻つきの予定を 1 件でも作った後も戻せない＝旧ビルドは 1/3 の回を「やった」と見せ、丸の 2 度目でタップを全部消す）
- 0012 で RPC の引数が変わる関数は DROP → CREATE（重ねて残さない。PGRST203 を避ける）。適用から新ビルドを入れるまでの間、旧ビルドの予定の保存は「関数が無い」で失敗する（読み取り・丸・スキップは動く）。この間は数分に収める

## 用語
- V = 見ている日。回の日 = occurrence_date
- **回数は時刻と独立**（本人 2026-10-14。下の「本人の決定 2」）: すべての予定が目標の回数を持つ（既定 1）。繰り越しは時刻なしだけ
- 回の記録 = `actual_task` の 1 行（status done または skipped。時刻つきの間に作った done は実績の時刻を持ち、時刻なしの間に作った done は持たない）＋タップの行 `actual_task_tap`（押した時刻）。時刻あり↔なしを切り替えても記録はそのまま
- 回数: **時刻なしの回** = JST の日付が V 以前のタップの数（過去日はその日の時点）。**時刻つきの回** = V に依らず全部のタップの数（繰り越さないので時点の数え方は要らない。日をまたぐ回を翌日に押しても回の日の一覧で数える。再レビュー重大 1）。完了 = 回数 ≥ その回の目標
- **時刻つきで目標 1 の回は今の仕組みをそのまま使う**（再レビュー重大 2）: 丸・スワイプ・楽観更新は今の `.set`／`.clear`（checkin_set／checkin_clear）と `CheckInPlanner.toggle/skip/override`。完了は今と同じく status done。スキップ済みの丸を押す・スワイプで取り消すと記録なしに戻る。`record_tap_*`・`record_skip_*` は時刻なしの回と、時刻つきで目標 2 以上の回だけが使う
- 閉じた日（時刻なしの見せる条件にだけ使う）= 目標の回数目のタップの JST 日、またはスキップした日（`skipped_on`。時刻つきの間にスキップして NULL なら回の日）の早い方。**保存しない**（レビュー「簡単にできる所 1」を採用。設計書の `closed_on` 列は作らず、タップ・目標・skipped_on から毎回求める。再計算の漏れが構造的に起きない）
- スキップ（V の時点）= status skipped かつ skipped_on ≤ V。V < skipped_on の日はタップから数えた進みを出す

## 1. DB（`supabase/migrations/0012_untimed_tasks.sql`・apply 名 `v2_untimed_tasks`）
冪等（IF NOT EXISTS・DROP FUNCTION IF EXISTS）。作り直す制約（actual_task の status_chk・time_chk、scheduled_task の一意索引）は `DROP ... IF EXISTS` → `ADD` を無条件に流す（0007 の「無ければ足す」書き方だと既存の同名制約が残り時刻なしの done が入らない。レビュー中 6）。順序: 列 → backfill → 制約・索引 → 関数 → GRANT。

### 1-1. 列と制約
| 表 | 変更 |
|---|---|
| `task_template` | `start_minutes_from_midnight`・`duration_minutes` の NOT NULL を外す（旧列。0013 で消す。時刻なしの系列は NULL で写す） |
| `task_template_version` | 開始・長さの NOT NULL を外す。`target_count INT NOT NULL DEFAULT 1 CHECK (1〜99)`・`carry_over BOOLEAN NOT NULL DEFAULT false` を足す（既存の行は 1・false）。CHECK `timing_chk`: 開始と長さは両方あるか両方 NULL。CHECK `carry_chk`: `NOT carry_over OR 開始 IS NULL`（繰り越しは時刻なしだけ） |
| `scheduled_task` | `occurrence_date DATE` を足し、`(start_at AT TIME ZONE 'Asia/Tokyo')::date` で埋めて NOT NULL。start_at・end_at の NOT NULL を外す（既存の `end_at > start_at` は NULL で通る）。`target_count INT NOT NULL DEFAULT 1 CHECK (1〜99)` を足す。CHECK `timing_chk`: （時刻あり かつ occurrence_date = start_at の JST 日）か（start_at・end_at とも NULL） |
| `scheduled_task` 索引 | `scheduled_task_template_day_unique`（start_at の式）を DROP し、`(template_id, occurrence_date) WHERE template_id IS NOT NULL` の一意索引に置き換える。`occurrence_date` の索引を足す |
| `actual_task` | `skipped_on DATE` を足す（スキップした日）。status は done・skipped のまま。`time_chk` を作り直す: done = 時刻は両方あって終了 > 開始、または両方 NULL（時刻なし）／skipped = 時刻 NULL。CHECK `skipped_on_chk`: `skipped_on IS NULL OR status = 'skipped'`。`skip_needs_link` はそのまま。予定外の実績の時刻必須は `actual_save` が守る（CHECK にすると、系列を消して SET NULL になった時刻なしの done で止まる） |
| `scheduled_task` の作成日時 | `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` を足す（2-2 の単発の並びに使う。既存の行は start_at で埋める。実装中に Swift エージェントが発見・AI 既定 2026-10-14） |
| `actual_task_tap` の backfill | 回につながる既存の done の行に、タップを 1 行（tapped_at = end_at）。冪等（タップの無い行だけ）。これで「回数 ≥ 目標（1）」= 今の「やった」と同じになる |
| `actual_task_tap`（新） | `id UUID PK`、`actual_task_id UUID NOT NULL REFERENCES actual_task ON DELETE CASCADE`、`tapped_at TIMESTAMPTZ NOT NULL`、索引 `(actual_task_id, tapped_at)` |

- 目標の上限 99 は AI 既定（− ＋ で押す数の現実的な上限）
- status を増やさない理由: 回数が時刻と独立になったので、記録の形は時刻の有無で分けない（旧ビルドも decode できる）

### 1-2. 関数（`規則の写し`。日付の判定は start_at でなく occurrence_date）
共通の内部関数（GRANT しない）:
- `todo_target(p_template_id, p_date, p_scheduled_task_id)`: 単発 → その target。系列 → O(D) があればその target、無ければ p_date に効く世代（effective_from ≤ p_date の最新）の target
- `todo_closed_on(p_actual_id)`: 閉じた日を求める（目標の回数目のタップの JST 日と skipped_on の早い方。どちらも無ければ NULL）。Swift の同名の規則の写し
- `schedule_assert_single_editable(p_id, p_new_date)`: 時刻なしで「今日の時点で閉じていない」（閉じた日が NULL か ≥ 今日）単発は、p_new_date = 元の日（そのまま）か p_new_date ≥ 今日 なら通す。それ以外は今と同じ「元の日 ≥ 今日 かつ p_new_date ≥ 今日」（設計書 重大 2・レビュー重大 2。今の single_save は新しい日と元の日の両方を検査しているので両方差し替える）

予定の RPC（引数が変わるものは DROP → CREATE）:
| 関数 | 変更 |
|---|---|
| `schedule_single_save` | 引数に `p_target int` を足す（時刻なしは p_start・p_duration が NULL）。p_date = 単発の日（時刻なしの繰り越し中は元の日のまま渡す。日付を変えたときだけ新しい日）。検査は `assert_single_editable`。時刻の有無を変えても記録は残す（本人決定 2）。実績の occurrence_date も単発の日に合わせる |
| `schedule_single_delete` | 日の判定を occurrence_date に。検査を `assert_single_editable` に。done の行は今と同じくつながりを外して残す（時刻なしの done は時刻が無いので一覧に出ない＝見えない記録として残る。タップも残る） |
| `schedule_template_create` | `p_target int`・`p_carry_over boolean` を足す。旧列にも同じ値（時刻なしは NULL）。単発から作るときの実績のつなぎ直しは今と同じ（occurrence_date = D。タップは押した時刻のまま残り、D の回の進みに入る＝過去日の V < D の進みからは消える。AI 既定）。単発の検査は `assert_single_editable` |
| `schedule_template_save_following` | `p_target`・`p_carry_over` を足す。O(D) の削除を occurrence_date で。時刻の有無を変えても D の回の記録は残す（本人決定 2） |
| `schedule_template_delete_following` | O の削除を occurrence_date で。終了の世代に target・carry_over も写す（設計書 重大 3）。D より前の回（閉じていない繰り越し）は残す＝今の規則のまま（決定 3） |
| `schedule_template_end_to_single` | `p_target` を足す。作る単発は世代の時刻の有無に合わせる。D の回の実績のつなぎ直しは今と同じ |
| `schedule_occurrence_save` | `p_target` を足す。日の判定を occurrence_date に（式インデックスでなくなったので `ON CONFLICT (template_id, occurrence_date)` の upsert にできるが、今の UPDATE → INSERT のままでよい）。系列の世代と時刻の有無が違う保存は拒否（「その日だけ」で時刻の有無は変えない） |
| `schedule_occurrence_delete` | 日の判定を occurrence_date に。D の skipped は今と同じく消す。done は今と同じく残す（時刻なしの done は見えない記録として残る） |

実績の RPC:
| 関数 | 変更 |
|---|---|
| `checkin_set`・`checkin_clear` | 引数は同じ（CREATE OR REPLACE。旧ビルドもそのまま使える）。単発の日を occurrence_date から取る。checkin_set で done にしたときタップが 0 件なら 1 行足す（tapped_at = p_end。後で時刻なしへ切り替えても回数 1 で残るため）。タップは減らさない。done なら p_start・p_end 必須（終了 > 開始）を関数の中で検査する（time_chk が時刻 NULL の done を通すようになるため。InMemory と同じ）。ON CONFLICT の更新に `skipped_on = CASE WHEN status = 'skipped' THEN skipped_on ELSE NULL END` を足す（スキップ → やったの保存が skipped_on_chk で止まらないように。再レビュー重大 3）。clear は行ごと消す（タップは CASCADE。目標 1 の丸の 2 度目のタップ＝今の取り消しと同じ） |
| `record_tap_add(p_template_id, p_occurrence_date, p_scheduled_task_id, p_name, p_category_id, p_tapped_at, p_start, p_end)`（新・時刻あり／なし共通） | 回の行が無ければ done で作り（時刻つきは p_start・p_end = 予定の時刻、時刻なしは NULL）、タップを 1 行足す。p_tapped_at の JST 日は 回の日以上・今日以下。skipped の回は拒否。時刻つきで目標 1 の回は呼ばない（Swift 側。SQL も拒否） |
| `record_tap_remove(同じキー, p_as_of date)`（新） | JST 日が p_as_of 以前のタップのうち最も新しい 1 行を消す。skipped の回は拒否。0 件になったら行も消す（実績の時刻も消える＝記録なしに戻る。目標 2 以上で編集画面で直した実績の時刻も消える＝AI 既定） |
| `record_skip_set(同じキー, p_name, p_category_id, p_on date)`（新。時刻なしと時刻つきの目標 2 以上） | status = skipped、skipped_on = p_on（一覧のスワイプでは V。回の日以上・今日以下）。タップは残す |
| `record_skip_clear(同じキー)`（新。時刻なしと時刻つきの目標 2 以上） | タップがあれば done に戻し skipped_on を NULL に（時刻つきは実績の時刻 = 予定の時刻を入れ直す）、無ければ行を消す |

読み取りの RPC（新・1 往復）:
- `todo_fetch(p_date date, p_from date, p_count_from date) RETURNS jsonb`。範囲は Swift が決めて渡す（p_from = V−7、p_count_from = V−366）。返すもの:
  - `singles`: 時刻なしの単発で occurrence_date ≤ V かつ `todo_closed_on` が NULL か ≥ V
  - `overrides`: 時刻なしの O(D) で occurrence_date ∈ [p_from, V]
  - `actuals`: 上の単発の実績＋時刻なしの系列の回の実績で occurrence_date ∈ [p_from, V]
  - `taps`: 上の実績のタップで JST 日 ≤ V
  - `exdates`・`day_metas`: 日付 ∈ [p_count_from, V]
  - `older_closed`: 時刻なしの系列の回で occurrence_date ∈ [p_count_from, p_from) かつ閉じた日 < V の (template_id, occurrence_date) をそのまま（繰り越しのオン・オフ、その日に回があったかは Swift がその日の世代で突き合わせる。レビュー軽微）
- 選び方の規則（どの回を出すか）は Swift。SQL は範囲で絞るだけ（単発の「V より前に閉じた」だけは件数を抑えるため SQL で絞る＝規則の写し）

GRANT: 新しい関数と作り直した関数を anon・authenticated に。内部関数（todo_target・todo_closed_on・assert_single_editable）は `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`（Postgres は関数を既定で PUBLIC に開くため、GRANT しないだけでは閉じない。レビュー中 4）。SECURITY は既存と同じ INVOKER。**実装中の変更（2026-10-14・SQL エージェントが実測）**: INVOKER の関数が中から呼ぶ関数にも呼んだ人の EXECUTE が要るため、public のまま REVOKE すると todo_fetch・schedule_single_delete が permission denied で落ちる。内部関数は PostgREST が公開しないスキーマ `private` に置き、PUBLIC から REVOKE・anon/authenticated に USAGE と EXECUTE を付ける（API からは 404 で「外から呼べない」を保つ。採らなかった案: public のまま REVOKE しない＝0006 の assert_editable と同じ／公開 RPC を SECURITY DEFINER。AI 既定）。plpgsql は中から呼ぶ関数の DROP を検知しないので（end_to_single → single_save など）、作り直した関数を中から呼ぶ経路は検証 3 で全部通す

### 1-3. 番号の書き直し（旧列の削除 0012 → 0013）
`day-cycle-walkthrough.md`:160・196・226・258・293・346、`domain-model.md`:4、`0006`:8・163 のコメント、`0011`:11。0013 で消すものに「0012 の旧 RPC の写し」は無い（DROP 済み）。0013 で `task_template` の旧列を消すときは時刻なしの系列も対象（中身の列は version だけにある）

## 2. Swift
### 2-1. 型（取得の境界で分ける。設計書 レビュー A′ の修正）
- `TaskTemplateVersion`: `startMinutesFromMidnight`・`durationMinutes` を Optional にし、`targetCount: Int`（既定 1）・`carryOver: Bool` を足す（既定値つきの init を明示し、今の呼び出し 6 か所を変えない）。`var timing: ScheduleTiming { .timed(start, duration) / .untimed }`。`TaskTemplate`・`ScheduledTask` にも `targetCount`（既定 1）を足す（時刻つきの行の丸に使う）。`template`（TaskTemplate を作る）は時刻ありのときだけ（`var timedTemplate: TaskTemplate?`）
- 世代の選び方（レビュー重大 1）: **系列ごとにその日の最新の世代を 1 つ選び（isEnded を除く）、それから時刻の有無で分ける**。先に時刻ありへ絞ると、時刻なしへ切り替えた後に古い時刻ありの世代が選ばれて復活する。`effectiveVersions` → 時刻ありだけを返す（DayBuilder・SleepStore は変わらない）、`effectiveTodoVersions` → 時刻なしだけ。`effectiveVersion(templateId:)`・`ScheduleCatalog.seriesInput` は種類を問わず返し、`ScheduleEntryInput` に timing を持たせる（時刻なしの系列も編集画面が開く）
- `ScheduledTask`（時刻必須）はそのまま。取得の行は `ScheduledTaskRow`（時刻 Optional・occurrenceDate・targetCount）で受け、境界で `ScheduledTask` か `TodoEntity` に分ける
- `ActualTask` に `skippedOn: Date?` を足す（status は増やさない）。`ActualTaskTap { id, actualTaskId, tappedAt }`。時刻つきの回のタップも取得する（`loadDayContext` の実績と同じ回の分）
- `ScheduleContent`: `startMinutes`・`durationMinutes` を `timing: ScheduleTiming`（`.timed(startMinutes:durationMinutes:)` / `.untimed`）にし、`targetCount: Int` を足す。`ScheduleRepeatRule` に `carriesOver: Bool`（時刻なしの繰り返しのときだけ意味を持つ）
- `Day` に足すのは `taps: [ActualTaskTap]`（時刻つきの回の回数用・既定は空）だけ。時刻なしは別の型 `TodoDay { date, todos: [DayTodo], olderOpenCounts: [UUID: Int] }` にし、予定タブだけが読む（レビュー中 5）
- InMemory の `State` に時刻なしの単発・O(D) の置き場（`todoEntities`）を足す。系列ごと消すときの「D より前の実体が残っていれば止める」（FK RESTRICT 相当）の検査に含める
- `DayTodo { key: CheckInKey, name, categoryId, target, occurrenceDate, count (V の時点), record: ActualTask?, closedOn (V の時点で求めた閉じた日), isSkipped (skipped_on ≤ V), origin (単発・系列・その日だけ変更) }`

### 2-2. 組み立て（pure・新 `TodoBuilder`）
- 入力: V、世代全件、祝日の登録、パターン、`todo_fetch` の結果、祝日の判定
- 系列: 日 d ∈ [V−7, V] ごとに、d に効く時刻なしの世代 → DayBuilder と同じ規則で d に回があるか（day_meta の「何もしない日」・パターン・rrule・祝日・除外日。規則は DayBuilder の resolveMode／rrule の判定を共有する関数に切り出して両方から呼ぶ）。d < V の回は「d の世代の carry_over がオン」のものだけ。O(d) があればその中身
- 単発: `singles` 全部（V の時点で閉じていないもの＋ V に閉じたもの）
- 見せる条件: 回の日 ≤ V かつ（閉じた日が NULL か ≥ V）。閉じた日 = V の回は「完了（10/10 から）」
- 回数は V の時点（JST 日 ≤ V のタップ）、完了 = 回数 ≥ 目標
- 「ほか N 件」: 系列ごとに d ∈ [V−366, V−8] で「d の世代が時刻なし・繰り越しオンで、d に回がある」日を数え、`older_closed` のうちその日に当たるものを引く。1 年より前は数えない（AI 既定）
- 並び: 終わっていない → 終わった。同じ中は作った順（単発は `created_at`、系列は系列の最初の世代の `created_at`）。重なる回（決定 7: 2 行）は古い回が上
- Swift の時刻ありの実績は従来どおり occurrence_date ∈ {V−1, V} に絞ってから DayBuilder に渡す（`Day.records` の意味を変えない）
- `CheckInPlanner.listItems` の予定外の判定から「時刻なしの回（やること）のキーに当たる実績」を外す（時刻つき → なしに切り替えた回の時刻つきの頃の done が、予定外としても出て 2 か所に出るのを防ぐ。再レビュー中 5）

### 2-3. 書き込み
- `ScheduleOperation` の各 case は `ScheduleContent`（timing 入り）のまま。`ScheduleRPC` が timing から `p_start`・`p_duration`・`p_target`（＋ `p_carry_over`）を作る（無い方は null で送る）
- `CheckInOperation` に `.tap(key, name, categoryId, at: Date, plannedStart: Date?, plannedEnd: Date?)`・`.untap(key, asOf: Date)`・`.skipCounted(key, name, categoryId, on: Date)`・`.unskipCounted(key)` を足す（時刻なしと時刻つきの目標 2 以上が使う。目標 1 の時刻つきは今の `.set`／`.clear`）
- `InMemoryScheduleDataSource`: 1-2 の規則を全部持つ（原本）。`todo_fetch` と同じ形を返す `loadTodoFetch(date:)`
- `SchedulePlanner.save`: 時刻の有無を変えた保存は「これ以降」に固定（確認なし。今の「繰り返しの設定を変えたとき」と同じ）。時刻の有無を変えても、その回の記録（タップ・スキップ・実績の時刻）は残す（本人決定 2）
- 編集の対象: 時刻なしの単発の `ScheduleEditTarget.date` は V（今日以降）、元の日は別に持つ（`occurrenceDate`）。updateSingle は元の日（または本人が選んだ日）を送る。単発 → 繰り返しは V から始め、記録は V の回へつなぎ直す

### 2-4. 読み込みとキャッシュ
- `loadDayContext` には足さない（睡眠タブ・今日のカードも呼ぶため。失敗が伝わり往復も増える。レビュー中 5）。`TodoDataSource.loadTodos(date:)` を別に作り、ScheduleStore だけが `loadDayContext` と並列で呼ぶ。入力は `todo_fetch` の結果＋カタログ（世代全件・登録・パターン）。失敗したら「やること」の節だけ「読み込みに失敗しました［再試行］」
- `ScheduleStore`: 時刻なしの書き込みの後は前後 1 日でなく、キャッシュを全部捨てて V を読み直す（繰り越しは何日も先の一覧に出るため。設計書 重大 4）
- 楽観更新: 回数をそのまま上書きしない（同じ回が複数の日に出るため）。「足したタップ（押した時刻つき）／消したタップ」を回ごとに持ち、表示する日ごとに V 以前で数え直す。直列化は今の `checkInChains`（レビュー中 7）

### 2-5. 画面
- 予定の一覧（`HomeView`）: 時刻つきの節の下に「やること」の節。行 = 丸（目標 1 は今の丸、2 以上は「3/8」の丸）・名前・2 行目（種類・「10/10 から」・「この日だけ変更」）。丸のタップは常に +1（目標 1 で完了済みなら取り消す＝ untap）。右スワイプでスキップ（その日 V で）。行を押したとき: 回の日 ≥ 今日の回と閉じていない単発は編集画面、繰り越し中の系列の回（回の日 < 今日）は予定を読むだけ＋回数の − ＋・スキップ（本人決定 1）。左スワイプの削除は編集画面が開く行だけ。やることだけがある日は「予定はありません」を出さない。節の下に「掃除: ほか 3 回（7 日より前）」（押せない文字）
- 節は時刻なしが 1 件も無い日は出さない（AI 既定）
- 現在進行中のカード（CurrentBlockCard）・睡眠タブ・ジムの判定には出さない
- 時刻つきの行の丸（本人決定 2）: 目標 1 は今と同じ（押すと予定の時刻で「やった」、2 度目で取り消し）。目標 2 以上は「1/3」の丸（`CheckInCircleStyle.progress(count, target)` を足す）で、押すたびに +1（目標を超えても数える）。1/3 でも status は done なので、「やった」の判定は status でなく「回数 ≥ 目標」で見る（`CheckInState.isDone`・丸・3 行目。目標 1 は status done と同じ結果）。行を開くと実績欄に「回数」の − ＋ と実績の時刻。繰り越しはしない。ジム（セットのある回は今の固定の丸）・睡眠は目標の回数を出さない（1 固定。種類をジム・睡眠に変えて保存したら目標は 1 に戻す。AI 既定）
- 編集画面（`ScheduleEntryEditView`）: 「時刻を決める」トグル（新規の既定はオン＝今と同じ）。オフで開始・終了が消える。「目標の回数」（− ＋、1〜99、既定 1）は時刻の有無に関係なく出す（ジム・睡眠の種類では出さない）。繰り返しがあるとき「終わらなければ翌日にも出す」トグル（既定オフ）。時刻なしのときだけ種類の選択肢から睡眠を外す。時刻なしの単発は「日付」の行（繰り越し中は「10/10 から繰り越し中」と「日付を変える」→ 今日以降の日付）。実績欄は「回数 3/8」と − ＋（V の時点。− は V 以前の最新のタップを消す）・スキップ
- 過去日: 予定は読むだけ・回数の − ＋ とスキップは使える（今の時刻つきと同じ）。過去日に押した +1 は「その日の、今と同じ時計の時刻」で残す（AI 既定）

## 3. テスト（`xcodebuild test` 全件。新しいテストは `UntimedTasksTests.swift`）
- TodoBuilder: 単発の繰り越し（10/10 作成 → 10/13 に「10/10 から」）、閉じた日だけ「完了（から）」・翌日は出ない、過去日の進み（10/13 は 3/8・10/14 は 8/8 から）、繰り越しオフの系列は昨日の回を出さない、オンは 7 日まで・8 日目からは N 件、重なりは 2 行、「何もしない日」・祝日・除外日に回が無い、その日だけ変更の目標、並び
- 規則（InMemory）: タップ・取り消し（V 以前の最新）・スキップ（skipped_on = V。V より前の日では未完と出る）・スキップの取り消し（タップがあれば done に戻る）、目標の変更で閉じた日が付く／外れる、「これ以降を削除」・時刻ありへの切替の後も D より前の閉じていない回が出続ける（決定 3）、繰り越し中の単発を元の日のまま保存・削除できる／過去の日付への変更は拒否、閉じた単発の過去日は編集できない、単発 → 繰り返しでタップが D の回に入る、時刻あり↔なしを切り替えても記録（タップ・スキップ）が残る、時刻つきで目標 3 の丸が 1/3 → 3/3 で完了・目標 1 の丸の 2 度目は取り消し・スキップ済みの丸を押すと記録なし（今と同じ）、日をまたぐ時刻つきの回を翌日に押しても回の日の一覧で数える、時刻つき → なしに切り替えた回が予定外として出ない、checkin_set でスキップ → やったにできる、backfill 後の既存の done が回数 1 で完了と出る、checkin_set で時刻だけ入れた done にタップが 1 つ付く、睡眠の種類を拒否、未来のタップを拒否
- 世代の選び方（レビュー重大 1）: D で時刻あり → なしにした後、D+1 の DayBuilder に時刻つきの行が出ない／なし → ありの後、d ≥ D の todos に出ない／時刻なしの系列でも `seriesInput` が返る
- 楽観更新中に過去日と今日を行き来しても、それぞれの日の時点の回数が出る
- `loadTodos` が失敗しても SleepStore・TodayDataLoader が動く
- テストの暦は Asia/Tokyo に固定（閉じた日は JST 日）
- RPC の写像: `ScheduleRPC` の引数（timing → p_start/p_duration/p_target/p_carry_over・新しい 4 本）
- 既存: DayBuilder・SleepStore・睡眠・ジムのテストに差分なし（時刻なしの世代が混ざっても時刻つきの結果が変わらないテストを 1 本足す）

## 4. SQL の検証（使い捨て Postgres 16 ＋ PostgREST を docker で。記録は scratchpad `untimed/`）
1. 0001→0005 → seed → 0006 → 0007 → 0008〜0011 → 0012 ×2（冪等）がエラー 0
2. backfill: 既存の scheduled_task の occurrence_date = start_at の JST 日、CHECK が全行で通る
3. 3 の規則のテストと同じ場面を SQL で流し、InMemory と同じ結果になる（タップ・閉じた日・繰り越し・削除後の残り・拒否のケース）
4. PostgREST 経由（関数の作り直しの後に `NOTIFY pgrst, 'reload schema'`）で新しい引数の呼び出しが 1 関数に決まる（PGRST203 が出ない）、旧引数の呼び出しは 404 になる、anon で呼べる、REVOKE した内部関数は anon で拒否される
5. 時刻つきの RPC 全部の前後で、時刻つきの行が今と同じになる（回帰）
6. 0012 を 2 回流した後に時刻 NULL の done を INSERT できる（制約の作り直しが効いている）。backfill のタップが 2 回目で増えない
7. 適用後・時刻なし 0 件の状態で、旧ビルドの読み取りの問い合わせ（世代・実体・実績）が今と同じ行を返す

## 5. モック（`-mock-day`）
`makeFixture(withSamples:)` に足す: 3 日前の単発「書類を出す」（閉じていない）、毎日「水を飲む」目標 8・繰り越しオン（昨日 3/8）、平日「掃除」目標 1・繰り越しオフ、今日 1 回押した「ストレッチ」目標 3

## 6. 作業の順番
1. 親: この計画のレビュー（opus）→ 本人に見せる
2. 番号の書き直し（1-3）と 0012 の SQL・検証（エージェント A）／Swift の型・TodoBuilder・InMemory・テスト（エージェント B）を並列。ファイルは排他（A は `supabase/` と scratchpad、B は `LifeTracker/`）
3. B の画面（2-5）→ 親がシミュレータで確認（`-mock-day`。5 の場面を全部見る）
4. docs: `domain-model.md`（DDL）・`day-cycle-walkthrough.md`（時刻なしの節）・`spec.md`・設計書の状態・memory
5. 本人のシミュレータ確認 → OK で commit・push → 本人 OK で本番に 0012（前提の順序で）→ 実機

## 7. 完了条件
- SQL: 4 の 1〜5 がすべて通る
- Swift: `xcodebuild test` 全件成功（件数を記録）。既存テストのファイルの差分は型の変更による機械的なものだけ
- シミュレータ: 5 の場面と 2-5 の操作（＋1・−・スキップ・削除・時刻の有無の切替・繰り越しオン/オフ・過去日の進み）を確認
- 本人の確認: 下の AI 既定

## 本人の決定（2026-10-14・計画の段階で聞いたもの）
1. 繰り越し中の繰り返しの回（例: 10/13 に出ている「掃除（10/10 から）」）を押したとき何を開くか → **決定（2026-10-14）: 回数と記録だけ開く**（予定は読むだけ＋回数の − ＋・スキップ。系列そのものは今日の回から開く。~~削除のスワイプは出さない~~）。選ばなかったもの: 今日の回の編集を開く・押せない。→ **2026-10-15 本人決定で変更: その回だけを消せるようにする（同日 10:35 実装・検証済み・未 commit）**（本人指摘「ユーザから見て消せるものと消せないものの区別がつかない上になぜ消せないのかを理解できないよね。これはUXとしてNG」。`day-cycle-walkthrough.md`「消せる行と消せない行の区別」）
2. 記録がある回の時刻あり↔なしの切替 → **本人回答（2026-10-14）原文「回数を持つことと時間を持つことは排他ではないのだから時間を持つ予定も回数を持てるようにすれば良いのでは？」**→ AI が「全部の予定が目標の回数を持つ（既定 1）・時刻つきで目標 1 は今の丸・切り替えても記録は残る」と整理し、繰り越しを時刻つきにも広げるかを聞いた → **決定（2026-10-14）: 回数だけ広げる**（繰り越しは時刻なしだけ）。選ばなかったもの: 回数も繰り越しも広げる・回数は時刻なしだけのまま。これで元の問い（記録がある回の切替）は「記録はそのまま残る」で解消。元の問い: 単発は回が 1 つなので「記録があれば変えられない」だと 1 度押した単発は二度と切り替えられず、決定 8「後から切り替えられる」と食い違う（レビュー中 9）。案: (a) 記録があれば変えられない (b) 変えてよく、合わない記録は予定から外れる（時刻つきの「やった」は予定外として残る、回数は見えない記録として残る） (c) 変えてよく、記録は消す
3. 丸を押して完了になった行を、すぐ節の下へ動かすか → **本人原文（2026-10-14）「再描画までは、行を元の位置に残す。」**。完了・スキップ・取り消しで並びを組み直すのは、日を移る・タブを開き直す・読み直す（再試行・引っ張って更新・保存の後）のときだけ。押した直後は丸と回数だけ変わり、行の位置は変えない（AI が親のシミュレータ確認で、2 度目のタップが隣の行に当たって別の行を完了にしたのを本人に挙げた）。選ばなかったもの: 今のまま（すぐ下へ動く）（シミュレータ確認の後に聞いたもの）

## AI 既定（本人未確認。実機で違和感があれば変える）
- 目標の上限 99／「ほか N 件」は系列ごとに 1 行で、1 年より前は数えない／節は時刻なしが無い日は出さない
- 「この予定」を削除したときの時刻なしの記録（タップ）は消さず、つながりを外して残す（見えなくなる）
- 過去日に押した +1 は、その日の今と同じ時計の時刻として残す
- 単発の日付は今日以降にだけ変えられる。日付を変えても、それまでのタップは残る（後ろに移すと、移す前の日の過去日の進みからは消える。今日閉じた単発を明日へ移すと出なくなるので、閉じた単発の日付は変えられない）
- 単発を繰り返しにしたとき、それまでのタップは D の回の進みに入る

## 実装中に決めたこと（2026-10-14・AI 既定。エージェントの指摘から）
- `scheduled_task.created_at` を足す（単発の並び。既存の行は start_at）
- 内部関数は `private` スキーマ（1-2 の GRANT の所に理由）
- 時刻ありで carry_over=true は CHECK で拒否。Swift は `carriesOver && 時刻なし` で送る
- `assert_single_editable` の「繰り越し中は元の日のまま通す」は時刻なしの保存だけ（時刻ありへ切り替えるなら日付は今日以降が要る。過去日の時刻つきの単発ができるのを防ぐ）
- 時刻なしで閉じた日を持つ単発は、元の日が何日でも日付を変えられない（AI 既定「閉じた単発の日付は変えられない」に合わせる。1-2 の書き方は抜けていた）
- 時刻つきの単発の日付を変えると、実績の occurrence_date も合わせて変わる（1-2 のとおり。今までとの小さな差）
- `record_tap_add` は actual_task.id を返す／`record_tap_remove`・`record_skip_clear` は記録が無ければ何もしない／回があるかは世代・O(d)・単発の有無だけで判定（rrule・除外日は見ない＝ checkin_set と同じ）
- 本番に当てる前に確かめる: anon が `actual_task_tap` を読める／`private` スキーマが既に無い
- 単発 → 繰り返し（template_create の p_replace_single_id）は、実績をつなぎ直す前に単発の検査（削除と同じ）を通す。今日より前に閉じた時刻なしの単発は変えられない／繰り越し中・今日閉じた単発は変えられ、記録は今日の回へ移る（Swift エージェントが発見）
- InMemory と SQL の突き合わせで揃えた細部: 世代が終了した日は回が無い（タップ・スキップ拒否）／回が見つからないときの目標は 1／その日だけの保存で効く世代が無い日は時刻の有無を検査しない／目標 1〜99 の外は丸めず拒否／時刻あり→なしの単発は created_at を残す／todo_fetch の actuals・older_closed は時刻なしの回だけ

## 本番適用の手順（2026-10-14 作成。本番には未適用。本人 OK の後に行う）
- 本人 OK（2026-10-15 11:17 原文「commitしてOK。DBへの変更も入れて良い」）。commit・push の後にこの手順で当てる
対象は Supabase の ref `hyngpesrmqodiegonoze`。0012 は使い捨ての Postgres 16 ＋ PostgREST で検証 1〜7 が通っている（`day-cycle-walkthrough.md`「時刻のないやること」の検証）。下の確認のクエリも、使い捨て DB（Supabase と同じ既定の権限のスタブ）で 0012 の前後に流し、期待どおりの結果になることを確かめた（2026-10-14。`schema_migrations` は Supabase にだけあるので除く）。

### 順序（前提の「本番の順序」と同じ）
1. 新ビルドを作る（commit・push は本人 OK の後）
2. 下の「事前に確かめる」を流す（読み取りだけ）
3. 0012 を適用する: Supabase MCP `apply_migration`（name `v2_untimed_tasks`、中身は `supabase/migrations/0012_untimed_tasks.sql` 全文）。冪等なので、途中で止まっても頭から流し直せる
4. すぐに新ビルドを入れる。適用から新ビルドを入れるまでの間は、旧ビルドの予定の保存が「関数が無い」で失敗する（引数が変わった 5 関数は DROP 済み）。読み取り・丸・スキップは動く。この間は数分に収める
5. 下の「適用後に確かめる」を流す
6. それから時刻なしの予定を作る。時刻なしを 1 件でも作った後と、目標 2 以上の時刻つきの予定を 1 件でも作った後は、旧ビルドに戻せない（0012 には戻す migration が無い）

### 事前に確かめる（読み取りだけ）
```sql
-- 1. private スキーマが既に無い (0 行であること。あれば中身を見てから名前を決め直す)
SELECT nspname FROM pg_namespace WHERE nspname = 'private';

-- 2. anon が新しい表 (actual_task_tap) を読めるか = public の既定の権限が anon・authenticated に表を開いている
--    (0012 は表に GRANT を書かず Supabase の既定に任せる。0009 sleep_record と同じ)。
--    defaclobjtype = 'r' の行の defaclacl に anon=… と authenticated=… が含まれること
SELECT defaclrole::regrole, defaclobjtype, defaclacl
  FROM pg_default_acl WHERE defaclnamespace = 'public'::regnamespace;
--    比較用: 既定の権限で作った既存の表に anon の権限があること (true)
SELECT has_table_privilege('anon', 'public.sleep_record', 'SELECT, INSERT, DELETE');

-- 3. 適用済みの migration が 0011 (v2_profile_body_weight) までであること (MCP list_migrations でも可)
SELECT version, name FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 3;
```

### 適用後に確かめる
```sql
-- backfill: 既存の実体の回の日 = 開始の JST 日 (0)・作った日時が埋まっている (0)
SELECT count(*) FROM scheduled_task WHERE occurrence_date IS DISTINCT FROM (start_at AT TIME ZONE 'Asia/Tokyo')::date;
SELECT count(*) FROM scheduled_task WHERE created_at IS NULL;
-- backfill: 回につながる done にタップが 1 つずつ (2 つの数が同じ)
SELECT (SELECT count(*) FROM actual_task WHERE status = 'done' AND (template_id IS NOT NULL OR scheduled_task_id IS NOT NULL) AND end_at IS NOT NULL) AS done_linked,
       (SELECT count(*) FROM actual_task_tap) AS taps;
-- 制約がすべて検査済み (10 行・すべて t)
SELECT conname, convalidated FROM pg_constraint
 WHERE conname IN ('task_template_version_target_chk','task_template_version_timing_chk','task_template_version_carry_chk',
                   'scheduled_task_target_chk','scheduled_task_timing_chk','actual_task_status_chk','actual_task_time_chk',
                   'actual_task_skipped_on_chk','actual_task_link_chk','actual_task_skip_needs_link');
-- 同じ名前の関数が重なって残っていない (0 行。重なると PostgREST が PGRST203)。拡張が public に置いた関数は除く (pg_depend の deptype 'e')
SELECT p.proname, count(*) FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
 GROUP BY p.proname HAVING count(*) > 1;
-- actual_task_tap の RLS が無効 (f。既存の表と同じ。有効だと anon の読み書きが 0 行になる)
SELECT relname, relrowsecurity FROM pg_class WHERE oid = 'public.actual_task_tap'::regclass;
-- 権限: すべて true
SELECT has_table_privilege('anon', 'public.actual_task_tap', 'SELECT, INSERT, DELETE') AS tap_table,
       has_function_privilege('anon', 'public.todo_fetch(date, date, date)', 'EXECUTE') AS todo_fetch,
       has_function_privilege('anon', 'public.record_tap_add(uuid, date, uuid, text, uuid, timestamptz, timestamptz, timestamptz, uuid)', 'EXECUTE') AS tap_add,
       has_schema_privilege('anon', 'private', 'USAGE') AS private_usage,
       has_function_privilege('anon', 'private.todo_closed_on(uuid)', 'EXECUTE') AS nested_call,
       has_function_privilege('anon', 'private.todo_is_open_carried(uuid, date)', 'EXECUTE') AS carried_call;
-- 内部の関数が public に無い (0 行)
SELECT proname FROM pg_proc WHERE pronamespace = 'public'::regnamespace
   AND proname IN ('todo_occurrence','todo_target','todo_closed_on','schedule_assert_single_editable','record_occurrence_checked',
                   'todo_is_open_carried');
-- 時刻なし 0 件の今は、旧ビルドの読み取りと同じ行 (時刻 NULL の行が 0)
SELECT (SELECT count(*) FROM task_template_version WHERE start_minutes_from_midnight IS NULL) AS untimed_versions,
       (SELECT count(*) FROM scheduled_task WHERE start_at IS NULL) AS untimed_entities;
-- PostgREST の関数の一覧を読み直す (Supabase は DDL で自動で読み直すが、念のため)
NOTIFY pgrst, 'reload schema';
```
- 新ビルドで確かめる: 予定タブが開き、時刻つきの行・丸が今と同じ。「やること」の節は時刻なしが無いので出ない（読み込みの失敗も出ない）。睡眠タブ・今日のカードが動く
- 0012 を当てる前に新ビルドを起動しない（新ビルドは 0012 の列・関数・表を前提にする。実装後レビュー R2）。0012 を戻すなら、先に旧ビルドに戻す
- 失敗したとき: 適用は 1 トランザクションなので、途中で止まれば何も変わらない。適用の後に新ビルドで問題が出たら、時刻なしを作る前なら旧ビルドでも読み取りは動く（予定の保存だけが失敗する）。0012 の取り消しは手で書く必要がある（関数の旧版は 0006・0007 にある）ので、本人と相談してから

## 親のシミュレータ確認で直したこと（2026-10-14・AI 既定）
- 時刻なしで閉じた単発（元の日が今日より前）は「時刻を決める」を押せなくし、下に「終わった単発は時刻を決められません。」（保存して初めてエラーになる形をやめる）。閉じた単発の日付の行は「10/11(日)」だけにし、「日付を変える」と「終わるまで翌日以降にも出ます。」を出さない
- 回数欄の「−」は見ている日以前のタップが 0 件なら押せない
- 読むだけ＋回数欄のシート（繰り越し中の繰り返しの回・過去日のやること）は、右上を「閉じる」1 つにする
- 未決（本人に提示済み）: スキップした当日の画面でも「スキップ（10/14）」と日付まで出る。当日は「スキップ」だけにするか

## 実装後レビュー（opus・2026-10-14）で直すこと（AI 既定）
- R1 「これ以降」で時刻の有無を変えたとき、D より後の「その日だけ」O(d) で時刻の有無が新しい中身と違うものは、その skipped の実績と一緒に消す（SQL・InMemory。残すと 2 か所に出たり、記録できない回が繰り越し続けたりする）
- R2 タップは実績の埋め込みでなく別の問い合わせで読み、失敗したら空として扱う（0012 が無い DB でも睡眠タブ・今日のカードが落ちない）。手順書に「0012 の前に新ビルドを起動しない」も書く
- R3 時刻つきの一覧は todo_fetch を待たずに出す。やることは届いた時点で反映する
- R4 楽観更新は読み込み元ごとに外す（時刻つきは日の読み込み、やることは todo_fetch の成功で）
- R5 タップの id はアプリが作り、`record_tap_add` に `p_tap_id` で渡す。読み込んだタップに同じ id があれば上乗せから外す（続けて押したとき 1 多く出るのを防ぐ）
- R6 status が skipped の回は、見ている日が skipped_on より前でも記録の操作を出さず、スキップの取り消しだけにする（表示は「スキップ（10/12）」）
- R7 記録の無い回のスキップにも楽観更新を効かせる
- R8 todo_fetch は時刻なしの世代・O を持つ系列に先に絞る。閉じた日は 1 回だけ求める
- R9 時刻なし → ありに切り替えた回の編集画面が、開いただけで「変更あり」にならないようにする
- R10 新しい規則のエラーは、Supabase の経路でも日本語の文言で出す
- R11 同じ回で前の回数の操作が失敗したら、後に並んだ操作は送らない
- R12 時刻つきの回の − は全部のタップの中で最新を消す（数え方と揃える。日をまたぐ回）
- R13 適用後の確認に actual_task_tap の RLS が無効なことを足す。関数の重なりの確認は拡張の関数を除く
