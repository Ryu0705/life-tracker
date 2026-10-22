import Foundation

/// テスト / プレビュー用のインメモリ実装。DB の制約のうち画面の挙動に効くもの
/// (1 人 1 日 1 セッション・時刻の窓 (日の 0:00〜翌日 2:00)・セットの日 = セッションの日・UNIQUE (entry_id, set_index)・
/// UNIQUE (session_id, sort_order)・entry と set の (session_id, exercise_id) 一致 (複合 FK)・CASCADE・空 entry の削除) を再現する
final class MockWorkoutDataSource: WorkoutDataSource {
    enum MockError: Error, Equatable {
        case duplicateSetIndex
        case notFound
        /// workout_entry の UNIQUE (session_id, sort_order)
        case duplicateEntrySortOrder
        /// workout_set の複合 FK (entry_id, session_id, exercise_id) → workout_entry (id, session_id, exercise_id) (0015)
        case entryMismatch
        /// 複合 FK (NO ACTION): セットが残っている entry は消せない
        case entryHasSets
        /// workout_session の UNIQUE (user_id, day) (0015)
        case duplicateDay
        /// started_at・completed_at が day の 0:00〜翌日 2:00 の外 (0015 の CHECK)
        case outsideWindow
        /// workout_set の外部キー (session_id, user_id, day) → workout_session (id, user_id, day) (0015)
        case dayMismatch
    }

    /// DB の date と同じ日の区切り (DateOnly と同じ JST)。テストの calendar に依らない
    private static let jst: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }()

    private(set) var exercises: [Exercise]
    private(set) var routines: [Routine]
    private(set) var routineExercises: [RoutineExercise]
    private(set) var sessions: [WorkoutSession]
    private(set) var sets: [WorkoutSet]
    private(set) var entries: [WorkoutEntry]
    private(set) var weeklyGoals: [WeeklyGoal] = []
    var profile: UserProfile?
    var bodyWeights: [BodyWeightRecord] = []
    /// テスト用の失敗注入: 次の saveBodyWeight を失敗させる (初回入力の 2 本目の失敗の再現)
    var failNextBodyWeightSave = false

    /// テスト用の失敗注入: addSet の応答を遅らせる (二度押しの再現)
    var addSetDelayNanoseconds: UInt64 = 0
    /// シミュレータ確認用: fetchSets(daysFrom:to:) の応答を遅らせる (分析のページ切替中の取得の再現)
    var fetchSetsDelayNanoseconds: UInt64 = 0
    /// テスト用: true の間 fetchSets(daysFrom:to:) の応答を止める (releaseFetchSets で返す)
    var holdsFetchSets = false
    private var fetchSetsWaiters: [CheckedContinuation<Void, Never>] = []
    /// テスト用の失敗注入: 次の fetchSets(daysFrom:to:) を失敗させる
    var failNextFetchSets = false
    /// テスト用: fetchSets(daysFrom:to:) の呼び出し回数 (履歴 store のキャッシュ確認)
    private(set) var fetchRangeCallCount = 0
    /// テスト用の失敗注入: 次の addSet は INSERT した後に応答だけ失う (回線断の再現)
    var dropNextAddSetResponse = false

    /// テスト用: reorderEntries の呼び出し記録 (書き込みの有無と順番の確認)
    private(set) var reorderCalls: [[UUID]] = []

    /// entries に無い entryId のセットには、migration 0010 の backfill と同じ規則で entry を作る
    /// (同じ entryId = 1 行・セッションごとに最初の completed_at 順で sort_order)。テストの組み立てを短くするため
    init(
        exercises: [Exercise] = [],
        routines: [Routine] = [],
        routineExercises: [RoutineExercise] = [],
        sessions: [WorkoutSession] = [],
        sets: [WorkoutSet] = [],
        entries: [WorkoutEntry] = []
    ) {
        self.exercises = exercises
        self.routines = routines
        self.routineExercises = routineExercises
        self.sessions = sessions
        self.sets = sets
        var all = entries
        let known = Set(entries.map(\.id))
        let orphans = Dictionary(grouping: sets.filter { !known.contains($0.entryId) }, by: \.entryId)
        let firstAt = { (id: UUID) in orphans[id]!.compactMap(\.completedAt).min() ?? .distantFuture }
        for id in orphans.keys.sorted(by: { (firstAt($0), $0.uuidString) < (firstAt($1), $1.uuidString) }) {
            let sample = orphans[id]![0]
            let next = (all.filter { $0.sessionId == sample.sessionId }.map(\.sortOrder).max() ?? 0) + 1
            all.append(WorkoutEntry(id: id, sessionId: sample.sessionId, exerciseId: sample.exerciseId, sortOrder: next))
        }
        self.entries = all
    }

    func fetchExercises() async throws -> [Exercise] {
        exercises
            .filter { !$0.isArchived }
            .sorted { ($0.sortOrder ?? .max, $0.name) < ($1.sortOrder ?? .max, $1.name) }
    }

    func fetchRoutines() async throws -> [Routine] {
        routines
            .filter { !$0.isArchived }
            .sorted { ($0.sortOrder ?? .max, $0.name) < ($1.sortOrder ?? .max, $1.name) }
    }

    func fetchRoutineExercises(routineId: UUID) async throws -> [RoutineExercise] {
        routineExercises.filter { $0.routineId == routineId }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func fetchAllRoutineExercises() async throws -> [RoutineExercise] {
        routineExercises.sorted { ($0.routineId.uuidString, $0.sortOrder) < ($1.routineId.uuidString, $1.sortOrder) }
    }

    /// テスト用の失敗注入: 次の saveRoutine は routine を書いた後、種目の INSERT で失敗する (原子的でないことの再現)
    var failNextRoutineExerciseInsert = false

    func saveRoutine(id: UUID?, name: String, exerciseIds: [UUID]) async throws -> Routine {
        let routine: Routine
        if let id {
            guard let index = routines.firstIndex(where: { $0.id == id }) else { throw MockError.notFound }
            let r = routines[index]
            routine = Routine(id: r.id, name: name, note: r.note, isArchived: r.isArchived, sortOrder: r.sortOrder)
            routines[index] = routine
        } else {
            routine = Routine(id: UUID(), name: name, note: nil, isArchived: false,
                              sortOrder: (routines.compactMap(\.sortOrder).max() ?? 0) + 1)
            routines.append(routine)
        }
        routineExercises.removeAll { $0.routineId == routine.id }
        if failNextRoutineExerciseInsert {
            failNextRoutineExerciseInsert = false
            throw URLError(.networkConnectionLost)
        }
        routineExercises += exerciseIds.enumerated().map {
            RoutineExercise(routineId: routine.id, exerciseId: $1, sortOrder: $0 + 1, targetSets: nil, targetReps: nil, targetWeight: nil)
        }
        return routine
    }

    func archiveRoutine(id: UUID) async throws {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { throw MockError.notFound }
        let r = routines[index]
        routines[index] = Routine(id: r.id, name: r.name, note: r.note, isArchived: true, sortOrder: r.sortOrder)
    }

    func fetchSessions(days: [Date]) async throws -> [WorkoutSession] {
        sessions.filter { session in days.contains { Self.sameDay($0, session.day) } }
            .sorted { $0.day < $1.day }
    }

    func fetchOpenSessions() async throws -> [WorkoutSession] {
        sessions.filter(\.isInProgress).sorted { $0.day < $1.day }
    }

    func startSession(day: Date, routineId: UUID?, startedAt: Date) async throws -> WorkoutSession {
        guard !sessions.contains(where: { Self.sameDay($0.day, day) }) else { throw MockError.duplicateDay }
        guard Self.isInWindow(startedAt, of: day) else { throw MockError.outsideWindow }
        let session = WorkoutSession(
            id: UUID(), actualTaskId: nil, routineId: routineId,
            startedAt: startedAt, endedAt: nil, note: nil, day: Self.jst.startOfDay(for: day)
        )
        sessions.append(session)
        return session
    }

    /// テスト用: 別端末がその日のセッションを先に作った状態を再現する (UNIQUE (user_id, day) に当たる)
    @discardableResult
    func insertSessionFromAnotherDevice(day: Date, startedAt: Date) -> WorkoutSession {
        let session = WorkoutSession(id: UUID(), actualTaskId: nil, routineId: nil,
                                     startedAt: startedAt, endedAt: nil, note: nil, day: Self.jst.startOfDay(for: day))
        sessions.append(session)
        return session
    }

    func endSession(id: UUID, endedAt: Date) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw MockError.notFound }
        let s = sessions[index]
        sessions[index] = WorkoutSession(
            id: s.id, actualTaskId: s.actualTaskId, routineId: s.routineId,
            startedAt: s.startedAt, endedAt: endedAt, note: s.note, day: s.day
        )
    }

    func deleteSession(id: UUID) async throws {
        sessions.removeAll { $0.id == id }
        sets.removeAll { $0.sessionId == id }
        entries.removeAll { $0.sessionId == id }
    }

    func fetchSets(sessionId: UUID) async throws -> [WorkoutSet] {
        sets.filter { $0.sessionId == sessionId }
    }

    func addSet(_ new: NewWorkoutSet) async throws -> WorkoutSet {
        guard let session = sessions.first(where: { $0.id == new.sessionId }) else { throw MockError.notFound }
        guard Self.sameDay(session.day, new.day) else { throw MockError.dayMismatch }
        guard Self.isInWindow(new.completedAt, of: new.day) else { throw MockError.outsideWindow }
        guard entries.contains(where: { $0.id == new.entryId && $0.sessionId == new.sessionId && $0.exerciseId == new.exerciseId }) else {
            throw MockError.entryMismatch
        }
        guard !sets.contains(where: { $0.entryId == new.entryId && $0.setIndex == new.setIndex }) else {
            throw MockError.duplicateSetIndex
        }
        let set = WorkoutSet(
            id: UUID(), sessionId: new.sessionId, exerciseId: new.exerciseId, entryId: new.entryId, setIndex: new.setIndex,
            weight: new.weight, reps: new.reps, durationSec: new.durationSec, distanceM: new.distanceM,
            rpe: nil, isWarmup: new.isWarmup, completedAt: new.completedAt, day: session.day
        )
        sets.append(set)
        if addSetDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: addSetDelayNanoseconds) }
        if dropNextAddSetResponse {
            dropNextAddSetResponse = false
            throw URLError(.networkConnectionLost)
        }
        return set
    }

    func updateSet(id: UUID, values: WorkoutSetInput.Validated) async throws -> WorkoutSet {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { throw MockError.notFound }
        sets[index] = sets[index].with(values: values)
        return sets[index]
    }

    /// RPC workout_set_delete と同じく、同じ entry の残りの set_index を 1..n に詰め直し、空になった entry を消す
    func deleteSet(id: UUID) async throws {
        guard let target = sets.first(where: { $0.id == id }) else { return }
        sets = WorkoutLogic.removingAndRenumbering(target, from: sets)
        entries = WorkoutLogic.pruningEntry(target.entryId, remainingSets: sets, entries: entries)
    }

    func fetchEntries(sessionId: UUID) async throws -> [WorkoutEntry] {
        entries.filter { $0.sessionId == sessionId }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func fetchEntries(sessionIds: [UUID]) async throws -> [WorkoutEntry] {
        let ids = Set(sessionIds)
        return entries.filter { ids.contains($0.sessionId) }
            .sorted { ($0.sessionId.uuidString, $0.sortOrder) < ($1.sessionId.uuidString, $1.sortOrder) }
    }

    func addEntry(sessionId: UUID, exerciseId: UUID, sortOrder: Int) async throws -> WorkoutEntry {
        guard sessions.contains(where: { $0.id == sessionId }) else { throw MockError.notFound }
        guard !entries.contains(where: { $0.sessionId == sessionId && $0.sortOrder == sortOrder }) else {
            throw MockError.duplicateEntrySortOrder
        }
        let entry = WorkoutEntry(id: UUID(), sessionId: sessionId, exerciseId: exerciseId, sortOrder: sortOrder)
        entries.append(entry)
        return entry
    }

    func deleteEntry(id: UUID) async throws {
        guard !sets.contains(where: { $0.entryId == id }) else { throw MockError.entryHasSets }
        entries.removeAll { $0.id == id }
    }

    func reorderEntries(sessionId: UUID, entryIds: [UUID]) async throws {
        reorderCalls.append(entryIds)
        entries = WorkoutLogic.reordering(entries, sessionId: sessionId, entryIds: entryIds)
    }

    /// テスト用: 別端末が同じセッションに entry を作った状態を再現する
    func insertEntryFromAnotherDevice(sessionId: UUID, exerciseId: UUID) -> WorkoutEntry {
        let entry = WorkoutEntry(id: UUID(), sessionId: sessionId, exerciseId: exerciseId,
                                 sortOrder: (entries.filter { $0.sessionId == sessionId }.map(\.sortOrder).max() ?? 0) + 1)
        entries.append(entry)
        return entry
    }

    func fetchExerciseSets(exerciseId: UUID) async throws -> [WorkoutSet] {
        sets.filter { $0.exerciseId == exerciseId }
    }

    func fetchRecordedExerciseIds() async throws -> Set<UUID> {
        Set(sets.map(\.exerciseId))
    }

    /// 止めている fetchSets(daysFrom:to:) の数
    var pendingFetchSets: Int { fetchSetsWaiters.count }

    func releaseFetchSets() {
        let released = fetchSetsWaiters
        fetchSetsWaiters = []
        released.forEach { $0.resume() }
    }

    func fetchSets(daysFrom from: Date, to: Date) async throws -> [WorkoutSet] {
        fetchRangeCallCount += 1
        if holdsFetchSets { await withCheckedContinuation { fetchSetsWaiters.append($0) } }
        if fetchSetsDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: fetchSetsDelayNanoseconds) }
        if failNextFetchSets {
            failNextFetchSets = false
            throw MockError.notFound
        }
        let (lower, upper) = (Self.jst.startOfDay(for: from), Self.jst.startOfDay(for: to))
        return sets
            .filter { $0.completedAt != nil && lower <= Self.jst.startOfDay(for: $0.day) && Self.jst.startOfDay(for: $0.day) < upper }
            .sorted { ($0.day, $0.completedAt!, $0.setIndex, $0.id.uuidString) < ($1.day, $1.completedAt!, $1.setIndex, $1.id.uuidString) }
    }

    /// view workout_training_day と同じ: completed_at のあるセットの day
    func fetchTrainingDays() async throws -> Set<Date> {
        Set(sets.filter { $0.completedAt != nil }.map(\.day))
    }

    func fetchWeeklyGoals() async throws -> [WeeklyGoal] {
        weeklyGoals.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    func saveWeeklyGoal(_ goal: WeeklyGoal) async throws {
        weeklyGoals.removeAll { $0.effectiveFrom == goal.effectiveFrom }
        weeklyGoals.append(goal)
    }

    func fetchProfile() async throws -> UserProfile? {
        profile
    }

    func saveProfile(_ profile: UserProfile) async throws {
        self.profile = profile
    }

    func fetchBodyWeights() async throws -> [BodyWeightRecord] {
        bodyWeights.sorted { $0.recordedOn < $1.recordedOn }
    }

    func saveBodyWeight(_ record: BodyWeightRecord) async throws {
        if failNextBodyWeightSave {
            failNextBodyWeightSave = false
            throw MockError.notFound
        }
        bodyWeights.removeAll { $0.recordedOn == record.recordedOn }
        bodyWeights.append(record)
    }

    private static func sameDay(_ a: Date, _ b: Date) -> Bool {
        jst.isDate(a, inSameDayAs: b)
    }

    /// 0015 の CHECK: day の 0:00 以上・翌日 2:00 未満
    private static func isInWindow(_ at: Date, of day: Date) -> Bool {
        jst.startOfDay(for: day) <= at && at < RecordWindow.closingTime(of: day, calendar: jst)
    }
}
