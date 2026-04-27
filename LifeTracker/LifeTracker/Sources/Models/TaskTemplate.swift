import Foundation

struct TaskTemplate: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let categoryId: UUID
    let startMinutesFromMidnight: Int
    let durationMinutes: Int
    let rrule: String?
}
