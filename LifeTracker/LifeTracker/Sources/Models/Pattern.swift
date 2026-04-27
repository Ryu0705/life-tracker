import Foundation

struct Pattern: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let applyDay: ApplyDay?

    enum ApplyDay: String, Codable {
        case Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday, Holiday
    }
}
