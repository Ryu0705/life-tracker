import Foundation

struct DayMeta: Codable, Hashable {
    let date: Date
    let appliedPatternId: UUID?
}
