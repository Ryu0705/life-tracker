import Foundation

struct TemplateExdate: Codable, Hashable {
    let templateId: UUID
    @DateOnly var date: Date
}
