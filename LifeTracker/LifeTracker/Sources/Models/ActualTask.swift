import Foundation

struct ActualTask: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let categoryId: UUID
    let startAt: Date
    let endAt: Date
}
