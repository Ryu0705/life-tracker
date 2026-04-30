import Testing
import Foundation
@testable import LifeTracker

@Suite("TodayDataLoader")
@MainActor
struct TodayDataLoaderTests {
    let calendar: Calendar

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        self.calendar = cal
    }

    private func makeFixedNow(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test("refresh が成功すると day に DayBuilder.build の結果が入り isLoading が false に戻る")
    func refreshSuccess() async {
        let today = makeFixedNow("2026-05-01T10:00:00+09:00")
        let templateId = UUID()
        let categoryId = UUID()
        let template = TaskTemplate(
            id: templateId,
            name: "朝食",
            categoryId: categoryId,
            startMinutesFromMidnight: 7 * 60,
            durationMinutes: 30,
            rrule: "FREQ=DAILY"
        )
        let context = DayBuilderContext(
            templates: [template],
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
        let loader = TodayDataLoader(
            dataSource: MockDayDataSource(context: context),
            calendar: calendar,
            now: { today }
        )

        await loader.refresh()

        #expect(loader.isLoading == false)
        #expect(loader.error == nil)
        #expect(loader.day != nil)
        #expect(loader.day?.scheduled.count == 1)
        #expect(loader.day?.scheduled.first?.task.name == "朝食")
    }

    @Test("loadDayContext が throw すると error にセットされ day は nil のまま")
    func refreshFailure() async {
        let loader = TodayDataLoader(
            dataSource: ThrowingDayDataSource(),
            calendar: calendar,
            now: { Date() }
        )

        await loader.refresh()

        #expect(loader.day == nil)
        #expect(loader.error != nil)
        #expect(loader.isLoading == false)
    }

    @Test("リトライ成功で前回の error がクリアされる")
    func refreshClearsPreviousError() async {
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
            calendar: calendar
        )
        let dataSource = ToggleableDayDataSource(context: context)
        let loader = TodayDataLoader(
            dataSource: dataSource,
            calendar: calendar,
            now: { Date() }
        )

        dataSource.shouldThrow = true
        await loader.refresh()
        #expect(loader.error != nil)

        dataSource.shouldThrow = false
        await loader.refresh()
        #expect(loader.error == nil)
        #expect(loader.day != nil)
    }
}

private struct ThrowingDayDataSource: DayDataSource {
    struct Failure: Error {}
    func loadDayContext(date: Date) async throws -> DayBuilderContext {
        throw Failure()
    }
}

private final class ToggleableDayDataSource: DayDataSource, @unchecked Sendable {
    let context: DayBuilderContext
    var shouldThrow: Bool = false

    init(context: DayBuilderContext) {
        self.context = context
    }

    func loadDayContext(date: Date) async throws -> DayBuilderContext {
        if shouldThrow {
            struct Failure: Error {}
            throw Failure()
        }
        return context
    }
}
