import Foundation
import Testing
@testable import LifeTracker

// 段階 2 (チェックイン＝予実の記録) の単体テスト。docs/day-cycle-walkthrough.md「段階 2 確定仕様」の完了条件と
// レビュー docs/day-cycle-review-2026-09-30-stage2.md §10 の追加項目。
// 日付は S1 と同じ (2026 年 JST。今日 = 9/30(水) 10:00。10/12(月) は祝日)。睡眠 = 毎日 23:00〜8h、ジム = 平日 6:45〜45 分

@MainActor
enum S2 {
    static var cal: Calendar { S1.calendar }

    static func category(_ source: InMemoryScheduleDataSource, _ name: String) -> LifeTracker.Category {
        source.snapshot.categories.first { $0.name == name }!
    }

    /// その日の一覧の行 (名前で。前日から続く行は spillover: true)
    static func row(_ day: Day, _ name: String, spillover: Bool = false) -> DayScheduledTask {
        day.scheduled.first { $0.task.name == name && $0.isSpillover == spillover }!
    }

    static func state(_ source: InMemoryScheduleDataSource, _ day: Day, _ row: DayScheduledTask) -> CheckInState {
        CheckInPlanner.state(for: row, records: day.records, overrides: [:],
                             category: source.snapshot.categories.first { $0.id == row.task.categoryId },
                             workoutSetTimes: CheckInPlanner.workoutSets(for: row, day: day, calendar: cal), calendar: cal)
    }

    static func apply(_ source: InMemoryScheduleDataSource, _ operation: CheckInOperation) async throws {
        try await source.applyCheckIn(operation)
    }

    static func done(_ row: DayScheduledTask, start: Date? = nil, end: Date? = nil) -> CheckInOperation {
        .set(key: CheckInKey.of(row, calendar: cal), status: .done, name: row.task.name, categoryId: row.task.categoryId,
             start: start ?? row.task.startAt, end: end ?? row.task.endAt)
    }
}

// MARK: - 回のキー (レビュー §1-5)

@MainActor
struct CheckInKeyTests {
    let cal = S2.cal

    @Test func virtualOverriddenSpilloverSingleAndHolidayKeys() async throws {
        let source = S1.source()
        let gymId = S1.series(source, "ジム"), sleepId = S1.series(source, "睡眠")
        let gym = S2.category(source, "ジム")
        // O(D): 10/1 のジムをその日だけ 8:00 に
        try await source.apply(.saveOccurrence(templateId: gymId, date: S1.date(10, 1), patternId: nil,
                                               content: S1.content("ジム", gym.id, 480, 60)))
        try await source.apply(.createSingle(date: S1.date(10, 1), content: S1.content("買い物", gym.id, 900, 60)))
        let oct1 = try await S1.build(source, S1.date(10, 1))
        let overridden = S2.row(oct1, "ジム")
        #expect(!overridden.isVirtual)
        #expect(CheckInKey.of(overridden, calendar: cal) == .occurrence(templateId: gymId, date: S1.date(10, 1)))
        // 仮想の回
        let today = try await S1.build(source, S1.date(9, 30))
        #expect(CheckInKey.of(S2.row(today, "ジム"), calendar: cal) == .occurrence(templateId: gymId, date: S1.date(9, 30)))
        // 前日から続く睡眠は前日の回
        #expect(CheckInKey.of(S2.row(today, "睡眠", spillover: true), calendar: cal) == .occurrence(templateId: sleepId, date: S1.date(9, 29)))
        #expect(CheckInKey.of(S2.row(today, "睡眠"), calendar: cal) == .occurrence(templateId: sleepId, date: S1.date(9, 30)))
        // 単発
        let single = S2.row(oct1, "買い物")
        #expect(CheckInKey.of(single, calendar: cal) == .single(id: single.task.id))
        // 祝日パターン経由の回 (10/12 の睡眠) も系列＋日
        let holiday = try await S1.build(source, S1.holiday)
        let holidaySleep = S2.row(holiday, "睡眠")
        #expect(holidaySleep.origin == .pattern)
        #expect(CheckInKey.of(holidaySleep, calendar: cal) == .occurrence(templateId: sleepId, date: S1.holiday))
    }

    @Test func actualKeyFollowsLink() {
        let t = UUID(), s = UUID()
        let linked = ActualTask(id: UUID(), name: "ジム", categoryId: UUID(), startAt: nil, endAt: nil, status: .skipped,
                                templateId: t, occurrenceDate: S1.date(9, 29))
        let single = ActualTask(id: UUID(), name: "x", categoryId: UUID(), startAt: S1.date(9, 30, 9), endAt: S1.date(9, 30, 10),
                                scheduledTaskId: s)
        let unplanned = ActualTask(id: UUID(), name: "読書", categoryId: UUID(), startAt: S1.date(9, 30, 14), endAt: S1.date(9, 30, 16))
        #expect(CheckInKey.of(linked, calendar: cal) == .occurrence(templateId: t, date: S1.date(9, 29)))
        #expect(CheckInKey.of(single, calendar: cal) == .single(id: s))
        #expect(CheckInKey.of(unplanned, calendar: cal) == nil)
        #expect(unplanned.occurrenceDate == S1.date(9, 30), "省略時の一覧に出る日は開始の JST 日")
    }
}

// MARK: - 状態遷移 (記録なし ↔ やった ↔ スキップ・時刻の修正)

@MainActor
struct CheckInTransitionTests {
    let cal = S2.cal

    @Test func noneDoneSkippedAndBack() async throws {
        let source = S1.source()
        var day = try await S1.build(source, S1.date(9, 30))
        let gym = S2.row(day, "ジム")
        #expect(S2.state(source, day, gym) == .none)

        // 丸: 記録なし → やった (予定の時刻どおり)
        try await S2.apply(source, CheckInPlanner.toggle(row: gym, state: .none, calendar: cal)!)
        day = try await S1.build(source, S1.date(9, 30))
        guard case .done(let record) = S2.state(source, day, gym) else { Issue.record("やったにならない"); return }
        #expect(record.startAt == S1.date(9, 30, 6, 45) && record.endAt == S1.date(9, 30, 7, 30))
        #expect(record.name == "ジム" && record.templateId == gym.task.templateId && record.occurrenceDate == S1.date(9, 30))
        #expect(CheckInPlanner.actualLine(row: gym, state: .done(record), category: S2.category(source, "ジム"),
                                          now: S1.today, calendar: cal) == nil, "予定どおりなら実績の行は出さない")

        // 右スワイプ: やった → スキップ (同じ行を書き換える・時刻は消える)
        try await S2.apply(source, CheckInPlanner.skip(row: gym, state: .done(record), calendar: cal)!)
        day = try await S1.build(source, S1.date(9, 30))
        guard case .skipped(let skipped) = S2.state(source, day, gym) else { Issue.record("スキップにならない"); return }
        #expect(skipped.id == record.id)
        #expect(skipped.startAt == nil && skipped.endAt == nil)
        #expect(source.snapshot.actualTasks.count == 1)

        // 丸: スキップ → 記録なし
        try await S2.apply(source, CheckInPlanner.toggle(row: gym, state: .skipped(skipped), calendar: cal)!)
        day = try await S1.build(source, S1.date(9, 30))
        #expect(S2.state(source, day, gym) == .none)
        #expect(source.snapshot.actualTasks.isEmpty)

        // 右スワイプ: 記録なし → スキップ → 取り消し
        try await S2.apply(source, CheckInPlanner.skip(row: gym, state: .none, calendar: cal)!)
        day = try await S1.build(source, S1.date(9, 30))
        let state = S2.state(source, day, gym)
        #expect(state.isSkipped)
        #expect(CheckInPlanner.skip(row: gym, state: state, calendar: cal) == .clear(key: CheckInKey.of(gym, calendar: cal)))
    }

    @Test func correctingTimesShowsActualLine() async throws {
        let source = S1.source()
        var day = try await S1.build(source, S1.date(9, 30))
        let gym = S2.row(day, "ジム")
        try await S2.apply(source, S2.done(gym))
        try await S2.apply(source, S2.done(gym, start: S1.date(9, 30, 7), end: S1.date(9, 30, 7, 40)))
        day = try await S1.build(source, S1.date(9, 30))
        let state = S2.state(source, day, gym)
        #expect(state.record?.startAt == S1.date(9, 30, 7))
        #expect(source.snapshot.actualTasks.count == 1, "1 つの回に 1 行")
        #expect(CheckInPlanner.actualLine(row: gym, state: state, category: S2.category(source, "ジム"), now: S1.today, calendar: cal)
                == "実績 7:00–7:40")
        // 取れた実績は時刻の範囲の一覧 (Day.actual) にも出る
        #expect(day.actual.map(\.task.name) == ["ジム"])
    }

    @Test func rulesRejectFutureInvalidAndSleepCategory() async throws {
        let source = S1.source()
        let tomorrow = try await S1.build(source, S1.date(10, 1))
        await #expect(throws: CheckInRuleError.futureDay) { try await S2.apply(source, S2.done(S2.row(tomorrow, "ジム"))) }
        let today = try await S1.build(source, S1.date(9, 30))
        let gym = S2.row(today, "ジム")
        await #expect(throws: CheckInRuleError.invalidTime) {
            try await S2.apply(source, S2.done(gym, start: S1.date(9, 30, 8), end: S1.date(9, 30, 7)))
        }
        // 睡眠の種類は actual_task に書かない (やった・スキップ・予定外とも。記録は sleep_record。S2-6)
        let sleepRow = S2.row(today, "睡眠", spillover: true)
        await #expect(throws: CheckInRuleError.sleepIsSeparate) { try await S2.apply(source, S2.done(sleepRow)) }
        await #expect(throws: CheckInRuleError.sleepIsSeparate) {
            try await S2.apply(source, CheckInPlanner.skip(row: sleepRow, state: .none, calendar: cal)!)
        }
        await #expect(throws: CheckInRuleError.sleepIsSeparate) {
            try await S2.apply(source, .saveActual(id: nil, name: "昼の睡眠", categoryId: S2.category(source, "睡眠").id,
                                                   start: S1.date(9, 30, 8), end: S1.date(9, 30, 9)))
        }
        #expect(source.snapshot.actualTasks.isEmpty)
        // 睡眠の行は実績欄を出さない (前日の回・今夜の回とも)。睡眠以外の今日の回は時刻に依らず出す
        let sleepCategory = S2.category(source, "睡眠")
        #expect(!CheckInPlanner.acceptsActual(for: sleepRow, category: sleepCategory, now: S1.today, calendar: cal))
        #expect(!CheckInPlanner.acceptsActual(for: S2.row(today, "睡眠"), category: sleepCategory, now: S1.date(9, 30, 23, 30), calendar: cal))
        #expect(CheckInPlanner.acceptsActual(for: gym, category: S2.category(source, "ジム"), now: S1.date(9, 30, 0, 1), calendar: cal))
    }

    @Test func circleShownByOccurrenceDayNotViewDay() async throws {
        let source = S1.source()
        let gymCategory = S2.category(source, "ジム"), sleepCategory = S2.category(source, "睡眠")
        let today = try await S1.build(source, S1.date(9, 30))
        let tomorrow = try await S1.build(source, S1.date(10, 1))
        // 今日のこれからの回も丸が出る。明日以降は出ない
        #expect(CheckInPlanner.circleStyle(row: S2.row(today, "ジム"), state: .none, category: gymCategory, today: S1.today, calendar: S2.cal) == .empty)
        #expect(CheckInPlanner.circleStyle(row: S2.row(tomorrow, "ジム"), state: .none, category: gymCategory, today: S1.today, calendar: S2.cal) == nil)
        // 睡眠は丸なし。今日の一覧では並びを揃える幅だけ取る。明日の一覧 (丸の無い日) の最上段 (今夜の睡眠) は幅も取らない
        #expect(CheckInPlanner.circleStyle(row: S2.row(today, "睡眠", spillover: true), state: .none, category: sleepCategory,
                                           today: S1.today, calendar: S2.cal) == .hidden)
        #expect(CheckInPlanner.circleStyle(row: S2.row(today, "睡眠"), state: .none, category: sleepCategory,
                                           today: S1.today, calendar: S2.cal) == .hidden)
        #expect(CheckInPlanner.circleStyle(row: S2.row(tomorrow, "睡眠", spillover: true), state: .none, category: sleepCategory,
                                           today: S1.today, calendar: S2.cal) == nil)
        #expect(CheckInPlanner.circleStyle(row: S2.row(tomorrow, "睡眠"), state: .none, category: sleepCategory,
                                           today: S1.today, calendar: S2.cal) == nil)
    }
}

// MARK: - 予定外の実績 (C6)

@MainActor
struct UnplannedActualTests {
    let cal = S2.cal

    @Test func addEditDeleteOnPastDay() async throws {
        let source = S1.source()
        let errand = try await source.createCategory(name: "用事")
        let (start, end) = CheckInPlanner.unplannedRange(day: S1.date(9, 28), startMinutes: 840, endMinutes: 960, calendar: cal)!
        try await S2.apply(source, .saveActual(id: nil, name: "読書", categoryId: errand.id, start: start, end: end))
        var day = try await S1.build(source, S1.date(9, 28))
        let items = CheckInPlanner.listItems(day: day, calendar: cal)
        guard let unplanned = items.compactMap({ if case .unplanned(let a) = $0 { a } else { nil } }).first else {
            Issue.record("予定外の実績が一覧に出ない"); return
        }
        #expect(unplanned.name == "読書" && unplanned.occurrenceDate == S1.date(9, 28))
        // 時刻順: ジム (6:45 の O(D) は無いので仮想) → 読書 14:00 → 睡眠 23:00
        #expect(items.map { item -> String in
            switch item { case .planned(let r): return r.task.name; case .unplanned(let a): return a.name }
        } == ["睡眠", "ジム", "読書", "睡眠"])

        // 編集: 名前と時刻 (日をまたぐ終了は翌日)
        let (s2, e2) = CheckInPlanner.unplannedRange(day: S1.date(9, 28), startMinutes: 1380, endMinutes: 30, calendar: cal)!
        #expect(e2 == S1.date(9, 29, 0, 30))
        try await S2.apply(source, .saveActual(id: unplanned.id, name: "映画", categoryId: errand.id, start: s2, end: e2))
        day = try await S1.build(source, S1.date(9, 28))
        #expect(day.records.map(\.name) == ["映画"])
        // 翌日の一覧には予定外として出さない (一覧に出る日は 9/28)
        let next = try await S1.build(source, S1.date(9, 29))
        #expect(!CheckInPlanner.listItems(day: next, calendar: cal).contains { if case .unplanned = $0 { true } else { false } })

        // 削除 (過去日も可)
        try await S2.apply(source, .deleteActual(id: unplanned.id))
        #expect(source.snapshot.actualTasks.isEmpty)
        // 明日の記録は拒む
        let (fs, fe) = CheckInPlanner.unplannedRange(day: S1.date(10, 1), startMinutes: 600, endMinutes: 660, calendar: cal)!
        await #expect(throws: CheckInRuleError.futureDay) {
            try await S2.apply(source, .saveActual(id: nil, name: "x", categoryId: errand.id, start: fs, end: fe))
        }
    }

    @Test func defaultTimes() {
        #expect(CheckInPlanner.defaultUnplannedMinutes(day: S1.date(9, 28), now: S1.today, calendar: cal) == (720, 780))
        #expect(CheckInPlanner.defaultUnplannedMinutes(day: S1.date(9, 30), now: S1.date(9, 30, 14, 58), calendar: cal) == (810, 870))
        #expect(CheckInPlanner.defaultUnplannedMinutes(day: S1.date(9, 30), now: S1.date(9, 30, 0, 20), calendar: cal) == (0, 60))
    }
}

// MARK: - 予定の操作と実績 (スキップは消え、やったは残る・変換ではつなぎ直す)

@MainActor
struct CheckInWithScheduleOperationTests {
    let cal = S2.cal

    @Test func deletingOccurrenceRemovesSkippedKeepsDone() async throws {
        let source = S1.source()
        let errand = try await source.createCategory(name: "用事")
        let daily = ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: false)
        try await source.apply(.createSeries(date: S1.date(9, 30), content: S1.content("読書", errand.id, 1260, 60),
                                             repeatRule: daily, replacingSingle: nil))
        let gymId = S1.series(source, "ジム"), readingId = S1.series(source, "読書")
        var day = try await S1.build(source, S1.date(9, 30))
        try await S2.apply(source, CheckInPlanner.skip(row: S2.row(day, "ジム"), state: .none, calendar: cal)!)
        try await S2.apply(source, S2.done(S2.row(day, "読書")))
        try await source.apply(.deleteOccurrence(templateId: gymId, date: S1.date(9, 30)))
        try await source.apply(.deleteOccurrence(templateId: readingId, date: S1.date(9, 30)))
        #expect(source.snapshot.actualTasks.map(\.status) == [.done])
        // 回は出なくなり、やったは予定外として同じ日に出る (つながりは残る)
        day = try await S1.build(source, S1.date(9, 30))
        let items = CheckInPlanner.listItems(day: day, calendar: cal)
        #expect(items.contains { if case .unplanned(let a) = $0 { a.name == "読書" && a.templateId == readingId } else { false } })
    }

    @Test func deletingSingleRemovesSkippedAndUnlinksDone() async throws {
        let source = S1.source()
        let errand = try await source.createCategory(name: "用事")
        try await source.apply(.createSingle(date: S1.date(9, 30), content: S1.content("読書", errand.id, 840, 60)))
        try await source.apply(.createSingle(date: S1.date(9, 30), content: S1.content("散歩", errand.id, 1020, 30)))
        let day = try await S1.build(source, S1.date(9, 30))
        let reading = S2.row(day, "読書"), walk = S2.row(day, "散歩")
        try await S2.apply(source, CheckInPlanner.skip(row: reading, state: .none, calendar: cal)!)
        try await S2.apply(source, S2.done(walk))
        try await source.apply(.deleteSingle(id: reading.task.id))
        try await source.apply(.deleteSingle(id: walk.task.id))
        let rest = source.snapshot.actualTasks
        #expect(rest.count == 1)
        #expect(rest.first?.name == "散歩" && rest.first?.isUnplanned == true && rest.first?.occurrenceDate == S1.date(9, 30))
    }

    @Test func deletingWholeSeriesRemovesSkippedAndUnlinksDone() async throws {
        let source = S1.source()
        let errand = try await source.createCategory(name: "用事")
        let daily = ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: false)
        try await source.apply(.createSeries(date: S1.date(9, 30), content: S1.content("勉強", errand.id, 600, 60),
                                             repeatRule: daily, replacingSingle: nil))
        try await source.apply(.createSeries(date: S1.date(9, 30), content: S1.content("英語", errand.id, 660, 30),
                                             repeatRule: daily, replacingSingle: nil))
        let day = try await S1.build(source, S1.date(9, 30))
        try await S2.apply(source, CheckInPlanner.skip(row: S2.row(day, "勉強"), state: .none, calendar: cal)!)
        try await S2.apply(source, S2.done(S2.row(day, "英語")))
        try await source.apply(.deleteFollowing(templateId: S1.series(source, "勉強"), date: S1.date(9, 30)))
        try await source.apply(.deleteFollowing(templateId: S1.series(source, "英語"), date: S1.date(9, 30)))
        let rest = source.snapshot.actualTasks
        #expect(rest.map(\.name) == ["英語"])
        #expect(rest.first?.isUnplanned == true, "系列ごと消すと、やったのつながりは外れる (SET NULL)")
    }

    @Test func endingSeriesFromTodayKeepsPastDoneAndRemovesSkipped() async throws {
        let source = S1.source()
        let gymId = S1.series(source, "ジム")
        let yesterday = try await S1.build(source, S1.date(9, 29))
        let today = try await S1.build(source, S1.date(9, 30))
        try await S2.apply(source, S2.done(S2.row(yesterday, "ジム")))
        try await S2.apply(source, CheckInPlanner.skip(row: S2.row(today, "ジム"), state: .none, calendar: cal)!)
        try await source.apply(.deleteFollowing(templateId: gymId, date: S1.date(9, 30)))
        let rest = source.snapshot.actualTasks
        #expect(rest.count == 1)
        #expect(rest.first?.occurrenceDate == S1.date(9, 29) && rest.first?.templateId == gymId)
    }

    @Test func conversionsRelinkDoneAndSkipped() async throws {
        for status in [ActualTask.Status.done, .skipped] {
            let source = S1.source()
            let errand = try await source.createCategory(name: "用事")
            try await source.apply(.createSingle(date: S1.date(9, 30), content: S1.content("読書", errand.id, 840, 60)))
            var day = try await S1.build(source, S1.date(9, 30))
            let single = S2.row(day, "読書")
            let op: CheckInOperation = status == .done ? S2.done(single) : CheckInPlanner.skip(row: single, state: .none, calendar: cal)!
            try await S2.apply(source, op)
            let recordId = source.snapshot.actualTasks.first!.id

            // 単発 → 繰り返し (曜日を付けた)
            let daily = ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: false)
            try await source.apply(.createSeries(date: S1.date(9, 30), content: S1.content("読書", errand.id, 840, 60),
                                                 repeatRule: daily, replacingSingle: single.task.id))
            day = try await S1.build(source, S1.date(9, 30))
            let occurrence = S2.row(day, "読書")
            #expect(occurrence.task.templateId != nil)
            #expect(S2.state(source, day, occurrence).record?.id == recordId, "丸の状態が保たれる (\(status))")
            #expect(S2.state(source, day, occurrence).record?.status == status)
            #expect(CheckInPlanner.listItems(day: day, calendar: cal).count == day.scheduled.count, "予定外の二重表示がない")

            // 繰り返し → 単発 (繰り返しをやめる)
            try await source.apply(.endSeriesToSingle(templateId: occurrence.task.templateId!, date: S1.date(9, 30),
                                                      content: S1.content("読書", errand.id, 840, 60)))
            day = try await S1.build(source, S1.date(9, 30))
            let back = S2.row(day, "読書")
            #expect(back.task.templateId == nil)
            #expect(S2.state(source, day, back).record?.id == recordId)
            #expect(S2.state(source, day, back).record?.status == status)
            #expect(source.snapshot.actualTasks.count == 1)
        }
    }

    @Test func weekdayChangeKeepsSkippedButHidesIt() async throws {
        let source = S1.source()
        let gymId = S1.series(source, "ジム")
        let gym = S2.category(source, "ジム")
        var day = try await S1.build(source, S1.date(9, 30))
        try await S2.apply(source, CheckInPlanner.skip(row: S2.row(day, "ジム"), state: .none, calendar: cal)!)
        // 曜日を月・金に (水曜の今日は出なくなる)。skipped は消さない (本人確認 (b))
        try await source.apply(.saveFollowing(templateId: gymId, date: S1.date(9, 30), content: S1.content("ジム", gym.id, 405, 45),
                                              repeatRule: ScheduleRepeatRule(weekdays: [.monday, .friday], showsOnHoliday: false)))
        #expect(source.snapshot.actualTasks.count == 1)
        day = try await S1.build(source, S1.date(9, 30))
        #expect(!CheckInPlanner.listItems(day: day, calendar: cal).contains { if case .unplanned = $0 { true } else { false } },
                "回の無いスキップは一覧に出さない")
    }
}

// MARK: - ジムの表示時判定 (C4)

@MainActor
struct GymWorkoutJudgementTests {
    let cal = S2.cal

    @Test func setsMakeGymDoneAndFixed() async throws {
        let source = S1.source()
        let day0 = try await S1.build(source, S1.date(9, 29))
        let gymRow = S2.row(day0, "ジム")
        // スキップした後にセットがあれば、やったを優先
        try await S2.apply(source, CheckInPlanner.skip(row: gymRow, state: .none, calendar: cal)!)
        var state = source.snapshot
        state.workoutSetTimes = [S1.date(9, 29, 7, 35), S1.date(9, 29, 6, 50), S1.date(9, 29, 7, 10), S1.date(9, 30, 6, 0)]
        let withSets = InMemoryScheduleDataSource(state: state, calendar: cal, holidayChecker: S1.isHoliday, now: { S1.today })
        let day = try await S1.build(withSets, S1.date(9, 29))
        #expect(day.workoutSetTimes.count == 3, "その日のセットだけ")
        let judged = S2.state(withSets, day, S2.row(day, "ジム"))
        #expect(judged == .workout(first: S1.date(9, 29, 6, 50), last: S1.date(9, 29, 7, 35), count: 3))
        #expect(judged.isDone)
        #expect(CheckInPlanner.toggle(row: gymRow, state: judged, calendar: cal) == nil, "押しても変わらない")
        #expect(CheckInPlanner.skip(row: gymRow, state: judged, calendar: cal) == nil)
        let gymCategory = S2.category(withSets, "ジム")
        #expect(CheckInPlanner.circleStyle(row: gymRow, state: judged, category: gymCategory, today: S1.today, calendar: cal) == .fixedDone)
        #expect(CheckInPlanner.actualLine(row: gymRow, state: judged, category: gymCategory, now: S1.today, calendar: cal)
                == "実績 6:50–7:35（トレーニング）")
        #expect(CheckInPlanner.actualLine(row: gymRow, state: .workout(first: S1.date(9, 29, 7), last: S1.date(9, 29, 7), count: 1),
                                          category: gymCategory, now: S1.today, calendar: cal) == "トレーニングの記録あり")
        // 実績の行は書かない (スキップ行がそのまま残る)
        #expect(withSets.snapshot.actualTasks.map(\.status) == [.skipped])
        // セットの無い日は手で押せる
        let today = try await S1.build(withSets, S1.date(9, 30))
        #expect(today.workoutSetTimes.count == 1)
        let noSets = try await S1.build(withSets, S1.date(9, 28))
        #expect(S2.state(withSets, noSets, S2.row(noSets, "ジム")) == .none)
    }

    @Test func nonGymCategoryIgnoresSets() async throws {
        var state = S1.source().snapshot
        state.workoutSetTimes = [S1.date(9, 29, 23, 30)]
        let source = InMemoryScheduleDataSource(state: state, calendar: cal, holidayChecker: S1.isHoliday, now: { S1.today })
        let day = try await S1.build(source, S1.date(9, 29))
        #expect(S2.state(source, day, S2.row(day, "睡眠")) == .none)
    }
}

// MARK: - 実績時刻の解釈 (レビュー §3-2)

@MainActor
struct CheckInTimeRuleTests {
    let cal = S2.cal

    @Test func nearestAndEnd() {
        let planned = S1.date(9, 30, 23)
        #expect(CheckInPlanner.nearest(minutes: 30, around: planned, calendar: cal) == S1.date(10, 1, 0, 30))
        #expect(CheckInPlanner.nearest(minutes: 1350, around: planned, calendar: cal) == S1.date(9, 30, 22, 30))
        #expect(CheckInPlanner.nearest(minutes: 330, around: S1.date(9, 30, 6, 45), calendar: cal) == S1.date(9, 30, 5, 30))
        #expect(CheckInPlanner.end(minutes: 430, after: S1.date(9, 30, 23, 40), calendar: cal) == S1.date(10, 1, 7, 10))
        #expect(CheckInPlanner.end(minutes: 1420, after: S1.date(9, 30, 23, 40), calendar: cal) == nil, "開始と同じ時刻は不可")
        #expect(CheckInPlanner.durationText(S1.date(9, 30, 23, 40), S1.date(10, 1, 7, 10)) == "7時間30分")
    }
}

// MARK: - 取得・decode

@MainActor
struct CheckInDecodeTests {
    @Test func skippedRowDecodesWithNullTimes() throws {
        let json = """
        [{"id":"6E1F2B3C-0000-4000-8000-000000000001","name":"ジム","category_id":"6E1F2B3C-0000-4000-8000-000000000002",
          "start_at":null,"end_at":null,"status":"skipped","template_id":"6E1F2B3C-0000-4000-8000-000000000003",
          "occurrence_date":"2026-09-29","scheduled_task_id":null},
         {"id":"6E1F2B3C-0000-4000-8000-000000000004","name":"英語","category_id":"6E1F2B3C-0000-4000-8000-000000000005",
          "start_at":"2026-09-29T15:30:00.000Z","end_at":"2026-09-29T22:30:00+00:00","status":"done",
          "template_id":"6E1F2B3C-0000-4000-8000-000000000006","occurrence_date":"2026-09-29","scheduled_task_id":null},
         {"id":"6E1F2B3C-0000-4000-8000-000000000007","name":"読書","category_id":"6E1F2B3C-0000-4000-8000-000000000005",
          "start_at":"2026-09-30T05:00:00Z","end_at":"2026-09-30T07:00:00Z","status":"done","template_id":null,
          "occurrence_date":"2026-09-30","scheduled_task_id":null}]
        """
        let rows = try JSONDecoder.supabase.decode([ActualTask].self, from: Data(json.utf8))
        #expect(rows.count == 3)
        #expect(rows[0].status == .skipped && rows[0].startAt == nil && rows[0].occurrenceDate == S1.date(9, 29))
        #expect(rows[1].startAt == S1.date(9, 30, 0, 30) && rows[1].templateId != nil)
        #expect(rows[2].isUnplanned)
        // DayBuilder はスキップ行を時刻の一覧に入れず、records には残す
        let context = DayBuilderContext(templates: [], patterns: [], memberships: [], exdates: [], dayMeta: nil,
                                        scheduledTasks: [], actualTasks: rows, holidayChecker: { _ in false }, calendar: S1.calendar)
        let day = DayBuilder.build(date: S1.date(9, 30), context: context)
        #expect(day.records.count == 3)
        #expect(day.actual.map(\.task.name) == ["英語", "読書"])
    }

    @Test func checkInRPCParams() {
        let cal = S1.calendar
        let t = UUID(), c = UUID(), s = UUID()
        let set = ScheduleRPC.call(for: .set(key: .occurrence(templateId: t, date: S1.date(9, 29, 23)), status: .done, name: "英語",
                                             categoryId: c, start: S1.date(9, 30, 0, 30), end: S1.date(9, 30, 7, 30)),
                                   calendar: cal)
        #expect(set.function == "checkin_set")
        #expect(set.params.values["p_template_id"] == .string(t.uuidString))
        #expect(set.params.values["p_occurrence_date"] == .string("2026-09-29"))
        #expect(set.params.values["p_scheduled_task_id"] == .null)
        #expect(set.params.values["p_start"] == .string("2026-09-29T15:30:00.000Z"))
        // 0007 の checkin_set は 8 引数 (睡眠のスコアの引数は無い)
        #expect(Set(set.params.values.keys) == ["p_template_id", "p_occurrence_date", "p_scheduled_task_id", "p_status", "p_name",
                                                 "p_category_id", "p_start", "p_end"])
        let skip = ScheduleRPC.call(for: .set(key: .single(id: s), status: .skipped, name: "x", categoryId: c, start: nil, end: nil),
                                    calendar: cal)
        #expect(skip.params.values["p_start"] == .null && skip.params.values["p_status"] == .string("skipped"))
        #expect(skip.params.values["p_scheduled_task_id"] == .string(s.uuidString) && skip.params.values["p_template_id"] == .null)
        #expect(ScheduleRPC.call(for: .clear(key: .single(id: s)), calendar: cal).function == "checkin_clear")
        let save = ScheduleRPC.call(for: .saveActual(id: nil, name: "読書", categoryId: c, start: S1.date(9, 30, 14), end: S1.date(9, 30, 16)),
                                    calendar: cal)
        #expect(save.function == "actual_save" && save.params.values["p_id"] == .null)
        #expect(ScheduleRPC.call(for: .deleteActual(id: s), calendar: cal).params.values == ["p_id": .string(s.uuidString)])
    }
}

// MARK: - store (楽観更新・回ごとの直列化。レビュー §5-3)

@MainActor
struct CheckInStoreTests {
    let cal = S2.cal

    func makeStore(_ source: InMemoryScheduleDataSource) -> ScheduleStore {
        ScheduleStore(dayDataSource: source, dataSource: source, calendar: cal, holidayChecker: S1.isHoliday)
    }

    @Test func secondTapReturnsToNone() async throws {
        let inner = S1.source()
        let source = GatedCheckInSource(inner: inner)
        let store = ScheduleStore(dayDataSource: source, dataSource: source, calendar: cal, holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(9, 30))
        let day = try #require(store.day(S1.date(9, 30)))
        let gym = S2.row(day, "ジム")
        let key = CheckInKey.of(gym, calendar: cal)

        // 1 回目: 応答を止めておく。押した瞬間に表示は「やった」(楽観更新)
        let first = Task { await store.checkIn(CheckInPlanner.toggle(row: gym, state: .none, calendar: cal)!, reloading: S1.date(9, 30)) }
        for _ in 0..<1000 where source.pending == 0 { await Task.yield() }
        #expect(source.pending == 1)
        #expect(store.checkInState(for: gym, in: day).isDone)

        // 2 回目 (1 回目の応答前): 表示はすぐ記録なし。送るのは 1 回目の応答の後 (直列化)
        let second = Task { await store.checkIn(.clear(key: key), reloading: S1.date(9, 30)) }
        for _ in 0..<1000 where store.overrides[key] != .cleared { await Task.yield() }
        #expect(store.checkInState(for: gym, in: day) == .none)
        #expect(source.pending == 1, "2 回目はまだ送っていない")

        source.release()
        for _ in 0..<1000 where source.pending == 0 { await Task.yield() }
        source.release()
        let (e1, e2) = await (first.value, second.value)
        #expect(e1 == nil && e2 == nil)
        #expect(inner.snapshot.actualTasks.isEmpty)
        let reloaded = try #require(store.day(S1.date(9, 30)))
        #expect(store.checkInState(for: S2.row(reloaded, "ジム"), in: reloaded) == .none)
        #expect(store.overrides.isEmpty)
    }

    @Test func optimisticStateThenFailureRollsBack() async throws {
        let source = S1.source()
        let store = makeStore(source)
        await store.ensureLoaded(S1.date(10, 1))
        let day = try #require(store.day(S1.date(10, 1)))
        let gym = S2.row(day, "ジム")
        // 明日の回は DB (モック) が拒む → 表示は戻り、エラーが返る
        let error = await store.checkIn(S2.done(gym), reloading: S1.date(10, 1))
        #expect(error as? CheckInRuleError == .futureDay)
        let reloaded = try #require(store.day(S1.date(10, 1)))
        #expect(store.checkInState(for: S2.row(reloaded, "ジム"), in: reloaded) == .none)
        #expect(store.overrides.isEmpty)
    }

    @Test func mockDayFixtureHasCheckInSamples() async throws {
        let source = InMemoryScheduleDataSource.makeFixture(calendar: cal, holidayChecker: S1.isHoliday, now: { S1.today }, withSamples: true)
        let yesterday = try await S1.build(source, S1.date(9, 29))
        #expect(S2.state(source, yesterday, S2.row(yesterday, "ジム")).isSkipped)
        #expect(CheckInPlanner.listItems(day: yesterday, calendar: cal).contains { if case .unplanned(let a) = $0 { a.name == "読書" } else { false } })
        // 睡眠は actual_task でなく sleep_record (一昨日の夜 23:40–7:10・昨日の仮眠 13:10–13:40)
        #expect(source.snapshot.actualTasks.allSatisfy { $0.name != "睡眠" })
        let records = source.snapshot.sleepRecords.sorted { $0.startAt < $1.startAt }
        #expect(records.map(\.kind) == [.sleep, .nap])
        #expect(records.first?.startAt == S1.date(9, 28, 23, 40) && records.first?.endAt == S1.date(9, 29, 7, 10))
        #expect(records.last?.startAt == S1.date(9, 29, 13, 10) && records.last?.endAt == S1.date(9, 29, 13, 40))
        let spill = S2.row(yesterday, "睡眠", spillover: true)
        let assigned = SleepRules.assign(rows: yesterday.scheduled.filter { $0.task.name == "睡眠" }, records: yesterday.sleepRecords)
        #expect(SleepRules.planLine(assigned[spill.id] ?? [], calendar: cal) == "実績 23:40–7:10（7時間30分）")
        #expect(assigned[S2.row(yesterday, "睡眠").id] == nil, "昨夜は未入力 (行に何も出さない)")
        let setDay = try await S1.build(source, S1.date(9, 28))
        if case .workout(_, _, let count) = S2.state(source, setDay, S2.row(setDay, "ジム")) {
            #expect(count == 3)
        } else {
            Issue.record("セットのある日のジムがやったにならない")
        }
    }
}

/// 実績の書き込みの応答を止めておける data source (楽観更新・直列化の確認用)
final class GatedCheckInSource: DayDataSource, ScheduleDataSource, @unchecked Sendable {
    let inner: InMemoryScheduleDataSource
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(inner: InMemoryScheduleDataSource) {
        self.inner = inner
    }

    /// 応答待ちの書き込みの数
    var pending: Int { lock.withLock { waiters.count } }

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

    func applyCheckIn(_ operation: CheckInOperation) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
        try await inner.applyCheckIn(operation)
    }
}
