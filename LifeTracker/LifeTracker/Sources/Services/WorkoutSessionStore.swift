import Foundation
import Combine

/// トレーニング画面の状態。書き込みは WorkoutDataSource 経由のみ、導出は WorkoutLogic / WorkoutProgress に委ねる。
///
/// 開始・終了の操作は持たない (2026-09-30 本人フィードバック「単純に何をしたのかを記録したい」)。
/// その日 (トレーニングの日) 最初のセット記録でその日の workout_session を作り、もう記録できない日の進行中セッションは閉じる。
///
/// 記録する日は週の帯で選んでいる日 (2026-10-22〜23 本人決定。docs/training-day-implementation-plan.md 付録 A)。
/// 開いている日 (今日と、RecordWindow で開いていれば前の日) ごとに状態 (DayState) を持ち、画面は activeDay の状態を見せる。
/// 非同期の処理は、始めたときのカード・セットの日を使う (終わったときの activeDay を使わない)
@MainActor
final class WorkoutSessionStore: ObservableObject {
    /// 開いている 1 日分の状態
    struct DayState: Hashable {
        /// その日のセッション (まだ 1 セットも記録していなければ nil)
        var session: WorkoutSession?
        var sets: [WorkoutSet] = []
        /// その日のセッションの entry
        var entries: [WorkoutEntry] = []
        /// 画面のカードの並び。記録済みカードの相対順は entry の sort_order (= 実施した順) と一致させる。
        /// 記録しても勝手には動かさない (記録のたびにカードが動くと押し間違えるため)。動かすのは並べ替えだけ
        var cards: [TodayCard] = []
    }

    @Published private(set) var exercises: [Exercise] = []
    /// 開いている日の状態だけを持つ。キーは calendar の日の始まり。閉じた日のカードと行は消す (今日へ移さない。2026-10-23 本人「移さない」)
    @Published private(set) var days: [Date: DayState]
    /// 記録できる日 (RecordWindow.recordableDays の結果。今日が先頭)
    @Published private(set) var openDays: [Date]
    /// 今日 (日の始まり)。load・reconcile が進める (時計が 0:00 を越えても reconcile までは前のまま)
    @Published private(set) var today: Date
    /// 画面が見せて書く日。既定は今日。開いていない日にはならない (setActiveDay・閉じたときに今日へ戻す)
    @Published private(set) var activeDay: Date
    /// 未保存の行 (カード id → 行)。アプリ内メモリのみで、✓ を押した行だけ DB に入る。カードの id は日をまたいで一意
    @Published private(set) var drafts: [UUID: [DraftSet]] = [:]
    /// 種目ごとの全セット (前回・推移・履歴の元データ)
    @Published private(set) var history: [UUID: [WorkoutSet]] = [:]
    /// 前回の日の entry (前回の対応と履歴の区切りの順番)。history を取るときに、開いている日それぞれの前回の日のセッション分だけ取る
    @Published private(set) var historyEntries: [UUID: WorkoutEntry] = [:]
    @Published private(set) var isLoading = false
    /// 書き込み中。二度押しで同じ set_index / その日のセッションを重複 INSERT しないためのガード。
    /// 日を閉じる (その日のカードと行を消す) のも、これを取ってから行う
    @Published private(set) var isWriting = false
    @Published var error: Error?

    /// セット・entry を変える書き込みが終わるたびに +1。load は読み始めの値と比べ、読んでいる間に書き込みが終わっていたら読み直す
    /// (読んだ古い状態で反映すると、その間に ✓ したセットが消えうる)
    private var revision = 0
    /// load の読み直しの上限
    private static let loadRereadLimit = 3

    private let dataSource: WorkoutDataSource
    let calendar: Calendar
    /// 今日の判定の時計 (テストで差し替える)。記録の時刻・新しいセッションの日・開いている日の計算に使う
    let now: () -> Date

    init(dataSource: WorkoutDataSource, calendar: Calendar, now: @escaping () -> Date = { Date() }) {
        self.dataSource = dataSource
        self.calendar = calendar
        self.now = now
        // 前の日が開いているかは今日の記録の有無で決まるので、load で読むまでは今日だけを開く
        let today = calendar.startOfDay(for: now())
        self.today = today
        self.activeDay = today
        self.openDays = [today]
        self.days = [today: DayState()]
    }

    var exercisesById: [UUID: Exercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    // MARK: - activeDay の状態 (画面と今のテストの呼び方を保つ)

    /// activeDay のセッション (まだ 1 セットも記録していなければ nil)
    var session: WorkoutSession? { days[activeDay]?.session }
    /// activeDay のセット
    var sets: [WorkoutSet] { days[activeDay]?.sets ?? [] }
    /// activeDay のセッションの entry
    var entries: [WorkoutEntry] { days[activeDay]?.entries ?? [] }
    /// activeDay の画面のカードの並び
    var cards: [TodayCard] { days[activeDay]?.cards ?? [] }

    /// activeDay の種目 (画面順・同じ種目は枚数ぶん重複する)。プログラムへの保存・同じ並びの判定に使う
    var todayExerciseIds: [UUID] { cards.map(\.exerciseId) }

    /// 画面が見せて書く日を選ぶ。開いていない日なら今日
    func setActiveDay(_ day: Date) {
        let target = key(day)
        activeDay = openDays.contains(target) ? target : today
    }

    /// 開いている日のセット (週の帯の点・続けている週の数が使う)。開いていない日は空
    func sets(on day: Date) -> [WorkoutSet] {
        days[key(day)]?.sets ?? []
    }

    /// カードのある日 (開いている日のどれか)。無ければ nil
    func day(ofCard id: UUID) -> Date? {
        days.first { $0.value.cards.contains { $0.id == id } }?.key
    }

    /// カードの日で引く
    func card(id: UUID) -> TodayCard? {
        day(ofCard: id).flatMap { day in days[day]?.cards.first { $0.id == id } }
    }

    /// そのカードのセット (set_index 順)。カードの日で引く。未記録のカードは空
    func sets(for card: TodayCard) -> [WorkoutSet] {
        guard let entryId = card.entryId, let day = day(ofCard: card.id) else { return [] }
        return (days[day]?.sets ?? []).filter { $0.entryId == entryId }.sorted { $0.setIndex < $1.setIndex }
    }

    /// その種目の activeDay の全セット (記録順)。自己ベストの判定など種目単位の用途
    func sets(for exerciseId: UUID) -> [WorkoutSet] {
        sets(for: exerciseId, on: activeDay)
    }

    private func sets(for exerciseId: UUID, on day: Date) -> [WorkoutSet] {
        (days[day]?.sets ?? []).filter { $0.exerciseId == exerciseId }
            .sorted { ($0.completedAt ?? .distantPast, $0.setIndex) < ($1.completedAt ?? .distantPast, $1.setIndex) }
    }

    // MARK: - 読み込み

    /// 開いている日 (今日と、開いていれば前の日) のセッションを日で引いて入れ直す。カードと行は消さない
    /// (開いている日はいまのカードを DB の entry に合わせ、開かなくなった日のカードと行は消す)。
    /// 全件取得してから一括で反映する (途中で失敗したときに半端な状態を作らない)
    func load() async {
        isLoading = true
        defer { isLoading = false }
        var snapshot: LoadSnapshot?
        do {
            for _ in 0...Self.loadRereadLimit {
                let startRevision = revision
                snapshot = try await readSnapshot()
                // 書き込みの途中に反映すると、✓ の途中のカードの日を閉じて消してしまう (reconcile と同じく終わるのを待つ)
                guard await waitForWrites() else { return }
                if revision == startRevision { break }
            }
        } catch {
            report(error)
            return
        }
        guard let snapshot else { return }
        // ここから反映まで await を挟まない (書き込みが割り込まない)
        applyLoaded(snapshot)
        exercises = snapshot.exercises
        history = [:] // 日付が変わった後の再表示でも前回・推移を取り直す

        // 片付け: もう記録できない日の開いたままのセッションだけ閉じる (開いている日のセッションは閉じない)
        if let error = await closeStaleSessions(now: snapshot.now) { report(error) }
        let allCards = days.keys.sorted().flatMap { days[$0]?.cards ?? [] }
        for exerciseId in Set(allCards.map(\.exerciseId)) { await loadHistory(exerciseId: exerciseId) }
        for card in allCards { prepareDrafts(card) }
    }

    private struct LoadSnapshot {
        let now: Date
        let exercises: [Exercise]
        let states: [Date: DayState]
    }

    private func readSnapshot() async throws -> LoadSnapshot {
        let now = now()
        let today = key(now)
        let readDays = [today, calendar.date(byAdding: .day, value: -1, to: today)!]
        async let exercisesResp = dataSource.fetchExercises()
        async let statesResp = fetchDayStates(readDays)
        let (exercises, states) = try await (exercisesResp, statesResp)
        return LoadSnapshot(now: now, exercises: exercises, states: states)
    }

    /// 日のセッション・セット・entry をまとめて読む。セッションの無い日は入れない (cards は空。呼ぶ側が合わせる)。
    /// 終わったセッションでも日で見つかれば使う (開き直さない)
    private func fetchDayStates(_ targets: [Date]) async throws -> [Date: DayState] {
        var result: [Date: DayState] = [:]
        for session in try await dataSource.fetchSessions(days: targets) {
            async let setsResp = dataSource.fetchSets(sessionId: session.id)
            async let entriesResp = dataSource.fetchEntries(sessionId: session.id)
            let (sets, entries) = try await (setsResp, entriesResp)
            result[key(session.day)] = DayState(session: session, sets: sets, entries: entries)
        }
        return result
    }

    /// 読んだ状態を反映する。開いている日は、いまのカードを DB の entry に合わせる。開かなくなった日 (日付が変わった・
    /// 今日に記録がある・2:00 を過ぎた) のカードは持たない (reconcile と同じく消す)。どのカードにも属さなくなった行も消す
    private func applyLoaded(_ snapshot: LoadSnapshot) {
        let newToday = key(snapshot.now)
        let open = RecordWindow.recordableDays(now: snapshot.now,
                                               todayHasRecords: !(snapshot.states[newToday]?.sets.isEmpty ?? true),
                                               calendar: calendar)
        var next: [Date: DayState] = [:]
        for day in open {
            var state = snapshot.states[day] ?? DayState()
            state.cards = WorkoutLogic.reconcile(days[day]?.cards ?? [], with: state.entries)
            next[day] = state
        }
        today = newToday
        days = next
        openDays = open
        if !open.contains(activeDay) { activeDay = newToday }
        let alive = Set(next.values.flatMap { $0.cards.map(\.id) })
        drafts = drafts.filter { alive.contains($0.key) }
    }

    // MARK: - 開いている日の計算し直し (日付の変わり目・2:00・今日の記録の有無)

    /// 時計の進みに合わせて開いている日を計算し直す (画面が毎分呼ぶ)。開く日と今日が今と同じなら何もしない。
    /// 変わるときは書き込みが終わるのを待ってから閉じる・開く (✓ の途中のカードの日を閉じない)。戻り値は閉じた日 (画面が履歴のその週を取り直す)
    @discardableResult
    func reconcile(now: Date) async -> [Date] {
        guard needsApply(now: now) else { return [] }
        guard await waitForWrites() else { return [] }
        isWriting = true
        defer {
            isWriting = false
            revision += 1
        }
        return await applyOpenDays(now: now)
    }

    private func needsApply(now: Date) -> Bool {
        let newToday = key(now)
        let open = RecordWindow.recordableDays(now: now, todayHasRecords: hasRecords(on: newToday), calendar: calendar)
        return newToday != today || open != openDays
    }

    /// 書き込みが終わるまで待つ。待っている間に取り消されたら false (取り消された task で回り続けない)
    private func waitForWrites() async -> Bool {
        while isWriting {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// 開いている日を now で計算し直す (呼ぶ側が isWriting を持つ)。今日が変わっていれば進めて空の状態を足し、
    /// 開いていなくなった日は閉じて、その日のカードと行を消す (今日へ移さない。2026-10-23 本人「移さない」)。
    /// 新しく開いた前の日 (今日の記録を全部消した) はサーバーから読み直す (✓ 済みのカードだけが戻る)。
    /// 閉じた日のうち、もう記録できない日 (isPermanentlyClosed) だけサーバーのセッションを閉じる。
    /// 「今日に記録があるから閉じた」だけの日はサーバーで閉じない (また開きうる)。戻り値は閉じた日
    @discardableResult
    private func applyOpenDays(now: Date) async -> [Date] {
        let newToday = key(now)
        if newToday != today {
            today = newToday
            if days[newToday] == nil { days[newToday] = DayState() }
        }
        let open = RecordWindow.recordableDays(now: now, todayHasRecords: hasRecords(on: newToday), calendar: calendar)
        let closed = days.keys.filter { !open.contains($0) }.sorted()
        for day in closed {
            if let state = days.removeValue(forKey: day) {
                for card in state.cards { drafts[card.id] = nil }
            }
        }
        let reopened = open.filter { days[$0] == nil }
        for day in reopened { days[day] = DayState() }
        openDays = open
        if !open.contains(activeDay) { activeDay = newToday }

        if !reopened.isEmpty, let fetched = try? await fetchDayStates(reopened) {
            for (day, loaded) in fetched {
                let checked = loaded.entries.filter { entry in loaded.sets.contains { $0.entryId == entry.id } }
                update(day) { state in
                    let cards = state.cards // 読んでいる間に足した予定のカード
                    state = loaded
                    state.cards = WorkoutLogic.reconcile(cards, with: checked)
                }
            }
        }
        if closed.contains(where: { RecordWindow.isPermanentlyClosed(day: $0, now: now, calendar: calendar) }) {
            _ = await closeStaleSessions(now: now) // 失敗しても止めない (次の load の片付けでやり直す)
        }
        return closed
    }

    /// その日に今 (now) 記録できるか。できなければ開いている日を計算し直し (閉じた日のカードと行は消える)、false を返す。
    /// 呼ぶ側が isWriting を持つ
    private func ensureRecordable(_ day: Date, now: Date) async -> Bool {
        let open = RecordWindow.recordableDays(now: now, todayHasRecords: hasRecords(on: key(now)), calendar: calendar)
        guard open.contains(day) else {
            await applyOpenDays(now: now)
            return false
        }
        return true
    }

    /// 今日 (now の日) の記録の有無が変わったら、開いている日を計算し直す (0 → 1 で前の日が閉じ、1 → 0 で 2:00 前なら開く)
    private func applyOpenDaysIfNeeded(hadTodayRecords: Bool, now: Date) async {
        guard hasRecords(on: key(now)) != hadTodayRecords else { return }
        await applyOpenDays(now: now)
    }

    private func hasRecords(on day: Date) -> Bool {
        !(days[day]?.sets.isEmpty ?? true)
    }

    // MARK: - カードと行

    /// 種目を activeDay の画面に足し、前回の値で埋めた行を用意する。同じ種目がその日にあっても 2 枚目として足す
    @discardableResult
    func addPlannedExercise(_ exerciseId: UUID) async -> TodayCard {
        let card = TodayCard(id: UUID(), exerciseId: exerciseId, entryId: nil)
        update(activeDay) { $0.cards.append(card) }
        await loadHistory(exerciseId: exerciseId)
        prepareDrafts(card)
        return card
    }

    /// 未記録のカードを外す (記録済みのカードは外せない)。セットの無い entry の残骸があれば消す
    func removePlannedCard(_ card: TodayCard) async {
        guard let day = day(ofCard: card.id), let current = self.card(id: card.id), sets(for: current).isEmpty else { return }
        update(day) { $0.cards.removeAll { $0.id == card.id } }
        drafts[card.id] = nil
        await discardEmptyEntry(current.entryId, day: day)
    }

    /// 未記録のカードの種目を差し替える (Gymwork の ⇄)。位置は保ち、行は差し替え先の前回値で作り直す。
    /// その日にある種目への差し替えも可 (2 枚目になる)。記録済みのカード・同じ種目への差し替えは何もしない
    func replacePlannedCard(_ card: TodayCard, with exerciseId: UUID) async {
        guard let day = day(ofCard: card.id), let index = days[day]?.cards.firstIndex(where: { $0.id == card.id }),
              let old = days[day]?.cards[index], sets(for: old).isEmpty, old.exerciseId != exerciseId else { return }
        let replacement = TodayCard(id: UUID(), exerciseId: exerciseId, entryId: nil)
        update(day) { $0.cards[index] = replacement }
        drafts[old.id] = nil
        await discardEmptyEntry(old.entryId, day: day)
        await loadHistory(exerciseId: exerciseId)
        prepareDrafts(replacement)
    }

    /// 並べ替え (シートの ≡)。activeDay の画面の並びだけを同期で変える (List の onMove は同期で反映しないと行が跳ねる)。
    /// 続けて saveCardOrder で DB に書く
    func moveCard(fromOffsets source: IndexSet, toOffset destination: Int) {
        update(activeDay) { state in
            // Array.move(fromOffsets:toOffset:) は SwiftUI のため、同じ規則 (destination は移動前の位置) で並べ直す
            let moving = source.map { state.cards[$0] }
            let insertAt = destination - source.filter { $0 < destination }.count
            var rest = state.cards.enumerated().filter { !source.contains($0.offset) }.map(\.element)
            rest.insert(contentsOf: moving, at: insertAt)
            state.cards = rest
        }
    }

    /// 記録済みカードの相対順が DB と違うときだけ書く (未記録のカードの移動では書かない)。呼んだときの activeDay の並び。
    /// 進行中の書き込み (✓ など) が終わってから送る。失敗は戻り値で返す (画面の並びはそのまま)
    @discardableResult
    func saveCardOrder() async -> Error? {
        let day = activeDay
        while isWriting { try? await Task.sleep(for: .milliseconds(20)) }
        isWriting = true
        defer {
            isWriting = false
            revision += 1
        }
        do {
            try await writeEntryOrderIfChanged(day: day)
            return nil
        } catch {
            return error
        }
    }

    func updateDraft(cardId: UUID, draftId: UUID, input: WorkoutSetInput) {
        guard let index = drafts[cardId]?.firstIndex(where: { $0.id == draftId }) else { return }
        drafts[cardId]?[index].input = input
    }

    func addDraft(cardId: UUID) {
        guard let card = card(id: cardId) else { return }
        let rows = drafts[cardId] ?? []
        let recorded = sets(for: card)
        let lastRow = rows.last?.input ?? recorded.last.map { WorkoutLogic.input(from: $0, keepWarmup: false) }
        let position = recorded.count + rows.count
        let input = WorkoutLogic.nextDraft(lastRow: lastRow, previousAtPosition: previousSet(for: card, position: position))
        drafts[cardId, default: []].append(DraftSet(input: input))
    }

    /// 「残りのセットに適用」: この行より下の未保存の行を同じ値にする (ウォームアップ区分は各行のまま)
    func applyToRemaining(cardId: UUID, from draftId: UUID) {
        guard let rows = drafts[cardId], let index = rows.firstIndex(where: { $0.id == draftId }) else { return }
        let source = rows[index].input
        for i in rows.indices where i > index {
            var input = source
            input.isWarmup = rows[i].input.isWarmup
            drafts[cardId]?[i].input = input
        }
    }

    func removeDraft(cardId: UUID, draftId: UUID) {
        drafts[cardId]?.removeAll { $0.id == draftId }
    }

    /// ✓: 行を DB に保存し、成功したら未保存の行から外す (外すのは書き込みのガードを放す前)
    @discardableResult
    func completeDraft(card: TodayCard, exercise: Exercise, draftId: UUID) async -> Result<WorkoutSet, Error> {
        guard let draft = drafts[card.id]?.first(where: { $0.id == draftId }) else {
            return .failure(StoreError.busy)
        }
        return await record(card: card, exercise: exercise, input: draft.input, completingDraft: draftId)
    }

    /// 行の初期値: 前回の同じ順番のかたまり。それが無い 2 枚目以降は、その日のその種目の最後のセット
    /// (まだ無ければ前回の日の最後のセット) を写した 1 行 (Q2「a」)。前回はカードの日より前
    private func prepareDrafts(_ card: TodayCard) {
        guard drafts[card.id] == nil, let day = day(ofCard: card.id) else { return }
        let current = sets(for: card)
        let previous = previousSets(for: card)
        if previous.isEmpty, current.isEmpty, ordinal(of: card) > 1 {
            let source = sets(for: card.exerciseId, on: day).last ?? previousDay(for: card.exerciseId, before: day)?.sets.last
            drafts[card.id] = [DraftSet(input: source.map { WorkoutLogic.input(from: $0, keepWarmup: false) } ?? WorkoutSetInput())]
            return
        }
        drafts[card.id] = WorkoutLogic.initialDrafts(currentSets: current, previousSets: previous).map { DraftSet(input: $0) }
    }

    func loadHistory(exerciseId: UUID) async {
        guard history[exerciseId] == nil else { return }
        do {
            let loaded = try await dataSource.fetchExerciseSets(exerciseId: exerciseId)
            // 開いている日それぞれの前回の日のセッション (前回の対応の順番に entry を使う)
            let previousSessions = openDays.compactMap { WorkoutProgress.previousDay(loaded, before: $0, calendar: calendar) }
                .flatMap { $0.sets.map(\.sessionId) }
            let sessionIds = Set(previousSessions).subtracting(historyEntries.values.map(\.sessionId))
            if !sessionIds.isEmpty {
                for entry in try await dataSource.fetchEntries(sessionIds: Array(sessionIds)) { historyEntries[entry.id] = entry }
            }
            history[exerciseId] = loaded
        } catch {
            report(error)
        }
    }

    // MARK: - 書き込み

    /// 失敗は戻り値で返す (呼び出し側の画面で表示する。push 先から root の alert は出ないことがあるため)。
    /// カードの最初の ✓ で entry を作り、画面上の位置に差し込む (実施した順の初期値)
    @discardableResult
    func addSet(card: TodayCard, exercise: Exercise, input: WorkoutSetInput) async -> Result<WorkoutSet, Error> {
        await record(card: card, exercise: exercise, input: input, completingDraft: nil)
    }

    /// ✓ の本体。カードの日 (始めたときの日) のセッションに、now を 1 回だけ読んで記録する。
    /// その日に今は記録できなければ書かずに dayClosed (開いている日を計算し直し、閉じた日のカードと行は消える)
    private func record(card: TodayCard, exercise: Exercise, input: WorkoutSetInput,
                        completingDraft draftId: UUID?) async -> Result<WorkoutSet, Error> {
        guard !isWriting else { return .failure(StoreError.busy) }
        let validated: WorkoutSetInput.Validated
        switch input.validate(for: exercise.metricKind) {
        case .failure(let validationError): return .failure(validationError)
        case .success(let v): validated = v
        }

        isWriting = true
        defer {
            isWriting = false
            revision += 1
        }
        guard let day = day(ofCard: card.id) else { return .failure(StoreError.busy) }
        let now = now()
        let hadTodayRecords = hasRecords(on: key(now))
        guard await ensureRecordable(day, now: now) else { return .failure(StoreError.dayClosed) }

        let session: WorkoutSession
        let entryId: UUID
        do {
            session = try await sessionCreatingIfNeeded(day: day, startedAt: now)
            entryId = try await entryCreatingIfNeeded(cardId: card.id, day: day, session: session)
        } catch {
            return .failure(error)
        }

        do {
            let created = try await dataSource.addSet(NewWorkoutSet(
                sessionId: session.id,
                exerciseId: exercise.id,
                entryId: entryId,
                setIndex: WorkoutLogic.nextSetIndex(forEntry: entryId, in: days[day]?.sets ?? []),
                weight: validated.weight, reps: validated.reps,
                durationSec: validated.durationSec, distanceM: validated.distanceM,
                isWarmup: validated.isWarmup,
                completedAt: now,
                day: day
            ))
            // 同じセットを二重に持たない (読み直しが INSERT の後・応答の前に読んでいた場合)
            update(day) { state in
                if !state.sets.contains(where: { $0.id == created.id }) { state.sets.append(created) }
            }
            // 未ロードの履歴に 1 件だけ入れると loadHistory が「ロード済み」と誤認して前回が出なくなる
            if history[exercise.id]?.contains(where: { $0.id == created.id }) == false { history[exercise.id]?.append(created) }
            // ✓ した行はガードを放す前に外す (行の出し入れを ✓ の中で終える。放した後だと間で日を閉じる処理と入れ違う)
            if let draftId { drafts[card.id]?.removeAll { $0.id == draftId } }
            await applyOpenDaysIfNeeded(hadTodayRecords: hadTodayRecords, now: now)
            return .success(created)
        } catch {
            // INSERT が通ってレスポンスだけ失われた可能性があるため、サーバーの状態に合わせ直す
            await refreshDay(day, sessionId: session.id)
            if let refreshedHistory = try? await dataSource.fetchExerciseSets(exerciseId: exercise.id) {
                history[exercise.id] = refreshedHistory
            }
            await applyOpenDaysIfNeeded(hadTodayRecords: hadTodayRecords, now: now)
            return .failure(error)
        }
    }

    /// その日のセッション。無ければ startedAt で作る。作れなければ (別端末が先に作った = UNIQUE (user_id, day)・
    /// 作成の応答だけ失われた) 日で引き直し、あればそれを使ってその日のセットと entry を取り直す。無ければ元のエラー
    private func sessionCreatingIfNeeded(day: Date, startedAt: Date) async throws -> WorkoutSession {
        if let session = days[day]?.session { return session }
        do {
            let created = try await dataSource.startSession(day: day, routineId: nil, startedAt: startedAt)
            update(day) { state in
                state.session = created
                state.sets = []
                state.entries = []
                state.cards = WorkoutLogic.reconcile(state.cards, with: [])
            }
            return created
        } catch {
            guard let existing = try? await dataSource.fetchSessions(days: [day]).first else { throw error }
            async let setsResp = dataSource.fetchSets(sessionId: existing.id)
            async let entriesResp = dataSource.fetchEntries(sessionId: existing.id)
            let (sets, entries) = try await (setsResp, entriesResp)
            update(day) { state in
                state.session = existing
                state.sets = sets
                state.entries = entries
                state.cards = WorkoutLogic.reconcile(state.cards, with: entries)
            }
            return existing
        }
    }

    /// カードの entry。無ければ作り (sort_order = その日の最大 + 1)、画面でそのカードより下に記録済みカードがあれば
    /// 画面順に並べ直す。作成に失敗したら取り直し、応答だけ失われた自分の entry があればそれを使い、
    /// 無ければ (別端末と同時に作って UNIQUE に当たった = E5) 1 回だけやり直す
    private func entryCreatingIfNeeded(cardId: UUID, day: Date, session: WorkoutSession) async throws -> UUID {
        guard let card = days[day]?.cards.first(where: { $0.id == cardId }) else { throw StoreError.busy }
        if let entryId = card.entryId, days[day]?.entries.contains(where: { $0.id == entryId }) == true { return entryId }
        let created: WorkoutEntry
        do {
            created = try await dataSource.addEntry(sessionId: session.id, exerciseId: card.exerciseId, sortOrder: nextSortOrder(day: day))
            update(day) { $0.entries.append(created) }
        } catch {
            let referenced = Set(days[day]?.cards.compactMap(\.entryId) ?? [])
            let fetched = try await dataSource.fetchEntries(sessionId: session.id)
            update(day) { $0.entries = fetched }
            let daySets = days[day]?.sets ?? []
            if let lost = fetched.last(where: { entry in
                !referenced.contains(entry.id) && entry.exerciseId == card.exerciseId && !daySets.contains { $0.entryId == entry.id }
            }) {
                created = lost
            } else {
                update(day) { $0.cards = WorkoutLogic.reconcile($0.cards, with: fetched) }
                created = try await dataSource.addEntry(sessionId: session.id, exerciseId: card.exerciseId, sortOrder: nextSortOrder(day: day))
                update(day) { $0.entries.append(created) }
            }
        }
        // 画面の並びは変えない (reconcile は DB の順に並べ直すので、ここでは使わない)
        update(day) { state in
            if let index = state.cards.firstIndex(where: { $0.id == cardId }) { state.cards[index].entryId = created.id }
        }
        // 差し込みの失敗はセットの記録を止めない (entry は末尾のまま。次の並べ替えで画面順が入る)
        try? await writeEntryOrderIfChanged(day: day)
        return created.id
    }

    private func nextSortOrder(day: Date) -> Int { ((days[day]?.entries ?? []).map(\.sortOrder).max() ?? 0) + 1 }

    /// 記録済みの行の編集 (入力シートの「保存」)。completed_at・set_index は変えない。休憩タイマーには触れない。
    /// 閉じた日の行は編集させない (completed_at は変えないので DB は通るが、閉じた日は画面で編集できない決まり)
    @discardableResult
    func updateSet(_ set: WorkoutSet, exercise: Exercise, input: WorkoutSetInput) async -> Result<WorkoutSet, Error> {
        guard !isWriting else { return .failure(StoreError.busy) }
        let validated: WorkoutSetInput.Validated
        switch input.validate(for: exercise.metricKind) {
        case .failure(let validationError): return .failure(validationError)
        case .success(let v): validated = v
        }

        isWriting = true
        defer {
            isWriting = false
            revision += 1
        }
        guard await ensureRecordable(key(set.day), now: now()) else { return .failure(StoreError.dayClosed) }
        do {
            let updated = try await dataSource.updateSet(id: set.id, values: validated)
            replace(updated)
            return .success(updated)
        } catch {
            return .failure(error)
        }
    }

    /// スワイプの削除。後ろのセットの番号は詰める (DB は RPC で、ローカルは同じ規則で振り直す)。
    /// セットの日が閉じていれば dayClosed。今日の記録が 0 になったら開いている日を計算し直す (2:00 前なら前の日が開く)
    @discardableResult
    func deleteSet(_ set: WorkoutSet) async -> Error? {
        guard !isWriting else { return StoreError.busy }
        isWriting = true
        defer {
            isWriting = false
            revision += 1
        }
        let now = now()
        let hadTodayRecords = hasRecords(on: key(now))
        guard await ensureRecordable(key(set.day), now: now) else { return StoreError.dayClosed }
        let error = await removeOnServer(set)
        await applyOpenDaysIfNeeded(hadTodayRecords: hadTodayRecords, now: now)
        return error
    }

    /// ✓ の取り消し: 行を DB から消し、同じ値で未保存の行の先頭に戻す (確認なし。失うのは記録時刻だけ)。
    /// entry が空になってもカードは残る (再 ✓ で entry を作り直し、画面の位置に差し込む = E1)。
    /// セットの日が閉じていれば dayClosed。今日の記録が 0 になったら開いている日を計算し直す (✓ の取り消しも「消す」に数える)。
    /// 成功したら戻した行の id を返す
    @discardableResult
    func undoSet(_ set: WorkoutSet) async -> Result<UUID, Error> {
        guard !isWriting else { return .failure(StoreError.busy) }
        isWriting = true
        defer {
            isWriting = false
            revision += 1
        }
        let now = now()
        let day = key(set.day)
        let hadTodayRecords = hasRecords(on: key(now))
        guard await ensureRecordable(day, now: now) else { return .failure(StoreError.dayClosed) }
        let cardId = days[day]?.cards.first { $0.entryId == set.entryId }?.id
        let error = await removeOnServer(set)
        let draft = DraftSet(input: WorkoutLogic.input(from: set, keepWarmup: true))
        if error == nil, let cardId { drafts[cardId, default: []].insert(draft, at: 0) }
        await applyOpenDaysIfNeeded(hadTodayRecords: hadTodayRecords, now: now)
        if let error { return .failure(error) }
        return .success(draft.id)
    }

    /// 削除してセットの日の sets・entries と history の番号を詰め直す。失敗時は削除が通って応答だけ失われた可能性があるため、サーバーに合わせ直す
    private func removeOnServer(_ set: WorkoutSet) async -> Error? {
        let day = key(set.day)
        do {
            try await dataSource.deleteSet(id: set.id)
            update(day) { state in
                state.sets = WorkoutLogic.removingAndRenumbering(set, from: state.sets)
                state.entries = WorkoutLogic.pruningEntry(set.entryId, remainingSets: state.sets, entries: state.entries)
                state.cards = WorkoutLogic.reconcile(state.cards, with: state.entries)
            }
            if let loaded = history[set.exerciseId] {
                history[set.exerciseId] = WorkoutLogic.removingAndRenumbering(set, from: loaded)
            }
            return nil
        } catch {
            if Self.isCancellation(error) { return nil }
            if let sessionId = days[day]?.session?.id, set.sessionId == sessionId { await refreshDay(day, sessionId: sessionId) }
            if history[set.exerciseId] != nil,
               let refreshedHistory = try? await dataSource.fetchExerciseSets(exerciseId: set.exerciseId) {
                history[set.exerciseId] = refreshedHistory
            }
            return error
        }
    }

    /// その日のセットと entry をサーバーに合わせ直す (その日のセッションだけ。失敗は黙って諦める。呼び出し元が元のエラーを返す)
    private func refreshDay(_ day: Date, sessionId: UUID) async {
        if let refreshed = try? await dataSource.fetchSets(sessionId: sessionId) { update(day) { $0.sets = refreshed } }
        if let refreshed = try? await dataSource.fetchEntries(sessionId: sessionId) {
            update(day) { state in
                state.entries = refreshed
                state.cards = WorkoutLogic.reconcile(state.cards, with: refreshed)
            }
        }
    }

    /// その日の記録済みカードの画面順が entry の sort_order と違えば RPC で揃える
    private func writeEntryOrderIfChanged(day: Date) async throws {
        guard let state = days[day], let session = state.session else { return }
        let screen = state.cards.compactMap(\.entryId)
        guard screen != state.entries.sorted(by: { $0.sortOrder < $1.sortOrder }).map(\.id) else { return }
        try await dataSource.reorderEntries(sessionId: session.id, entryIds: screen)
        update(day) { $0.entries = WorkoutLogic.reordering($0.entries, sessionId: session.id, entryIds: screen) }
    }

    /// セットの無い entry (E6 の残骸) を消す。失敗しても画面には影響しない (過去日には出ない)
    private func discardEmptyEntry(_ entryId: UUID?, day: Date) async {
        guard let entryId, !(days[day]?.sets.contains { $0.entryId == entryId } ?? false) else { return }
        guard (try? await dataSource.deleteEntry(id: entryId)) != nil else { return }
        update(day) { $0.entries.removeAll { $0.id == entryId } }
        revision += 1
    }

    private func replace(_ updated: WorkoutSet) {
        update(key(updated.day)) { state in
            if let index = state.sets.firstIndex(where: { $0.id == updated.id }) { state.sets[index] = updated }
        }
        if let index = history[updated.exerciseId]?.firstIndex(where: { $0.id == updated.id }) {
            history[updated.exerciseId]?[index] = updated
        }
    }

    // MARK: - 片付け

    /// もう記録できない日 (RecordWindow.isPermanentlyClosed) の開いたままのセッションを閉じる。開いている日のセッションは閉じない。
    /// 1 つが失敗しても残りは続け、最初のエラーを返す
    private func closeStaleSessions(now: Date) async -> Error? {
        let open: [WorkoutSession]
        do {
            open = try await dataSource.fetchOpenSessions()
        } catch {
            return Self.isCancellation(error) ? nil : error
        }
        var firstError: Error?
        for session in open where RecordWindow.isPermanentlyClosed(day: session.day, now: now, calendar: calendar) {
            do {
                try await close(staleSession: session)
            } catch {
                firstError = firstError ?? error
            }
        }
        return firstError
    }

    /// もう記録できない日の進行中セッションを閉じる。破棄の判定はサーバーのセットで行う
    /// (応答だけ失われたセットを CASCADE で消さないため)。終了時刻は最後のセットの時刻
    private func close(staleSession: WorkoutSession) async throws {
        let serverSets = try await dataSource.fetchSets(sessionId: staleSession.id)
        if serverSets.isEmpty {
            try await dataSource.deleteSession(id: staleSession.id)
        } else {
            let lastSetAt = serverSets.compactMap(\.completedAt).max() ?? staleSession.startedAt
            try await dataSource.endSession(
                id: staleSession.id,
                endedAt: WorkoutLogic.endDate(startedAt: staleSession.startedAt, now: lastSetAt)
            )
        }
    }

    // MARK: - 補助

    /// 日の鍵 (calendar の日の始まり)。サーバーの day (JST 0 時) もこれで引く
    private func key(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// 開いている日の状態を書き換える。閉じた日 (days に無い) には何もしない (await の後に閉じていることがある)
    private func update(_ day: Date, _ change: (inout DayState) -> Void) {
        guard var state = days[day] else { return }
        change(&state)
        days[day] = state
    }

    /// 画面離脱で .task がキャンセルされた場合はエラー表示しない
    private func report(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        self.error = error
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    struct DraftSet: Identifiable, Hashable {
        let id = UUID()
        var input: WorkoutSetInput
    }

    enum StoreError: Error, LocalizedError {
        case busy
        /// 記録しようとした日が閉じた (前の日の 2:00 を過ぎた・今日に記録がある)
        case dayClosed

        var errorDescription: String? {
            switch self {
            case .busy: return "記録中です"
            case .dayClosed: return "前の日には記録できなくなりました"
            }
        }
    }
}
