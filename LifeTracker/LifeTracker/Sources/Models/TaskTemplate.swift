import Foundation

struct TaskTemplate: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let categoryId: UUID
    let startMinutesFromMidnight: Int
    let durationMinutes: Int
    let rrule: String?
    /// 目標の回数 (既定 1。回数は時刻と独立。docs/untimed-tasks-implementation-plan.md「本人の決定 2」)
    var targetCount: Int = 1
}
