import Foundation

enum DayMembership: Hashable {
    case primary
    case spillover(from: Date)
    case overflow(to: Date)
}

enum TaskOrigin: Hashable {
    case rrule
    case pattern
    case manual
}

struct DayScheduledTask: Identifiable, Hashable {
    let task: ScheduledTask
    let membership: DayMembership
    let visibleRange: DateInterval
    let origin: TaskOrigin
    /// true = 世代から組み立てた仮想の回 (DB に行が無い)。false = 実体 (scheduled_task)。
    /// 編集の分岐 (その日だけ変えた回か) に使う (レビュー DB §1-2)
    var isVirtual: Bool = false
    var id: UUID { task.id }
}

struct DayActualTask: Identifiable, Hashable {
    let task: ActualTask
    let membership: DayMembership
    let visibleRange: DateInterval
    var id: UUID { task.id }
}

struct Day {
    let date: Date
    let scheduled: [DayScheduledTask]
    /// やった (時刻あり) の実績のうち、その日に重なるもの (時刻の範囲で clip 済み)
    let actual: [DayActualTask]
    /// 取得した実績の行そのまま (一覧に出る日が前日か当日。スキップ行を含む)。回の丸の状態・予定外の実績の一覧に使う (段階 2)
    var records: [ActualTask] = []
    /// 当日に完了したセットの completed_at (昇順)。ジムの回の表示時判定 (段階 2 決定 C4)
    var workoutSetTimes: [Date] = []
    /// 睡眠の記録 (sleep_record。actual には混ぜない)。睡眠の行の 3 行目に SleepRules.assign で結ぶ
    var sleepRecords: [SleepRecord] = []

    func currentBlock(at moment: Date) -> DayScheduledTask? {
        scheduled.first { dayTask in
            switch dayTask.membership {
            case .spillover:
                return false
            case .primary, .overflow:
                return dayTask.visibleRange.start <= moment && moment < dayTask.visibleRange.end
            }
        }
    }
}
