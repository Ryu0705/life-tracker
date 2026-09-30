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
    let actual: [DayActualTask]

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
