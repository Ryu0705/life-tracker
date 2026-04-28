import Foundation

struct DayMeta: Codable, Hashable {
    @DateOnly var date: Date
    let appliedPatternId: UUID?
}
