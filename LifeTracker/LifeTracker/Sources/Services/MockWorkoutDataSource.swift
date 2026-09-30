import Foundation

/// テスト / プレビュー用のインメモリ実装。DB の制約のうち画面の挙動に効くもの
/// (進行中セッション同時 1 件・set_index の UNIQUE・CASCADE) を再現する
final class MockWorkoutDataSource: WorkoutDataSource {
    enum MockError: Error, Equatable {
        case sessionAlreadyInProgress
        case duplicateSetIndex
        case notFound
        /// routine_exercise の PK (routine_id, exercise_id)
        case duplicateRoutineExercise
    }

    private(set) var exercises: [Exercise]
    private(set) var routines: [Routine]
    private(set) var routineExercises: [RoutineExercise]
    private(set) var sessions: [WorkoutSession]
    private(set) var sets: [WorkoutSet]
    private(set) var weeklyGoals: [WeeklyGoal] = []

    /// テスト用の失敗注入: addSet の応答を遅らせる (二度押しの再現)
    var addSetDelayNanoseconds: UInt64 = 0
    /// テスト用: fetchSets(completedFrom:to:) の呼び出し回数 (履歴 store のキャッシュ確認)
    private(set) var fetchRangeCallCount = 0
    /// テスト用の失敗注入: 次の addSet は INSERT した後に応答だけ失う (回線断の再現)
    var dropNextAddSetResponse = false

    init(
        exercises: [Exercise] = [],
        routines: [Routine] = [],
        routineExercises: [RoutineExercise] = [],
        sessions: [WorkoutSession] = [],
        sets: [WorkoutSet] = []
    ) {
        self.exercises = exercises
        self.routines = routines
        self.routineExercises = routineExercises
        self.sessions = sessions
        self.sets = sets
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
        guard Set(exerciseIds).count == exerciseIds.count else { throw MockError.duplicateRoutineExercise }
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
    }

    func fetchSets(sessionId: UUID) async throws -> [WorkoutSet] {
        sets.filter { $0.sessionId == sessionId }
    }

    func addSet(_ new: NewWorkoutSet) async throws -> WorkoutSet {
        guard !sets.contains(where: {
            $0.sessionId == new.sessionId && $0.exerciseId == new.exerciseId && $0.setIndex == new.setIndex
        }) else { throw MockError.duplicateSetIndex }
        let set = WorkoutSet(
            id: UUID(), sessionId: new.sessionId, exerciseId: new.exerciseId, setIndex: new.setIndex,
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

    func deleteSet(id: UUID) async throws {
        sets.removeAll { $0.id == id }
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
