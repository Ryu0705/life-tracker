import Foundation

// トレーニング・サブドメイン (domain-model.md v16 / migration 0003)。
// workout_session は actual_task に従属しない独立アグリゲート (training-domain-design.md 判断 A)。

struct Exercise: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let muscleGroup: MuscleGroup
    let equipment: Equipment?
    let metricKind: MetricKind
    let note: String?
    let isArchived: Bool
    let sortOrder: Int?

    enum MuscleGroup: String, Codable, CaseIterable {
        case chest, back, traps, shoulders, biceps, triceps, forearms
        case quads, hamstrings, glutes, calves, core, cardio
        case fullBody = "full_body"

        var displayName: String {
            switch self {
            case .chest: return "胸"
            case .back: return "背中"
            case .traps: return "僧帽筋"
            case .shoulders: return "肩"
            case .biceps: return "二頭"
            case .triceps: return "三頭"
            case .forearms: return "前腕"
            case .quads: return "大腿四頭"
            case .hamstrings: return "ハム"
            case .glutes: return "臀部"
            case .calves: return "ふくらはぎ"
            case .core: return "体幹"
            case .cardio: return "有酸素"
            case .fullBody: return "全身"
            }
        }
    }

    enum Equipment: String, Codable {
        case barbell, dumbbell, machine, cable, bodyweight, kettlebell, band, other
    }
}

/// 種目ごとに埋まる列を決める。DB の CHECK では表現できないため
/// `WorkoutSetInput.validate` (モデル層) で整合を担保する。
enum MetricKind: String, Codable {
    case weightReps = "weight_reps"
    case repsOnly = "reps_only"
    case duration
    case durationDistance = "duration_distance"
}

struct Routine: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let note: String?
    let isArchived: Bool
    let sortOrder: Int?
}

struct RoutineExercise: Codable, Hashable {
    let routineId: UUID
    let exerciseId: UUID
    let sortOrder: Int
    let targetSets: Int?
    let targetReps: Int?
    let targetWeight: Double?
}

/// day = トレーニングの日 (週の帯で選んでいた日。migration 0015)。started_at の日とは限らない
/// (前の日に 0:30 に始めた場合)。1 人 1 日 1 つ (UNIQUE (user_id, day))
struct WorkoutSession: Codable, Identifiable, Hashable {
    let id: UUID
    let actualTaskId: UUID?
    let routineId: UUID?
    let startedAt: Date
    let endedAt: Date?
    let note: String?
    /// DATE (JST 0 時)。started_at はこの日の 0:00〜翌日 2:00 (0015 の CHECK)
    let day: Date

    var isInProgress: Bool { endedAt == nil }
}

// MARK: - Codable (day は DATE。ActualTask と同じく手で読む。extension に書いて memberwise の init を残す)
extension WorkoutSession {
    private enum CodingKeys: String, CodingKey {
        case id, actualTaskId, routineId, startedAt, endedAt, note, day
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        actualTaskId = try c.decodeIfPresent(UUID.self, forKey: .actualTaskId)
        routineId = try c.decodeIfPresent(UUID.self, forKey: .routineId)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        day = try c.decode(DateOnly.self, forKey: .day).wrappedValue
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(actualTaskId, forKey: .actualTaskId)
        try c.encode(routineId, forKey: .routineId)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(note, forKey: .note)
        try c.encode(DateOnly(wrappedValue: day), forKey: .day)
    }
}

/// その日 (セッション) に実施した種目 1 回分 = 記録画面のカード (migration 0010)。同じ種目を 2 回やれば 2 行。
/// sortOrder は「実施した順番」(2026-10-04 本人決定)。未記録のカード (予定) は行を作らない
struct WorkoutEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionId: UUID
    let exerciseId: UUID
    let sortOrder: Int

    func with(sortOrder: Int) -> WorkoutEntry {
        WorkoutEntry(id: id, sessionId: sessionId, exerciseId: exerciseId, sortOrder: sortOrder)
    }
}

struct WorkoutSet: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionId: UUID
    let exerciseId: UUID
    /// どのカード (workout_entry) のセットか。set_index は entry ごとに 1 から
    let entryId: UUID
    let setIndex: Int
    let weight: Double?
    let reps: Int?
    let durationSec: Int?
    let distanceM: Double?
    let rpe: Double?
    let isWarmup: Bool
    let completedAt: Date?
    /// トレーニングの日 = そのセッションの day (DB の外部キー (session_id, user_id, day) で一致)。
    /// completed_at の日とは限らない (前の日に 0:30 に記録したセットは前の日)
    let day: Date
}

// MARK: - Codable (day は DATE。WorkoutSession と同じ形)
extension WorkoutSet {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, exerciseId, entryId, setIndex, weight, reps, durationSec, distanceM, rpe, isWarmup, completedAt, day
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        exerciseId = try c.decode(UUID.self, forKey: .exerciseId)
        entryId = try c.decode(UUID.self, forKey: .entryId)
        setIndex = try c.decode(Int.self, forKey: .setIndex)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight)
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        durationSec = try c.decodeIfPresent(Int.self, forKey: .durationSec)
        distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
        rpe = try c.decodeIfPresent(Double.self, forKey: .rpe)
        isWarmup = try c.decode(Bool.self, forKey: .isWarmup)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        day = try c.decode(DateOnly.self, forKey: .day).wrappedValue
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(exerciseId, forKey: .exerciseId)
        try c.encode(entryId, forKey: .entryId)
        try c.encode(setIndex, forKey: .setIndex)
        try c.encode(weight, forKey: .weight)
        try c.encode(reps, forKey: .reps)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(rpe, forKey: .rpe)
        try c.encode(isWarmup, forKey: .isWarmup)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(DateOnly(wrappedValue: day), forKey: .day)
    }
}

extension WorkoutSet {
    /// 詰め直し後の番号 (WorkoutLogic.removingAndRenumbering)
    func with(setIndex: Int) -> WorkoutSet {
        WorkoutSet(id: id, sessionId: sessionId, exerciseId: exerciseId, entryId: entryId, setIndex: setIndex,
                   weight: weight, reps: reps, durationSec: durationSec, distanceM: distanceM,
                   rpe: rpe, isWarmup: isWarmup, completedAt: completedAt, day: day)
    }

    /// 編集後の値。completed_at・set_index・day はそのまま
    func with(values: WorkoutSetInput.Validated) -> WorkoutSet {
        WorkoutSet(id: id, sessionId: sessionId, exerciseId: exerciseId, entryId: entryId, setIndex: setIndex,
                   weight: values.weight, reps: values.reps, durationSec: values.durationSec, distanceM: values.distanceM,
                   rpe: rpe, isWarmup: values.isWarmup, completedAt: completedAt, day: day)
    }
}
