import Foundation

// WorkoutSummary (pure 導出) の結果の値型。永続化しない (INV-5: 導出値は読み取り時に計算する)

/// 1 日分の合計 (合計バー・過去日)。ボリュームは weight_reps の本番セットのみ、W だけの日は nil
struct DayTotals: Equatable {
    let volume: Double?
    let workingSets: Int
    let exerciseCount: Int
    let totalSets: Int
    let firstAt: Date?
    let lastAt: Date?
}

/// 1 週分の合計 (分析画面)
struct WeekTotals: Equatable {
    struct DayMuscle: Equatable, Hashable {
        let day: Date
        let muscle: Exercise.MuscleGroup
        let volume: Double
    }
    struct MuscleCount: Equatable, Hashable {
        let muscle: Exercise.MuscleGroup
        let count: Int
    }
    let volume: Double?
    let byDayMuscle: [DayMuscle]
    let workingSetsByMuscle: [MuscleCount]
    let totalWorkingSets: Int
}
