import Foundation

struct MockDayDataSource: DayDataSource {
    let context: DayBuilderContext

    func loadDayContext(date: Date) async throws -> DayBuilderContext {
        context
    }
}
