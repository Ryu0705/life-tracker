import Foundation

protocol DayDataSource {
    func loadDayContext(date: Date) async throws -> DayBuilderContext
}
