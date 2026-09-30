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

struct WorkoutSession: Codable, Identifiable, Hashable {
    let id: UUID
    let actualTaskId: UUID?
    let routineId: UUID?
    let startedAt: Date
    let endedAt: Date?
    let note: String?

    var isInProgress: Bool { endedAt == nil }
}

struct WorkoutSet: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionId: UUID
    let exerciseId: UUID
    let setIndex: Int
    let weight: Double?
    let reps: Int?
    let durationSec: Int?
    let distanceM: Double?
    let rpe: Double?
    let isWarmup: Bool
    let completedAt: Date?
}
