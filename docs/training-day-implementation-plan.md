<!-- 2026-10-23 本人が承認した計画（Claude Code の計画モードの原本 ~/.claude/plans/sequential-hugging-horizon.md を写した）。作業の記録は末尾の「作業時間」に足す -->
# トレーニングの日またぎ（前の日に 2:00 まで記録できる）実装計画

## Context

- 今のトレーニングは「セットの時刻の JST の日」で日を決めるので、0:00 をまたぐと 2 つに分かれる（前の日の記録が画面から消える・読み直すと画面が空になる・週の回数が 2 日）。調べた結果は `docs/gymwork-alignment-design.md` §3.5。
- 本人の決定（2026-10-22 23:5x〜10-23 01:0x。原文は同 §3.5 と `~/life/.life/secretary/decision-log.md`）:
  1. 記録する日は、トレーニングのタブの週の帯で選んでいる日。今日はいつでも、前の日は翌日の 2:00 まで、今日と同じ画面で ✓ できる。アプリが時刻で日を振り分けることはしない
  2. ただし、今日（0:00 以降）に記録があれば 2:00 前でも前の日は閉じる。今日の記録を全部消せば開く
  3. 段階 3 の後に作る（段階 3 は 10-23 00:4x に済んだ）。本人「先にさっき決めたトレーニング側の修正を入れたい」（10-23 01:0x）
- 伝え済みの AI 既定: 0:00 をまたいでも画面は選んでいた日のまま／~~前の日が閉じたら、前の日の ✓ していない種目と行を今日の画面に移す（開き直しても戻さない）~~（**2026-10-23 02:5x 本人の選択「移さない」で替えた: 前の日が閉じたら、✓ していないカードと行は消える**。`gymwork-alignment-design.md` §3.5 の 9）／✓ の取り消しも「消す」に数える
- 結果として、日のまとめ・ボリューム・分析・月の表・「前回」・週の回数・ウィジェットは、トレーニングの日で数える。予定のタブの時刻は実際の時刻のまま
- 本番の今のデータ【事実・読むだけの SQL・10-23 01:1x】: セッション 11（すべて別の日）・セット 118（時刻なし 0）・開いたままのセッション 0・セットとそのエントリーのセッションの食い違い 0

## 方針（要点）

- **DB（0015）**: トレーニングの日 `day` をセッションに持ち、各セットにも同じ値を写して外部キーで一致を保証する（セットは集計でいちばん多く読まれ、日で範囲を取るため）。1 人 1 日 1 セッション。時刻の窓（日の 0:00〜翌日 2:00）を DB の制約でも守る。`day` を送らない書き込み（今の iPhone のビルド・MCP の手入力）は、トリガーが始めた日・セッションの日で埋める → 0015 を先に流しても今のビルドは壊れない
- **アプリ**: 今日だけを持つ `WorkoutSessionStore` を「日ごとの状態」を持つ形に変える（今日と、開いている前の日の 2 つ）。画面は選んだ日の状態を出す。集計の「日」はすべて `set.day` に替える
- 2 つの store を並べる案は採らない（✓ の途中で行を移すと幽霊の行が残る・書き込みのロックと履歴のキャッシュが 2 重になる。設計の点検で指摘）

## 1. DB: `supabase/migrations/0015_training_day.sql`（新規）

順（1 つのトランザクション）:
1. `workout_session.day date`・`workout_set.day date` を足す → 埋める（セッションは `(started_at AT TIME ZONE 'Asia/Tokyo')::date`、セットはセッションから）→ DO の砦（同じ人の同じ日が 2 つ・窓の外・set.day ≠ session.day があれば止める）→ NOT NULL
2. CHECK（どちらも不変の式。`day::timestamptz` は使わない）:
   - セッション: `started_at >= (day::timestamp AT TIME ZONE 'Asia/Tokyo') AND started_at < (((day + 1) + time '02:00') AT TIME ZONE 'Asia/Tokyo')`
   - セット: `completed_at IS NULL OR (同じ形)`
   - 注: クライアントの送る時刻で検査するので、2:00 の締めと「今日に記録があれば閉じる」はアプリで守る（DB は窓の外のデータを入れない砦）
3. `UNIQUE (user_id, day)`・`UNIQUE (id, user_id, day)`（外部キーの的）。`workout_session_id_user_id_key` は残す（entry が使う）
4. `workout_set_session_id_fkey` を `(session_id, user_id, day) → workout_session (id, user_id, day) ON DELETE CASCADE` に作り直す（同じ名前）
5. `workout_set_entry_fk` を `(entry_id, session_id, exercise_id, user_id)` に締める（`workout_entry` に `UNIQUE (id, session_id, exercise_id, user_id)`。前の日のエントリーに今日のセットが付くのを DB で止める。本番の食い違いは 0）。外部キーの数は 19 のまま
6. `workout_session_single_in_progress`（1 人 1 つだけ開いている）を消す（前の日と今日が同時に開きうる。二重の作成は `UNIQUE (user_id, day)` が止める）。索引 `workout_set (user_id, day)`
7. トリガー関数 2 つを `private` に（SECURITY INVOKER・`SET search_path = ''`・名前はスキーマ付き・`authenticated` と `service_role` に EXECUTE、anon と PUBLIC には無し）。BEFORE INSERT で `day IS NULL` のときだけ埋める
8. `CREATE OR REPLACE VIEW public.workout_training_day WITH (security_invoker = true) AS SELECT DISTINCT day FROM public.workout_set WHERE completed_at IS NOT NULL`（**security_invoker を必ず書き直す**。書かないと全員の日が見える）＋ GRANT/REVOKE を書き直す

付随:
- `supabase/rollback/0015_down.sql`（新規）: view を戻す → 外部キーを戻す → 一意を消す → 開いているセッションが 1 人 2 つ以上なら古い方を閉じる（`ended_at = greatest(max(completed_at), started_at + 1s)`）→ `single_in_progress` を作り直す → 列とトリガーを消す。先頭に「戻すと、前の日に記録した 0:00 以降のセットはまた次の日に数えられる」と書く
- `supabase/test/run.sh`: `--rollback` を番号つき（既定 0014）に、`--dump` の `--from` をそのまま使えるように。トリガー関数も plpgsql_check にかける
- `supabase/test/checks.sql`: 関数 29 → 31・「authenticated は全関数を呼べる」はトリガー関数も含めて通る形（EXECUTE を付ける）・`single_in_progress` が無い・`day` が NOT NULL・CHECK が有効・トリガーが有効・set.day = session.day・view が security_invoker
- `supabase/test/multiuser_test.sql`・`write_all.sql`: 新しい CHECK で落ちる箇所（204-213 の前日のセット、224 の進行中 2 つ）を固定の時刻で直す。足す: 窓の外 23514・同じ日 23505・日の食い違い 23503・トリガーで埋まる・前の日に 0:30 のセットを入れると view がその日を返す・前の日と今日が同時に開ける

## 2. アプリ

### データの層
- `Models/Workout.swift`: `WorkoutSession.day`・`WorkoutSet.day`（`DateOnly` を手で読む形。`Models/ActualTask.swift:53-79` と同じ）。`WorkoutSet` に明示の init と、`with(setIndex:)`・`with(values:)` で day を写す
- `Services/WorkoutDataSource.swift`: `NewWorkoutSet.day`。メソッドを替える: `fetchInProgressSession` → `fetchSessions(days:)`（日で引く）と `fetchOpenSessions()`（片付け用）／`startSession(day:routineId:startedAt:)`（23505 なら日で引き直す）／`fetchSets(completedFrom:to:)` → `fetchSets(daysFrom:to:)`（`day` の半開区間・並びは day, completed_at, set_index, id）。`fetchTrainingDays` は呼び方そのまま（view が変わる）
- `SupabaseWorkoutDataSource.swift`・`MockWorkoutDataSource.swift`（DB と同じ制約を持たせる: 1 日 1 つ・窓・日の一致・entry のセッション一致。`fetchTrainingDays` の `Calendar.current` を直す）・`WorkoutFixtures.swift`

### 決まりの純粋な関数（新規 `Services/RecordWindow.swift`）
- `recordableDays(now:todayHasRecords:calendar:) -> [Date]`: 今日は必ず。前の日は「今が今日の 2:00 より前」かつ「今日の記録が 0」のとき
- `isPermanentlyClosed(day:now:)`: 前の日より前、または前の日で 2:00 を過ぎた（サーバーのセッションを閉じてよい日）

### `Services/WorkoutSessionStore.swift`（日ごとの状態にする）
- 中身を `days: [Date: DayState(session, sets, entries, cards)]` に。`drafts` はカードの id で引く 1 つの辞書のまま（id は日をまたいで一意）。`activeDay` と、その日を見せる計算プロパティ（`cards`・`sets`・`session`・`todayExerciseIds`）で、画面と多くのテストの呼び方を保つ
- 非同期の処理は、始めたときのカードやセットの日を使う（終わったときの `activeDay` を使わない）: `addSet`・`entryCreatingIfNeeded`・`nextSortOrder`・`writeEntryOrderIfChanged`・`refreshToday` → その日のセッションだけ取り直す・`removeOnServer`
- `load()` を壊さない形に: 開いている日（今日と、開いていれば前の日）のセッションを日で引いて入れ直す。カードと行は消さない（今はタブを替えるたびに前の日を閉じて行を消してしまう）。片付けは `isPermanentlyClosed` の日だけ（セットが無ければ消す・あれば最後のセットの時刻で閉じる。今の `close(staleSession:)` を使う）。閉じたセッションにも日で見つかれば足す（開き直しはしない）
- `reconcile(now:) -> 閉じた日`: 開いている日を計算し直し、閉じた前の日の ✓ していないカードと行を今日に移す（✓ 済みのカードの残りの行は、今日の新しいカードにして移す）。書き込みの途中なら終わるのを待ってから移す
- 書く前に窓を確かめる（閉じていたら書かずに失敗を返す。文言は【AI 既定】「前の日には記録できなくなりました」）
- `WorkoutSessionStore+Previous.swift`: 「前回」・過去の日・自己ベストの基準を `now()` から「その日（activeDay）より前」に
- 「今日」の判定・新しいセッションの日は、注入した時計で決める

### 集計を `set.day` に（完了時刻から日を作っている所を全部替える）
- `Services/WorkoutSummary.swift`: `recordedDays`・`weekTotals`（byDayMuscle も）・`latestDaySets(before:)`・`mergeToday` → `mergeLive(history, live: [Date: [WorkoutSet]])`。先頭の「日の基準は completed_at の暦日」の注記を書き直す
- `Services/WorkoutProgress.swift`: `daily` は `set.day` でまとめる・`previousDay(before:)`
- `Services/WorkoutHistoryStore.swift`: 取得を `fetchSets(daysFrom:to:)` に・週の振り分け・`sets(on:)`・`entries(on:)`
- `Services/StrengthLevels.swift`: 期間の絞り込みと `bodyWeight(on:)` を `set.day` で
- `Views/Workout/MonthHeatmapView.swift`（heatmapVolumes）・`TrainingContentPage.swift`（dayVolume）・`BodyStrengthViews.swift:331`（ベストの日）
- `Services/ContinuityStore.swift`: `recordedToday: Bool` を「開いている日ごとの記録の有無」に替え、`days`・`status`・`share` を合わせる（ウィジェットの週の回数も前の日に入る）
- 変えない: `dayTotals`・`timeRangeText`（実際の時刻の幅。「23:30–0:20 · 50分」になる）・予定のタブ（`SupabaseDayDataSource` の completed_at）

### 画面 `Views/Workout/WorkoutView.swift` ほか
- 時計: トレーニングのタブにも `ClockTick` を渡す（`LifeTrackerApp.swift` の MainTabView）。`today` を `clockTick.now` から。変わったら `store.reconcile(now:)`
- 日付をまたいだとき、`selectedDay == nil`（今日を見ていた）なら `selectedDay` を前の今日に留める（前の日が開いている間）
- 表示している前の日が閉じたら、今日に切り替え、その日に向いているシート（行の編集・並べ替え・種目の追加）を閉じる
- 開いている日なら編集できる一覧、そうでなければ `PastDayView`。`store.activeDay` を選んだ日に合わせる
- 開いている日が減ったら、履歴のキャッシュのその週を取り直す（今は `store.session?.id` の変化でしか取り直さない）
- 週の帯の点・`ContinuityRow`・分析の各ページは「履歴＋開いている日の記録」（`mergeLive`）で
- `programContext`・プログラムのメニュー・種目の追加の数・自己ベストの判定は、選んでいる日の状態で
- `Views/Workout/AnalysisView.swift`・`ExerciseDetailView.swift`: `Date()` をやめ、注入した時計／その日を使う
- 文言【AI 既定】前の日を開いているときだけ、「今日」を「この日」に替える: カードの見出し「今日 …（前回 …）」・メニュー「今日から外す」・プログラムのメニューの「今日の種目…」。上の帯の日付は「10/22(木)」と「今日へ」のまま（今の過去の日と同じ）

### 確かめのための DEBUG の起動の引数
- `Services/LaunchPlan.swift`: `-mock-now <ISO8601>`（DEBUG だけ・`-mock-workout` と一緒のときだけ効く・トレーニングのタブの時計だけずらす。休憩タイマーとライブアクティビティは実時刻のまま）。シミュレータで 0:30 や 2:00 の前後を本物の DB に触れずに見るため

## 3. テスト（Swift Testing・`LifeTrackerTests/`）

- `RecordWindow`: 1:59 と 2:00 の境・今日に記録があれば閉じる・前の日より前は常に閉じる
- store: 0:30 に前の日へ ✓ → セッションの日は前の日・始めた時刻は 0:30・セットの日も前の日／0:30 に読み直しても前の日のカードと行が消えない／今日に ✓ → 前の日が閉じ、✓ していない行が今日へ移る／今日の記録を全部取り消す → 前の日が開き、✓ 済みのカードだけが戻る／2:00 で閉じる／✓ の途中で閉じても幽霊の行が残らない／閉じた日の書き込みは失敗を返す／片付けは閉じてよい日だけ
- 集計: 月曜 0:30 に日曜へ記録したセットが日曜の週・日曜の回数に入る（WorkoutSummary・WorkoutProgress・HistoryStore・StrengthLevels・ContinuityStore）
- 今の振る舞いを書いたテストを新しい決まりに書き直す: `recordAcrossMidnightWithoutReload`・`staleSessionClosedOnLoad`・`emptyStaleSessionDeleted`・`lostResponseSetSurvivesClose`・WorkoutTests:172/192（開いているのは 1 つ）・WorkoutHistoryStoreTests（completedFrom）・WorkoutEntryTests:351-367（23:50 と 0:10）
- テストの `set(... at:)` の補助は、日を指定しなければ `at` の JST の日にする（書き直しを減らす）
- UI テスト 1 本（`-mock-now` で 0:30・前の日を選んで ✓ → 前の日の点がつく）

## 4. 進め方と分担（repo の CLAUDE.md の S 級: 親が設計を確定・1 件ずつ直列・親が差分を読む）

1. DB（0015・戻し・run.sh・checks・multiuser_test）→ docker で全部通す（空の DB から 0001〜0015・`--rollback 0015` の差分 0・10-23 のバックアップで 0013→0014→0015）【opus】
2. データの層・RecordWindow・store【opus】→ 親が差分を読む → 単体テスト
3. 集計・画面・時計・文言・`-mock-now`【opus】→ 親が差分を読む → 単体テスト＋UI テスト
4. シミュレータ（`-mock-day -mock-workout -mock-auth -mock-now …`）で 0:30・前の日を選んで ✓・今日に ✓ で閉じる・取り消しで開く・2:00 の後、をスクリーンショットで確かめる【親】
5. docs: `gymwork-alignment-design.md` §3.5（決まりと実装）・`continuity-design.md` の日の基準・`domain-model.md` の workout_session / workout_set
6. 本人に画面を見てもらう → commit・push は本人に言われてから

## 5. 本番に入れる順（本人の OK を別にもらう）

1. 本人のターミナルで `pg_dump`（U4 と同じ手順・`2026-10-XX-before-0015.dump`）
2. AI: そのバックアップで `run.sh --dump … --from 0015` のリハーサル
3. 本人の OK → 0015 を本番に（23:00〜2:30 とトレーニングの最中は避ける）。流れた SQL の md5・checks.sql を本番で
4. 本人が新しいビルドを iPhone に入れる（0015 の後なら順はどちらでも今のビルドは動く。新しいビルドで本番につなぐシミュレータを、iPhone に古いビルドがある間は使わない）
5. アプリだけ戻すときは、前の日より前の開いているセッションを閉じてから古いビルドを入れる

## 確かめ（完了条件）

- docker: 0001〜0015 が空の DB で全部通る・checks がすべて t・戻しの差分 0・本番の写しでのリハーサルが通る
- 単体テストが全件通る（今の 397 件＋新しいテスト）・UI テストが通る
- シミュレータで上の 4 の場面をスクリーンショットで確かめる
- 本番: 0015 の後の checks・md5・本人の行の件数（セッションとセットの日が埋まった）・2 人目から見えない・iPhone で前の日に記録できる（本人）

## 本人に確かめたいこと（承認のときに違えば言ってもらう）

- 文言: 前の日を開いているときの「今日 → この日」の置き換え（上の 3 か所）
- 表示している前の日が閉じたら、今日の画面に切り替える
- 閉じた後に ✓ したときの失敗の文言「前の日には記録できなくなりました」
- 前の日の締めは DB でも時刻の窓（日の 0:00〜翌日 2:00）で守るが、「今日に記録があれば閉じる」はアプリだけで守る

## 付録 A: 4 の 2（データの層・RecordWindow・store）の設計【親が確定・2026-10-23 01:4x。opus に渡す】

今の形（親が読んだ）: store は今日だけを持ち（`session`・`sets`・`entries`・`cards` が今日）、`load()` は `fetchInProgressSession()` が今日でなければ閉じて `cards`・`drafts` を空にする。✓ は `todaySessionCreatingIfNeeded()` で今日のセッションを作る。`WorkoutSessionStore+Previous.swift` の前回・過去・自己ベストは `now()` の日が基準。

### A-1. モデル `Models/Workout.swift`
- `WorkoutSession.day: Date`・`WorkoutSet.day: Date`（DATE。`DateOnly` で読み書き。`Models/ActualTask.swift:53-79` と同じ形の `init(from:)`・`encode(to:)` を **extension に**書いて、memberwise の init を残す）。`day` は最後の項目に置く（呼ぶ所は末尾に `, day:` を足すだけ）
- `WorkoutSet.with(setIndex:)`・`with(values:)` は day を写す
- 意味: セッションの day = 記録した日（週の帯で選んでいた日）。started_at の日とは限らない（前の日に 0:30 に始めた場合）。セットの day = セッションの day（DB の外部キーで一致）

### A-2. `Services/WorkoutDataSource.swift`（protocol）
- 消す: `fetchInProgressSession()`
- 足す: `fetchSessions(days: [Date]) -> [WorkoutSession]`（その日のセッション。終わったものも返す）・`fetchOpenSessions() -> [WorkoutSession]`（ended_at IS NULL。片付け用。前の日と今日の 2 つまでありうる）
- 替える: `startSession(day: Date, routineId: UUID?, startedAt: Date)`（同じ日が既にあれば失敗する＝UNIQUE (user_id, day)。startedAt はその日の 0:00〜翌日 2:00）／`fetchSets(completedFrom:to:)` → `fetchSets(daysFrom: Date, to: Date)`（セットの day の半開区間・completed_at IS NULL は除く・並びは day, completed_at, set_index, id。ページングは今と同じ）
- `NewWorkoutSet.day: Date`（`@DateOnly var day: Date`。Supabase の `NewWorkoutSession` も day を送る）
- `fetchTrainingDays()` の呼び方は今のまま（view が set.day を返すようになる）
- Supabase: 日の値は `DateOnly.formatter` の文字列（`SupabaseDayDataSource.swift:58` の `.in("date", values:)` と同じ書き方）
- Mock（`MockWorkoutDataSource.swift`）は DB と同じ制約を持つ: `duplicateDay`（1 人 1 日 1 つ）・`outsideWindow`（startedAt・completedAt が day の 0:00〜翌日 2:00 の外）・`dayMismatch`（set.day ≠ そのセッションの day）・`entryMismatch` を (entry の id, session_id, exercise_id) の一致に締める・`sessionAlreadyInProgress` は消す。`fetchTrainingDays` は `Set(completed のセットの day)`（`Calendar.current` をやめる）。テスト用に `insertSessionFromAnotherDevice(day:startedAt:)` を足す
- `WorkoutFixtures.swift`: セッションとセットに day（JST の日）を入れる

### A-3. 新規 `Services/RecordWindow.swift`（pure・テストしやすい 2 つの関数）
```swift
enum RecordWindow {
    static let closingHour = 2   // 前の日を締める時刻 (翌日の 2:00。0015 の CHECK と同じ)
    /// 記録できる日 (日の始まり)。今日は必ず (先頭)。前の日は now < 今日の 2:00 かつ todayHasRecords == false のとき (2 番目)
    static func recordableDays(now: Date, todayHasRecords: Bool, calendar: Calendar) -> [Date]
    /// もう二度と記録できない日 (サーバーのセッションを閉じてよい): 前の日より前、または前の日で now >= 今日の 2:00。今日と未来は false
    static func isPermanentlyClosed(day: Date, now: Date, calendar: Calendar) -> Bool
}
```

### A-4. `Services/WorkoutSessionStore.swift`（日ごとの状態）
```swift
struct DayState: Hashable { var session: WorkoutSession?; var sets: [WorkoutSet] = []; var entries: [WorkoutEntry] = []; var cards: [TodayCard] = [] }
@Published private(set) var days: [Date: DayState]      // 開いている日だけ。キーは calendar の日の始まり
@Published private(set) var openDays: [Date]            // RecordWindow.recordableDays の結果 (今日が先頭)
@Published private(set) var today: Date                 // load・reconcile が進める (時計が 0:00 を越えても reconcile までは前のまま)
@Published private(set) var activeDay: Date             // 画面が見せて書く日。既定は今日。setActiveDay(_:) は開いていない日なら今日にする
@Published private(set) var drafts: [UUID: [DraftSet]]  // カードの id で引く (id は日をまたいで一意)
// 画面と今のテストの呼び方を保つ (activeDay の状態): session・sets・entries・cards・todayExerciseIds は計算プロパティ
func sets(on day: Date) -> [WorkoutSet]                 // 開いている日のセット (週の帯の点・続けている週の数が使う。4 の 3)
func day(ofCard id: UUID) -> Date?                      // card(id:)・sets(for card:) はカードの日で引く
func reconcile(now: Date) async -> [Date]               // 戻り値 = 閉じた日 (画面が履歴のその週を取り直す)
```
- **非同期の処理は、始めたときのカード・セットの日を使う**（終わったときの activeDay を使わない）: addSet・entryCreatingIfNeeded・nextSortOrder・writeEntryOrderIfChanged・refreshToday（→ `refreshDay(_:)`）・removeOnServer（`set.day`）・removePlannedCard・replacePlannedCard。`addPlannedExercise`・`moveCard`・`saveCardOrder` は呼んだときの activeDay
- **✓（addSet）**: isWriting を取る → カードの日を引く（無ければ busy）→ `now` を 1 回だけ読む → その日が `recordableDays(now, 今日の記録の有無)` に無ければ書かずに `applyOpenDays(now:)` して `StoreError.dayClosed`（文言「前の日には記録できなくなりました」）→ その日のセッション（無ければ `startSession(day:routineId:nil, startedAt: now)`。失敗したら `fetchSessions(days: [day])` で引き直し、あればそれを使ってその日のセットと entry を取り直す。無ければ元のエラー）→ entry → `addSet(... completedAt: now, day: day)` → その日の sets に足す → **✓ した行を drafts から外すのは isWriting を放す前**（`completeDraft` は外す行の id を渡す形にする。放した後に外すと、間で移した行に幽霊が残る）→ 今日の記録が 0 → 1 になったら `applyOpenDays(now:)`（前の日が閉じる）
- **取り消し・削除（undoSet・deleteSet）**: セットの日が開いていなければ dayClosed。消した後、今日の記録が 1 → 0 になったら `applyOpenDays(now:)`（2:00 前なら前の日が開く）
- **updateSet**: セットの日が開いていなければ dayClosed（completed_at は変えないので DB は通るが、閉じた日は画面で編集させない）
- **applyOpenDays(now:)**（呼ぶ側が isWriting を持つ）: 今日が変わっていれば `today` を進め、新しい今日の空の状態を足す → `recordableDays` を計算 → 開いていなくなった日は「閉じる」: その日の ✓ していないカード（その日のセットが無いカード）は同じ id のまま entryId を nil にして今日の末尾へ（行はそのまま）。✓ 済みのカードに残っている行は、今日の末尾に新しいカード（新しい id）を作って行を移す。✓ 済みで行が無いカードは消える（drafts も消す）→ days から外す → 新しく開いた前の日（今日の記録を全部消した）は、サーバーから `fetchSessions(days:)`・セット・entry を取り、cards = `WorkoutLogic.reconcile([], with: entries)`（✓ 済みのカードだけが戻る。移したカードは今日のまま）・取れなければ空の状態 → `openDays` を更新 → activeDay が開いていなければ今日 → 閉じた日のうち `isPermanentlyClosed` の日のサーバーのセッションを `close(staleSession:)`（今のまま: セットが無ければ消す・あれば最後のセットの時刻で閉じる。失敗しても止めない）。「今日に記録があるから閉じた」だけの日はサーバーで閉じない（また開きうる）
- **reconcile(now:)**: 開く日と今日が今と同じなら何もしない（毎分呼ばれる）。違えば isWriting が空くまで待ち（20ms ごと）、取って `applyOpenDays(now:)`
- **load()**（壊さない形）: `now` を 1 回読み、今日と前の日のセッションを `fetchSessions(days:)` で引き、あればセットと entry を取る → `recordableDays` → 開いている日は `DayState`（cards は **今あるカード**を `WorkoutLogic.reconcile(days[d]?.cards ?? [], with: entries)`）。開いていなくなった日は applyOpenDays と同じ規則で今日へ移す。**カードと行を空にしない**（今はタブを替えるたびに前の日を閉じて消してしまう）。どのカードにも属さなくなった drafts だけ消す → 片付けは `fetchOpenSessions()` のうち `isPermanentlyClosed` の日だけ `close(staleSession:)`（開いている日のセッションは閉じない）→ 終わったセッションでも日で見つかれば使う（開き直さない）→ history を空にして取り直し、全部の日のカードの行を用意する（今と同じ）
- **読んでいる間の書き込み**: `revision`（セット・entry を変える書き込みが終わるたびに +1）を load の始めに覚え、反映の前に変わっていたら読み直す（3 回まで）。今は load と ✓ が重なると、読んだ古い状態で ✓ したセットが消えうる
- 前回・推移（`WorkoutSessionStore+Previous.swift`）: `ordinal(of:)`・`previousSets(for:)`・`previousSet(for:position:)`・`prepareDrafts` は**カードの日**が基準（その日より前の最後の日）。`previousDay(for:)`・`pastDays(for:)` は activeDay より前。`bestOneRMBeforeToday` → `bestOneRMBeforeActiveDay`（呼ぶ所 `WorkoutView.swift:489` も直す）。`loadHistory` の前回の日の entry は、開いている日それぞれの前回の日の分を取る。`WorkoutProgress.previousDay(_:today:calendar:)` には基準の日を渡す（中の日の作り方を set.day にするのは 4 の 3）
- 時計: 今のまま注入した `now`（4 の 3 で画面の `ClockTick` から `reconcile(now:)` を呼ぶ）

### A-5. この段で直す呼ぶ所（ビルドを通すだけ。集計の中身は 4 の 3）
- `WorkoutHistoryStore.swift:67` を `fetchSets(daysFrom:to:)` に（週の頭の日をそのまま渡す）
- `WorkoutView.swift:489` の名前
- テストの `WorkoutSet(...)`・`WorkoutSession(...)`・`NewWorkoutSet(...)` に day（補助の `set(... at:)` は日を指定しなければ `at` の JST の日）

### A-6. テスト（Swift Testing）
- 新規 `RecordWindowTests.swift`: 1:59 と 2:00 の境・今日に記録があれば閉じる・前の日より前は常に閉じる・23:00 は今日だけ
- 新規 `TrainingDayStoreTests.swift`: ① 0:30 に前の日（activeDay）へ ✓ → セッションの日は前の日・started_at は 0:30・セットの日も前の日 ② 0:30 に load し直しても前の日のカードと行が消えない ③ 今日に ✓ → 前の日が閉じ、✓ していないカードと行が今日へ・✓ 済みのカードの残りの行は今日の新しいカードへ・activeDay は今日 ④ 今日の記録を全部取り消す → 前の日が開き、✓ 済みのカードだけが戻る（移したカードは今日のまま） ⑤ 2:00 の reconcile で閉じ、サーバーの前の日のセッションが閉じる（セットが無ければ消える） ⑥ 1:59:59 に前の日へ ✓（Mock の `addSetDelayNanoseconds`）している間に時計を 2:00:30 にして reconcile → ✓ したセットは前の日に 1 つ・移した行に ✓ した行が混ざらない ⑦ 時計だけ 2:01 にして（reconcile なし）前の日のカードに ✓ → `dayClosed`・セットは増えない・カードは今日へ移っている ⑧ load の片付けは閉じてよい日だけ（2 日前の開いたままは閉じる・前の日の 1:00 は閉じない） ⑨ 別の端末が今日のセッションを先に作っていた（`insertSessionFromAnotherDevice`）→ ✓ はそのセッションに入る ⑩ 23:50 に今日へ ✓ → 時計を 0:10 にして reconcile → 開く日は [新しい今日, 前の日]・activeDay は前の日のまま → 同じカードに ✓ → 同じセッション・セットの日は前の日 ⑪ Mock の制約（同じ日・窓の外・日の食い違い・別のセッションの entry）
- 今の振る舞いを書いたテストを新しい決まりに書き直す: `recordAcrossMidnightWithoutReload`・`staleSessionClosedOnLoad`・`emptyStaleSessionDeleted`・`lostResponseSetSurvivesClose`・`WorkoutTests.swift` の 172 と 192 あたり（開いているのは 1 つ）・`WorkoutHistoryStoreTests.swift:41`・`WorkoutEntryTests.swift` の 351〜367（23:50 と 0:10）
- 完了の条件: BUILD と単体テスト（`-only-testing:LifeTrackerTests`）が全部通る。今の 397 件のうち消したテストがあれば名前と理由を報告

## 付録 B: 4 の 3（集計・画面・時計・文言・`-mock-now`）の設計【親が確定・2026-10-23 01:5x。4 の 2 の結果を見て直す】

### B-1. 集計の「日」を `set.day` に（完了時刻から日を作っている所を全部替える）
- `WorkoutSummary.swift`: 先頭の注記を「日の基準はセットの day（トレーニングの日。0015）。completed_at は時刻の幅（dayTotals・timeRangeText）にだけ使う」に／`recordedDays` は completed のセットの `day`／`weekTotals` の週の絞り込みと byDayMuscle の日は `set.day`／`latestDaySets(_:today:)` → `latestDaySets(_:before:)`／`mergeToday` → `mergeLive(history: [WorkoutSet], live: [Date: [WorkoutSet]]) -> [WorkoutSet]`（履歴から live の日を除いて live を足す）
- `WorkoutProgress.swift`: `daily` は `set.day` でまとめる（completed のみ・日の中は記録順のまま）／`previousDay(_:today:calendar:)` → `previousDay(_:before:calendar:)`
- `WorkoutHistoryStore.swift`: 週の振り分け・`sets(on:)` を `set.day` で。`entries(on:)` の注記の「0 時またぎ（E4）」は「セッションのセットはすべて同じ日」に
- `StrengthLevels.swift`: `summarize`・`cardioTotals` の期間の絞り込みと `bodyWeight(on:)` の日を `set.day` で（interval は日の始まりの半開区間なので `interval.start <= set.day && set.day < interval.end`）
- `MonthHeatmapView.swift`（heatmapVolumes の日・mergeLive）・`TrainingContentPage.swift`（dayVolume の日・mergeLive 2 か所）・`BodyStrengthViews.swift:331`（ベストの日の表記は `best.day`）
- `ContinuityStore.swift`: `days(today:recordedToday:)` → `days(live: [Date: Bool])`（開いている日 → 記録があるか。trainingDays から開いている日を除き、記録がある日を足す）／`status(today:live:)`・`share(today:live:)`。呼ぶ所（WorkoutView・MonthHeatmapView:120）も
- 変えない: `dayTotals`・`timeRangeText`（実際の時刻の幅。「23:30–0:20 · 50分」になる）・予定のタブ（`SupabaseDayDataSource` の completed_at）

### B-2. 時計と `-mock-now`
- `LaunchPlan`: `mockNow: Date?`（DEBUG で `-mock-workout` と一緒のときだけ。`-mock-now 2026-10-23T00:30:00+09:00` の次の引数を ISO8601 で読む。読めなければ nil）
- 起動の組み立て → `MainTabView` → `WorkoutView(dataSource:profileStore:clockTick:nowOffset:)`。`nowOffset = mockNow − 起動の時刻`（本物は 0）。store の `now` は `{ Date().addingTimeInterval(nowOffset) }`。休憩タイマー・ライブアクティビティ・予定と睡眠のタブは実時刻のまま
- `-mock-workout` のデータ（`WorkoutFixtures.makeMockDataSource(now:)`）にもずらした時刻を渡す（「昨日」が mock の今の昨日になるように）
- `WorkoutView`: `.onChange(of: clockTick.now)` で `store.reconcile(now: store.now())`。戻り値（閉じた日）が空でなければ `historyStore.invalidate()` → 履歴を取り直す → `continuity.load()` → share。今の `.onChange(of: store.session?.id)` による取り直しはやめる（日をまたいでもセッションの id では分からなくなった）
- `AnalysisView`・`ExerciseDetailView` の `Date()` → `store.today`／`store.now()`

### B-3. 画面 `WorkoutView.swift`
- `today` は `store.today`。`selectedDay: Date?`（nil = 今日）はそのまま。`displayedDay = selectedDay ?? today`
- `displayedDay` が `store.openDays` に入っていれば編集できる一覧（今の todayList。中身は activeDay の状態）、入っていなければ `PastDayView`。`displayedDay` が変わったら・出たときに `store.setActiveDay(displayedDay)`
- 日付をまたいだとき（`.onChange(of: store.today)`）: `selectedDay == nil` で前の今日がまだ開いていれば `selectedDay = 前の今日`（画面は選んでいた日のまま）
- 表示している日が開いている → 閉じたとき（`.onChange(of: store.openDays)` で、前は入っていて今は無い）: `selectedDay = nil`（今日へ）・`editing = nil`・`isReordering = false`・`picker = nil`
- 週の帯の点: `historyStore.recordedDays` から開いている日を除き、開いている日のうち `store.sets(on:)` が空でない日を足す
- `displayedSets`: 開いている日は `store.sets(on:)`、そうでなければ `historyStore.sets(on:)`
- `ContinuityRow`・ウィジェットの share・`MonthHeatmapView` の連続: `live = openDays → !store.sets(on:).isEmpty`。share は live が変わったときと目標が変わったとき
- `programContext`: `todayCounts` は activeDay のカード、`latestSets` は `latestDaySets(_:before: displayedDay)`
- ✓ の失敗 `dayClosed` は今のカードの下の文言の出し方のまま（カードは今日へ移っていて、同じ id なら今日のカードの下に出る）

### B-4. 文言【AI 既定】前の日を開いているとき（activeDay ≠ today）だけ「今日」を「この日」に
- カードの見出し: `WorkoutSummary.cardHeadline` に日の呼び方を渡す（「この日 1,105kg · e1RM 69kg（前回 …）」）
- カードのメニュー「今日から外す」→「この日から外す」（`TodayExerciseCard.swift:111`）
- プログラムのメニュー（`ProgramViews.swift` の TodayProgramMenu: 「今日の種目（n種目）」「今日の種目を新しいプログラムに保存」「今日の種目で上書き」「今日と同じ内容です」と、`ProgramDraft` の題「今日の種目で上書き」）
- 変えない: 上の帯の「10/22(木)」と「今日へ」（今の過去の日と同じ）・「種目を追加」の下の説明

### B-5. テスト
- 集計: 月曜 0:30 に日曜へ記録したセット（day = 日曜・completed_at = 月曜 0:30）が、日曜の週・日曜の回数・日曜のボリュームに入る（WorkoutSummary の recordedDays・weekTotals・mergeLive・latestDaySets／WorkoutProgress.daily・previousDay／HistoryStore の週と sets(on:)／StrengthLevels の期間と体重の日／ContinuityStore.days(live:)）
- `LaunchPlan` の `-mock-now`（読める・読めない・`-mock-workout` が無いと効かない・Release は効かない）
- UI テスト 1 本: `-mock-day -mock-workout -mock-auth -mock-now <前の日の翌 0:30>` → 週の帯で前の日を選ぶ → 種目を足して ✓ → 前の日に点が付き、上の帯は前の日のまま
- 今の呼び方を使うテスト（mergeToday・latestDaySets(today:)・previousDay(today:)・days(today:recordedToday:)）を新しい形に

## 作業時間

- 2026-10-23 01:0x〜01:2x 計画モード: 調べ 3 つ（データの層・日で集計している所・画面の流れ。opus の Explore）→ 設計の点検（Plan）で「2 つの store」をやめて日ごとの状態を持つ 1 つの store に・`load()` が前の日の行を消す・閉じた後の履歴のキャッシュ・view の security_invoker の書き直し・entry の外部キーの締め、を足した → 01:2x 本人が計画を承認（「本人に確かめたいこと」の 4 点は AI 既定のまま）
- 2026-10-23 01:3x 本人「実装に入る前に一旦止まって」→ 止めた。この時点でしたのは記録だけ（この計画を docs に写した・`gymwork-alignment-design.md` §3.5 に 1 行・vault の決定の記録と日次ノートと memory）。コード・SQL・本番は触っていない
- 2026-10-23 01:3x 本人「実装に入って」→ 4 の 1（DB の 0015）から始めた
- 2026-10-23 01:3x〜01:4x 4 の 1（DB）済み【親が書いた】: `0015_training_day.sql`・`rollback/0015_down.sql`・`run.sh`（`--rollback [N]`・トリガーの関数も plpgsql_check・0014 より後から流すリハーサルは表ごとの行数が同じかを見る）・`checks.sql`（「day:」の 7 行・関数 31）・`multiuser_test.sql`（11 を足した・4 の B のセッションと A の 2 つ目を固定の時刻に）・`write_all.sql`（セッションとセットを今日の 9 時台に固定）
  - 先に本番を読むだけの SQL で: セッション 11・同じ日の重なり 0・窓の外のセット 0・セッションと違う日のセット 0・開いたまま 0 → 埋めた後も日ごとの数は今と変わらない
  - docker: 空の DB から 0001〜0015 が全部通る（checks すべて t・関数の md5 f4f35958…）／`--rollback 0015` と `--rollback`（0014）の差分 0／開いているセッションが 3 つある人の戻しで 1 つになる／10-23 のバックアップで 0013→0014→0015（行数の照合も通る）
  - 本番の 0015 のリハーサルは 0014 の後の写しから `--from 0015` で流す。模擬の写し（docker で 0014 まで流して pg_dump）で試したら 2 つ止まったので `run.sh` を直した: btree_gist が写しに無い（extensions は写さない）→ 先に入れる／stub の既定の権限が戻した表・view に付く（anon が表を読め、authenticated が view に書けた）→ public の既定の権限を空にしてから戻す。直した後は通り、空の DB から作った形と表・view・関数・権限が同じ（違いは本番だけにある supabase_admin の既定の権限など）
  - わざと壊した 6 通り（view の security_invoker なし・種目 1 回分の外部キーにセッションなし・セッションの窓なし・トリガーの関数に EXECUTE なし・窓を 3:00 まで・進行中 1 件の一意を残す）はすべて落ちる。トリガーは EXECUTE が無くても動く（checks だけが拾う）
- 2026-10-23 01:4x 4 の 2 の設計を親が今のコード（store・data source・モデル・テスト）を読んで決め、上の付録 A に書いた → opus に渡した（実装と単体テスト）。待つ間に 4 の 3 の設計のために集計と画面を読む
- 2026-10-23 02:1x 4 の 2 済み【opus が実装・親が差分を読んだ】: モデル（day・Codable は extension）・protocol（fetchSessions(days:)・fetchOpenSessions・startSession(day:)・fetchSets(daysFrom:)）・Supabase・Mock（1 日 1 つ・窓・日の食い違い・entry のセッション一致）・`RecordWindow.swift`（新規）・日ごとの store。単体テスト 415 件すべて通過（今の 397＋18。親が回し直して確かめた）。⑥（✓ の途中の 2:00）は reconcile が待たないように壊すと落ちることを opus が確かめた
  - 付録 A から足したこと（opus）: load も書き込みの終わりを待ってから反映する／開き直した前の日のカードはセットのある entry だけから作る／取り消し・削除・編集の窓の判定は ✓ と同じ／init では今日だけ開き、前の日は load で開く／revision は reconcile・並べ替え・空の entry を消したときも進める
  - 親が読んで確かめた所: 閉じた日の行の付け替え（cardsMovedToToday）・✓ の行を外すのがガードを放す前・片付けは isPermanentlyClosed の日だけ・セッションの作成の失敗で日で引き直す・Supabase の day の絞り込み（`.in("day")`・`not.is.null`）
  - opus が挙げた振る舞いの変化: アプリを開いたまま翌朝に読み直すと、前の日に残っていた行（✓ 済みのカードの残りの行・足しただけの種目の空の 1 行）が今日のカードとして出る（今までは消えた）→ 本人に聞く
- 2026-10-23 02:5x 本人に聞いた（4 の 2 で分かった振る舞い: 計画どおりだと翌朝に前の日のやり残しが今日に並ぶ）。問い「前の日が閉じたとき、前の日の残りの行（✓ していない種目・✓ 済みの種目の残りの行）をどうしますか？」→ 本人の選択「移さない」（推奨は「今日に記録して閉じたときだけ移す」だった）→ store の閉じる処理を「消す」に替える（親が直す）。上の Context の AI 既定に取り消し線
- 2026-10-23 02:2x〜03:0x 4 の 3【opus が実装】: 付録 B の B-1〜B-5。opus の報告: ビルド警告 0・単体 427 件・UI 9 件すべて通過（新しい UI テスト `testRecordPreviousDayAfterMidnight`: `-mock-now 2026-10-23T00:30:00+09:00` で 10/22 を選んで ✓）。付録 B から変えた所: 閉じた日の後の取り直しは reconcile の戻り値でなく「開いている日が減った」をきっかけに（今日に ✓ して閉じるときは reconcile を通らない）／今日と開いている日を 1 つの onChange（DayWindow）で見る（2:00 の後に開き直すと両方同時に変わる）／`share(live:)`・`currentTarget(today:)`（Date() をやめた）
- 2026-10-23 03:0x 本人の選択「移さない」に合わせて親が直した: store の閉じる処理（applyLoaded・applyOpenDays）は前の日のカードと行を消す（`cardsMovedToToday` を消した）・テストの ③④⑥⑦ を「消える」に・`WorkoutTests` の `removeAllDrafts` は要らなくなったので消した・画面は閉じた後の ✓・取り消し・編集・削除の dayClosed をアラートで出す（カードがその日ごと消えて下に文言を出せない）・表示していない日の行の編集シートを開いたままその日が閉じたら閉じる（`EditorTarget.cardId`）
- 2026-10-23 03:0x 親の直しの後、単体テスト 427 件（失敗 0）・UI テスト 9 件（失敗 0）すべて通過
- 2026-10-23 03:0x〜03:1x 4 の 4（シミュレータ）済み【親】: 一時の UI テスト（スクリーンショットを撮るだけ。確かめた後に消した・repo には入れていない）で `-mock-day -mock-workout -mock-auth -mock-now …` の画面を撮って見た。0:30: 前の日（10/22）を選ぶと編集できる一覧（見出し「この日 …」・上の帯は「10/22(木)」と「今日へ」）→ ✓ で 10/22 が 9 セット・4 種目、上の帯は 10/22 のまま → 今日に ✓ すると今日に点・見出しは「今日 …」、10/22 は読むだけの画面（0:30 に足したベンチを含めて 9 セット）→ 今日の ✓ を取り消すと今日は「まだ記録なし」・10/22 がまた編集できる（✓ 済みのカードだけ）。1:59:20 から待つと、2:00 を過ぎた最初の毎分の時計で今日の画面に切り替わり、10/22 は読むだけ。時刻の幅は確認用のデータが朝 7 時の記録なので「7:00–0:30 · 1050分」になる（計画どおり実際の時刻の幅のまま）
- 2026-10-23 03:0x〜03:1x 4 の 5（docs）: `domain-model.md`（workout_session の前に 0015 の注記）・`continuity-design.md`（トレーニングした日の定義と view）・`gymwork-alignment-design.md`（§3.5 の 9・10、日の基準と mergeToday の行に日付つきの注記）・`gymwork-design-duplicate-and-reorder.md`（E4）。過去のレビューの記録（body-strength-review・body-strength-and-heatmap-period）の mergeToday は当時の記録なので直していない
- 次: 4 の 6 本人に画面を見てもらう → commit・push は本人に言われてから → 5 本番に 0015（別の OK。0014 の後の pg_dump → `run.sh --dump … --from 0015` のリハーサル → 23:00〜2:30 とトレーニングの最中を避けて流す → 新しいビルドを iPhone に）
- 2026-10-23 03:3x 本人「OK。」→ 画面の確認は済み（4 の 6）と受け取った。commit・push と本番の 0015 は、それぞれ本人に言われてから
- 2026-10-23 03:4x 本人「commit & pushしていいよ」→ 4 つに分けて commit して `feat/round3-training` に push（DB の 0015 と確かめ・アプリとテスト・日またぎの docs・段階 3 の記録の docs）。本番の 0015 はまだ（別の OK）。食事の docs と体型の画像は入れていない（未追跡のまま）
- 既知の振る舞い（4 の 3 で opus が挙げ、直していないもの）: 前の日が開き直したとき、サーバーから読み終わるまでその日の点が一瞬消える（store はいったん空の状態を足す）／日が閉じると履歴のキャッシュを全部捨てて読み直すので、点と過去日が一瞬「読み込み中」（前と同じ形）
- 2026-10-23 04:0x 本人「dumpから進めたい」→ 5 の 1（本人のターミナルで `pg_dump` → `~/Backups/life-tracker/2026-10-23-before-0015.dump`）から始める
- 2026-10-23 04:1x〜04:2x `pg_dump` がパスワードの違いで失敗（何も取れていない）→ 本人「パスワードを作り直したい」。本番の DB のパスワードを使うのは本人の `pg_dump` だけ（アプリは公開のキー、MCP はアクセストークン。`~/dev` に本番への直の接続文字列を持つファイルは無い・AI が grep で確かめた）
- 2026-10-23 04:2x 本人「作り直さなくていけた。」→ バックアップ `2026-10-23-before-0015.dump`（04:25・172,668 バイト。パスワードは作り直していない）
- 2026-10-23 04:2x 5 の 2 のリハーサル（`run.sh --dump … --from 0015 --owner <本人の UID>`）が通った: 流す前と後で 21 表の行数が同じ（workout_session 12・workout_set 137 ほか）・plpgsql_check の error 0・multiuser_test 全部（11 のトレーニングの日を含む）・checks.sql 全部 t（関数 31・外部キー 19・policy 24・view 2 つが security_invoker）
- 2026-10-23 04:2x 本番を読むだけの SQL: セッション 12（人は 1 人）・開いたまま 1（10-23 01:49 に始まり、最後のセットは 03:28・直近 30 分のセットは 0）・セット 137・`day` の列は無い・最後の migration は `v2_multiuser_rls`。開いているセッションは 0015 で日が 10-23 になる（03:28 のセットは 10-22 の窓の外なので、前の日には移せない）
- 2026-10-23 04:3x 本人「流して」→ 5 の 3: 0015 を本番に（MCP apply_migration `v2_training_day`・version 20261022193108 = 04:31 JST・成功）。確かめ: 本番に記録された SQL とファイルの md5 が一致（ef52f9e7835a82e8b478b560fd3bcc33）・本番の checks.sql が全部 t（関数の定義の md5 f4f35958… がリハーサルと同じ）・行は流す前と同じ（セッション 12・セット 137・種目 42。すべてに日・人と日の組は 12 で重なり 0・view のトレーニングした日 12 = 時刻で数えた日 12）・開いているセッションは 10-23 の日。本番の checks.sql（execute_sql）でも MCP の確認の画面が出て、1 回目は期限切れ（読むだけなので何も変わらない）→ 流し直して通った。残り: 5 の 4（本人が新しいビルドを iPhone に）
- 2026-10-23 04:4x 本人「commit & pushしていいよ」→ 9a24c32（0015 の本番適用の記録・CLAUDE.md の注記）を `feat/round3-training` に push
- 2026-10-23 04:4x〜04:5x 本人「iPhoneに入れた」→ 5 の 4 済み。本番の API のログ（edge_logs・04:49〜04:50）: 新しいビルドの要求はすべて 200／204（`workout_session?day=in.(10-23,10-22)`・`workout_set?day=gte…`・`workout_training_day` を含む。load は今日と前の日を必ず読み、開いている日だけを使う形のとおり）。行は変わらず（セッション 12・開いているのは 10-23 の 1 つ・セット 137）。security advisor に 0015 に関わる指摘は無い（出たのは Auth の漏れたパスワードの検査が無効の 1 件だけ）。本番に入れる 5 の 1〜4 は全部済み
- 完了条件（上の「確かめ」）の残り（2026-10-23 04:5x）: 「iPhone で前の日に記録できる（本人）」だけ。次に 0:00 をまたいで記録するとき（前の日を週の帯で選んで ✓・2:00 まで）に本人が見る。「2 人目から見えない」は本番の checks.sql（RLS・権限）とリハーサルの multiuser_test で確かめた（本番でセッションを持つ人は 1 人だけ）
