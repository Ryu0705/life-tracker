import Foundation

struct Category: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let subInputKind: SubInputKind?

    enum SubInputKind: String, Codable {
        case gym
        case sleep
    }
}
