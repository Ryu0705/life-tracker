import Testing
import Foundation
@testable import LifeTracker

@Suite("DayBuilder")
struct DayBuilderTests {
    let calendar: Calendar
    let categoryFood: UUID
    let categorySleep: UUID
    let categoryRemote: UUID

    let templateBreakfast: TaskTemplate
    let templateNewYearGreeting: TaskTemplate
    let templateRemoteMorning: TaskTemplate

    let patternHoliday: Pattern
    let patternRemote: Pattern

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        self.calendar = cal

        let foodId = UUID()
        let sleepId = UUID()
        let remoteId = UUID()
        self.categoryFood = foodId
        self.categorySleep = sleepId
        self.categoryRemote = remoteId

        self.templateBreakfast = TaskTemplate(
            id: UUID(),
            name: "朝食",
            categoryId: foodId,
            startMinutesFromMidnight: 7 * 60,
            durationMinutes: 30,
            rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        )
        self.templateNewYearGreeting = TaskTemplate(
            id: UUID(),
            name: "新年の挨拶",
            categoryId: foodId,
            startMinutesFromMidnight: 10 * 60,
            durationMinutes: 60,
            rrule: nil
        )
        self.templateRemoteMorning = TaskTemplate(
            id: UUID(),
            name: "在宅 morning",
            categoryId: remoteId,
            startMinutesFromMidnight: 9 * 60,
            durationMinutes: 30,
            rrule: nil
        )
        self.patternHoliday = Pattern(id: UUID(), name: "祝日", applyDay: .holiday)
        self.patternRemote = Pattern(id: UUID(), name: "在宅日", applyDay: nil)
    }

    // MARK: - Helpers

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "Asia/Tokyo")
        components.year = y
        components.month = m
        components.day = d
        components.hour = h
        components.minute = min
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func makeContext(
        templates: [TaskTemplate] = [],
        patterns: [Pattern] = [],
        memberships: [PatternTemplateMembership] = [],
        exdates: [TemplateExdate] = [],
        dayMeta: DayMeta? = nil,
        scheduledTasks: [ScheduledTask] = [],
        actualTasks: [ActualTask] = [],
        holidayDates: [Date] = []
    ) -> DayBuilderContext {
        let cal = calendar
        let checker: (Date) -> Bool = { d in
            holidayDates.contains { cal.isDate($0, inSameDayAs: d) }
        }
        return DayBuilderContext(
            templates: templates,
            patterns: patterns,
            memberships: memberships,
            exdates: exdates,
            dayMeta: dayMeta,
            scheduledTasks: scheduledTasks,
            actualTasks: actualTasks,
            holidayChecker: checker,
            calendar: calendar
        )
    }

    // MARK: - T1: rrule weekday primary

    @Test("T1: 平日 rrule は月曜に scheduled 1 件、origin .rrule, primary")
    func rruleWeekdayPrimary() {
        let context = makeContext(templates: [templateBreakfast])
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        #expect(item.task.name == "朝食")
        #expect(item.origin == .rrule)
        #expect(item.membership == .primary)
        #expect(item.visibleRange.start == date(2026, 4, 27, 7))
        #expect(item.visibleRange.duration == 30 * 60)
        #expect(item.task.templateId == templateBreakfast.id)
        #expect(item.task.patternId == nil)
    }

    // MARK: - T2: rrule weekend exclusion

    @Test("T2: 平日 rrule は土曜には出ない (scheduled 0 件)")
    func rruleWeekendExcluded() {
        let context = makeContext(templates: [templateBreakfast])
        let day = DayBuilder.build(date: date(2026, 4, 25), context: context)
        #expect(day.scheduled.isEmpty)
    }

    // MARK: - T3: 元日 holiday pattern

    @Test("T3: 元日 (2027-01-01 金) は祝日 pattern 適用、平日 template は出ない")
    func holidayPatternNewYear() {
        let context = makeContext(
            templates: [templateBreakfast, templateNewYearGreeting],
            patterns: [patternHoliday],
            memberships: [PatternTemplateMembership(patternId: patternHoliday.id, templateId: templateNewYearGreeting.id)],
            holidayDates: [date(2027, 1, 1)]
        )
        let day = DayBuilder.build(date: date(2027, 1, 1), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        #expect(item.task.name == "新年の挨拶")
        #expect(item.origin == .pattern)
        #expect(item.task.patternId == patternHoliday.id)
    }

    // MARK: - T4: 建国記念 holiday pattern

    @Test("T4: 建国記念の日 (2027-02-11 木) は祝日 pattern 適用、平日 template は出ない")
    func holidayPatternFoundation() {
        let context = makeContext(
            templates: [templateBreakfast, templateNewYearGreeting],
            patterns: [patternHoliday],
            memberships: [PatternTemplateMembership(patternId: patternHoliday.id, templateId: templateNewYearGreeting.id)],
            holidayDates: [date(2027, 2, 11)]
        )
        let day = DayBuilder.build(date: date(2027, 2, 11), context: context)

        #expect(day.scheduled.count == 1)
        #expect(day.scheduled[0].task.name == "新年の挨拶")
        #expect(day.scheduled[0].origin == .pattern)
    }

    // MARK: - T5: 振替休日

    @Test("T5: 振替休日 (2026-05-06 水) も祝日扱いで pattern 適用、平日 template は出ない")
    func holidayPatternSubstitute() {
        let context = makeContext(
            templates: [templateBreakfast, templateNewYearGreeting],
            patterns: [patternHoliday],
            memberships: [PatternTemplateMembership(patternId: patternHoliday.id, templateId: templateNewYearGreeting.id)],
            holidayDates: [date(2026, 5, 6)]
        )
        let day = DayBuilder.build(date: date(2026, 5, 6), context: context)

        #expect(day.scheduled.count == 1)
        #expect(day.scheduled[0].task.name == "新年の挨拶")
        #expect(day.scheduled[0].origin == .pattern)
    }

    // MARK: - T6: pattern overlay 全置換

    @Test("T6: dayMeta で pattern 適用日 = 平日 rrule 由来は出さず pattern membership のみ表示")
    func patternOverlayReplacesRrule() {
        let dayMeta = DayMeta(date: date(2026, 4, 27), appliedPatternId: patternRemote.id)
        let context = makeContext(
            templates: [templateBreakfast, templateRemoteMorning],
            patterns: [patternRemote],
            memberships: [PatternTemplateMembership(patternId: patternRemote.id, templateId: templateRemoteMorning.id)],
            dayMeta: dayMeta
        )
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        #expect(item.task.name == "在宅 morning")
        #expect(item.origin == .pattern)
        #expect(item.task.patternId == patternRemote.id)
    }

    // MARK: - T7: exdate 除外

    @Test("T7: exdate(template_id, date) があれば virtual 合成スキップ")
    func exdateExcludesVirtual() {
        let exdate = TemplateExdate(templateId: templateBreakfast.id, date: date(2026, 4, 27))
        let context = makeContext(
            templates: [templateBreakfast],
            exdates: [exdate]
        )
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)
        #expect(day.scheduled.isEmpty)
    }

    // MARK: - T8: scheduled_task 実体優先

    @Test("T8: 編集済み scheduled_task が存在すれば virtual を抑制し実体のみ表示")
    func entityOverridesVirtual() {
        let edited = ScheduledTask(
            id: UUID(),
            name: "編集済朝食",
            categoryId: categoryFood,
            startAt: date(2026, 4, 27, 7),
            endAt: date(2026, 4, 27, 7, 30),
            templateId: templateBreakfast.id,
            patternId: nil
        )
        let context = makeContext(
            templates: [templateBreakfast],
            scheduledTasks: [edited]
        )
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        #expect(item.task.name == "編集済朝食")
        #expect(item.task.id == edited.id)
        #expect(item.origin == .rrule)
    }

    // MARK: - T9: DayMembership.primary

    @Test("T9: 当日内 task は membership .primary、visibleRange は start_at ~ end_at")
    func membershipPrimary() {
        let task = ScheduledTask(
            id: UUID(),
            name: "ミーティング",
            categoryId: categoryFood,
            startAt: date(2026, 4, 27, 9),
            endAt: date(2026, 4, 27, 10),
            templateId: nil,
            patternId: nil
        )
        let context = makeContext(scheduledTasks: [task])
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        #expect(item.membership == .primary)
        #expect(item.visibleRange.start == date(2026, 4, 27, 9))
        #expect(item.visibleRange.end == date(2026, 4, 27, 10))
    }

    // MARK: - T10: DayMembership.spillover

    @Test("T10: 前日 23:00 → 当日 07:00 の睡眠は当日に spillover、visibleRange = 00:00-07:00 JST")
    func membershipSpillover() {
        let sleep = ScheduledTask(
            id: UUID(),
            name: "睡眠",
            categoryId: categorySleep,
            startAt: date(2026, 4, 26, 23),
            endAt: date(2026, 4, 27, 7),
            templateId: nil,
            patternId: nil
        )
        let context = makeContext(scheduledTasks: [sleep])
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        if case .spillover(let from) = item.membership {
            #expect(from == date(2026, 4, 26))
        } else {
            Issue.record("expected .spillover but got \(item.membership)")
        }
        #expect(item.visibleRange.start == date(2026, 4, 27))
        #expect(item.visibleRange.end == date(2026, 4, 27, 7))
    }

    // MARK: - T11: currentBlock(at:)

    @Test("T11: Day.currentBlock(at:) は時刻で primary/overflow を返す。spillover は対象外")
    func currentBlockTimeBased() {
        let breakfast = ScheduledTask(
            id: UUID(),
            name: "朝食",
            categoryId: categoryFood,
            startAt: date(2026, 4, 27, 9),
            endAt: date(2026, 4, 27, 10),
            templateId: nil,
            patternId: nil
        )
        let walk = ScheduledTask(
            id: UUID(),
            name: "散歩",
            categoryId: categoryFood,
            startAt: date(2026, 4, 27, 10),
            endAt: date(2026, 4, 27, 11),
            templateId: nil,
            patternId: nil
        )
        let sleep = ScheduledTask(
            id: UUID(),
            name: "睡眠",
            categoryId: categorySleep,
            startAt: date(2026, 4, 26, 23),
            endAt: date(2026, 4, 27, 7),
            templateId: nil,
            patternId: nil
        )
        let context = makeContext(scheduledTasks: [breakfast, walk, sleep])
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.currentBlock(at: date(2026, 4, 27, 9, 30))?.task.id == breakfast.id)
        #expect(day.currentBlock(at: date(2026, 4, 27, 10, 30))?.task.id == walk.id)
        #expect(day.currentBlock(at: date(2026, 4, 27, 12)) == nil)
        #expect(day.currentBlock(at: date(2026, 4, 27, 10))?.task.id == walk.id)
        #expect(day.currentBlock(at: date(2026, 4, 27, 5)) == nil)
    }

    // MARK: - T12: DayMembership.overflow

    @Test("T12: 当日 22:00 → 翌 02:00 の task は当日に overflow、visibleRange = 22:00-翌 00:00 JST")
    func membershipOverflow() {
        let nightOwl = ScheduledTask(
            id: UUID(),
            name: "深夜作業",
            categoryId: categoryFood,
            startAt: date(2026, 4, 27, 22),
            endAt: date(2026, 4, 28, 2),
            templateId: nil,
            patternId: nil
        )
        let context = makeContext(scheduledTasks: [nightOwl])
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        if case .overflow(let to) = item.membership {
            #expect(to == date(2026, 4, 28))
        } else {
            Issue.record("expected .overflow but got \(item.membership)")
        }
        #expect(item.visibleRange.start == date(2026, 4, 27, 22))
        #expect(item.visibleRange.end == date(2026, 4, 28))
    }

    // MARK: - T13: TaskOrigin.manual

    @Test("T13: template_id / pattern_id 共に nil の手動 scheduled_task は origin .manual")
    func originManual() {
        let manual = ScheduledTask(
            id: UUID(),
            name: "突発ミーティング",
            categoryId: categoryFood,
            startAt: date(2026, 4, 27, 14),
            endAt: date(2026, 4, 27, 15),
            templateId: nil,
            patternId: nil
        )
        let context = makeContext(scheduledTasks: [manual])
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day.scheduled.count == 1)
        #expect(day.scheduled[0].origin == .manual)
    }

    // MARK: - T14: Mode.doNothing

    @Test("T14: dayMeta レコードあり + appliedPatternId nil の日は rrule template も出さない (空きの日)")
    func doNothingDay() {
        let dayMeta = DayMeta(date: date(2026, 4, 27), appliedPatternId: nil)
        let context = makeContext(
            templates: [templateBreakfast],
            dayMeta: dayMeta
        )
        let day = DayBuilder.build(date: date(2026, 4, 27), context: context)
        #expect(day.scheduled.isEmpty)
    }

    // MARK: - T15: dayMeta が祝日判定より優先

    @Test("T15: 祝日かつ dayMeta(在宅 pattern) が指定されていれば dayMeta 側が勝つ")
    func dayMetaOverridesHoliday() {
        let dayMeta = DayMeta(date: date(2027, 1, 1), appliedPatternId: patternRemote.id)
        let context = makeContext(
            templates: [templateBreakfast, templateNewYearGreeting, templateRemoteMorning],
            patterns: [patternHoliday, patternRemote],
            memberships: [
                PatternTemplateMembership(patternId: patternHoliday.id, templateId: templateNewYearGreeting.id),
                PatternTemplateMembership(patternId: patternRemote.id, templateId: templateRemoteMorning.id)
            ],
            dayMeta: dayMeta,
            holidayDates: [date(2027, 1, 1)]
        )
        let day = DayBuilder.build(date: date(2027, 1, 1), context: context)

        #expect(day.scheduled.count == 1)
        let item = day.scheduled[0]
        #expect(item.task.name == "在宅 morning")
        #expect(item.task.patternId == patternRemote.id)
    }

    // MARK: - T16: virtual ID deterministic

    @Test("T16: 同じ template_id + start_at で 2 回 build しても virtual scheduled の id は一致")
    func virtualIdDeterministic() {
        let context = makeContext(templates: [templateBreakfast])
        let day1 = DayBuilder.build(date: date(2026, 4, 27), context: context)
        let day2 = DayBuilder.build(date: date(2026, 4, 27), context: context)

        #expect(day1.scheduled.count == 1)
        #expect(day2.scheduled.count == 1)
        #expect(day1.scheduled[0].task.id == day2.scheduled[0].task.id)
    }
}
