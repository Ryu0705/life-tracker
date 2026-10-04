import Foundation

/// テスト / プレビュー用のインメモリ実装。DB の制約のうち画面の挙動に効くもの
/// (進行中セッション同時 1 件・UNIQUE (entry_id, set_index)・UNIQUE (session_id, sort_order)・
/// entry と set の exercise_id 一致 (複合 FK)・CASCADE・空 entry の削除) を再現する
final class MockWorkoutDataSource: WorkoutDataSource {
    enum MockError: Error, Equatable {
        case sessionAlreadyInProgress
        case duplicateSetIndex
        case notFound
        /// workout_entry の UNIQUE (session_id, sort_order)
        case duplicateEntrySortOrder
        /// workout_set の複合 FK (entry_id, exercise_id) → workout_entry (id, exercise_id)
        case entryMismatch
        /// 複合 FK (NO ACTION): セットが残っている entry は消せない
        case entryHasSets
    }

    private(set) var exercises: [Exercise]
    private(set) var routines: [Routine]
    private(set) var routineExercises: [RoutineExercise]
    private(set) var sessions: [WorkoutSession]
    private(set) var sets: [WorkoutSet]
    private(set) var entries: [WorkoutEntry]
    private(set) var weeklyGoals: [WeeklyGoal] = []

    /// テスト用の失敗注入: addSet の応答を遅らせる (二度押しの再現)
    var addSetDelayNanoseconds: UInt64 = 0
    /// テスト用: fetchSets(completedFrom:to:) の呼び出し回数 (履歴 store のキャッシュ確認)
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

    func fetchInProgressSession() async throws -> WorkoutSession? {
        sessions.first { $0.isInProgress }
    }

    func startSession(routineId: UUID?, startedAt: Date) async throws -> WorkoutSession {
        guard !sessions.contains(where: \.isInProgress) else { throw MockError.sessionAlreadyInProgress }
        let session = WorkoutSession(
            id: UUID(), actualTaskId: nil, routineId: routineId,
            startedAt: startedAt, endedAt: nil, note: nil
        )
        sessions.append(session)
        return session
    }

    func endSession(id: UUID, endedAt: Date) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw MockError.notFound }
        let s = sessions[index]
        sessions[index] = WorkoutSession(
            id: s.id, actualTaskId: s.actualTaskId, routineId: s.routineId,
            startedAt: s.startedAt, endedAt: endedAt, note: s.note
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
        guard entries.contains(where: { $0.id == new.entryId && $0.exerciseId == new.exerciseId }) else {
            throw MockError.entryMismatch
        }
        guard !sets.contains(where: { $0.entryId == new.entryId && $0.setIndex == new.setIndex }) else {
            throw MockError.duplicateSetIndex
        }
        let set = WorkoutSet(
            id: UUID(), sessionId: new.sessionId, exerciseId: new.exerciseId, entryId: new.entryId, setIndex: new.setIndex,
            weight: new.weight, reps: new.reps, durationSec: new.durationSec, distanceM: new.distanceM,
            rpe: nil, isWarmup: new.isWarmup, completedAt: new.completedAt
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

    func fetchSets(completedFrom from: Date, to: Date) async throws -> [WorkoutSet] {
        fetchRangeCallCount += 1
        return sets
            .filter { $0.completedAt.map { from <= $0 && $0 < to } ?? false }
            .sorted { ($0.completedAt!, $0.setIndex) < ($1.completedAt!, $1.setIndex) }
    }

    func fetchTrainingDays() async throws -> Set<Date> {
        let calendar = Calendar.current
        return Set(sets.compactMap(\.completedAt).map { calendar.startOfDay(for: $0) })
    }

    func fetchWeeklyGoals() async throws -> [WeeklyGoal] {
        weeklyGoals.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    func saveWeeklyGoal(_ goal: WeeklyGoal) async throws {
        weeklyGoals.removeAll { $0.effectiveFrom == goal.effectiveFrom }
        weeklyGoals.append(goal)
    }
}
