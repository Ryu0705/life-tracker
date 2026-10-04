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
}

extension WorkoutSet {
    /// 詰め直し後の番号 (WorkoutLogic.removingAndRenumbering)
    func with(setIndex: Int) -> WorkoutSet {
        WorkoutSet(id: id, sessionId: sessionId, exerciseId: exerciseId, entryId: entryId, setIndex: setIndex,
                   weight: weight, reps: reps, durationSec: durationSec, distanceM: distanceM,
                   rpe: rpe, isWarmup: isWarmup, completedAt: completedAt)
    }

    /// 編集後の値。completed_at・set_index はそのまま
    func with(values: WorkoutSetInput.Validated) -> WorkoutSet {
        WorkoutSet(id: id, sessionId: sessionId, exerciseId: exerciseId, entryId: entryId, setIndex: setIndex,
                   weight: values.weight, reps: values.reps, durationSec: values.durationSec, distanceM: values.distanceM,
                   rpe: rpe, isWarmup: values.isWarmup, completedAt: completedAt)
    }
}
