import Foundation

struct Pattern: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let applyDay: ApplyDay?

    enum ApplyDay: String, Codable {
        case monday = "Monday"
        case tuesday = "Tuesday"
        case wednesday = "Wednesday"
        case thursday = "Thursday"
        case friday = "Friday"
        case saturday = "Saturday"
        case sunday = "Sunday"
        case holiday = "Holiday"
    }
}
