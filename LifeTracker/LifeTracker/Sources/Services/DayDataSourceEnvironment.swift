import SwiftUI

private struct DayDataSourceKey: EnvironmentKey {
    static let defaultValue: DayDataSource = MockDayDataSource(context: .empty)
}

extension EnvironmentValues {
    var dayDataSource: DayDataSource {
        get { self[DayDataSourceKey.self] }
        set { self[DayDataSourceKey.self] = newValue }
    }
}

extension DayBuilderContext {
    static var empty: DayBuilderContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return DayBuilderContext(
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
            calendar: calendar
        )
    }
}
