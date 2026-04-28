import Testing
import Foundation
@testable import LifeTracker

@Suite("MockDayDataSource")
struct MockDayDataSourceTests {
    @Test("loadDayContext は init で渡された context を引数 date に依らずそのまま返す")
    func returnsSameContext() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        let context = DayBuilderContext(
            templates: [],
            patterns: [],
            memberships: [],
            exdates: [],
            previousExdates: [],
            dayMeta: nil,
            previousDayMeta: nil,
            scheduledTasks: [],
            actualTasks: [],
            holidayChecker: { _ in false },
            calendar: cal
        )
        let mock = MockDayDataSource(context: context)

        let result = try await mock.loadDayContext(date: Date())

        #expect(result.templates.isEmpty)
        #expect(result.patterns.isEmpty)
        #expect(result.memberships.isEmpty)
        #expect(result.exdates.isEmpty)
        #expect(result.dayMeta == nil)
        #expect(result.scheduledTasks.isEmpty)
        #expect(result.actualTasks.isEmpty)
    }
}
