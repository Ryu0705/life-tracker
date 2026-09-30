import Foundation
import Testing
@testable import LifeTracker

// 段階 1 (週帯＋繰り返しの予定の世代管理) の単体テスト。docs/day-cycle-walkthrough.md「段階 1 確定仕様」の完了条件
// 日付はすべて 2026 年 JST。今日 = 9/30(水)。10/12(月) は祝日 (スポーツの日)

enum S1 {
    static var calendar: Calendar { HomeView.defaultCalendar }

    static func date(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: m, day: d, hour: h, minute: min))!
    }

    static let today = date(9, 30, 10)
    static let holiday = date(10, 12)
    static let isHoliday: (Date) -> Bool = { calendar.isDate($0, inSameDayAs: holiday) }

    static func source() -> InMemoryScheduleDataSource {
        InMemoryScheduleDataSource.makeFixture(calendar: calendar, holidayChecker: isHoliday, now: { today })
    }

    static func build(_ source: InMemoryScheduleDataSource, _ day: Date) async throws -> Day {
        DayBuilder.build(date: day, context: try await source.loadDayContext(date: day))
    }

    static func series(_ source: InMemoryScheduleDataSource, _ name: String) -> UUID {
        source.snapshot.versions.first { $0.name == name }!.templateId
    }

    static func content(_ name: String, _ category: UUID, _ start: Int, _ duration: Int) -> ScheduleContent {
        ScheduleContent(name: name, categoryId: category, startMinutes: start, durationMinutes: duration)
    }

    /// その日の行 (前日からの流入を除く = その日に始まる回)
    static func own(_ day: Day) -> [DayScheduledTask] {
        day.scheduled.filter { calendar.isDate($0.task.startAt, inSameDayAs: day.date) }
    }

    static func spillovers(_ day: Day) -> [DayScheduledTask] {
        day.scheduled.filter(\.isSpillover)
    }

    static func version(_ template: UUID, _ from: Date, name: String, start: Int, duration: Int = 60, rrule: String?,
                        ended: Bool = false, category: UUID = UUID()) -> TaskTemplateVersion {
        TaskTemplateVersion(id: UUID(), templateId: template, effectiveFrom: from, isEnded: ended, name: name, categoryId: category,
                            startMinutesFromMidnight: start, durationMinutes: duration, rrule: rrule)
    }
}

// MARK: - 世代の解決 (pure)

struct TemplateVersionsResolveTests {
    let cal = S1.calendar

    @Test func picksLatestVersionOnOrBeforeDay() {
        let t = UUID()
        let v1 = S1.version(t, S1.date(4, 26), name: "旧", start: 405, rrule: "FREQ=DAILY")
        let v2 = S1.version(t, S1.date(10, 5), name: "新", start: 420, rrule: "FREQ=DAILY")
        let before = TemplateVersions.resolve(versions: [v1, v2], memberships: [], on: S1.date(10, 4), calendar: cal)
        let on = TemplateVersions.resolve(versions: [v2, v1], memberships: [], on: S1.date(10, 5, 23), calendar: cal)
        #expect(before.templates.map(\.name) == ["旧"])
        #expect(on.templates.map(\.name) == ["新"])
        #expect(on.templates.first?.id == t, "TaskTemplate の id は系列の id")
        // 最初の世代より前の日は何も出さない
        #expect(TemplateVersions.resolve(versions: [v1, v2], memberships: [], on: S1.date(4, 25), calendar: cal).templates.isEmpty)
    }

    @Test func endedVersionYieldsNothingIncludingMembership() {
        let t = UUID(), holiday = UUID()
        let v1 = S1.version(t, S1.date(4, 26), name: "睡眠", start: 1380, duration: 480, rrule: "FREQ=DAILY")
        let ended = S1.version(t, S1.date(10, 5), name: "睡眠", start: 1380, duration: 480, rrule: nil, ended: true)
        let memberships = [PatternVersionMembership(patternId: holiday, versionId: v1.id),
                           PatternVersionMembership(patternId: holiday, versionId: ended.id)]
        let result = TemplateVersions.resolve(versions: [v1, ended], memberships: memberships, on: S1.date(10, 6), calendar: cal)
        #expect(result.templates.isEmpty)
        #expect(result.memberships.isEmpty)
        let before = TemplateVersions.resolve(versions: [v1, ended], memberships: memberships, on: S1.date(10, 4), calendar: cal)
        #expect(before.memberships == [PatternTemplateMembership(patternId: holiday, templateId: t)])
    }

    @Test func holidayMembershipFollowsVersion() async throws {
        // 旧世代は祝日に出る / 新世代 (10/13 から) は出ない → 10/12 の祝日は旧世代で出る、翌年の祝日は出ない
        let t = UUID(), pattern = Pattern(id: UUID(), name: "休日", applyDay: .holiday)
        let v1 = S1.version(t, S1.date(4, 26), name: "勉強", start: 480, rrule: "FREQ=WEEKLY;BYDAY=MO")
        let v2 = S1.version(t, S1.date(10, 13), name: "勉強", start: 480, rrule: "FREQ=WEEKLY;BYDAY=MO")
        let memberships = [PatternVersionMembership(patternId: pattern.id, versionId: v1.id)]
        func names(_ day: Date, holidays: [Date]) -> [String] {
            let context = TemplateVersions.context(
                date: day, versions: [v1, v2], versionMemberships: memberships, patterns: [pattern], exdates: [], previousExdates: [],
                dayMeta: nil, previousDayMeta: nil, scheduledTasks: [], actualTasks: [],
                holidayChecker: { d in holidays.contains { cal.isDate($0, inSameDayAs: d) } }, calendar: cal)
            return DayBuilder.build(date: day, context: context).scheduled.map(\.task.name)
        }
        #expect(names(S1.date(10, 12), holidays: [S1.date(10, 12)]) == ["勉強"])
        #expect(names(S1.date(11, 23), holidays: [S1.date(11, 23)]) == [])
    }

    @Test func previousDayUsesPreviousVersion() {
        // 睡眠 23:00〜8h を 10/5 から 22:00〜8h に。10/5 の朝の流入は 10/4 の世代 (23:00 発) で出る
        let t = UUID()
        let v1 = S1.version(t, S1.date(4, 26), name: "睡眠", start: 1380, duration: 480, rrule: "FREQ=DAILY")
        let v2 = S1.version(t, S1.date(10, 5), name: "睡眠", start: 1320, duration: 480, rrule: "FREQ=DAILY")
        let context = TemplateVersions.context(
            date: S1.date(10, 5), versions: [v1, v2], versionMemberships: [], patterns: [], exdates: [], previousExdates: [],
            dayMeta: nil, previousDayMeta: nil, scheduledTasks: [], actualTasks: [], holidayChecker: { _ in false }, calendar: cal)
        let day = DayBuilder.build(date: S1.date(10, 5), context: context)
        #expect(S1.spillovers(day).first?.task.startAt == S1.date(10, 4, 23))
        #expect(S1.own(day).first?.task.startAt == S1.date(10, 5, 22))
    }
}

// MARK: - DayBuilder の既存バグ (レビュー DB §3-1)

struct DayBuilderPreviousOverrideTests {
    @Test func previousDayOverrideNotOverlappingStillSuppressesSpillover() {
        let cal = S1.calendar
        let sleep = TaskTemplate(id: UUID(), name: "睡眠", categoryId: UUID(), startMinutesFromMidnight: 1380, durationMinutes: 480,
                                 rrule: "FREQ=DAILY")
        // 前日 10/6 の睡眠を「この予定」で 21:00–23:00 (当日に重ならない) に変えた
        let override = ScheduledTask(id: UUID(), name: "仮眠", categoryId: sleep.categoryId, startAt: S1.date(10, 6, 21),
                                     endAt: S1.date(10, 6, 23), templateId: sleep.id, patternId: nil)
        let context = DayBuilderContext(templates: [sleep], patterns: [], memberships: [], exdates: [], dayMeta: nil,
                                        scheduledTasks: [override], actualTasks: [], holidayChecker: { _ in false }, calendar: cal)
        let day = DayBuilder.build(date: S1.date(10, 7), context: context)
        #expect(S1.spillovers(day).isEmpty, "前日の仮想 (23:00 発) の流入は出ない")
        #expect(!day.scheduled.contains { $0.task.id == override.id }, "前日の実体は当日の一覧には出ない")
        #expect(day.scheduled.count == 1)
        #expect(day.scheduled.first?.task.startAt == S1.date(10, 7, 23))
    }

    @Test func virtualAndEntityAreDistinguished() {
        let cal = S1.calendar
        let gym = TaskTemplate(id: UUID(), name: "ジム", categoryId: UUID(), startMinutesFromMidnight: 405, durationMinutes: 45,
                               rrule: "FREQ=DAILY")
        let context = DayBuilderContext(templates: [gym], patterns: [], memberships: [], exdates: [], dayMeta: nil,
                                        scheduledTasks: [], actualTasks: [], holidayChecker: { _ in false }, calendar: cal)
        let rows = DayBuilder.build(date: S1.date(10, 7), context: context).scheduled
        #expect(rows.count == 1)
        #expect(rows.filter { !$0.isVirtual }.isEmpty)
    }
}

// MARK: - 操作の規則 (メモリ上の実装。RPC と同じ規則)

struct ScheduleOperationRuleTests {
    @Test func fixtureMatchesProduction() async throws {
        let source = S1.source()
        let wed = try await S1.build(source, S1.date(9, 30))
        #expect(S1.own(wed).map(\.task.name) == ["ジム", "睡眠"])
        #expect(S1.spillovers(wed).map(\.task.name) == ["睡眠"])
        // 祝日 10/12(月): 休日パターン = 睡眠だけ
        #expect(S1.own(try await S1.build(source, S1.holiday)).map(\.task.name) == ["睡眠"])
        // 土曜はジムなし
        #expect(S1.own(try await S1.build(source, S1.date(10, 3))).map(\.task.name) == ["睡眠"])
    }

    @Test func thisOccurrenceSaveCreatesThenRewritesEntity() async throws {
        let source = S1.source()
        let gym = S1.series(source, "ジム")
        let category = source.snapshot.categories.first { $0.name == "ジム" }!.id
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(10, 1), patternId: nil,
                                               content: S1.content("ジム遅め", category, 480, 60)))
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(10, 1), patternId: nil,
                                               content: S1.content("ジム遅め", category, 540, 60)))
        #expect(source.snapshot.scheduledTasks.count == 1)
        let day = try await S1.build(source, S1.date(10, 1))
        let gymRow = S1.own(day).first { $0.task.templateId == gym }!
        #expect(S1.own(day).filter { $0.task.templateId == gym }.count == 1)
        #expect(gymRow.task.startAt == S1.date(10, 1, 9))
        #expect(gymRow.isOverridden)
        // 他の日は変わらない
        let other = try await S1.build(source, S1.date(10, 2))
        #expect(S1.own(other).first { $0.task.templateId == gym }?.task.startAt == S1.date(10, 2, 6, 45))
    }

    @Test func thisOccurrenceDeleteAddsExdateAndRemovesOverride() async throws {
        let source = S1.source()
        let gym = S1.series(source, "ジム"), sleep = S1.series(source, "睡眠")
        let category = source.snapshot.categories.first { $0.name == "ジム" }!.id
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(10, 1), patternId: nil,
                                               content: S1.content("ジム", category, 480, 60)))
        try await source.apply(.deleteOccurrence(templateId: gym, date: S1.date(10, 1)))
        #expect(source.snapshot.scheduledTasks.isEmpty)
        #expect(!S1.own(try await S1.build(source, S1.date(10, 1))).contains { $0.task.templateId == gym })
        // 睡眠 (日をまたぐ) をその日だけ消す → その夜と翌朝の流入が消える
        try await source.apply(.deleteOccurrence(templateId: sleep, date: S1.date(10, 1)))
        #expect(!S1.own(try await S1.build(source, S1.date(10, 1))).contains { $0.task.templateId == sleep })
        #expect(S1.spillovers(try await S1.build(source, S1.date(10, 2))).isEmpty)
        #expect(S1.spillovers(try await S1.build(source, S1.date(10, 1))).count == 1, "前日 9/30 からの流入は残る")
    }

    @Test func followingSaveReplacesFromDKeepsLaterOverridesAndExdates() async throws {
        let source = S1.source()
        let gym = S1.series(source, "ジム")
        let category = source.snapshot.categories.first { $0.name == "ジム" }!.id
        // D = 10/5(月)。O(10/5)・O(10/7)・X(10/8) を先に作る。10/9 からの世代も先に置く
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(10, 5), patternId: nil, content: S1.content("O5", category, 480, 60)))
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(10, 7), patternId: nil, content: S1.content("O7", category, 480, 60)))
        try await source.apply(.deleteOccurrence(templateId: gym, date: S1.date(10, 8)))
        try await source.apply(.saveFollowing(templateId: gym, date: S1.date(10, 9), content: S1.content("先の世代", category, 600, 30),
                                              repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: false)))
        try await source.apply(.saveFollowing(templateId: gym, date: S1.date(10, 5), content: S1.content("ジム新", category, 420, 45),
                                              repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: false)))
        let snapshot = source.snapshot
        // O(D) は消す (本人決定 1)、D より後の O・X は残す
        #expect(snapshot.scheduledTasks.map(\.name) == ["O7"])
        #expect(snapshot.exdates.count == 1)
        // D より後の世代は消える
        #expect(snapshot.versions.filter { $0.templateId == gym }.map(\.name).sorted() == ["ジム", "ジム新"])
        func gymRow(_ day: Date) async throws -> DayScheduledTask? {
            S1.own(try await S1.build(source, day)).first { $0.task.templateId == gym }
        }
        #expect(try await gymRow(S1.date(10, 5))?.task.name == "ジム新")
        #expect(try await gymRow(S1.date(10, 5))?.isVirtual == true)
        #expect(try await gymRow(S1.date(10, 2))?.task.name == "ジム", "D より前は変わらない")
        #expect(try await gymRow(S1.date(10, 7))?.task.name == "O7")
        #expect(try await gymRow(S1.date(10, 8)) == nil)
        #expect(try await gymRow(S1.date(10, 9))?.task.name == "ジム新")

        // 同じ日にもう一度「これ以降」→ 世代の id を保って書き換える
        let versionId = source.snapshot.versions.first { $0.name == "ジム新" }!.id
        try await source.apply(.saveFollowing(templateId: gym, date: S1.date(10, 5), content: S1.content("ジム新2", category, 420, 45),
                                              repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: false)))
        #expect(source.snapshot.versions.first { $0.name == "ジム新2" }?.id == versionId)
    }

    @Test func followingSaveOfSleepKeepsMorningFromPreviousVersion() async throws {
        let source = S1.source()
        let sleep = S1.series(source, "睡眠")
        let category = source.snapshot.categories.first { $0.name == "睡眠" }!.id
        try await source.apply(.saveFollowing(templateId: sleep, date: S1.date(10, 1), content: S1.content("睡眠", category, 1320, 480),
                                              repeatRule: ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: true)))
        let day = try await S1.build(source, S1.date(10, 1))
        #expect(S1.spillovers(day).first?.task.startAt == S1.date(9, 30, 23), "前日の回は前日の世代")
        #expect(S1.own(day).first { $0.task.templateId == sleep }?.task.startAt == S1.date(10, 1, 22))
        #expect(S1.spillovers(try await S1.build(source, S1.date(10, 2))).first?.task.startAt == S1.date(10, 1, 22))
        // 祝日の登録も新しい世代に付く
        #expect(S1.own(try await S1.build(source, S1.holiday)).first?.task.startAt == S1.date(10, 12, 22))
    }

    @Test func followingDeleteEndsSeriesAndRemovesOverridesFromD() async throws {
        let source = S1.source()
        let sleep = S1.series(source, "睡眠")
        let category = source.snapshot.categories.first { $0.name == "睡眠" }!.id
        try await source.apply(.saveOccurrence(templateId: sleep, date: S1.date(10, 3), patternId: nil, content: S1.content("O3", category, 1380, 420)))
        try await source.apply(.saveOccurrence(templateId: sleep, date: S1.date(10, 6), patternId: nil, content: S1.content("O6", category, 1380, 420)))
        try await source.apply(.deleteFollowing(templateId: sleep, date: S1.date(10, 4)))
        let snapshot = source.snapshot
        #expect(snapshot.scheduledTasks.map(\.name) == ["O3"], "D 以降の O はすべて消え、前日の O は残る")
        let ended = snapshot.versions.first { $0.templateId == sleep && $0.isEnded }
        #expect(ended != nil && ended?.rrule == nil)
        #expect(!snapshot.versionMemberships.contains { $0.versionId == ended?.id })
        let d = try await S1.build(source, S1.date(10, 4))
        #expect(S1.own(d).isEmpty)
        #expect(S1.spillovers(d).map(\.task.name) == ["O3"], "前日 23:00 発の回は残る")
        #expect(!(try await S1.build(source, S1.date(10, 5))).scheduled.contains { $0.task.templateId == sleep }, "翌朝に流入しない")
        #expect(try await S1.build(source, S1.holiday).scheduled.isEmpty, "終了の世代の祝日の登録は無い")
        #expect(S1.own(try await S1.build(source, S1.date(10, 3))).map(\.task.name) == ["O3"], "D より前は変わらない")
    }

    @Test func followingDeleteRemovesWholeSeriesWithoutPastOccurrences() async throws {
        let source = S1.source()
        let category = source.snapshot.categories[0].id
        try await source.apply(.createSeries(date: S1.date(10, 3), content: S1.content("勉強", category, 480, 60),
                                             repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: true),
                                             replacingSingle: nil))
        let study = S1.series(source, "勉強")
        try await source.apply(.deleteOccurrence(templateId: study, date: S1.date(10, 6)))
        // 系列を作った日 (10/3) で「これ以降を削除」→ 系列ごと消える (除外日・祝日の登録も)
        try await source.apply(.deleteFollowing(templateId: study, date: S1.date(10, 3)))
        let snapshot = source.snapshot
        #expect(!snapshot.templateIds.contains(study))
        #expect(!snapshot.versions.contains { $0.templateId == study })
        #expect(!snapshot.exdates.contains { $0.templateId == study })
        #expect(snapshot.versionMemberships.count == 1, "睡眠の分だけ残る")
    }

    @Test func stopRepeatingBecomesSingleOnD() async throws {
        let source = S1.source()
        let gym = S1.series(source, "ジム")
        let category = source.snapshot.categories.first { $0.name == "ジム" }!.id
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(10, 5), patternId: nil, content: S1.content("O", category, 480, 60)))
        try await source.apply(.endSeriesToSingle(templateId: gym, date: S1.date(10, 5), content: S1.content("ジム", category, 420, 60)))
        let d = S1.own(try await S1.build(source, S1.date(10, 5))).filter { $0.task.name.hasPrefix("ジム") || $0.task.name == "O" }
        #expect(d.count == 1)
        #expect(d.first?.task.templateId == nil)
        #expect(d.first?.task.startAt == S1.date(10, 5, 7))
        #expect(!S1.own(try await S1.build(source, S1.date(10, 6))).contains { $0.task.name == "ジム" })
        #expect(S1.own(try await S1.build(source, S1.date(10, 2))).contains { $0.task.templateId == gym })
    }

    @Test func singleToSeriesReplacesSingle() async throws {
        let source = S1.source()
        let category = source.snapshot.categories[0].id
        try await source.apply(.createSingle(date: S1.date(10, 3), content: S1.content("買い出し", category, 1080, 60)))
        let single = source.snapshot.scheduledTasks[0]
        #expect(single.templateId == nil)
        try await source.apply(.createSeries(date: S1.date(10, 3), content: S1.content("買い出し", category, 1080, 60),
                                             repeatRule: ScheduleRepeatRule(weekdays: [.saturday], showsOnHoliday: false),
                                             replacingSingle: single.id))
        #expect(source.snapshot.scheduledTasks.isEmpty)
        let rows = S1.own(try await S1.build(source, S1.date(10, 3))).filter { $0.task.name == "買い出し" }
        #expect(rows.count == 1)
        #expect(rows.first?.isVirtual == true)
        #expect(S1.own(try await S1.build(source, S1.date(10, 10))).contains { $0.task.name == "買い出し" })
        #expect(!S1.own(try await S1.build(source, S1.date(9, 26))).contains { $0.task.name == "買い出し" }, "D より前には出ない")
    }

    @Test func singleUpdateAndDelete() async throws {
        let source = S1.source()
        let category = source.snapshot.categories[0].id
        try await source.apply(.createSingle(date: S1.date(10, 3), content: S1.content("通院", category, 600, 60)))
        let id = source.snapshot.scheduledTasks[0].id
        try await source.apply(.updateSingle(id: id, date: S1.date(10, 3), content: S1.content("通院", category, 660, 30)))
        #expect(source.snapshot.scheduledTasks[0].startAt == S1.date(10, 3, 11))
        #expect(source.snapshot.scheduledTasks[0].id == id)
        try await source.apply(.deleteSingle(id: id))
        #expect(source.snapshot.scheduledTasks.isEmpty)
    }

    @Test func pastDayIsRejectedAndNothingChanges() async throws {
        let source = S1.source()
        let gym = S1.series(source, "ジム")
        let category = source.snapshot.categories[0].id
        let before = source.snapshot.versions
        let past = S1.date(9, 29)
        let operations: [ScheduleOperation] = [
            .createSingle(date: past, content: S1.content("x", category, 600, 60)),
            .createSeries(date: past, content: S1.content("x", category, 600, 60),
                          repeatRule: ScheduleRepeatRule(weekdays: [.monday], showsOnHoliday: false), replacingSingle: nil),
            .saveOccurrence(templateId: gym, date: past, patternId: nil, content: S1.content("x", category, 600, 60)),
            .deleteOccurrence(templateId: gym, date: past),
            .saveFollowing(templateId: gym, date: past, content: S1.content("x", category, 600, 60),
                           repeatRule: ScheduleRepeatRule(weekdays: [.monday], showsOnHoliday: false)),
            .deleteFollowing(templateId: gym, date: past),
            .endSeriesToSingle(templateId: gym, date: past, content: S1.content("x", category, 600, 60)),
        ]
        for operation in operations {
            await #expect(throws: ScheduleRuleError.pastDay) { try await source.apply(operation) }
        }
        #expect(source.snapshot.versions == before)
        #expect(source.snapshot.scheduledTasks.isEmpty && source.snapshot.exdates.isEmpty)
        // 今日の過ぎた回は編集できる (本人決定 6。境目は日単位)
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(9, 30), patternId: nil, content: S1.content("x", category, 405, 45)))
    }

    @Test func holidayOccurrenceKeepsPatternId() async throws {
        let source = S1.source()
        let sleep = S1.series(source, "睡眠")
        let row = S1.own(try await S1.build(source, S1.holiday)).first!
        #expect(row.origin == .pattern)
        let target = SchedulePlanner.target(for: row, on: S1.holiday, catalog: try await source.fetchCatalog(), calendar: S1.calendar)!
        let decision = SchedulePlanner.save(target: target, input: ScheduleEntryInput(
            content: S1.content("睡眠", row.task.categoryId, 1320, 480), repeatRule: target.original!.repeatRule))
        guard case .chooseScope(let this, _) = decision else { Issue.record("\(decision)"); return }
        try await source.apply(this)
        let saved = source.snapshot.scheduledTasks.first
        #expect(saved?.templateId == sleep)
        #expect(saved?.patternId == row.task.patternId && saved?.patternId != nil)
        #expect(S1.own(try await S1.build(source, S1.holiday)).map(\.task.startAt) == [S1.date(10, 12, 22)])
    }
}

// MARK: - 保存・削除の分岐 (操作表)

struct SchedulePlannerTests {
    let category = UUID()
    let template = UUID()
    let d = S1.date(10, 5)

    var gymContent: ScheduleContent { S1.content("ジム", category, 405, 45) }
    var weekdaysRule: ScheduleRepeatRule { ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: false) }

    func occurrence(overridden: Bool = false) -> ScheduleEditTarget {
        ScheduleEditTarget(date: d, kind: .occurrence(templateId: template, patternId: nil, isOverridden: overridden),
                           original: ScheduleEntryInput(content: gymContent, repeatRule: weekdaysRule), usual: nil)
    }

    @Test func newEntry() {
        let target = ScheduleEditTarget(date: d, kind: .new, original: nil, usual: nil)
        #expect(SchedulePlanner.save(target: target, input: ScheduleEntryInput(content: gymContent, repeatRule: .none))
                == .apply(.createSingle(date: d, content: gymContent)))
        #expect(SchedulePlanner.save(target: target, input: ScheduleEntryInput(content: gymContent, repeatRule: weekdaysRule))
                == .apply(.createSeries(date: d, content: gymContent, repeatRule: weekdaysRule, replacingSingle: nil)))
        // 祝日だけでも繰り返し (系列)
        let holidayOnly = ScheduleRepeatRule(weekdays: [], showsOnHoliday: true)
        #expect(SchedulePlanner.save(target: target, input: ScheduleEntryInput(content: gymContent, repeatRule: holidayOnly))
                == .apply(.createSeries(date: d, content: gymContent, repeatRule: holidayOnly, replacingSingle: nil)))
    }

    @Test func singleEntry() {
        let id = UUID()
        let target = ScheduleEditTarget(date: d, kind: .single(id: id),
                                        original: ScheduleEntryInput(content: gymContent, repeatRule: .none), usual: nil)
        var changed = gymContent
        changed.startMinutes = 420
        #expect(SchedulePlanner.save(target: target, input: ScheduleEntryInput(content: changed, repeatRule: .none))
                == .apply(.updateSingle(id: id, date: d, content: changed)))
        #expect(SchedulePlanner.save(target: target, input: ScheduleEntryInput(content: gymContent, repeatRule: weekdaysRule))
                == .apply(.createSeries(date: d, content: gymContent, repeatRule: weekdaysRule, replacingSingle: id)))
        #expect(SchedulePlanner.delete(target: target) == .apply(.deleteSingle(id: id)))
    }

    @Test func occurrenceContentChangeAsksScope() {
        var changed = gymContent
        changed.name = "ジム (脚)"
        for overridden in [false, true] {
            #expect(SchedulePlanner.save(target: occurrence(overridden: overridden), input: ScheduleEntryInput(content: changed, repeatRule: weekdaysRule))
                    == .chooseScope(this: .saveOccurrence(templateId: template, date: d, patternId: nil, content: changed),
                                    following: .saveFollowing(templateId: template, date: d, content: changed, repeatRule: weekdaysRule)))
        }
        #expect(SchedulePlanner.save(target: occurrence(), input: ScheduleEntryInput(content: gymContent, repeatRule: weekdaysRule)) == .noChange)
    }

    @Test func occurrenceRepeatChangeGoesFollowingWithoutAsking() {
        let rule = ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: true)
        #expect(SchedulePlanner.save(target: occurrence(), input: ScheduleEntryInput(content: gymContent, repeatRule: rule))
                == .apply(.saveFollowing(templateId: template, date: d, content: gymContent, repeatRule: rule)))
    }

    @Test func occurrenceRepeatClearedConfirmsStop() {
        #expect(SchedulePlanner.save(target: occurrence(), input: ScheduleEntryInput(content: gymContent, repeatRule: .none))
                == .confirmStopRepeating(.endSeriesToSingle(templateId: template, date: d, content: gymContent)))
    }

    @Test func occurrenceDeleteAsksScope() {
        #expect(SchedulePlanner.delete(target: occurrence())
                == .chooseScope(this: .deleteOccurrence(templateId: template, date: d),
                                following: .deleteFollowing(templateId: template, date: d)))
    }
}

// MARK: - 行 → 編集の対象 (前日から続く行・過去日・その日だけ変えた回)

struct ScheduleEditTargetTests {
    @Test func pastDayRowsAreNotEditable() async throws {
        let source = S1.source()
        let catalog = try await source.fetchCatalog()
        let day = try await S1.build(source, S1.date(9, 29))
        for row in day.scheduled {
            #expect(SchedulePlanner.editTarget(row: row, viewDay: S1.date(9, 29), day: day, today: S1.today,
                                               catalog: catalog, calendar: S1.calendar) == nil)
        }
    }

    @Test func spilloverOnTodayOpensTonight() async throws {
        let source = S1.source()
        let catalog = try await source.fetchCatalog()
        let day = try await S1.build(source, S1.date(9, 30))
        let spill = S1.spillovers(day).first!
        let target = SchedulePlanner.editTarget(row: spill, viewDay: S1.date(9, 30), day: day, today: S1.today,
                                                catalog: catalog, calendar: S1.calendar)
        #expect(target?.date == S1.date(9, 30))
        #expect(target?.original?.content.startMinutes == 1380)
        #expect(target?.original?.repeatRule == ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: true))
    }

    @Test func spilloverOnFutureDayOpensPreviousDay() async throws {
        let source = S1.source()
        let catalog = try await source.fetchCatalog()
        let day = try await S1.build(source, S1.date(10, 2))
        let spill = S1.spillovers(day).first!
        let target = SchedulePlanner.editTarget(row: spill, viewDay: S1.date(10, 2), day: day, today: S1.today,
                                                catalog: catalog, calendar: S1.calendar)
        #expect(target?.date == S1.date(10, 1))
    }

    @Test func spilloverOfPastSingleIsNotEditable() async throws {
        let cal = S1.calendar
        let single = ScheduledTask(id: UUID(), name: "夜勤", categoryId: UUID(), startAt: S1.date(9, 29, 22), endAt: S1.date(9, 30, 6),
                                   templateId: nil, patternId: nil)
        let context = DayBuilderContext(templates: [], patterns: [], memberships: [], exdates: [], dayMeta: nil,
                                        scheduledTasks: [single], actualTasks: [], holidayChecker: { _ in false }, calendar: cal)
        let day = DayBuilder.build(date: S1.date(9, 30), context: context)
        #expect(SchedulePlanner.editTarget(row: day.scheduled[0], viewDay: S1.date(9, 30), day: day, today: S1.today,
                                           catalog: .empty, calendar: cal) == nil)
    }

    @Test func overriddenOccurrenceShowsUsual() async throws {
        let source = S1.source()
        let gym = S1.series(source, "ジム")
        let category = source.snapshot.categories.first { $0.name == "ジム" }!.id
        try await source.apply(.saveOccurrence(templateId: gym, date: S1.date(10, 1), patternId: nil, content: S1.content("ジム", category, 480, 60)))
        let day = try await S1.build(source, S1.date(10, 1))
        let row = S1.own(day).first { $0.task.templateId == gym }!
        let target = SchedulePlanner.editTarget(row: row, viewDay: S1.date(10, 1), day: day, today: S1.today,
                                                catalog: try await source.fetchCatalog(), calendar: S1.calendar)!
        #expect(target.isOverridden)
        #expect(target.original?.content.startMinutes == 480)
        #expect(target.usual?.timeRangeText == "6:45–7:30")
        #expect(target.original?.repeatRule.weekdays == ScheduleRepeat.weekdays)
    }
}

// MARK: - 繰り返しの表示・RPC の引数

struct ScheduleRepeatTests {
    @Test func rruleRoundTrip() {
        #expect(ScheduleRepeat.rrule(for: Set(ScheduleWeekday.allCases)) == "FREQ=DAILY")
        #expect(ScheduleRepeat.rrule(for: ScheduleRepeat.weekdays) == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        #expect(ScheduleRepeat.rrule(for: [.sunday, .monday]) == "FREQ=WEEKLY;BYDAY=MO,SU")
        #expect(ScheduleRepeat.rrule(for: []) == nil)
        for days: Set<ScheduleWeekday> in [[.wednesday], [.saturday, .sunday], ScheduleRepeat.weekdays, Set(ScheduleWeekday.allCases)] {
            #expect(ScheduleRepeat.weekdays(from: ScheduleRepeat.rrule(for: days)) == days)
        }
    }

    @Test func readsExistingRrulesLikeDayBuilder() {
        #expect(ScheduleRepeat.weekdays(from: "FREQ=WEEKLY") == Set(ScheduleWeekday.allCases))
        #expect(ScheduleRepeat.weekdays(from: "freq=weekly; byday=mo, fr") == [.monday, .friday])
        #expect(ScheduleRepeat.weekdays(from: "FREQ=MONTHLY") == [])
        #expect(ScheduleRepeat.weekdays(from: nil) == [])
    }

    @Test func durationAcrossMidnight() {
        #expect(ScheduleRepeat.duration(startMinutes: 1380, endMinutes: 420) == 480)
        #expect(ScheduleRepeat.duration(startMinutes: 405, endMinutes: 450) == 45)
        #expect(ScheduleRepeat.duration(startMinutes: 600, endMinutes: 600) == nil)
        #expect(ScheduleRepeat.endMinutes(startMinutes: 1380, duration: 480) == 420)
        #expect(ScheduleRepeat.timeText(405) == "6:45")
    }

    @Test func summary() {
        #expect(ScheduleRepeat.summary(days: Set(ScheduleWeekday.allCases), holiday: true) == "毎日・祝日")
        #expect(ScheduleRepeat.summary(days: ScheduleRepeat.weekdays, holiday: false) == "平日")
        #expect(ScheduleRepeat.summary(days: [.monday, .wednesday, .friday], holiday: false) == "月・水・金")
        #expect(ScheduleRepeat.summary(days: [], holiday: true) == "祝日だけ")
    }

    @Test func appearsAndNextDate() {
        let cal = S1.calendar
        #expect(ScheduleWeekday.of(S1.date(10, 3), calendar: cal) == .saturday)
        #expect(ScheduleWeekday.of(S1.date(10, 4), calendar: cal) == .sunday)
        #expect(ScheduleWeekday.of(S1.date(10, 5), calendar: cal) == .monday)
        // 土曜に平日を選んだ → 10/3 には出ない、次は 10/5(月)
        #expect(!ScheduleRepeat.appears(on: S1.date(10, 3), days: ScheduleRepeat.weekdays, holiday: false, isHoliday: S1.isHoliday, calendar: cal))
        #expect(ScheduleRepeat.nextDate(after: S1.date(10, 3), days: ScheduleRepeat.weekdays, holiday: false,
                                        isHoliday: S1.isHoliday, calendar: cal) == S1.date(10, 5))
        // 祝日だけ → 次は 10/12
        #expect(ScheduleRepeat.nextDate(after: S1.date(10, 3), days: [], holiday: true, isHoliday: S1.isHoliday, calendar: cal) == S1.date(10, 12))
        // 月曜だけ・祝日は出さない → 10/12 (祝日) を飛ばして 10/19
        #expect(ScheduleRepeat.nextDate(after: S1.date(10, 5), days: [.monday], holiday: false, isHoliday: S1.isHoliday, calendar: cal) == S1.date(10, 19))
    }

    @Test func validationAllowsNoRepeat() {
        let content = S1.content("通院", UUID(), 600, 60)
        #expect(ScheduleStore.validate(ScheduleEntryInput(content: content, repeatRule: .none)) == nil)
        var empty = content
        empty.name = "  "
        #expect(ScheduleStore.validate(ScheduleEntryInput(content: empty, repeatRule: .none)) == .emptyName)
    }
}

struct ScheduleRPCTests {
    @Test func mapsOperationsToFunctions() throws {
        let cal = S1.calendar
        let t = UUID(), c = UUID()
        let content = S1.content("ジム", c, 405, 45)
        let call = ScheduleRPC.call(for: .saveFollowing(templateId: t, date: S1.date(10, 5, 15), content: content,
                                                        repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: true)),
                                    calendar: cal)
        #expect(call.function == "schedule_template_save_following")
        #expect(call.params.values == [
            "p_template_id": .string(t.uuidString), "p_date": .string("2026-10-05"), "p_name": .string("ジム"),
            "p_category_id": .string(c.uuidString), "p_start": .int(405), "p_duration": .int(45),
            "p_rrule": .string("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"), "p_show_on_holiday": .bool(true),
        ])
        let names: [ScheduleOperation: String] = [
            .createSingle(date: S1.date(10, 5), content: content): "schedule_single_save",
            .updateSingle(id: t, date: S1.date(10, 5), content: content): "schedule_single_save",
            .deleteSingle(id: t): "schedule_single_delete",
            .createSeries(date: S1.date(10, 5), content: content, repeatRule: .none, replacingSingle: nil): "schedule_template_create",
            .deleteFollowing(templateId: t, date: S1.date(10, 5)): "schedule_template_delete_following",
            .endSeriesToSingle(templateId: t, date: S1.date(10, 5), content: content): "schedule_template_end_to_single",
            .saveOccurrence(templateId: t, date: S1.date(10, 5), patternId: nil, content: content): "schedule_occurrence_save",
            .deleteOccurrence(templateId: t, date: S1.date(10, 5)): "schedule_occurrence_delete",
        ]
        for (operation, name) in names {
            #expect(ScheduleRPC.call(for: operation, calendar: cal).function == name)
        }
    }

    @Test func sendsNullsExplicitly() throws {
        let call = ScheduleRPC.call(for: .createSeries(date: S1.date(10, 5), content: S1.content("祝日だけ", UUID(), 600, 60),
                                                       repeatRule: ScheduleRepeatRule(weekdays: [], showsOnHoliday: true), replacingSingle: nil),
                                    calendar: S1.calendar)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.supabase.encode(call.params)) as? [String: Any]
        #expect(json?["p_rrule"] is NSNull)
        #expect(json?["p_replace_single_id"] is NSNull)
        #expect(json?["p_show_on_holiday"] as? Bool == true)
        #expect(json?.keys.sorted() == ["p_category_id", "p_date", "p_duration", "p_name", "p_replace_single_id",
                                        "p_rrule", "p_show_on_holiday", "p_start"])
    }
}

// MARK: - store (読み込みのキャッシュ・書き込み後の読み直し)

@MainActor
struct ScheduleStoreTests {
    @Test func performInvalidatesAndReloadsVisibleDay() async throws {
        let source = S1.source()
        let store = ScheduleStore(dayDataSource: source, dataSource: source, calendar: S1.calendar, holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(10, 1))
        await store.ensureLoaded(S1.date(10, 2))
        #expect(store.day(S1.date(10, 2)) != nil)
        let category = store.categories.first { $0.name == "ジム" }!.id
        let gym = S1.series(source, "ジム")
        let error = await store.perform(.saveFollowing(templateId: gym, date: S1.date(10, 1), content: S1.content("ジム新", category, 420, 45),
                                                       repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays, showsOnHoliday: false)),
                                        reloading: S1.date(10, 1))
        #expect(error == nil)
        #expect(store.day(S1.date(10, 2)) == nil, "他の日のキャッシュは捨てる")
        #expect(store.day(S1.date(10, 1))?.scheduled.contains { $0.task.name == "ジム新" } == true)
        #expect(store.catalog.versions.contains { $0.name == "ジム新" })
        // 過去日への書き込みは失敗を返す
        let past = await store.perform(.deleteOccurrence(templateId: gym, date: S1.date(9, 29)), reloading: S1.date(10, 1))
        #expect(past as? ScheduleRuleError == .pastDay)
        #expect(store.canEditSchedule(on: S1.date(9, 30), today: S1.today))
        #expect(!store.canEditSchedule(on: S1.date(9, 29), today: S1.today))
    }
}

struct ScheduleDefaultStartTests {
    @Test func roundsUpToNextHalfHour() {
        let calendar = HomeView.defaultCalendar
        func at(_ h: Int, _ m: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: h, minute: m))!
        }
        #expect(ScheduleRepeat.defaultStartMinutes(now: at(14, 58), calendar: calendar) == 900)
        #expect(ScheduleRepeat.defaultStartMinutes(now: at(14, 20), calendar: calendar) == 870)
        #expect(ScheduleRepeat.defaultStartMinutes(now: at(15, 0), calendar: calendar) == 900)
        #expect(ScheduleRepeat.defaultStartMinutes(now: at(23, 45), calendar: calendar) == 1410)
    }
}
