import Foundation

struct ScheduledTask: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let categoryId: UUID
    let startAt: Date
    let endAt: Date
    let templateId: UUID?
    let patternId: UUID?
}
