import Foundation
import Supabase

final class SupabaseWorkoutDataSource: WorkoutDataSource {
    private let client: SupabaseClient
    /// 42501・PGRST3xx を DataAccessError に変える境界 (計画 §2-5・P9。予定・睡眠の data source と共有)
    private let access: DataAccessGuard

    init(client: SupabaseClient, access: DataAccessGuard) {
        self.client = client
        self.access = access
    }

    /// upsert の衝突先 (0014 の主キー・一意。人ごと)。送る中身に user_id は足さない (DB の既定値 auth.uid() で入る)
    enum Conflict {
        /// user_profile の主キー (人ごとに 1 行)
        static let profile = "user_id"
        /// training_goal の UNIQUE (user_id, effective_from)
        static let weeklyGoal = "user_id,effective_from"
        /// body_weight_record の主キー (人と日ごとに 1 行)
        static let bodyWeight = "user_id,recorded_on"
    }

    /// 種目の読み先。共有のマスタと自作に、人ごとのアーカイブ・メモ・並び順を重ねた view (0014 の i。列の形は Exercise と同じ)
    static let exerciseSource = "exercise_for_user"

    func fetchExercises() async throws -> [Exercise] {
        try await access.run {
            try await client.from(Self.exerciseSource)
                .select()
                .eq("is_archived", value: false)
                .order("sort_order")
                .order("name")
                .execute()
                .value
        }
    }

    func fetchRoutines() async throws -> [Routine] {
        try await access.run {
            try await client.from("routine")
                .select()
                .eq("is_archived", value: false)
                .order("sort_order")
                .order("name")
                .execute()
                .value
        }
    }

    func fetchRoutineExercises(routineId: UUID) async throws -> [RoutineExercise] {
        try await access.run {
            try await client.from("routine_exercise")
                .select()
                .eq("routine_id", value: routineId.uuidString)
                .order("sort_order")
                .execute()
                .value
        }
    }

    func fetchAllRoutineExercises() async throws -> [RoutineExercise] {
        try await access.run {
            try await fetchAllPages {
                client.from("routine_exercise")
                    .select()
                    .order("routine_id")
                    .order("sort_order")
                    .order("exercise_id")
            }
        }
    }

    func saveRoutine(id: UUID?, name: String, exerciseIds: [UUID]) async throws -> Routine {
        try await access.run {
            let routine: Routine
            if let id {
                routine = try await client.from("routine")
                    .update(RoutineNameUpdate(name: name))
                    .eq("id", value: id.uuidString)
                    .select()
                    .single()
                    .execute()
                    .value
            } else {
                let last: [Routine] = try await client.from("routine")
                    .select()
                    .order("sort_order", ascending: false, nullsFirst: false)
                    .limit(1)
                    .execute()
                    .value
                routine = try await client.from("routine")
                    .insert(NewRoutine(name: name, sortOrder: (last.first?.sortOrder ?? 0) + 1))
                    .select()
                    .single()
                    .execute()
                    .value
            }
            try await client.from("routine_exercise")
                .delete()
                .eq("routine_id", value: routine.id.uuidString)
                .execute()
            if !exerciseIds.isEmpty {
                try await client.from("routine_exercise")
                    .insert(exerciseIds.enumerated().map { NewRoutineExercise(routineId: routine.id, exerciseId: $1, sortOrder: $0 + 1) })
                    .execute()
            }
            return routine
        }
    }

    func archiveRoutine(id: UUID) async throws {
        try await access.run {
            try await client.from("routine")
                .update(RoutineArchiveUpdate(isArchived: true))
                .eq("id", value: id.uuidString)
                .execute()
        }
    }

    func fetchInProgressSession() async throws -> WorkoutSession? {
        try await access.run {
            let sessions: [WorkoutSession] = try await client.from("workout_session")
                .select()
                .is("ended_at", value: nil)
                .limit(1)
                .execute()
                .value
            return sessions.first
        }
    }

    func startSession(routineId: UUID?, startedAt: Date) async throws -> WorkoutSession {
        try await access.run {
            try await client.from("workout_session")
                .insert(NewWorkoutSession(routineId: routineId, startedAt: startedAt))
                .select()
                .single()
                .execute()
                .value
        }
    }

    func endSession(id: UUID, endedAt: Date) async throws {
        try await access.run {
            try await client.from("workout_session")
                .update(SessionEndUpdate(endedAt: endedAt))
                .eq("id", value: id.uuidString)
                .execute()
        }
    }

    func deleteSession(id: UUID) async throws {
        try await access.run {
            try await client.from("workout_session")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        }
    }

    func fetchSets(sessionId: UUID) async throws -> [WorkoutSet] {
        try await access.run {
            try await client.from("workout_set")
                .select()
                .eq("session_id", value: sessionId.uuidString)
                .order("completed_at")
                .order("set_index")
                .execute()
                .value
        }
    }

    func addSet(_ set: NewWorkoutSet) async throws -> WorkoutSet {
        try await access.run {
            try await client.from("workout_set")
                .insert(set)
                .select()
                .single()
                .execute()
                .value
        }
    }

    func updateSet(id: UUID, values: WorkoutSetInput.Validated) async throws -> WorkoutSet {
        try await access.run {
            try await client.from("workout_set")
                .update(SetValuesUpdate(values))
                .eq("id", value: id.uuidString)
                .select()
                .single()
                .execute()
                .value
        }
    }

    /// 削除と詰め直し (空になった entry の削除を含む) は 1 トランザクションで行う必要があるため RPC (0008 → 0010)
    func deleteSet(id: UUID) async throws {
        try await access.run {
            try await client.rpc("workout_set_delete", params: ["p_id": id.uuidString]).execute()
        }
    }

    func fetchEntries(sessionId: UUID) async throws -> [WorkoutEntry] {
        try await access.run {
            try await client.from("workout_entry")
                .select()
                .eq("session_id", value: sessionId.uuidString)
                .order("sort_order")
                .execute()
                .value
        }
    }

    /// URL の長さを抑えるため 50 セッションずつ取る
    func fetchEntries(sessionIds: [UUID]) async throws -> [WorkoutEntry] {
        try await access.run {
            let unique = Array(Set(sessionIds)).sorted { $0.uuidString < $1.uuidString }
            var result: [WorkoutEntry] = []
            for start in stride(from: 0, to: unique.count, by: 50) {
                let chunk = unique[start..<min(start + 50, unique.count)].map(\.uuidString)
                let rows: [WorkoutEntry] = try await fetchAllPages {
                    client.from("workout_entry")
                        .select()
                        .in("session_id", values: chunk)
                        .order("session_id")
                        .order("sort_order")
                        .order("id")
                }
                result += rows
            }
            return result
        }
    }

    func addEntry(sessionId: UUID, exerciseId: UUID, sortOrder: Int) async throws -> WorkoutEntry {
        try await access.run {
            try await client.from("workout_entry")
                .insert(NewWorkoutEntry(sessionId: sessionId, exerciseId: exerciseId, sortOrder: sortOrder))
                .select()
                .single()
                .execute()
                .value
        }
    }

    func deleteEntry(id: UUID) async throws {
        try await access.run {
            try await client.from("workout_entry")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        }
    }

    /// 並べ替えは sort_order の入れ替えを 1 トランザクションで行う必要があるため RPC (0010)
    func reorderEntries(sessionId: UUID, entryIds: [UUID]) async throws {
        try await access.run {
            try await client.rpc("workout_entry_reorder", params: ReorderParams(session: sessionId, entryIds: entryIds)).execute()
        }
    }

    func fetchExerciseSets(exerciseId: UUID) async throws -> [WorkoutSet] {
        try await access.run {
            try await fetchAllPages {
                client.from("workout_set")
                    .select()
                    .eq("exercise_id", value: exerciseId.uuidString)
                    .order("completed_at")
                    .order("set_index")
                    .order("id")
            }
        }
    }

    func fetchRecordedExerciseIds() async throws -> Set<UUID> {
        try await access.run {
            let rows: [ExerciseIdRow] = try await fetchAllPages {
                client.from("workout_set")
                    .select("exercise_id")
                    .order("id")
            }
            return Set(rows.map(\.exerciseId))
        }
    }

    func fetchSets(completedFrom from: Date, to: Date) async throws -> [WorkoutSet] {
        try await access.run {
            try await fetchAllPages {
                client.from("workout_set")
                    .select()
                    .gte("completed_at", value: Self.iso(from))
                    .lt("completed_at", value: Self.iso(to))
                    .order("completed_at")
                    .order("set_index")
                    .order("id")
            }
        }
    }

    func fetchTrainingDays() async throws -> Set<Date> {
        try await access.run {
            let rows: [TrainingDayRow] = try await fetchAllPages {
                client.from("workout_training_day")
                    .select()
                    .order("day")
            }
            return Set(rows.map(\.day))
        }
    }

    func fetchWeeklyGoals() async throws -> [WeeklyGoal] {
        try await access.run {
            let rows: [WeeklyGoalRow] = try await client.from("training_goal")
                .select("weekly_target, effective_from")
                .order("effective_from")
                .execute()
                .value
            return rows.map { WeeklyGoal(weeklyTarget: $0.weeklyTarget, effectiveFrom: $0.effectiveFrom) }
        }
    }

    func saveWeeklyGoal(_ goal: WeeklyGoal) async throws {
        try await access.run {
            try await client.from("training_goal")
                .upsert(WeeklyGoalRow(weeklyTarget: goal.weeklyTarget, effectiveFrom: goal.effectiveFrom), onConflict: Conflict.weeklyGoal)
                .execute()
        }
    }

    func fetchProfile() async throws -> UserProfile? {
        try await access.run {
            let rows: [UserProfile] = try await client.from("user_profile")
                .select("sex, birth_date")
                .limit(1)
                .execute()
                .value
            return rows.first
        }
    }

    func saveProfile(_ profile: UserProfile) async throws {
        try await access.run {
            try await client.from("user_profile")
                .upsert(ProfileRow(sex: profile.sex, birthDate: profile.birthDate), onConflict: Conflict.profile)
                .execute()
        }
    }

    func fetchBodyWeights() async throws -> [BodyWeightRecord] {
        try await access.run {
            try await fetchAllPages {
                client.from("body_weight_record")
                    .select("recorded_on, weight_kg")
                    .order("recorded_on")
            }
        }
    }

    func saveBodyWeight(_ record: BodyWeightRecord) async throws {
        try await access.run {
            try await client.from("body_weight_record")
                .upsert(record, onConflict: Conflict.bodyWeight)
                .execute()
        }
    }

    /// PostgREST の max-rows (1000) を越えた分はエラーにならず黙って切られるため、件数が pageSize 未満になるまで
    /// .range で取り直す。ページ間で行がずれないよう、query は一意なキー (id) まで order を付けること。
    /// builder は range で自身を書き換えるので、ページごとに query を作り直す
    private func fetchAllPages<T: Decodable>(pageSize: Int = 1000, _ query: () -> PostgrestTransformBuilder) async throws -> [T] {
        var rows: [T] = []
        var offset = 0
        while true {
            let page: [T] = try await query().range(from: offset, to: offset + pageSize - 1).execute().value
            rows += page
            if page.count < pageSize { return rows }
            offset += pageSize
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct TrainingDayRow: Decodable {
    @DateOnly var day: Date
}

/// training_goal の読み書きの列 (user_id は送らない)
struct WeeklyGoalRow: Codable {
    let weeklyTarget: Int
    @DateOnly var effectiveFrom: Date
}

/// user_profile の書き込みの列。id 列は 0014 で消え、主キーは user_id (送らずに既定値 auth.uid() で入る)
struct ProfileRow: Encodable {
    let sex: Sex
    @DateOnly var birthDate: Date
}

private struct ExerciseIdRow: Decodable {
    let exerciseId: UUID
}

private struct NewWorkoutSession: Encodable {
    let routineId: UUID?
    let startedAt: Date
}

private struct NewWorkoutEntry: Encodable {
    let sessionId: UUID
    let exerciseId: UUID
    let sortOrder: Int
}

private struct ReorderParams: Encodable {
    let session: UUID
    let entryIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case session = "p_session"
        case entryIds = "p_entry_ids"
    }
}

private struct NewRoutine: Encodable {
    let name: String
    let sortOrder: Int
}

private struct NewRoutineExercise: Encodable {
    let routineId: UUID
    let exerciseId: UUID
    let sortOrder: Int
}

private struct RoutineNameUpdate: Encodable {
    let name: String
}

private struct RoutineArchiveUpdate: Encodable {
    let isArchived: Bool
}

private struct SessionEndUpdate: Encodable {
    let endedAt: Date
}

/// 記録済みセットの値の UPDATE。空の列も null で送る (合成の Encodable は nil の列を省き、古い値が残るため)
private struct SetValuesUpdate: Encodable {
    let values: WorkoutSetInput.Validated

    init(_ values: WorkoutSetInput.Validated) {
        self.values = values
    }

    enum CodingKeys: String, CodingKey {
        case weight, reps, durationSec, distanceM, isWarmup
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(values.weight, forKey: .weight)
        try c.encode(values.reps, forKey: .reps)
        try c.encode(values.durationSec, forKey: .durationSec)
        try c.encode(values.distanceM, forKey: .distanceM)
        try c.encode(values.isWarmup, forKey: .isWarmup)
    }
}
