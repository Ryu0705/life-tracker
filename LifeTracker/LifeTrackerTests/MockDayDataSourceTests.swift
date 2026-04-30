import Testing
import Foundation
@testable import LifeTracker

@Suite("MockDayDataSource")
@MainActor
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
        #expect(result.previousExdates.isEmpty)
        #expect(result.dayMeta == nil)
        #expect(result.previousDayMeta == nil)
        #expect(result.scheduledTasks.isEmpty)
        #expect(result.actualTasks.isEmpty)
    }

    @Test("loadDayContext は previousDayMeta と previousExdates を含む全フィールドを保持して返す")
    func preservesAllFields() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        let templateId = UUID()
        let categoryId = UUID()
        let patternId = UUID()
        let template = TaskTemplate(
            id: templateId,
            name: "朝食",
            categoryId: categoryId,
            startMinutesFromMidnight: 7 * 60,
            durationMinutes: 30,
            rrule: "FREQ=DAILY"
        )
        let pattern = Pattern(
            id: patternId,
            name: "休日",
            applyDay: .holiday
        )
        let membership = PatternTemplateMembership(
            patternId: patternId,
            templateId: templateId
        )
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let exdateToday = TemplateExdate(templateId: templateId, date: today)
        let exdatePrev = TemplateExdate(templateId: templateId, date: yesterday)
        let dayMetaToday = DayMeta(date: today, appliedPatternId: patternId)
        let dayMetaPrev = DayMeta(date: yesterday, appliedPatternId: nil)
        let scheduled = ScheduledTask(
            id: UUID(),
            name: "会議",
            categoryId: categoryId,
            startAt: today.addingTimeInterval(3600 * 10),
            endAt: today.addingTimeInterval(3600 * 11),
            templateId: nil,
            patternId: nil
        )
        let actual = ActualTask(
            id: UUID(),
            name: "ランチ",
            categoryId: categoryId,
            startAt: today.addingTimeInterval(3600 * 12),
            endAt: today.addingTimeInterval(3600 * 13)
        )

        let context = DayBuilderContext(
            templates: [template],
            patterns: [pattern],
            memberships: [membership],
            exdates: [exdateToday],
            previousExdates: [exdatePrev],
            dayMeta: dayMetaToday,
            previousDayMeta: dayMetaPrev,
            scheduledTasks: [scheduled],
            actualTasks: [actual],
            holidayChecker: { _ in true },
            calendar: cal
        )
        let mock = MockDayDataSource(context: context)

        let result = try await mock.loadDayContext(date: Date())

        #expect(result.templates.count == 1)
        #expect(result.templates.first?.id == templateId)
        #expect(result.patterns.count == 1)
        #expect(result.patterns.first?.id == patternId)
        #expect(result.memberships.count == 1)
        #expect(result.exdates.count == 1)
        #expect(result.exdates.first?.date == today)
        #expect(result.previousExdates.count == 1)
        #expect(result.previousExdates.first?.date == yesterday)
        #expect(result.dayMeta?.date == today)
        #expect(result.dayMeta?.appliedPatternId == patternId)
        #expect(result.previousDayMeta?.date == yesterday)
        #expect(result.previousDayMeta?.appliedPatternId == nil)
        #expect(result.scheduledTasks.count == 1)
        #expect(result.actualTasks.count == 1)
        #expect(result.holidayChecker(today) == true)
        #expect(result.calendar.timeZone.identifier == "Asia/Tokyo")
    }
}
