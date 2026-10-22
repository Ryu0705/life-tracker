import Foundation
import Supabase
import Testing
@testable import LifeTracker

// 時刻のないやること (0012) と回数の単体テスト。docs/untimed-tasks-implementation-plan.md「3. テスト」。
// 暦は Asia/Tokyo 固定 (S1.calendar)。日付は 2026 年。10/12(月) は祝日 (S1.isHoliday)。今日は時計 (U.Clock) で動かす

@MainActor
enum U {
    static var cal: Calendar { S1.calendar }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    static func source(_ clock: Clock) -> InMemoryScheduleDataSource {
        InMemoryScheduleDataSource.makeFixture(calendar: cal, holidayChecker: S1.isHoliday, now: { clock.now })
    }

    /// 「生活」の種類を作って返す
    static func life(_ source: InMemoryScheduleDataSource) async throws -> UUID {
        try await source.createCategory(name: "生活").id
    }

    static func todo(_ name: String, _ category: UUID, target: Int = 1) -> ScheduleContent {
        ScheduleContent(name: name, categoryId: category, timing: .untimed, targetCount: target)
    }

    static func daily(carry: Bool = false) -> ScheduleRepeatRule {
        ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: false, carriesOver: carry)
    }

    static func todoDay(_ source: InMemoryScheduleDataSource, _ day: Date) async throws -> TodoDay {
        let catalog = try await source.fetchCatalog()
        let fetch = try await source.loadTodos(date: day)
        return TodoBuilder.build(date: day, versions: catalog.versions, versionMemberships: catalog.versionMemberships,
                                 patterns: catalog.patterns, fetch: fetch, holidayChecker: S1.isHoliday, calendar: cal)
    }

    static func rows(_ day: TodoDay, _ name: String) -> [DayTodo] {
        day.todos.filter { $0.name == name }
    }

    static func tap(_ key: CheckInKey, at: Date, name: String = "x", category: UUID) -> CheckInOperation {
        .tap(key: key, name: name, categoryId: category, at: at, plannedStart: nil, plannedEnd: nil)
    }

    static func singleId(_ source: InMemoryScheduleDataSource, _ name: String) -> UUID {
        source.snapshot.todoEntities.first { $0.name == name && $0.templateId == nil }?.id
            ?? source.snapshot.scheduledTasks.first { $0.name == name && $0.templateId == nil }!.id
    }
}

// MARK: - TodoBuilder (組み立て)

@MainActor
struct TodoBuilderTests {
    let cal = U.cal

    @Test func singleCarriesOverUntilClosedThenShowsCompleteOnlyThatDay() async throws {
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 10), content: U.todo("書類を出す", life)))
        clock.now = S1.date(10, 13, 10)
        // 10/13 に「10/10 から」で出る (元の日のまま)
        let oct13 = try await U.todoDay(source, S1.date(10, 13))
        let row = try #require(U.rows(oct13, "書類を出す").first)
        #expect(row.occurrenceDate == S1.date(10, 10))
        #expect(row.origin == .single && !row.isDone)
        // 10/13 に終える → 10/13 は「完了」で出る、10/14 は出ない、過去日 10/12 はその日の時点 (未完)
        try await source.applyCheckIn(U.tap(row.key, at: S1.date(10, 13, 10), category: life))
        let done = try await U.todoDay(source, S1.date(10, 13))
        #expect(U.rows(done, "書類を出す").first?.isDone == true)
        #expect(U.rows(done, "書類を出す").first?.closedOn == S1.date(10, 13))
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 14)), "書類を出す").isEmpty)
        let past = try #require(U.rows(try await U.todoDay(source, S1.date(10, 12)), "書類を出す").first)
        #expect(past.count == 0 && !past.isDone)
        // 元の日より前の日には出ない
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 9)), "書類を出す").isEmpty)
    }

    @Test func pastDayShowsProgressAsOfThatDay() async throws {
        // 10/13 は「水 3/8（未完）」、10/14 は「水 8/8（10/13 から）」
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("水", life, target: 8),
                                             repeatRule: U.daily(carry: true), replacingSingle: nil))
        let water = S1.series(source, "水")
        let key = CheckInKey.occurrence(templateId: water, date: S1.date(10, 13))
        for h in [10, 11, 12] { try await source.applyCheckIn(U.tap(key, at: S1.date(10, 13, h), category: life)) }
        clock.now = S1.date(10, 14, 20)
        for h in 8...12 { try await source.applyCheckIn(U.tap(key, at: S1.date(10, 14, h), category: life)) }

        let oct13 = try #require(U.rows(try await U.todoDay(source, S1.date(10, 13)), "水").first)
        #expect(oct13.count == 3 && !oct13.isDone)
        let oct14 = U.rows(try await U.todoDay(source, S1.date(10, 14)), "水")
        #expect(oct14.map(\.occurrenceDate) == [S1.date(10, 14), S1.date(10, 13)], "終わっていない今日の回が上、完了した 10/13 の回が下")
        let carried = try #require(oct14.first { $0.occurrenceDate == S1.date(10, 13) })
        #expect(carried.count == 8 && carried.isDone && carried.closedOn == S1.date(10, 14))
        // 翌日は 10/13 の回は出ない
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 15)), "水").map(\.occurrenceDate) == [S1.date(10, 14), S1.date(10, 15)])
    }

    @Test func carryOffSeriesDoesNotShowYesterday() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("掃除", life),
                                             repeatRule: U.daily(carry: false), replacingSingle: nil))
        clock.now = S1.date(10, 14, 9)
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 14)), "掃除").map(\.occurrenceDate) == [S1.date(10, 14)])
    }

    @Test func carryOnShowsSevenDaysThenCountsOlder() async throws {
        let clock = U.Clock(S1.date(10, 1, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 1), content: U.todo("読書", life),
                                             repeatRule: U.daily(carry: true), replacingSingle: nil))
        let book = S1.series(source, "読書")
        clock.now = S1.date(10, 12, 9)
        // 10/2 の回を 10/12 にスキップ (閉じた日 10/12 < 10/13 → 10/13 の「ほか N 件」から引く)
        try await source.applyCheckIn(.skipCounted(key: .occurrence(templateId: book, date: S1.date(10, 2)), name: "読書",
                                                   categoryId: life, on: S1.date(10, 12)))
        clock.now = S1.date(10, 13, 9)
        let oct13 = try await U.todoDay(source, S1.date(10, 13))
        // 回の日 ∈ [10/6, 10/13] (10/12 は祝日で回が無い) の 7 行。重なる回は古い回が上
        #expect(U.rows(oct13, "読書").map(\.occurrenceDate) == [6, 7, 8, 9, 10, 11, 13].map { S1.date(10, $0) })
        // 10/1〜10/5 のうち閉じた 10/2 を除く 4 件
        #expect(oct13.olderOpen == [TodoOlderOpen(templateId: book, name: "読書", count: 4)])
    }

    @Test func noOccurrenceOnDoNothingDayHolidayAndExdate() {
        // pure: 月曜だけ (祝日も出さない) の系列。10/12(月) は祝日 → 出ない、10/19(月) は day_meta「何もしない日」、10/26(月) は除外日
        let t = UUID(), category = UUID()
        let version = TaskTemplateVersion(id: UUID(), templateId: t, effectiveFrom: S1.date(10, 1), isEnded: false, name: "ゴミ出し",
                                          categoryId: category, startMinutesFromMidnight: nil, durationMinutes: nil,
                                          rrule: "FREQ=WEEKLY;BYDAY=MO")
        let holiday = Pattern(id: UUID(), name: "休日", applyDay: .holiday)
        var fetch = TodoFetch.empty
        fetch.dayMetas = [DayMeta(date: S1.date(10, 19), appliedPatternId: nil)]
        fetch.exdates = [TemplateExdate(templateId: t, date: S1.date(10, 26))]
        func names(_ day: Date) -> [String] {
            TodoBuilder.build(date: day, versions: [version], versionMemberships: [], patterns: [holiday], fetch: fetch,
                              holidayChecker: S1.isHoliday, calendar: cal).todos.map(\.name)
        }
        #expect(names(S1.date(10, 5)) == ["ゴミ出し"])
        #expect(names(S1.date(10, 12)) == [])
        #expect(names(S1.date(10, 19)) == [])
        #expect(names(S1.date(10, 26)) == [])
        #expect(names(S1.date(11, 2)) == ["ゴミ出し"])
        // 祝日も出す (休日パターンへの登録) なら祝日に出る
        let membership = PatternVersionMembership(patternId: holiday.id, versionId: version.id)
        #expect(TodoBuilder.build(date: S1.date(10, 12), versions: [version], versionMemberships: [membership], patterns: [holiday],
                                  fetch: fetch, holidayChecker: S1.isHoliday, calendar: cal).todos.first?.patternId == holiday.id)
    }

    @Test func overrideTargetAndOrdering() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("腕立て", life, target: 2),
                                             repeatRule: U.daily(), replacingSingle: nil))
        let pushup = S1.series(source, "腕立て")
        try await source.apply(.saveOccurrence(templateId: pushup, date: S1.date(10, 13), patternId: nil,
                                               content: U.todo("腕立て", life, target: 5)))
        clock.now = S1.date(10, 13, 9, 1)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("買い物", life)))
        clock.now = S1.date(10, 13, 9, 2)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("返信", life)))
        var day = try await U.todoDay(source, S1.date(10, 13))
        let row = try #require(U.rows(day, "腕立て").first)
        #expect(row.target == 5 && row.origin == .override)
        // 作った順。終えたものは下へ
        #expect(day.todos.map(\.name) == ["腕立て", "買い物", "返信"])
        try await source.applyCheckIn(U.tap(.single(id: U.singleId(source, "買い物")), at: S1.date(10, 13, 9), category: life))
        day = try await U.todoDay(source, S1.date(10, 13))
        #expect(day.todos.map(\.name) == ["腕立て", "返信", "買い物"])
        // この予定の保存で時刻の有無は変えられない
        await #expect(throws: ScheduleRuleError.timingMismatch) {
            try await source.apply(.saveOccurrence(templateId: pushup, date: S1.date(10, 14), patternId: nil,
                                                   content: S1.content("腕立て", life, 600, 30)))
        }
    }
}

// MARK: - 規則 (InMemory が原本)

@MainActor
struct UntimedRuleTests {
    let cal = U.cal

    @Test func tapUntapSkipAndUnskip() async throws {
        let clock = U.Clock(S1.date(10, 14, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 14), content: U.todo("水", life, target: 3),
                                             repeatRule: U.daily(carry: true), replacingSingle: nil))
        let key = CheckInKey.occurrence(templateId: S1.series(source, "水"), date: S1.date(10, 14))
        try await source.applyCheckIn(U.tap(key, at: S1.date(10, 14, 10), category: life))
        clock.now = S1.date(10, 15, 9)
        try await source.applyCheckIn(U.tap(key, at: S1.date(10, 15, 8), category: life))
        // − は見ている日以前の最新のタップを消す (10/14 の時点では 10/14 のタップ)
        try await source.applyCheckIn(.untap(key: key, asOf: S1.date(10, 14)))
        #expect(source.snapshot.taps.map(\.tappedAt) == [S1.date(10, 15, 8)])
        try await source.applyCheckIn(U.tap(key, at: S1.date(10, 14, 11), category: life))
        // スキップは skipped_on = V。V より前の日では未完と出る
        try await source.applyCheckIn(.skipCounted(key: key, name: "水", categoryId: life, on: S1.date(10, 15)))
        #expect(source.snapshot.actualTasks.first?.skippedOn == S1.date(10, 15))
        #expect(source.snapshot.taps.count == 2, "タップは残す")
        let before = try #require(U.rows(try await U.todoDay(source, S1.date(10, 14)), "水").first)
        #expect(!before.isSkipped && before.count == 1)
        #expect(before.isSkipRecorded, "skipped_on より前の日でもスキップの記録がある (操作は取り消しだけ。R6)")
        let on = try #require(U.rows(try await U.todoDay(source, S1.date(10, 15)), "水").first { $0.occurrenceDate == S1.date(10, 14) })
        #expect(on.isSkipped)
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 16)), "水").allSatisfy { $0.occurrenceDate != S1.date(10, 14) })
        // スキップした回は数えられない
        await #expect(throws: CheckInRuleError.skippedOccurrence) {
            try await source.applyCheckIn(U.tap(key, at: S1.date(10, 15, 9), category: life))
        }
        // 取り消し: タップがあれば「やった」に戻る
        try await source.applyCheckIn(.unskipCounted(key: key))
        #expect(source.snapshot.actualTasks.first?.status == .done && source.snapshot.actualTasks.first?.skippedOn == nil)
        // 全部消すと記録なし。スキップ → 取り消しでタップが無ければ行が消える
        try await source.applyCheckIn(.untap(key: key, asOf: S1.date(10, 15)))
        try await source.applyCheckIn(.untap(key: key, asOf: S1.date(10, 15)))
        #expect(source.snapshot.actualTasks.isEmpty && source.snapshot.taps.isEmpty)
        try await source.applyCheckIn(.skipCounted(key: key, name: "水", categoryId: life, on: S1.date(10, 15)))
        try await source.applyCheckIn(.unskipCounted(key: key))
        #expect(source.snapshot.actualTasks.isEmpty)
    }

    @Test func changingTargetClosesAndReopens() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("片付け", life, target: 3)))
        let id = U.singleId(source, "片付け")
        try await source.applyCheckIn(U.tap(.single(id: id), at: S1.date(10, 13, 9), category: life))
        try await source.apply(.updateSingle(id: id, date: S1.date(10, 13), content: U.todo("片付け", life, target: 1)))
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 13)), "片付け").first?.isDone == true)
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 14)), "片付け").isEmpty, "閉じた日 10/13 の翌日は出ない")
        try await source.apply(.updateSingle(id: id, date: S1.date(10, 13), content: U.todo("片付け", life, target: 3)))
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 14)), "片付け").first?.count == 1, "目標を上げると閉じた日が外れる")
    }

    @Test func earlierOpenOccurrencesSurviveDeleteFollowingAndSwitchToTimed() async throws {
        // 決定 3: 「これ以降を削除」・時刻ありへの切替の後も D より前の閉じていない回は繰り越し続ける
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 10), content: U.todo("日記", life),
                                             repeatRule: U.daily(carry: true), replacingSingle: nil))
        let diary = S1.series(source, "日記")
        try await source.apply(.createSeries(date: S1.date(10, 10), content: U.todo("散歩", life),
                                             repeatRule: U.daily(carry: true), replacingSingle: nil))
        let walk = S1.series(source, "散歩")
        clock.now = S1.date(10, 13, 9)
        try await source.apply(.deleteFollowing(templateId: diary, date: S1.date(10, 13)))
        // 10/12 は祝日 (祝日も出すでない系列は回が無い)
        let range = [S1.date(10, 10), S1.date(10, 11)]
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 13)), "日記").map(\.occurrenceDate) == range)
        try await source.apply(.saveFollowing(templateId: walk, date: S1.date(10, 13), content: S1.content("散歩", life, 420, 30),
                                              repeatRule: U.daily()))
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 13)), "散歩").map(\.occurrenceDate) == range)
        let timed = try await S1.build(source, S1.date(10, 13))
        #expect(timed.scheduled.contains { $0.task.name == "散歩" })
        #expect(source.snapshot.versions.first { $0.templateId == diary && $0.isEnded }?.timing == .untimed, "終了の世代も時刻なしを写す")
    }

    @Test func carriedSingleEditableClosedSingleNot() async throws {
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 10), content: U.todo("書類", life)))
        try await source.apply(.createSingle(date: S1.date(10, 10), content: U.todo("郵便", life)))
        let paper = U.singleId(source, "書類"), mail = U.singleId(source, "郵便")
        clock.now = S1.date(10, 11, 9)
        try await source.applyCheckIn(U.tap(.single(id: mail), at: S1.date(10, 11, 9), category: life))
        clock.now = S1.date(10, 13, 9)
        // 繰り越し中: 元の日のまま保存できる。過去の日付へは変えられない。今日以降へは変えられる
        try await source.apply(.updateSingle(id: paper, date: S1.date(10, 10), content: U.todo("書類を出す", life)))
        await #expect(throws: ScheduleRuleError.pastDay) {
            try await source.apply(.updateSingle(id: paper, date: S1.date(10, 11), content: U.todo("書類を出す", life)))
        }
        try await source.apply(.updateSingle(id: paper, date: S1.date(10, 14), content: U.todo("書類を出す", life)))
        #expect(source.snapshot.todoEntities.first { $0.id == paper }?.occurrenceDate == S1.date(10, 14))
        try await source.apply(.updateSingle(id: paper, date: S1.date(10, 14), content: U.todo("書類を出す", life)))
        // 10/11 に閉じた単発は過去日なので変えられない・消せない
        await #expect(throws: ScheduleRuleError.pastDay) {
            try await source.apply(.updateSingle(id: mail, date: S1.date(10, 10), content: U.todo("郵便", life)))
        }
        await #expect(throws: ScheduleRuleError.pastDay) { try await source.apply(.deleteSingle(id: mail)) }
        // 繰り越し中の単発は消せる
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("x", life)))
        clock.now = S1.date(10, 15, 9)
        try await source.apply(.deleteSingle(id: U.singleId(source, "x")))
        #expect(!source.snapshot.todoEntities.contains { $0.name == "x" })
    }

    @Test func singleEditRulesMatchSQL() async throws {
        // 0012 private.schedule_assert_single_editable と同じ (2026-10-14 リード指示)
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 10), content: U.todo("繰越", life)))
        try await source.apply(.createSingle(date: S1.date(10, 10), content: U.todo("今日閉じた", life)))
        let carried = U.singleId(source, "繰越"), closedToday = U.singleId(source, "今日閉じた")
        clock.now = S1.date(10, 13, 9)
        try await source.applyCheckIn(U.tap(.single(id: closedToday), at: S1.date(10, 13, 9), category: life))
        // 繰り越し中: 元の日のまま時刻ありへは切り替えられない (元の日 < 今日)。今日以降の日なら時刻ありにできる
        await #expect(throws: ScheduleRuleError.pastDay) {
            try await source.apply(.updateSingle(id: carried, date: S1.date(10, 10), content: S1.content("繰越", life, 600, 30)))
        }
        // 今日閉じた単発: 元の日のまま時刻なしで保存できる。日付は変えられない。消せる
        try await source.apply(.updateSingle(id: closedToday, date: S1.date(10, 10), content: U.todo("今日閉じた!", life)))
        await #expect(throws: ScheduleRuleError.closedSingleDate) {
            try await source.apply(.updateSingle(id: closedToday, date: S1.date(10, 14), content: U.todo("今日閉じた", life)))
        }
        try await source.apply(.deleteSingle(id: closedToday))
        try await source.apply(.updateSingle(id: carried, date: S1.date(10, 13), content: S1.content("繰越", life, 600, 30)))
        #expect(source.snapshot.scheduledTasks.contains { $0.id == carried })
    }

    @Test func countedOperationsCommonChecks() async throws {
        // 0012 private.record_occurrence_checked: 記録なしの −・取り消しは何もしない、時刻つきで目標 1 はスキップも拒否
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("x", life)))
        let key = CheckInKey.single(id: U.singleId(source, "x"))
        try await source.applyCheckIn(.untap(key: key, asOf: S1.date(10, 13)))
        try await source.applyCheckIn(.unskipCounted(key: key))
        #expect(source.snapshot.actualTasks.isEmpty)
        let gym = S2.row(try await S1.build(source, S1.date(10, 13)), "ジム")
        await #expect(throws: CheckInRuleError.notCounted) {
            try await source.applyCheckIn(.skipCounted(key: CheckInKey.of(gym, calendar: cal), name: "ジム",
                                                       categoryId: gym.task.categoryId, on: S1.date(10, 13)))
        }
        // 明日の回は記録できない
        try await source.apply(.createSingle(date: S1.date(10, 14), content: U.todo("y", life)))
        await #expect(throws: CheckInRuleError.futureDay) {
            try await source.applyCheckIn(.skipCounted(key: .single(id: U.singleId(source, "y")), name: "y", categoryId: life,
                                                       on: S1.date(10, 13)))
        }
    }

    @Test func singleToSeriesMovesTapsToTheDayOccurrence() async throws {
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 10), content: U.todo("筋トレ", life, target: 2)))
        let id = U.singleId(source, "筋トレ")
        clock.now = S1.date(10, 11, 9)
        try await source.applyCheckIn(U.tap(.single(id: id), at: S1.date(10, 11, 9), category: life))
        clock.now = S1.date(10, 13, 9)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("筋トレ", life, target: 2),
                                             repeatRule: U.daily(), replacingSingle: id))
        let record = try #require(source.snapshot.actualTasks.first)
        #expect(record.templateId == S1.series(source, "筋トレ") && record.occurrenceDate == S1.date(10, 13))
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 13)), "筋トレ").first?.count == 1)
    }

    @Test func switchingTimingKeepsTapsAndSkips() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        // 時刻つきの単発で「やった」→ 時刻なしへ切り替え: タップ 1 つ (checkin_set が付けた) が残り 1/1 で完了
        try await source.apply(.createSingle(date: S1.date(10, 13), content: S1.content("通院", life, 480, 60)))
        let clinic = U.singleId(source, "通院")
        try await source.applyCheckIn(.set(key: .single(id: clinic), status: .done, name: "通院", categoryId: life,
                                           start: S1.date(10, 13, 8), end: S1.date(10, 13, 9)))
        try await source.apply(.updateSingle(id: clinic, date: S1.date(10, 13), content: U.todo("通院", life)))
        #expect(source.snapshot.taps.count == 1)
        let row = try #require(U.rows(try await U.todoDay(source, S1.date(10, 13)), "通院").first)
        #expect(row.isDone && row.record?.startAt == S1.date(10, 13, 8))
        // 時刻つき → なしにした回の時刻つきの頃の「やった」は予定外としても出ない
        let day = try await S1.build(source, S1.date(10, 13))
        let todoKeys = try await U.todoDay(source, S1.date(10, 13)).keys
        #expect(!CheckInPlanner.listItems(day: day, calendar: cal, todoKeys: todoKeys).contains { $0.id == row.record?.id })
        #expect(CheckInPlanner.listItems(day: day, calendar: cal).contains { $0.id == row.record?.id }, "やることのキーを渡さないと出る")

        // 時刻なしの系列でスキップ → 時刻ありへ切り替えてもスキップが残る
        try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("ヨガ", life), repeatRule: U.daily(),
                                             replacingSingle: nil))
        let yoga = S1.series(source, "ヨガ")
        try await source.applyCheckIn(.skipCounted(key: .occurrence(templateId: yoga, date: S1.date(10, 13)), name: "ヨガ",
                                                   categoryId: life, on: S1.date(10, 13)))
        try await source.apply(.saveFollowing(templateId: yoga, date: S1.date(10, 13), content: S1.content("ヨガ", life, 1200, 30),
                                              repeatRule: U.daily()))
        let timed = try await S1.build(source, S1.date(10, 13))
        #expect(S2.state(source, timed, S2.row(timed, "ヨガ")).isSkipped)
    }

    @Test func checkinSetSkipToDoneAndOneTap() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13),
                                             content: ScheduleContent(name: "体操", categoryId: life, startMinutes: 420, durationMinutes: 30,
                                                                      targetCount: 2),
                                             repeatRule: U.daily(), replacingSingle: nil))
        let row = S2.row(try await S1.build(source, S1.date(10, 13)), "体操")
        let key = CheckInKey.of(row, calendar: cal)
        try await source.applyCheckIn(.skipCounted(key: key, name: "体操", categoryId: life, on: S1.date(10, 13)))
        // checkin_set でスキップのままなら skipped_on を保つ
        try await source.applyCheckIn(.set(key: key, status: .skipped, name: "体操", categoryId: life, start: nil, end: nil))
        #expect(source.snapshot.actualTasks.first?.skippedOn == S1.date(10, 13))
        // スキップ → やった: skipped_on を外す。タップが 1 つ付く (押した時刻 = 終了)
        try await source.applyCheckIn(S2.done(row))
        #expect(source.snapshot.actualTasks.first?.status == .done && source.snapshot.actualTasks.first?.skippedOn == nil)
        #expect(source.snapshot.taps.map(\.tappedAt) == [row.task.endAt])
        // 時刻だけ直してもタップは増えない
        try await source.applyCheckIn(S2.done(row, start: S1.date(10, 13, 7), end: S1.date(10, 13, 7, 40)))
        #expect(source.snapshot.taps.count == 1)
    }

    @Test func backfilledDoneCountsAsOne() async throws {
        // 0012 の backfill (既存の done にタップ 1 つ = end_at) の後: 目標 1 の回は今と同じ「やった」、時刻なしにしても 1/1
        let clock = U.Clock(S1.date(10, 13, 9))
        var state = U.source(clock).snapshot
        let life = Category(id: UUID(), name: "生活", subInputKind: nil)
        state.categories.append(life)
        let single = TodoEntity(id: UUID(), name: "掃除", categoryId: life.id, templateId: nil, patternId: nil,
                                occurrenceDate: S1.date(10, 13), targetCount: 1, createdAt: nil)
        state.todoEntities.append(single)
        let record = ActualTask(id: UUID(), name: "掃除", categoryId: life.id, startAt: S1.date(10, 13, 7), endAt: S1.date(10, 13, 8),
                                scheduledTaskId: single.id)
        state.actualTasks.append(record)
        state.taps.append(ActualTaskTap(id: UUID(), actualTaskId: record.id, tappedAt: S1.date(10, 13, 8)))
        let source = InMemoryScheduleDataSource(state: state, calendar: cal, holidayChecker: S1.isHoliday, now: { clock.now })
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 13)), "掃除").first?.isDone == true)
    }

    @Test func rejectsSleepFutureBeforeOccurrenceAndTimedTargetOne() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("x", life)))
        let key = CheckInKey.single(id: U.singleId(source, "x"))
        let sleep = S2.category(source, "睡眠").id
        await #expect(throws: CheckInRuleError.sleepIsSeparate) {
            try await source.applyCheckIn(.tap(key: key, name: "x", categoryId: sleep, at: S1.date(10, 13, 9), plannedStart: nil, plannedEnd: nil))
        }
        await #expect(throws: CheckInRuleError.futureDay) {
            try await source.applyCheckIn(U.tap(key, at: S1.date(10, 14, 9), category: life))
        }
        await #expect(throws: CheckInRuleError.beforeOccurrence) {
            try await source.applyCheckIn(U.tap(key, at: S1.date(10, 12, 9), category: life))
        }
        let day = try await S1.build(source, S1.date(10, 13))
        let gym = S2.row(day, "ジム")
        await #expect(throws: CheckInRuleError.notCounted) {
            try await source.applyCheckIn(.tap(key: CheckInKey.of(gym, calendar: cal), name: "ジム", categoryId: gym.task.categoryId,
                                               at: S1.date(10, 13, 9), plannedStart: gym.task.startAt, plannedEnd: gym.task.endAt))
        }
        #expect(source.snapshot.actualTasks.isEmpty)
    }
}

// MARK: - 時刻つきで目標 2 以上の回 (本人決定 2)

@MainActor
struct TimedCountTests {
    let cal = U.cal

    @Test func targetThreeCircleCountsUpThenDone() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: ScheduleContent(name: "水やり", categoryId: life, startMinutes: 600, durationMinutes: 30, targetCount: 3),
                                             repeatRule: U.daily(), replacingSingle: nil))
        var day = try await S1.build(source, S1.date(10, 13))
        let row = S2.row(day, "水やり")
        #expect(row.task.targetCount == 3)
        let category = source.snapshot.categories.first { $0.id == life }
        func state() -> CheckInState {
            CheckInPlanner.state(for: S2.row(day, "水やり"), records: day.records, overrides: [:], category: category,
                                 workoutSetTimes: [], calendar: cal, taps: day.taps, adjustments: [:])
        }
        #expect(state() == .progress(count: 0, target: 3, record: nil))
        #expect(CheckInPlanner.circleStyle(row: row, state: state(), category: category, today: clock.now, calendar: cal)
                == .progress(count: 0, target: 3))
        for minute in [0, 10, 20] {
            let op = try #require(CheckInPlanner.toggle(row: row, state: state(), calendar: cal, tapAt: S1.date(10, 13, 9, minute)))
            guard case .tap = op else { Issue.record("+1 にならない"); return }
            try await source.applyCheckIn(op)
            day = try await S1.build(source, S1.date(10, 13))
        }
        guard case .progress(3, 3, let record?) = state() else { Issue.record("3/3 にならない"); return }
        #expect(state().isDone && record.startAt == row.task.startAt, "回の行は予定の時刻で作る")
        // 目標を超えても数える
        try await source.applyCheckIn(CheckInPlanner.toggle(row: row, state: state(), calendar: cal, tapAt: S1.date(10, 13, 9, 30))!)
        day = try await S1.build(source, S1.date(10, 13))
        #expect(state() == .progress(count: 4, target: 3, record: record))
        // スワイプのスキップ → 丸でスキップの取り消し (タップがあるので「やった」に戻る)
        try await source.applyCheckIn(CheckInPlanner.skip(row: row, state: state(), calendar: cal, skipOn: S1.date(10, 13))!)
        day = try await S1.build(source, S1.date(10, 13))
        #expect(state().isSkipped)
        #expect(CheckInPlanner.toggle(row: row, state: state(), calendar: cal) == .unskipCounted(key: CheckInKey.of(row, calendar: cal)))
    }

    @Test func spilloverOccurrenceTappedNextDayCountsOnOccurrenceDay() async throws {
        let clock = U.Clock(S1.date(10, 14, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 14), content: ScheduleContent(name: "夜勉強", categoryId: life, startMinutes: 1380, durationMinutes: 120, targetCount: 2),
                                             repeatRule: U.daily(), replacingSingle: nil))
        clock.now = S1.date(10, 15, 9)
        let next = try await S1.build(source, S1.date(10, 15))
        let spill = try #require(next.scheduled.first { $0.task.name == "夜勉強" && $0.isSpillover })
        try await source.applyCheckIn(.tap(key: CheckInKey.of(spill, calendar: cal), name: "夜勉強", categoryId: life,
                                           at: S1.date(10, 15, 0, 30), plannedStart: spill.task.startAt, plannedEnd: spill.task.endAt))
        let first = try await S1.build(source, S1.date(10, 14))
        let category = source.snapshot.categories.first { $0.id == life }
        let state = CheckInPlanner.state(for: S2.row(first, "夜勉強"), records: first.records, overrides: [:], category: category,
                                         workoutSetTimes: [], calendar: cal, taps: first.taps, adjustments: [:])
        #expect(state == .progress(count: 1, target: 2, record: source.snapshot.actualTasks.first))
    }

    @Test func targetOneTimedKeepsTodaysCircle() async throws {
        let source = S1.source()
        let day = try await S1.build(source, S1.date(9, 30))
        let gym = S2.row(day, "ジム")
        // 目標 1 の時刻つきの回は今の .set / .clear
        guard case .set = CheckInPlanner.toggle(row: gym, state: .none, calendar: S2.cal)! else { Issue.record("set でない"); return }
        try await S2.apply(source, S2.done(gym))
        let done = try await S1.build(source, S1.date(9, 30))
        let state = S2.state(source, done, gym)
        #expect(CheckInPlanner.toggle(row: gym, state: state, calendar: S2.cal) == .clear(key: CheckInKey.of(gym, calendar: S2.cal)))
    }

    /// 2026-10-14 本人指示: 時刻つきで目標 1 の記録なしの丸は実績の時刻を聞く。やった・スキップ・目標 2 以上は今までどおり
    @Test func circleTapAsksActualTimeOnlyForEmptyTargetOne() async throws {
        let source = S1.source()
        let day = try await S1.build(source, S1.date(9, 30))
        let gym = S2.row(day, "ジム")
        let key = CheckInKey.of(gym, calendar: S2.cal)
        #expect(CheckInPlanner.circleTap(row: gym, state: .none, calendar: S2.cal) == .askActualTime)
        try await S2.apply(source, S2.done(gym))
        let done = try await S1.build(source, S1.date(9, 30))
        let doneState = S2.state(source, done, gym)
        #expect(CheckInPlanner.circleTap(row: gym, state: doneState, calendar: S2.cal) == .apply(.clear(key: key)), "やった → 記録なし")
        let skipped = ActualTask(id: UUID(), name: "ジム", categoryId: gym.task.categoryId, startAt: nil, endAt: nil, status: .skipped,
                                 templateId: gym.task.templateId, occurrenceDate: S1.date(9, 30), scheduledTaskId: nil)
        #expect(CheckInPlanner.circleTap(row: gym, state: .skipped(skipped), calendar: S2.cal) == .apply(.clear(key: key)), "スキップ → 記録なし")
        #expect(CheckInPlanner.circleTap(row: gym, state: .workout(first: S1.date(9, 30, 7), last: S1.date(9, 30, 8), count: 3),
                                         calendar: S2.cal) == nil, "セットのあるジムは押せない")
        // 目標 2 以上は聞かずに +1
        let tapAt = S1.date(9, 30, 9)
        let progress = CheckInPlanner.circleTap(row: gym, state: .progress(count: 0, target: 3, record: nil), calendar: S2.cal, tapAt: tapAt)
        guard case .apply(.tap(let tapKey, _, _, let at, _, _, _))? = progress else { Issue.record("+1 にならない"); return }
        #expect(tapKey == key && at == tapAt)
    }

    @Test func actualRangeSummaryShowsNextDayAndOtherStartDay() {
        let night: (start: Date, end: Date) = (S1.date(9, 30, 23), S1.date(10, 1, 0, 30))
        let summary = CheckInPlanner.actualRangeSummary(night, occurrenceDay: S1.date(9, 30), calendar: S2.cal)
        #expect(summary == "23:00〜0:30（翌日） · 1時間30分")
        // 前日から続く回の開始が回の日の翌日 (0:10 に始めた) なら日付を付ける
        let after: (start: Date, end: Date) = (S1.date(10, 1, 0, 10), S1.date(10, 1, 0, 40))
        let late = CheckInPlanner.actualRangeSummary(after, occurrenceDay: S1.date(9, 30), calendar: S2.cal)
        #expect(late.hasSuffix("0:10〜0:40 · 30分") && late != "0:10〜0:40 · 30分")
    }
}

// MARK: - 世代の選び方 (レビュー重大 1)

@MainActor
struct UntimedVersionSelectionTests {
    let cal = U.cal

    @Test func switchingTimingHidesTheOtherKind() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: S1.content("勉強", life, 600, 60),
                                             repeatRule: U.daily(), replacingSingle: nil))
        let study = S1.series(source, "勉強")
        try await source.apply(.saveFollowing(templateId: study, date: S1.date(10, 14), content: U.todo("勉強", life),
                                              repeatRule: U.daily()))
        // D 以降は時刻つきの行に出ない (古い時刻ありの世代が復活しない)、やることに出る
        #expect(!(try await S1.build(source, S1.date(10, 15))).scheduled.contains { $0.task.name == "勉強" })
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 15)), "勉強").count == 1)
        #expect((try await S1.build(source, S1.date(10, 13))).scheduled.contains { $0.task.name == "勉強" })
        // 時刻なしの系列でも編集画面の入力が返る
        let catalog = try await source.fetchCatalog()
        #expect(catalog.seriesInput(templateId: study, on: S1.date(10, 15), calendar: cal)?.content.timing == .untimed)
        // なし → あり: d ≥ D のやることに出ない
        try await source.apply(.saveFollowing(templateId: study, date: S1.date(10, 16), content: S1.content("勉強", life, 600, 60),
                                              repeatRule: U.daily()))
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 16)), "勉強").isEmpty)
        #expect((try await S1.build(source, S1.date(10, 16))).scheduled.contains { $0.task.name == "勉強" })
    }

    @Test func untimedVersionsDoNotChangeTimedRows() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let before = try await S1.build(source, S1.date(10, 14)).scheduled.map(\.task)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("水", life), repeatRule: U.daily(carry: true),
                                             replacingSingle: nil))
        try await source.apply(.createSingle(date: S1.date(10, 14), content: U.todo("書類", life)))
        let after = try await S1.build(source, S1.date(10, 14)).scheduled.map(\.task)
        #expect(before == after)
        let effective = TemplateVersions.effectiveVersions(versions: source.snapshot.versions, on: S1.date(10, 14), calendar: cal)
        #expect(effective.allSatisfy { $0.timing.isTimed })
        #expect(TemplateVersions.effectiveTodoVersions(versions: source.snapshot.versions, on: S1.date(10, 14), calendar: cal)
                .map(\.name) == ["水"])
    }

    @Test func planningSwitchOfTimingIsFollowing() {
        let t = UUID(), c = UUID()
        let original = ScheduleEntryInput(content: S1.content("勉強", c, 600, 60), repeatRule: U.daily())
        let target = ScheduleEditTarget(date: S1.date(10, 14), kind: .occurrence(templateId: t, patternId: nil, isOverridden: false),
                                        original: original, usual: nil)
        let input = ScheduleEntryInput(content: U.todo("勉強", c), repeatRule: U.daily())
        #expect(SchedulePlanner.save(target: target, input: input)
                == .apply(.saveFollowing(templateId: t, date: S1.date(10, 14), content: U.todo("勉強", c), repeatRule: U.daily())))
        // 時刻なしの繰り越し中の単発は元の日のまま。時刻ありへ変えたら見ている日
        let id = UUID()
        let single = ScheduleEditTarget(date: S1.date(10, 13), kind: .single(id: id),
                                        original: ScheduleEntryInput(content: U.todo("書類", c), repeatRule: .none), usual: nil,
                                        occurrenceDate: S1.date(10, 10))
        #expect(SchedulePlanner.save(target: single, input: ScheduleEntryInput(content: U.todo("書類を出す", c), repeatRule: .none))
                == .apply(.updateSingle(id: id, date: S1.date(10, 10), content: U.todo("書類を出す", c))))
        #expect(SchedulePlanner.save(target: single, input: ScheduleEntryInput(content: S1.content("書類", c, 600, 30), repeatRule: .none))
                == .apply(.updateSingle(id: id, date: S1.date(10, 13), content: S1.content("書類", c, 600, 30))))
        #expect(SchedulePlanner.save(target: single, input: ScheduleEntryInput(content: U.todo("書類", c), repeatRule: .none,
                                                                               singleDate: S1.date(10, 15)))
                == .apply(.updateSingle(id: id, date: S1.date(10, 15), content: U.todo("書類", c))))
    }
}

// MARK: - store (楽観更新・読み込みの失敗)

@MainActor
struct UntimedStoreTests {
    let cal = U.cal

    @Test func optimisticCountsPerViewDay() async throws {
        // 10/14 の回 (繰り越しオン) に 10/14 で 3 回。10/15 に 1 回押した応答前: 10/15 の一覧は 4、10/14 の一覧は 3 のまま
        let clock = U.Clock(S1.date(10, 14, 9))
        let inner = U.source(clock)
        let life = try await U.life(inner)
        try await inner.apply(.createSeries(date: S1.date(10, 14), content: U.todo("水", life, target: 8),
                                            repeatRule: U.daily(carry: true), replacingSingle: nil))
        let key = CheckInKey.occurrence(templateId: S1.series(inner, "水"), date: S1.date(10, 14))
        for h in [9, 10, 11] { try await inner.applyCheckIn(U.tap(key, at: S1.date(10, 14, h), category: life)) }
        clock.now = S1.date(10, 15, 9)
        let gated = GatedCheckInSource(inner: inner)
        let store = ScheduleStore(dayDataSource: gated, dataSource: gated, todoDataSource: inner, calendar: cal,
                                  holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(10, 14))
        await store.ensureLoaded(S1.date(10, 15))
        func count(_ day: Date) -> Int? { store.todoDay(day)?.todos.first { $0.key == key }?.count }
        #expect(count(S1.date(10, 15)) == 3 && count(S1.date(10, 14)) == 3)

        let pending = Task { await store.checkIn(U.tap(key, at: S1.date(10, 15, 9), category: life), reloading: S1.date(10, 15)) }
        for _ in 0..<1000 where gated.pending == 0 { await Task.yield() }
        #expect(count(S1.date(10, 15)) == 4)
        #expect(count(S1.date(10, 14)) == 3, "10/15 のタップは 10/14 の時点の回数に入らない")
        // − も応答前に見せる (V 以前の最新 = 応答前に足したタップ)
        let minus = Task { await store.checkIn(.untap(key: key, asOf: S1.date(10, 15)), reloading: S1.date(10, 15)) }
        for _ in 0..<1000 where count(S1.date(10, 15)) != 3 { await Task.yield() }
        #expect(count(S1.date(10, 15)) == 3)
        gated.release()
        for _ in 0..<1000 where gated.pending == 0 { await Task.yield() }
        gated.release()
        let (e1, e2) = await (pending.value, minus.value)
        #expect(e1 == nil && e2 == nil)
        #expect(count(S1.date(10, 15)) == 3)
        #expect(store.tapAdjustments.isEmpty)
        #expect(store.todoDay(S1.date(10, 14)) == nil, "回数の記録の後は見ている日以外のキャッシュを捨てる")
    }

    @Test func todoFailureDoesNotBreakOtherLoaders() async throws {
        let source = S1.source()
        let store = ScheduleStore(dayDataSource: source, dataSource: source, todoDataSource: ThrowingTodoSource(), calendar: cal,
                                  holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(9, 30))
        #expect(store.day(S1.date(9, 30)) != nil, "時刻つきの一覧は出る")
        #expect(store.todoErrors[S1.date(9, 30)] != nil && store.todoDay(S1.date(9, 30)) == nil)
        // 睡眠タブ・今日のカードは loadTodos を呼ばない
        let loader = TodayDataLoader(dataSource: source, calendar: cal, now: { S1.today })
        await loader.refresh()
        #expect(loader.day != nil && loader.error == nil)
        let sleep = SleepStore(dataSource: source, dayDataSource: source, scheduleDataSource: source, calendar: cal, now: { S1.today })
        await sleep.loadPlan(today: S1.today)
        #expect(!sleep.plans.isEmpty)
    }

    @Test func mockDayFixtureHasTodoSamples() async throws {
        let source = InMemoryScheduleDataSource.makeFixture(calendar: cal, holidayChecker: S1.isHoliday, now: { S1.today }, withSamples: true)
        let today = try await U.todoDay(source, S1.date(9, 30))
        #expect(U.rows(today, "書類を出す").map(\.occurrenceDate) == [S1.date(9, 27)])
        #expect(U.rows(today, "水を飲む").map { "\($0.count)/\($0.target)" }.sorted() == ["0/8", "3/8"])
        #expect(U.rows(today, "掃除").map(\.occurrenceDate) == [S1.date(9, 30)], "繰り越しオフは昨日の回を出さない")
        #expect(U.rows(today, "ストレッチ").first.map { "\($0.count)/\($0.target)" } == "1/3")
    }
}

/// loadTodos が必ず失敗する (やることの節だけ失敗になる確認用)
struct ThrowingTodoSource: TodoDataSource {
    struct Failure: Error {}
    func loadTodos(date: Date) async throws -> TodoFetch { throw Failure() }
}

// MARK: - RPC の写像・取得の decode

@MainActor
struct UntimedRPCTests {
    let cal = S1.calendar

    @Test func timingMapsToStartDurationTargetAndCarryOver() {
        let c = UUID(), t = UUID()
        let untimed = ScheduleRPC.call(for: .createSeries(date: S1.date(10, 13), content: ScheduleContent(name: "水", categoryId: c,
                                                                                                            timing: .untimed, targetCount: 8),
                                                          repeatRule: U.daily(carry: true), replacingSingle: nil), calendar: cal)
        #expect(untimed.params.values["p_start"] == .null && untimed.params.values["p_duration"] == .null)
        #expect(untimed.params.values["p_target"] == .int(8) && untimed.params.values["p_carry_over"] == .bool(true))
        // 時刻つきは繰り越しを送らない (carry_chk)
        let timed = ScheduleRPC.call(for: .saveFollowing(templateId: t, date: S1.date(10, 13), content: S1.content("水", c, 600, 30),
                                                         repeatRule: U.daily(carry: true)), calendar: cal)
        #expect(timed.params.values["p_carry_over"] == .bool(false) && timed.params.values["p_start"] == .int(600))
        for operation in [ScheduleOperation.createSingle(date: S1.date(10, 13), content: U.todo("x", c, target: 2)),
                          .endSeriesToSingle(templateId: t, date: S1.date(10, 13), content: U.todo("x", c, target: 2)),
                          .saveOccurrence(templateId: t, date: S1.date(10, 13), patternId: nil, content: U.todo("x", c, target: 2))] {
            let call = ScheduleRPC.call(for: operation, calendar: cal)
            #expect(call.params.values["p_target"] == .int(2) && call.params.values["p_start"] == .null)
            #expect(call.params.values["p_carry_over"] == nil)
        }
    }

    @Test func countedOperationsMapToNewFunctions() {
        let t = UUID(), c = UUID()
        let key = CheckInKey.occurrence(templateId: t, date: S1.date(10, 12))
        let tap = ScheduleRPC.call(for: .tap(key: key, name: "水", categoryId: c, at: S1.date(10, 13, 9), plannedStart: nil,
                                             plannedEnd: nil), calendar: cal)
        #expect(tap.function == "record_tap_add")
        #expect(Set(tap.params.values.keys) == ["p_template_id", "p_occurrence_date", "p_scheduled_task_id", "p_name", "p_category_id",
                                                 "p_tapped_at", "p_start", "p_end", "p_tap_id"])
        #expect(tap.params.values["p_occurrence_date"] == .string("2026-10-12") && tap.params.values["p_start"] == .null)
        let untap = ScheduleRPC.call(for: .untap(key: .single(id: t), asOf: S1.date(10, 13, 23)), calendar: cal)
        #expect(untap.function == "record_tap_remove")
        #expect(untap.params.values == ["p_template_id": .null, "p_occurrence_date": .null, "p_scheduled_task_id": .string(t.uuidString),
                                        "p_as_of": .string("2026-10-13")])
        let skip = ScheduleRPC.call(for: .skipCounted(key: key, name: "水", categoryId: c, on: S1.date(10, 13)), calendar: cal)
        #expect(skip.function == "record_skip_set" && skip.params.values["p_on"] == .string("2026-10-13"))
        #expect(Set(skip.params.values.keys) == ["p_template_id", "p_occurrence_date", "p_scheduled_task_id", "p_name", "p_category_id", "p_on"])
        let unskip = ScheduleRPC.call(for: .unskipCounted(key: key), calendar: cal)
        #expect(unskip.function == "record_skip_clear" && unskip.params.values.count == 3)
        let fetch = ScheduleRPC.todoFetch(date: S1.date(10, 13, 15), calendar: cal)
        #expect(fetch.function == "todo_fetch")
        #expect(fetch.params.values == ["p_date": .string("2026-10-13"), "p_from": .string("2026-10-06"),
                                        "p_count_from": .string("2025-10-12")])
    }

    @Test func decodesTodoFetchAndUntimedVersion() throws {
        let t = UUID(), s = UUID(), a = UUID(), c = UUID()
        let json = """
        {"singles": [{"id": "\(s)", "name": "書類", "category_id": "\(c)", "start_at": null, "end_at": null, "template_id": null,
                      "pattern_id": null, "occurrence_date": "2026-10-10", "target_count": 1}],
         "overrides": [],
         "actuals": [{"id": "\(a)", "name": "書類", "category_id": "\(c)", "start_at": null, "end_at": null, "status": "skipped",
                      "template_id": null, "occurrence_date": "2026-10-10", "scheduled_task_id": "\(s)", "skipped_on": "2026-10-13"}],
         "taps": [{"id": "\(UUID())", "actual_task_id": "\(a)", "tapped_at": "2026-10-12T09:00:00+09:00"}],
         "exdates": null, "day_metas": [], "older_closed": [{"template_id": "\(t)", "occurrence_date": "2026-09-30"}]}
        """
        let fetch = try JSONDecoder.supabase.decode(TodoFetch.self, from: Data(json.utf8))
        #expect(fetch.singles.map(\.occurrenceDate) == [S1.date(10, 10)])
        #expect(fetch.actuals.first?.skippedOn == S1.date(10, 13))
        #expect(fetch.taps.first?.tappedAt == S1.date(10, 12, 9))
        #expect(fetch.exdates.isEmpty)
        #expect(fetch.olderClosed == [TodoOccurrenceRef(templateId: t, occurrenceDate: S1.date(9, 30))])
        let version = """
        {"id": "\(UUID())", "template_id": "\(t)", "effective_from": "2026-10-13", "is_ended": false, "name": "水",
         "category_id": "\(c)", "start_minutes_from_midnight": null, "duration_minutes": null, "rrule": "FREQ=DAILY",
         "target_count": 8, "carry_over": true, "created_at": "2026-10-13T09:00:00+09:00"}
        """
        let decoded = try JSONDecoder.supabase.decode(TaskTemplateVersion.self, from: Data(version.utf8))
        #expect(decoded.timing == .untimed && decoded.targetCount == 8 && decoded.carryOver && decoded.timedTemplate == nil)
        // 0012 より前の行 (target_count・carry_over なし) も読める
        let old = """
        {"id": "\(UUID())", "template_id": "\(t)", "effective_from": "2026-04-26", "is_ended": false, "name": "ジム",
         "category_id": "\(c)", "start_minutes_from_midnight": 405, "duration_minutes": 45, "rrule": null}
        """
        let legacy = try JSONDecoder.supabase.decode(TaskTemplateVersion.self, from: Data(old.utf8))
        #expect(legacy.targetCount == 1 && !legacy.carryOver && legacy.timedTemplate?.startMinutesFromMidnight == 405)
    }
}

// MARK: - 時刻なし単発の検査の表 (0012 private.schedule_assert_single_editable。2026-10-14 リード指示)
// 今日 = 10/13。状態 = 閉じていない (元の日 10/10 の繰り越し中・元の日 10/13) / 今日閉じた / 今日より前 (10/11) に閉じた

@MainActor
struct SingleEditTableTests {
    enum Closed { case open, today, before }

    /// 元の日 origin の時刻なしの単発を 1 つ作り、closed の状態にした source (今日 = 10/13 9:00)
    func make(_ closed: Closed, origin: Date = S1.date(10, 10)) async throws -> (InMemoryScheduleDataSource, UUID, UUID) {
        let clock = U.Clock(origin.addingTimeInterval(9 * 3600))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: origin, content: U.todo("単発", life)))
        let id = U.singleId(source, "単発")
        switch closed {
        case .open:
            break
        case .today:
            clock.now = S1.date(10, 13, 9)
            try await source.applyCheckIn(U.tap(.single(id: id), at: S1.date(10, 13, 9), category: life))
        case .before:
            clock.now = S1.date(10, 11, 9)
            try await source.applyCheckIn(U.tap(.single(id: id), at: S1.date(10, 11, 9), category: life))
        }
        clock.now = S1.date(10, 13, 9)
        return (source, id, life)
    }

    func untimedSave(_ s: InMemoryScheduleDataSource, _ id: UUID, _ life: UUID, on date: Date = S1.date(10, 10)) async throws {
        try await s.apply(.updateSingle(id: id, date: date, content: U.todo("単発!", life)))
    }

    func timedSave(_ s: InMemoryScheduleDataSource, _ id: UUID, _ life: UUID, on date: Date) async throws {
        try await s.apply(.updateSingle(id: id, date: date, content: S1.content("単発", life, 600, 30)))
    }

    // 閉じていない (繰り越し中)
    @Test func openSaveUntimedKeepsOriginalDay() async throws {
        let (s, id, life) = try await make(.open)
        try await untimedSave(s, id, life)
        #expect(s.snapshot.todoEntities.first { $0.id == id }?.name == "単発!")
    }

    @Test func openSwitchToTimedNeedsTodayOrLater() async throws {
        let (s, id, life) = try await make(.open)
        await #expect(throws: ScheduleRuleError.pastDay) { try await timedSave(s, id, life, on: S1.date(10, 10)) }
        try await timedSave(s, id, life, on: S1.date(10, 13))
        #expect(s.snapshot.scheduledTasks.contains { $0.id == id })
        // 元の日 ≥ 今日 (繰り越していない) なら元の日のまま時刻ありにできる
        let (today, todayId, todayLife) = try await make(.open, origin: S1.date(10, 13))
        try await timedSave(today, todayId, todayLife, on: S1.date(10, 13))
        #expect(today.snapshot.scheduledTasks.contains { $0.id == todayId })
    }

    @Test func openDateChangeOnlyToTodayOrLater() async throws {
        let (s, id, life) = try await make(.open)
        await #expect(throws: ScheduleRuleError.pastDay) { try await untimedSave(s, id, life, on: S1.date(10, 11)) }
        try await untimedSave(s, id, life, on: S1.date(10, 14))
        #expect(s.snapshot.todoEntities.first { $0.id == id }?.occurrenceDate == S1.date(10, 14))
    }

    @Test func openCanBeDeleted() async throws {
        let (s, id, _) = try await make(.open)
        try await s.apply(.deleteSingle(id: id))
        #expect(s.snapshot.todoEntities.isEmpty)
    }

    // 今日閉じた
    @Test func closedTodaySaveUntimedKeepsOriginalDay() async throws {
        let (s, id, life) = try await make(.today)
        try await untimedSave(s, id, life)
        #expect(s.snapshot.todoEntities.first { $0.id == id }?.name == "単発!")
    }

    @Test func closedTodaySwitchToTimedNeedsTodayOrLater() async throws {
        let (s, id, life) = try await make(.today)
        await #expect(throws: ScheduleRuleError.pastDay) { try await timedSave(s, id, life, on: S1.date(10, 10)) }
        // 日を変える切替は「閉じた単発の日付は変えられない」で止まる
        await #expect(throws: ScheduleRuleError.closedSingleDate) { try await timedSave(s, id, life, on: S1.date(10, 13)) }
        let (today, todayId, todayLife) = try await make(.today, origin: S1.date(10, 13))
        try await timedSave(today, todayId, todayLife, on: S1.date(10, 13))
        #expect(today.snapshot.scheduledTasks.contains { $0.id == todayId })
    }

    @Test func closedTodayCannotChangeDate() async throws {
        let (s, id, life) = try await make(.today)
        await #expect(throws: ScheduleRuleError.closedSingleDate) { try await untimedSave(s, id, life, on: S1.date(10, 14)) }
        #expect(s.snapshot.todoEntities.first { $0.id == id }?.occurrenceDate == S1.date(10, 10))
    }

    @Test func closedTodayCanBeDeleted() async throws {
        let (s, id, _) = try await make(.today)
        try await s.apply(.deleteSingle(id: id))
        #expect(s.snapshot.todoEntities.isEmpty)
        #expect(s.snapshot.actualTasks.first?.scheduledTaskId == nil, "やったはつながりを外して残す")
    }

    // 今日より前に閉じた: どれもできない
    @Test func closedBeforeTodayRejectsEverything() async throws {
        let (s, id, life) = try await make(.before)
        await #expect(throws: ScheduleRuleError.pastDay) { try await untimedSave(s, id, life) }
        await #expect(throws: ScheduleRuleError.pastDay) { try await timedSave(s, id, life, on: S1.date(10, 10)) }
        await #expect(throws: ScheduleRuleError.pastDay) { try await timedSave(s, id, life, on: S1.date(10, 13)) }
        await #expect(throws: ScheduleRuleError.pastDay) { try await untimedSave(s, id, life, on: S1.date(10, 14)) }
        await #expect(throws: ScheduleRuleError.pastDay) { try await s.apply(.deleteSingle(id: id)) }
        #expect(s.snapshot.todoEntities.first { $0.id == id }?.name == "単発")
    }

    // 時刻つきの単発は今のまま
    @Test func timedSingleUnchanged() async throws {
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 10), content: S1.content("通院", life, 600, 60)))
        let id = U.singleId(source, "通院")
        clock.now = S1.date(10, 13, 9)
        await #expect(throws: ScheduleRuleError.pastDay) {
            try await source.apply(.updateSingle(id: id, date: S1.date(10, 10), content: U.todo("通院", life)))
        }
        await #expect(throws: ScheduleRuleError.pastDay) { try await source.apply(.deleteSingle(id: id)) }
    }
}

// MARK: - 時刻つきで目標 1 の回は回数の 4 操作をすべて拒否 (計画 1-2「SQL も拒否」)

@MainActor
struct TimedTargetOneRejectsCountedTests {
    @Test func allFourCountedOperationsRejected() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let gym = S2.row(try await S1.build(source, S1.date(10, 13)), "ジム")
        let key = CheckInKey.of(gym, calendar: U.cal)
        // 既に「やった」がある回でも拒否する (記録の有無に依らない)
        try await source.applyCheckIn(S2.done(gym))
        let operations: [CheckInOperation] = [
            .tap(key: key, name: "ジム", categoryId: gym.task.categoryId, at: S1.date(10, 13, 9),
                 plannedStart: gym.task.startAt, plannedEnd: gym.task.endAt),
            .untap(key: key, asOf: S1.date(10, 13)),
            .skipCounted(key: key, name: "ジム", categoryId: gym.task.categoryId, on: S1.date(10, 13)),
            .unskipCounted(key: key),
        ]
        for operation in operations {
            await #expect(throws: CheckInRuleError.notCounted) { try await source.applyCheckIn(operation) }
        }
        #expect(source.snapshot.actualTasks.count == 1 && source.snapshot.taps.count == 1, "何も変わらない")
    }
}

// MARK: - 単発 → 繰り返しの検査はつなぎ直す前 (2026-10-14 穴の修正。SQL の schedule_template_create と同じ順)

@MainActor
struct SingleToSeriesCheckTests {
    let table = SingleEditTableTests()

    func toSeries(_ s: InMemoryScheduleDataSource, _ id: UUID, _ life: UUID) async throws {
        try await s.apply(.createSeries(date: S1.date(10, 13), content: U.todo("単発", life), repeatRule: U.daily(), replacingSingle: id))
    }

    @Test func closedBeforeTodayIsRejectedAndNothingChanges() async throws {
        let (s, id, life) = try await table.make(.before)
        let before = s.snapshot
        await #expect(throws: ScheduleRuleError.pastDay) { try await toSeries(s, id, life) }
        #expect(s.snapshot.todoEntities == before.todoEntities)
        #expect(s.snapshot.actualTasks == before.actualTasks, "単発と実績のつながりはそのまま")
        #expect(s.snapshot.versions == before.versions && s.snapshot.templateIds == before.templateIds, "系列を作った分も取り消す")
    }

    @Test func carriedSingleMovesTapsToTodaysOccurrence() async throws {
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 10), content: U.todo("単発", life, target: 3)))
        let id = U.singleId(source, "単発")
        clock.now = S1.date(10, 11, 9)
        try await source.applyCheckIn(U.tap(.single(id: id), at: S1.date(10, 11, 9), category: life))
        clock.now = S1.date(10, 13, 9)
        try await toSeries(source, id, life)
        let record = try #require(source.snapshot.actualTasks.first)
        #expect(record.templateId == S1.series(source, "単発") && record.occurrenceDate == S1.date(10, 13))
        #expect(source.snapshot.taps.count == 1)
        #expect(source.snapshot.todoEntities.isEmpty)
    }

    @Test func closedTodayPasses() async throws {
        let (s, id, life) = try await table.make(.today)
        try await toSeries(s, id, life)
        #expect(s.snapshot.actualTasks.first?.occurrenceDate == S1.date(10, 13))
        #expect(s.snapshot.todoEntities.isEmpty)
    }

    @Test func pastTimedSingleIsRejected() async throws {
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 10), content: S1.content("通院", life, 600, 60)))
        let id = U.singleId(source, "通院")
        clock.now = S1.date(10, 13, 9)
        await #expect(throws: ScheduleRuleError.pastDay) {
            try await source.apply(.createSeries(date: S1.date(10, 13), content: S1.content("通院", life, 600, 60),
                                                 repeatRule: U.daily(), replacingSingle: id))
        }
        #expect(source.snapshot.scheduledTasks.contains { $0.id == id })
    }
}

// MARK: - SQL との突き合わせで揃えた点 (2026-10-14)

@MainActor
struct UntimedSQLAlignmentTests {
    @Test func fetchReturnsOnlyUntimedOccurrenceRecords() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        let gym = S2.row(try await S1.build(source, S1.date(10, 13)), "ジム")
        try await source.applyCheckIn(S2.done(gym))
        try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("水", life), repeatRule: U.daily(), replacingSingle: nil))
        let water = S1.series(source, "水")
        try await source.applyCheckIn(U.tap(.occurrence(templateId: water, date: S1.date(10, 13)), at: S1.date(10, 13, 9), category: life))
        let fetch = try await source.loadTodos(date: S1.date(10, 13))
        #expect(fetch.actuals.map(\.templateId) == [water], "時刻つきの回 (ジム) の実績は返さない")
    }

    @Test func targetOutOfRangeIsRejected() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        for target in [0, 100] {
            await #expect(throws: ScheduleRuleError.invalidTarget) {
                try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("x", life, target: target)))
            }
            await #expect(throws: ScheduleRuleError.invalidTarget) {
                try await source.apply(.createSeries(date: S1.date(10, 13), content: U.todo("x", life, target: target),
                                                     repeatRule: U.daily(), replacingSingle: nil))
            }
        }
        #expect(source.snapshot.todoEntities.isEmpty && !source.snapshot.versions.contains { $0.name == "x" })
    }

    @Test func switchingTimedToUntimedKeepsCreatedAt() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: S1.content("通院", life, 600, 60)))
        let id = U.singleId(source, "通院")
        #expect(source.snapshot.scheduledTasks.first { $0.id == id }?.createdAt == S1.date(10, 13, 9))
        clock.now = S1.date(10, 13, 12)
        try await source.apply(.updateSingle(id: id, date: S1.date(10, 13), content: U.todo("通院", life)))
        #expect(source.snapshot.todoEntities.first { $0.id == id }?.createdAt == S1.date(10, 13, 9))
    }
}

// MARK: - 再描画までは行を元の位置に残す (本人決定 2026-10-14)

@MainActor
struct TodoOrderPinTests {
    @Test func completingKeepsRowPositionUntilRedraw() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("A", life)))
        clock.now = S1.date(10, 13, 9, 1)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("B", life)))
        let store = ScheduleStore(dayDataSource: source, dataSource: source, calendar: U.cal, holidayChecker: S1.isHoliday)
        let today = S1.date(10, 13)
        await store.ensureLoaded(today)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["A", "B"])
        // ＋1 で A が完了しても並びは変わらない (中身だけ差し替わる)
        let a = try #require(store.todoDay(today)?.todos.first)
        let error = await store.checkIn(U.tap(a.key, at: S1.date(10, 13, 10), category: life), reloading: today)
        #expect(error == nil)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["A", "B"])
        #expect(store.todoDay(today)?.todos.first?.isDone == true)
        // 新しく現れた行は末尾に足す
        try await source.apply(.createSingle(date: today, content: U.todo("C", life)))
        await store.ensureLoaded(S1.date(10, 14))
        _ = await store.checkIn(U.tap(store.todoDay(today)!.todos[1].key, at: S1.date(10, 13, 11), category: life), reloading: today)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["A", "B", "C"])
        // 日を移って戻ると組み直す (完了の行が下)
        store.releaseTodoOrder()
        await store.ensureLoaded(S1.date(10, 14))
        await store.ensureLoaded(today)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["C", "A", "B"])
        #expect(store.pinnedTodoOrder == nil)
    }

    @Test func reloadAndRefreshReleaseOrder() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("A", life)))
        clock.now = S1.date(10, 13, 9, 1)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("B", life)))
        let store = ScheduleStore(dayDataSource: source, dataSource: source, calendar: U.cal, holidayChecker: S1.isHoliday)
        let today = S1.date(10, 13)
        await store.ensureLoaded(today)
        _ = await store.checkIn(U.tap(store.todoDay(today)!.todos[0].key, at: S1.date(10, 13, 10), category: life), reloading: today)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["A", "B"])
        // 引っ張って更新・再試行
        await store.reload(today)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["B", "A"])
        // タブを開き直す
        _ = await store.checkIn(.untap(key: store.todoDay(today)!.todos[1].key, asOf: today), reloading: today)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["B", "A"])
        await store.refresh(today)
        #expect(store.todoDay(today)?.todos.map(\.name) == ["A", "B"])
    }
}

// MARK: - 実装後レビュー (opus 2026-10-14) R1〜R12 の Swift 分

@MainActor
struct PostReviewTests {
    let cal = U.cal

    @Test func r1SaveFollowingDropsLaterOverridesOfTheOtherTiming() async throws {
        // 時刻つきの毎日の「掃除」の 10/20 を「この予定」で 10:00 → 10/15 から「これ以降」で時刻なし → 10/20 の時刻つきの O は消える
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: S1.content("掃除", life, 540, 30), repeatRule: U.daily(),
                                             replacingSingle: nil))
        let clean = S1.series(source, "掃除")
        try await source.apply(.saveOccurrence(templateId: clean, date: S1.date(10, 20), patternId: nil,
                                               content: S1.content("掃除", life, 600, 30)))
        try await source.apply(.saveFollowing(templateId: clean, date: S1.date(10, 15), content: U.todo("掃除", life),
                                              repeatRule: U.daily()))
        #expect(!source.snapshot.scheduledTasks.contains { $0.templateId == clean })
        #expect(!(try await S1.build(source, S1.date(10, 20))).scheduled.contains { $0.task.name == "掃除" })
        #expect(U.rows(try await U.todoDay(source, S1.date(10, 20)), "掃除").map(\.origin) == [.series])
        // 逆向き: 時刻なしの O(d) は時刻ありへの「これ以降」で消える。時刻の有無が同じ O は残る
        try await source.apply(.saveOccurrence(templateId: clean, date: S1.date(10, 22), patternId: nil, content: U.todo("大掃除", life, target: 3)))
        try await source.apply(.saveOccurrence(templateId: clean, date: S1.date(10, 24), patternId: nil, content: U.todo("小掃除", life)))
        try await source.apply(.saveFollowing(templateId: clean, date: S1.date(10, 23), content: U.todo("掃除", life, target: 2),
                                              repeatRule: U.daily()))
        #expect(source.snapshot.todoEntities.map(\.name).sorted() == ["大掃除", "小掃除"], "時刻の有無が同じなら残す")
        try await source.apply(.saveFollowing(templateId: clean, date: S1.date(10, 21), content: S1.content("掃除", life, 540, 30),
                                              repeatRule: U.daily()))
        #expect(source.snapshot.todoEntities.isEmpty)
    }

    @Test func r1DropsSkippedAndKeepsDoneOfRemovedOverrides() throws {
        // pure 規則 (static apply): D より後の O(d) の記録 (テストのために直接置く)。スキップは消え、
        // やったはつながりを保ったまま新しい世代の回に付く (系列＋回の日でつながる。SQL と同じ)
        let clock = U.Clock(S1.date(10, 13, 9))
        var state = U.source(clock).snapshot
        let life = UUID(), t = UUID()
        state.categories.append(Category(id: life, name: "生活", subInputKind: nil))
        state.templateIds.insert(t)
        state.versions.append(TaskTemplateVersion(id: UUID(), templateId: t, effectiveFrom: S1.date(10, 1), isEnded: false, name: "掃除",
                                                  categoryId: life, startMinutesFromMidnight: 540, durationMinutes: 30, rrule: "FREQ=DAILY"))
        state.scheduledTasks.append(ScheduledTask(id: UUID(), name: "掃除", categoryId: life, startAt: S1.date(10, 20, 10),
                                                  endAt: S1.date(10, 20, 10, 30), templateId: t, patternId: nil))
        state.scheduledTasks.append(ScheduledTask(id: UUID(), name: "掃除", categoryId: life, startAt: S1.date(10, 21, 10),
                                                  endAt: S1.date(10, 21, 10, 30), templateId: t, patternId: nil))
        let skipped = ActualTask(id: UUID(), name: "掃除", categoryId: life, startAt: nil, endAt: nil, status: .skipped, templateId: t,
                                 occurrenceDate: S1.date(10, 20))
        let done = ActualTask(id: UUID(), name: "掃除", categoryId: life, startAt: S1.date(10, 21, 10), endAt: S1.date(10, 21, 10, 30),
                              templateId: t, occurrenceDate: S1.date(10, 21))
        state.actualTasks = [skipped, done]
        try InMemoryScheduleDataSource.apply(.saveFollowing(templateId: t, date: S1.date(10, 15), content: U.todo("掃除", life),
                                                            repeatRule: U.daily()), to: &state, today: S1.date(10, 13), calendar: cal)
        #expect(state.scheduledTasks.isEmpty)
        #expect(state.actualTasks.map(\.id) == [done.id])
        #expect(state.actualTasks.first?.templateId == t && state.actualTasks.first?.occurrenceDate == S1.date(10, 21))
    }

    @Test func r3DayShowsBeforeTodosArrive() async throws {
        let source = S1.source()
        let todos = GatedTodoSource(inner: source)
        let store = ScheduleStore(dayDataSource: source, dataSource: source, todoDataSource: todos, calendar: cal, holidayChecker: S1.isHoliday)
        let loading = Task { await store.ensureLoaded(S1.date(9, 30)) }
        for _ in 0..<1000 where store.day(S1.date(9, 30)) == nil { await Task.yield() }
        #expect(store.day(S1.date(9, 30)) != nil, "時刻つきの一覧は todo_fetch を待たない")
        #expect(store.todoDay(S1.date(9, 30)) == nil)
        for _ in 0..<1000 where todos.pending == 0 { await Task.yield() }
        todos.release()
        await loading.value
        #expect(store.todoDay(S1.date(9, 30)) != nil)
    }

    @Test func r4TodoFailureDropsStaleTodosAndShowsError() async throws {
        let source = S1.source()
        let todos = ToggleableTodoSource(inner: source)
        let store = ScheduleStore(dayDataSource: source, dataSource: source, todoDataSource: todos, calendar: cal, holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(9, 30))
        #expect(store.todoDay(S1.date(9, 30)) != nil)
        todos.fails = true
        await store.reload(S1.date(9, 30))
        #expect(store.todoDay(S1.date(9, 30)) == nil, "古いやることを残さない")
        #expect(store.todoErrors[S1.date(9, 30)] != nil)
        #expect(store.day(S1.date(9, 30)) != nil)
    }

    @Test func r4TimedOverrideSettlesOnDayLoadEvenIfTodoFails() async throws {
        let source = S1.source()
        let todos = ToggleableTodoSource(inner: source)
        todos.fails = true
        let store = ScheduleStore(dayDataSource: source, dataSource: source, todoDataSource: todos, calendar: cal, holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(9, 30))
        let gym = S2.row(try #require(store.day(S1.date(9, 30))), "ジム")
        _ = await store.checkIn(S2.done(gym), reloading: S1.date(9, 30))
        #expect(store.overrides.isEmpty, "時刻つきの上書きは日の読み込みの成功で外す")
    }

    @Test func r5SameTapIdIsCountedOnce() async throws {
        // 読み込んだタップに同じ id があれば、足した分からは数えない
        let id = UUID()
        var adjustment = TapAdjustment()
        adjustment = TapAdjustment.applying(.tap(key: .single(id: UUID()), name: "x", categoryId: UUID(), at: S1.date(10, 13, 9),
                                                 plannedStart: nil, plannedEnd: nil, tapId: id), to: adjustment, taps: [], calendar: cal)
        let loaded = [ActualTaskTap(id: id, actualTaskId: UUID(), tappedAt: S1.date(10, 13, 9))]
        #expect(adjustment.times([]).count == 1)
        #expect(adjustment.times(loaded).count == 1)
        // InMemory: 同じ id を 2 回送っても 1 回
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("x", life, target: 3)))
        let op = CheckInOperation.tap(key: .single(id: U.singleId(source, "x")), name: "x", categoryId: life, at: S1.date(10, 13, 9),
                                      plannedStart: nil, plannedEnd: nil, tapId: id)
        try await source.applyCheckIn(op)
        try await source.applyCheckIn(op)
        #expect(source.snapshot.taps.map(\.id) == [id])
        #expect(ScheduleRPC.call(for: op, calendar: cal).params.values["p_tap_id"] == .string(id.uuidString))
    }

    @Test func r7SkipOfUnrecordedOccurrenceIsOptimistic() {
        let key = CheckInKey.occurrence(templateId: UUID(), date: S1.date(10, 13))
        var adjustment = TapAdjustment()
        adjustment = TapAdjustment.applying(.skipCounted(key: key, name: "水", categoryId: UUID(), on: S1.date(10, 13)), to: adjustment,
                                            taps: [], calendar: cal)
        let record = CountProgress.adjusted(record: nil, adjustment: adjustment, tapCount: 0, key: key, name: "水", categoryId: UUID())
        #expect(record?.status == .skipped && record?.skippedOn == S1.date(10, 13))
        let todo = DayTodo(key: key, name: "水", categoryId: UUID(), target: 8, occurrenceDate: S1.date(10, 13), origin: .series,
                           patternId: nil, record: nil, taps: [], count: 0, closedOn: nil, isSkipped: false, sortDate: S1.date(10, 1))
        let adjusted = todo.adjusted(by: adjustment, asOf: S1.date(10, 13), calendar: cal)
        #expect(adjusted.isSkipped && adjusted.isSkipRecorded)
    }

    @Test func r10PostgrestMessagesMapToRuleErrors() {
        func schedule(_ message: String, code: String? = nil) -> ScheduleRuleError? {
            RuleErrorMapping.schedule(PostgrestError(code: code, message: message))
        }
        #expect(schedule("past day is not editable: 2026-10-12") == .pastDay)
        #expect(schedule("timed single needs today or later: 2026-10-10") == .pastDay)
        #expect(schedule("closed single cannot change its date: x") == .closedSingleDate)
        #expect(schedule("single task not found: x") == .notFound)
        #expect(schedule("series needs weekdays or holiday") == .noRepeat)
        #expect(schedule("occurrence cannot change timed/untimed (use save_following)") == .timingMismatch)
        #expect(schedule("new row for relation \"scheduled_task\" violates check constraint \"scheduled_task_target_chk\"", code: "23514")
                == .invalidTarget)
        #expect(schedule("update or delete on table \"task_template\" violates foreign key constraint", code: "23503") == .referencedByPast)
        #expect(schedule("something else") == nil)

        let key = CheckInKey.single(id: UUID())
        let now = S1.date(10, 13, 9)
        func checkIn(_ message: String, _ op: CheckInOperation = .unskipCounted(key: key)) -> CheckInRuleError? {
            RuleErrorMapping.checkIn(PostgrestError(message: message), operation: op, now: now, calendar: cal)
        }
        #expect(checkIn("future occurrence cannot be recorded: 2026-10-14") == .futureDay)
        #expect(checkIn("future occurrence cannot be checked in: 2026-10-14") == .futureDay)
        #expect(checkIn("sleep is recorded in sleep_record") == .sleepIsSeparate)
        #expect(checkIn("done needs start and end (end > start)") == .invalidTime)
        #expect(checkIn("skipped occurrence cannot be tapped (clear the skip first)") == .skippedOccurrence)
        #expect(checkIn("timed occurrence with target 1 uses checkin_set / checkin_clear") == .notCounted)
        #expect(checkIn("occurrence not found: a b c") == .notFound)
        let future = CheckInOperation.tap(key: key, name: "x", categoryId: UUID(), at: S1.date(10, 14, 9), plannedStart: nil, plannedEnd: nil)
        let early = CheckInOperation.skipCounted(key: key, name: "x", categoryId: UUID(), on: S1.date(10, 9))
        #expect(checkIn("tap must be between the occurrence day and today: x", future) == .futureDay)
        #expect(checkIn("skip day must be between the occurrence day and today: x", early) == .beforeOccurrence)
    }

    @Test func r11LaterCountedOperationsAreDroppedAfterFailure() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let inner = U.source(clock)
        let life = try await U.life(inner)
        try await inner.apply(.createSingle(date: S1.date(10, 13), content: U.todo("x", life, target: 5)))
        let key = CheckInKey.single(id: U.singleId(inner, "x"))
        let source = FailFirstCheckInSource(inner: inner)
        let store = ScheduleStore(dayDataSource: source, dataSource: source, todoDataSource: inner, calendar: cal, holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(10, 13))
        let first = Task { await store.checkIn(U.tap(key, at: S1.date(10, 13, 9), category: life), reloading: S1.date(10, 13)) }
        for _ in 0..<1000 where source.pending == 0 { await Task.yield() }
        let second = Task { await store.checkIn(U.tap(key, at: S1.date(10, 13, 9, 1), category: life), reloading: S1.date(10, 13)) }
        for _ in 0..<1000 where store.todoDay(S1.date(10, 13))?.todos.first?.count != 2 { await Task.yield() }
        #expect(store.todoDay(S1.date(10, 13))?.todos.first?.count == 2)
        source.release()
        let (e1, e2) = await (first.value, second.value)
        #expect(e1 != nil && e2 != nil)
        #expect(source.calls == 1, "2 回目は送らない")
        #expect(inner.snapshot.taps.isEmpty)
        #expect(store.todoDay(S1.date(10, 13))?.todos.first?.count == 0, "楽観の分も戻る")
        #expect(store.tapAdjustments.isEmpty)
    }

    @Test func r12TimedUntapRemovesLatestOfAllTaps() async throws {
        // 日をまたぐ時刻つきの回: 回の日 10/14 に 1 回、翌日 10/15 に 1 回 → 今日 (10/15) の時点で − は 10/15 のタップを消す
        let clock = U.Clock(S1.date(10, 14, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 14),
                                             content: ScheduleContent(name: "夜勉強", categoryId: life, startMinutes: 1380, durationMinutes: 120,
                                                                      targetCount: 3),
                                             repeatRule: U.daily(), replacingSingle: nil))
        let row = S2.row(try await S1.build(source, S1.date(10, 14)), "夜勉強")
        let key = CheckInKey.of(row, calendar: cal)
        func tap(_ at: Date) -> CheckInOperation {
            .tap(key: key, name: "夜勉強", categoryId: life, at: at, plannedStart: row.task.startAt, plannedEnd: row.task.endAt)
        }
        try await source.applyCheckIn(tap(S1.date(10, 14, 23, 30)))
        clock.now = S1.date(10, 15, 9)
        try await source.applyCheckIn(tap(S1.date(10, 15, 0, 30)))
        try await source.applyCheckIn(.untap(key: key, asOf: clock.now))
        #expect(source.snapshot.taps.map(\.tappedAt) == [S1.date(10, 14, 23, 30)])
        // 楽観更新も同じ (asOf = 今日)
        let taps = [ActualTaskTap(id: UUID(), actualTaskId: UUID(), tappedAt: S1.date(10, 14, 23, 30)),
                    ActualTaskTap(id: UUID(), actualTaskId: UUID(), tappedAt: S1.date(10, 15, 0, 30))]
        let adjustment = TapAdjustment.applying(.untap(key: key, asOf: S1.date(10, 15, 9)), to: TapAdjustment(), taps: taps, calendar: cal)
        #expect(adjustment.removed == [taps[1].id])
    }
}

/// 回数の丸の枠の輪 (2026-10-14 本人「回数設定されているものは、画像のようにチェックの丸の枠に進捗表示もさせたい」「リングを区切らないで」)
@MainActor
struct ProgressRingTests {
    @Test func fractionIsCountOverTarget() {
        #expect(ProgressRing.fraction(count: 0, target: 3) == 0)
        #expect(abs(ProgressRing.fraction(count: 1, target: 3) - 1.0 / 3) < 1e-9)
        #expect(ProgressRing.fraction(count: 3, target: 3) == 1)
        #expect(abs(ProgressRing.fraction(count: 7, target: 99) - 7.0 / 99) < 1e-9)
    }

    @Test func fractionStaysWithinOneTurn() {
        #expect(ProgressRing.fraction(count: 5, target: 3) == 1)
        #expect(ProgressRing.fraction(count: -1, target: 3) == 0)
        #expect(ProgressRing.fraction(count: 1, target: 0) == 0)
    }
}

// MARK: - 行の長押しのメニュー

/// 2026-10-14 本人「行の長押しでメニューを出して欲しい。メニューに表示させる処理は既存のものだけ。
/// やったことにする（回数のあるものはインクリメント）、やってないことにする（回数のあるものはデクリメント）、スキップ、削除」
/// 同日「完了しているものに対して完了にする というメニューは不要。逆も然り。」
@MainActor
struct RowMenuTests {
    let cal = U.cal

    /// 時刻つきで目標 1: 丸・スワイプと同じ操作。使えない項目は出さない (nil)
    @Test func timedTargetOneMenuMatchesCircleAndSwipe() async throws {
        let source = S1.source()
        let day = try await S1.build(source, S1.date(9, 30))
        let gym = S2.row(day, "ジム")
        let key = CheckInKey.of(gym, calendar: S2.cal)
        let at = S1.date(9, 30, 9)
        func menu(_ state: CheckInState, _ style: CheckInCircleStyle?) -> CheckInMenu {
            CheckInPlanner.menu(row: gym, state: state, style: style, calendar: S2.cal, tapAt: at, now: at, skipOn: S1.date(9, 30))
        }
        let none = menu(.none, .empty)
        #expect(none.done == .askActualTime, "記録なし → 丸と同じく実績の時刻のシート")
        #expect(none.undone == nil && !none.isSkipped && !none.isCounted, "記録なしに完了を取り消すは出さない")
        #expect(none.skip == CheckInPlanner.skip(row: gym, state: .none, calendar: S2.cal, skipOn: S1.date(9, 30)), "左スワイプと同じ")
        try await S2.apply(source, S2.done(gym))
        let doneState = S2.state(source, try await S1.build(source, S1.date(9, 30)), gym)
        let done = menu(doneState, .done)
        #expect(done.done == nil, "済みの回に完了にするは出さない")
        #expect(done.undone == .clear(key: key) && done.skip != nil)
        let record = ActualTask(id: UUID(), name: "ジム", categoryId: gym.task.categoryId, startAt: nil, endAt: nil, status: .skipped,
                                templateId: gym.task.templateId, occurrenceDate: S1.date(9, 30), scheduledTaskId: nil)
        let skipped = menu(.skipped(record), .skipped)
        #expect(skipped.done == nil && skipped.undone == nil, "スキップした回は取り消しだけ")
        #expect(skipped.skip == .clear(key: key) && skipped.isSkipped)
        // 丸を出さない回 (未来の回・睡眠) とセットのあるジムは何も出さない
        let workout = CheckInState.workout(first: S1.date(9, 30, 7), last: S1.date(9, 30, 8), count: 3)
        let blank: [(CheckInState, CheckInCircleStyle?)] = [(.none, nil), (.none, .hidden), (workout, .fixedDone)]
        for (state, style) in blank {
            let m = menu(state, style)
            #expect(m.done == nil && m.undone == nil && m.skip == nil)
        }
    }

    /// 時刻つきで目標 3: 1回追加 = +1 (目標に届いたら出さない)、1回取り消す = −1 (0 回は出さない)、スキップした回は取り消しだけ
    @Test func timedCountedMenuIncrementsAndDecrements() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 13), content: ScheduleContent(name: "水やり", categoryId: life, startMinutes: 600, durationMinutes: 30, targetCount: 3),
                                             repeatRule: U.daily(), replacingSingle: nil))
        let category = source.snapshot.categories.first { $0.id == life }
        func current() async throws -> (CheckInState, CheckInMenu, DayScheduledTask) {
            let day = try await S1.build(source, S1.date(10, 13))
            let row = S2.row(day, "水やり")
            let state = CheckInPlanner.state(for: row, records: day.records, overrides: [:], category: category,
                                             workoutSetTimes: [], calendar: cal, taps: day.taps, adjustments: [:])
            let style = CheckInPlanner.circleStyle(row: row, state: state, category: category, today: clock.now, calendar: cal)
            let menu = CheckInPlanner.menu(row: row, state: state, style: style, calendar: cal, tapAt: clock.now, now: clock.now,
                                           skipOn: S1.date(10, 13))
            return (state, menu, row)
        }
        var (state, menu, row) = try await current()
        #expect(state == .progress(count: 0, target: 3, record: nil))
        #expect(menu.isCounted && menu.undone == nil, "0 回は 1回取り消すを出さない")
        for minute in [0, 10, 20] {
            clock.now = S1.date(10, 13, 9, minute)
            (_, menu, _) = try await current()
            guard case .apply(let op)? = menu.done, case .tap = op else { Issue.record("+1 にならない"); return }
            try await source.applyCheckIn(op)
        }
        (state, menu, row) = try await current()
        guard case .progress(3, 3, _) = state else { Issue.record("3/3 にならない"); return }
        #expect(menu.done == nil, "目標に届いた回は 1回追加を出さない")
        // 丸は目標を超えても数える (4/3)。超えていても 1回追加は出さず、1回取り消すは出す
        clock.now = S1.date(10, 13, 9, 30)
        guard case .apply(let circle)? = CheckInPlanner.circleTap(row: row, state: state, calendar: cal, tapAt: clock.now) else {
            Issue.record("丸が +1 にならない"); return
        }
        try await source.applyCheckIn(circle)
        (state, menu, row) = try await current()
        guard case .progress(4, 3, _) = state else { Issue.record("丸で 4/3 にならない"); return }
        #expect(menu.done == nil)
        try await source.applyCheckIn(try #require(menu.undone))
        (_, menu, _) = try await current()
        try await source.applyCheckIn(try #require(menu.undone))
        (state, menu, row) = try await current()
        guard case .progress(2, 3, _) = state else { Issue.record("−1 を 2 回で 2/3 にならない"); return }
        #expect(menu.done != nil && menu.undone != nil, "途中の回は両方出す")
        let skip = try #require(menu.skip)
        try await source.applyCheckIn(skip)
        (state, menu, row) = try await current()
        #expect(state.isSkipped && menu.isSkipped)
        #expect(menu.done == nil && menu.undone == nil)
        #expect(menu.skip == .unskipCounted(key: CheckInKey.of(row, calendar: cal)))
    }

    /// やること (目標 1・目標 3): 丸・スワイプと同じ操作。完了した回に完了の項目、0 回に取り消しの項目は出さない
    @Test func todoMenuMatchesCircleAndSwipe() async throws {
        let clock = U.Clock(S1.date(10, 13, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("買い物", life)))
        try await source.apply(.createSingle(date: S1.date(10, 13), content: U.todo("腕立て", life, target: 3)))
        func todo(_ name: String) async throws -> DayTodo {
            let day = try await U.todoDay(source, S1.date(10, 13))
            return try #require(U.rows(day, name).first)
        }
        func menu(_ name: String) async throws -> CheckInMenu {
            CheckInPlanner.menu(todo: try await todo(name), viewDay: S1.date(10, 13), tapAt: clock.now)
        }
        // 目標 1: 完了にする → (済み) 完了を取り消す
        var m = try await menu("買い物")
        #expect(m.undone == nil && !m.isSkipped && !m.isCounted)
        guard case .apply(let tap)? = m.done else { Issue.record("完了にするが無い"); return }
        try await source.applyCheckIn(tap)
        let shopping = try await todo("買い物")
        #expect(shopping.isDone)
        m = try await menu("買い物")
        #expect(m.done == nil, "目標 1 で済みなら出さない")
        try await source.applyCheckIn(try #require(m.undone))
        let undone = try await todo("買い物")
        #expect(undone.count == 0 && !undone.isDone)
        // 目標 3: 届くまで +1、届いたら 1回追加を出さない、−1 で 1 つ戻ると また出る
        let counted = try await menu("腕立て")
        #expect(counted.isCounted)
        for _ in 0..<3 {
            let next = try await menu("腕立て")
            guard case .apply(let op)? = next.done else { Issue.record("+1 にならない"); return }
            try await source.applyCheckIn(op)
        }
        let three = try await todo("腕立て")
        #expect(three.count == 3)
        m = try await menu("腕立て")
        #expect(m.done == nil, "目標に届いた回は 1回追加を出さない")
        try await source.applyCheckIn(try #require(m.undone))
        let two = try await todo("腕立て")
        #expect(two.count == 2)
        let reopened = try await menu("腕立て")
        #expect(reopened.done != nil, "目標を下回ったら 1回追加が また出る")
        // スキップ → 取り消しだけ → 取り消すとタップが残っているので 2 回に戻る
        try await source.applyCheckIn(try #require(try await menu("腕立て").skip))
        let skippedTodo = try await todo("腕立て")
        #expect(skippedTodo.isSkipRecorded)
        m = try await menu("腕立て")
        #expect(m.isSkipped && m.done == nil && m.undone == nil)
        #expect(m.skip == .unskipCounted(key: skippedTodo.key))
        try await source.applyCheckIn(try #require(m.skip))
        let back = try await todo("腕立て")
        #expect(!back.isSkipRecorded && back.count == 2)
    }
}

/// loadTodos を止めておける (時刻つきの一覧が先に出る確認用)
final class GatedTodoSource: TodoDataSource, @unchecked Sendable {
    let inner: InMemoryScheduleDataSource
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(inner: InMemoryScheduleDataSource) { self.inner = inner }
    var pending: Int { lock.withLock { waiters.count } }
    func release() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        released.forEach { $0.resume() }
    }
    func loadTodos(date: Date) async throws -> TodoFetch {
        await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
        return try await inner.loadTodos(date: date)
    }
}

/// loadTodos の失敗を切り替えられる
final class ToggleableTodoSource: TodoDataSource, @unchecked Sendable {
    let inner: InMemoryScheduleDataSource
    var fails = false
    init(inner: InMemoryScheduleDataSource) { self.inner = inner }
    func loadTodos(date: Date) async throws -> TodoFetch {
        if fails { throw ThrowingTodoSource.Failure() }
        return try await inner.loadTodos(date: date)
    }
}

/// 最初の実績の書き込みを止めておき、離したら失敗させる (後に並んだ回数の操作を送らない確認用)
final class FailFirstCheckInSource: DayDataSource, ScheduleDataSource, @unchecked Sendable {
    struct Failure: Error {}
    let inner: InMemoryScheduleDataSource
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    init(inner: InMemoryScheduleDataSource) { self.inner = inner }
    var pending: Int { lock.withLock { waiters.count } }
    var calls: Int { lock.withLock { count } }
    func release() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        released.forEach { $0.resume() }
    }
    func loadDayContext(date: Date) async throws -> DayBuilderContext { try await inner.loadDayContext(date: date) }
    func fetchCatalog() async throws -> ScheduleCatalog { try await inner.fetchCatalog() }
    func apply(_ operation: ScheduleOperation) async throws { try await inner.apply(operation) }
    func createCategory(name: String) async throws -> LifeTracker.Category { try await inner.createCategory(name: name) }
    func ensureUserDefaults() async throws { try await inner.ensureUserDefaults() }
    func applyCheckIn(_ operation: CheckInOperation) async throws {
        let first = lock.withLock { () -> Bool in
            count += 1
            return count == 1
        }
        if first {
            await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
            throw Failure()
        }
        try await inner.applyCheckIn(operation)
    }
}

// MARK: - 削除の出し分け (2026-10-15 本人決定 1〜3。docs/day-cycle-walkthrough.md「消せる行と消せない行の区別」)

@MainActor
struct DeleteAvailabilityTests {
    let cal = U.cal

    /// 「水」(時刻なし・毎日・目標 3・繰り越し) を 10/10 から。今日 = 10/13 9:00。10/11 の回は 10/12 に 1 回押してある
    func make() async throws -> (InMemoryScheduleDataSource, U.Clock, UUID, UUID) {
        let clock = U.Clock(S1.date(10, 10, 9))
        let source = U.source(clock)
        let life = try await U.life(source)
        try await source.apply(.createSeries(date: S1.date(10, 10), content: U.todo("水", life, target: 3),
                                             repeatRule: U.daily(carry: true), replacingSingle: nil))
        let water = S1.series(source, "水")
        clock.now = S1.date(10, 12, 9)
        try await source.applyCheckIn(U.tap(.occurrence(templateId: water, date: S1.date(10, 11)), at: S1.date(10, 12, 9), category: life))
        clock.now = S1.date(10, 13, 9)
        return (source, clock, water, life)
    }

    @Test func carriedOccurrenceDeletesOnlyThatDayAndKeepsTaps() async throws {
        let (source, _, water, _) = try await make()
        try await source.apply(.deleteOccurrence(templateId: water, date: S1.date(10, 11)))
        #expect(source.snapshot.exdates.contains { $0.templateId == water && $0.date == S1.date(10, 11) })
        // 消した回は今日にも元の日にも出ない。他の繰り越しの回 (10/10) と今日の回は残る (10/12 は祝日で回が無い)
        let todayRows = U.rows(try await U.todoDay(source, S1.date(10, 13)), "水")
        #expect(todayRows.map(\.occurrenceDate) == [S1.date(10, 10), S1.date(10, 13)])
        let originRows = U.rows(try await U.todoDay(source, S1.date(10, 11)), "水")
        #expect(originRows.map(\.occurrenceDate) == [S1.date(10, 10)])
        // 記録 (やった・タップ) は残る (単発の削除と同じ。見えない記録)
        let record = source.snapshot.actualTasks.first { $0.templateId == water && $0.occurrenceDate == S1.date(10, 11) }
        #expect(record?.status == .done && source.snapshot.taps.contains { $0.actualTaskId == record?.id })
    }

    @Test func pastOccurrenceIsRejectedUnlessOpenCarried() async throws {
        let (source, clock, water, life) = try await make()
        // 繰り越しオフの系列・時刻つきの系列の過去の回は今まで通り消せない
        clock.now = S1.date(10, 10, 9)
        try await source.apply(.createSeries(date: S1.date(10, 10), content: U.todo("掃除", life), repeatRule: U.daily(),
                                             replacingSingle: nil))
        try await source.apply(.createSeries(date: S1.date(10, 10), content: S1.content("散歩", life, 420, 30), repeatRule: U.daily(),
                                             replacingSingle: nil))
        // 10/10 の「水」を 10/11 に目標まで押して閉じる (今日より前に閉じた回)
        clock.now = S1.date(10, 11, 9)
        for minute in 0..<3 {
            try await source.applyCheckIn(U.tap(.occurrence(templateId: water, date: S1.date(10, 10)), at: S1.date(10, 11, 9, minute),
                                                category: life))
        }
        clock.now = S1.date(10, 13, 9)
        for (name, templateId) in [("掃除", S1.series(source, "掃除")), ("散歩", S1.series(source, "散歩")), ("閉じた水", water)] {
            let before = source.snapshot.exdates
            await #expect(throws: ScheduleRuleError.pastDay, "\(name)") {
                try await source.apply(.deleteOccurrence(templateId: templateId, date: name == "閉じた水" ? S1.date(10, 10) : S1.date(10, 11)))
            }
            #expect(source.snapshot.exdates == before)
        }
        // 今日スキップした繰り越しの回は今日閉じた回 = まだ消せる
        try await source.applyCheckIn(.skipCounted(key: .occurrence(templateId: water, date: S1.date(10, 11)), name: "水", categoryId: life,
                                                   on: S1.date(10, 13)))
        try await source.apply(.deleteOccurrence(templateId: water, date: S1.date(10, 11)))
        #expect(!source.snapshot.actualTasks.contains { $0.templateId == water && $0.occurrenceDate == S1.date(10, 11) },
                "スキップの記録は消える (今日の回の削除と同じ)")
    }

    @Test func todoTargetOffersDeleteForCarriedOccurrenceOnly() async throws {
        let (source, clock, water, life) = try await make()
        clock.now = S1.date(10, 11, 9)
        try await source.apply(.createSingle(date: S1.date(10, 11), content: U.todo("書類", life)))
        clock.now = S1.date(10, 13, 9)
        let catalog = try await source.fetchCatalog()
        let today = S1.date(10, 13, 9)
        func opened(_ view: Date, _ date: Date) async throws -> (target: ScheduleEditTarget, canEditPlan: Bool, canDelete: Bool) {
            let todos = try await U.todoDay(source, view).todos
            let todo = try #require(todos.first { $0.templateId == water && $0.occurrenceDate == date })
            return SchedulePlanner.todoTarget(for: todo, viewDay: view, today: today, catalog: catalog, calendar: cal)
        }
        // 今日の一覧の繰り越し中の回: 予定は読むだけ・消せる・その回だけ (確認なし)
        let carried = try await opened(S1.date(10, 13), S1.date(10, 11))
        #expect(!carried.canEditPlan && carried.canDelete && carried.target.isCarried)
        #expect(SchedulePlanner.delete(target: carried.target) == .apply(.deleteOccurrence(templateId: water, date: S1.date(10, 11))))
        // 今日の回: 編集できる・消せる・この予定／これ以降
        let current = try await opened(S1.date(10, 13), S1.date(10, 13))
        #expect(current.canEditPlan && current.canDelete && !current.target.isCarried)
        #expect(SchedulePlanner.delete(target: current.target)
                == .chooseScope(this: .deleteOccurrence(templateId: water, date: S1.date(10, 13)),
                                following: .deleteFollowing(templateId: water, date: S1.date(10, 13))))
        // 明日の一覧の繰り越し中の回 (回の日 < 今日) も消せる
        let tomorrow = try await opened(S1.date(10, 14), S1.date(10, 11))
        #expect(tomorrow.canDelete)
        // 過去の日の一覧: 同じ回も、繰り越し中の単発も消せない (決定 3)
        let past = try await opened(S1.date(10, 11), S1.date(10, 11))
        #expect(!past.canEditPlan && !past.canDelete && !past.target.isCarried)
        let pastTodos = try await U.todoDay(source, S1.date(10, 12)).todos
        let paper = try #require(pastTodos.first { $0.name == "書類" })
        #expect(!SchedulePlanner.todoTarget(for: paper, viewDay: S1.date(10, 12), today: today, catalog: catalog, calendar: cal).canDelete)
        let todayTodos = try await U.todoDay(source, S1.date(10, 13)).todos
        let paperToday = try #require(todayTodos.first { $0.name == "書類" })
        #expect(SchedulePlanner.todoTarget(for: paperToday, viewDay: S1.date(10, 13), today: today, catalog: catalog, calendar: cal).canDelete)
    }

    @Test func blockedReasonTexts() {
        let today = S1.date(10, 15, 9)
        // 過去の日は一つ (前日から続く行でも同じ)
        #expect(SchedulePlanner.deleteBlockedReason(viewDay: S1.date(10, 13), spilloverFrom: nil, today: today, calendar: cal)
                == "過去の日の予定は変えられません")
        #expect(SchedulePlanner.deleteBlockedReason(viewDay: S1.date(10, 13), spilloverFrom: S1.date(10, 12, 23), today: today, calendar: cal)
                == "過去の日の予定は変えられません")
        // 今日の一覧の前日から続く行
        #expect(SchedulePlanner.deleteBlockedReason(viewDay: S1.date(10, 15), spilloverFrom: S1.date(10, 14, 23), today: today, calendar: cal)
                == "10/14 の予定です。前の日の予定は変えられません")
        // 明日の一覧の、今日から続く行
        #expect(SchedulePlanner.deleteBlockedReason(viewDay: S1.date(10, 16), spilloverFrom: S1.date(10, 15, 23), today: today, calendar: cal)
                == "10/15 の予定です。前の日の予定はここからは消せません")
        // 今日以降の、前日から続かない行は理由を出さない
        #expect(SchedulePlanner.deleteBlockedReason(viewDay: S1.date(10, 15), spilloverFrom: nil, today: today, calendar: cal) == nil)
    }
}
