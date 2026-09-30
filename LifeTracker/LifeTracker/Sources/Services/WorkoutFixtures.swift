#if DEBUG
import Foundation

/// Debug ビルドで `-mock-workout` 起動引数を付けたときの確認用データ (Supabase 停止中でも画面を確認できるように)
enum WorkoutFixtures {
    /// 1 セット = (重量, 回数, 秒)。種目の metric_kind に合う列だけ使う
    private typealias Row = (weight: Double?, reps: Int?, sec: Int?)

    static func makeMockDataSource(now: Date = Date()) -> MockWorkoutDataSource {
        let bench = Exercise(id: UUID(), name: "ベンチプレス", muscleGroup: .chest, equipment: .barbell,
                             metricKind: .weightReps, note: "セーフティは胸の少し下", isArchived: false, sortOrder: 100)
        let incline = Exercise(id: UUID(), name: "インクラインDBプレス", muscleGroup: .chest, equipment: .dumbbell,
                               metricKind: .weightReps, note: nil, isArchived: false, sortOrder: 110)
        let pushdown = Exercise(id: UUID(), name: "ケーブルプッシュダウン", muscleGroup: .triceps, equipment: .cable,
                                metricKind: .weightReps, note: nil, isArchived: false, sortOrder: 120)
        let pullUp = Exercise(id: UUID(), name: "懸垂", muscleGroup: .back, equipment: .bodyweight,
                              metricKind: .repsOnly, note: nil, isArchived: false, sortOrder: 200)
        let latPulldown = Exercise(id: UUID(), name: "ラットプルダウン", muscleGroup: .back, equipment: .machine,
                                   metricKind: .weightReps, note: nil, isArchived: false, sortOrder: 210)
        let curl = Exercise(id: UUID(), name: "ダンベルカール", muscleGroup: .biceps, equipment: .dumbbell,
                            metricKind: .weightReps, note: nil, isArchived: false, sortOrder: 220)
        let squat = Exercise(id: UUID(), name: "スクワット", muscleGroup: .quads, equipment: .barbell,
                             metricKind: .weightReps, note: nil, isArchived: false, sortOrder: 250)
        let legPress = Exercise(id: UUID(), name: "レッグプレス", muscleGroup: .quads, equipment: .machine,
                                metricKind: .weightReps, note: nil, isArchived: false, sortOrder: 260)
        let plank = Exercise(id: UUID(), name: "プランク", muscleGroup: .core, equipment: .bodyweight,
                             metricKind: .duration, note: nil, isArchived: false, sortOrder: 300)
        let treadmill = Exercise(id: UUID(), name: "トレッドミル", muscleGroup: .cardio, equipment: .machine,
                                 metricKind: .durationDistance, note: nil, isArchived: false, sortOrder: 400)
        let programs = [("胸の日", [bench, incline, pushdown]), ("背中の日", [pullUp, latPulldown, curl]), ("脚の日", [squat, legPress, plank])]
            .enumerated().map { i, entry in (Routine(id: UUID(), name: entry.0, note: nil, isArchived: false, sortOrder: i + 1), entry.1) }

        func w(_ weight: Double, _ reps: Int) -> Row { (weight, reps, nil) }
        func r(_ reps: Int) -> Row { (nil, reps, nil) }
        func s(_ sec: Int) -> Row { (nil, nil, sec) }

        // 直近 4 週: 胸の日・背中の日・脚の日を各 2 回 (胸の日・背中の日・脚の日はプログラムにも登録済み) + ベンチ単独の日 (推移グラフ用)。
        // ベンチの最新は 2 日前の 60×10 / 65×8 / 65×6。昨日は背中の日 (過去日表示の確認用)
        let chestDay: (Double) -> [(Exercise, [Row])] = { top in
            [(bench, [w(60, 10), w(top, 8), w(top, 6)]), (incline, [w(20, 12), w(20, 10), w(22, 8)]), (pushdown, [w(25, 12), w(25, 12)])]
        }
        let backDay: [(Exercise, [Row])] = [(pullUp, [r(10), r(8), r(7)]), (latPulldown, [w(50, 12), w(55, 10), w(55, 9)]),
                                             (curl, [w(10, 12), w(10, 10)])]
        let history: [(daysAgo: Int, entries: [(Exercise, [Row])])] = [
            (25, [(bench, [w(55, 10), w(57.5, 8), w(57.5, 7)])]),
            (20, [(bench, [w(57.5, 10), w(60, 8), w(60, 6)])]),
            (16, [(bench, [w(60, 8), w(60, 8), w(62.5, 5)])]),
            (12, [(squat, [w(60, 10), w(70, 8), w(70, 8)]), (legPress, [w(120, 12), w(130, 10)]), (treadmill, [s(900)])]),
            (9, chestDay(62.5)),
            (8, backDay),
            (5, [(squat, [w(70, 8), w(72.5, 6), w(72.5, 6)]), (legPress, [w(130, 12), w(140, 10)]), (plank, [s(60), s(45)])]),
            (2, chestDay(65)),
            (1, backDay),
        ]

        let calendar = HomeView.defaultCalendar
        let today = calendar.startOfDay(for: now)
        var sessions: [WorkoutSession] = []
        var sets: [WorkoutSet] = []
        for entry in history {
            let start = calendar.date(byAdding: .day, value: -entry.daysAgo, to: today)!.addingTimeInterval(7 * 3600)
            let session = WorkoutSession(id: UUID(), actualTaskId: nil, routineId: nil,
                                         startedAt: start, endedAt: start.addingTimeInterval(3600), note: nil)
            sessions.append(session)
            var at = start
            for (exercise, rows) in entry.entries {
                for (index, row) in rows.enumerated() {
                    let distance = exercise.metricKind == .durationDistance ? row.sec.map { Double($0) * 3 } : nil
                    sets.append(WorkoutSet(id: UUID(), sessionId: session.id, exerciseId: exercise.id, setIndex: index + 1,
                                           weight: row.weight, reps: row.reps, durationSec: row.sec, distanceM: distance,
                                           rpe: nil, isWarmup: false, completedAt: at))
                    at = at.addingTimeInterval(180)
                }
            }
        }

        return MockWorkoutDataSource(
            exercises: [bench, incline, pushdown, pullUp, latPulldown, curl, squat, legPress, plank, treadmill],
            routines: programs.map(\.0),
            routineExercises: programs.flatMap { routine, exercises in
                exercises.enumerated().map {
                    RoutineExercise(routineId: routine.id, exerciseId: $1.id, sortOrder: $0 + 1, targetSets: nil, targetReps: nil, targetWeight: nil)
                }
            },
            sessions: sessions,
            sets: sets
        )
    }
}
#endif
