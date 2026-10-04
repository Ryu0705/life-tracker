import Foundation
import Testing
import Supabase
@testable import LifeTracker

// 睡眠の記録 (sleep_record・睡眠タブ) の単体テスト。docs/sleep-design/synthesis.md §6-1 を implementation-plan.md の差分で読み替えたもの
// (目覚め・時刻での夜/仮眠の判定の項目は、種別 kind の項目と予定ベースの cardDefault / addDefault の項目に差し替え)。
// 日付は S1 と同じ (2026 年 JST。今日 = 9/30(水) 10:00)。睡眠の予定 = 毎日 23:00〜8h

@MainActor
enum SL {
    static var cal: Calendar { S1.calendar }

    static func record(_ start: Date, _ end: Date, _ kind: SleepKind = .sleep) -> SleepRecord {
        SleepRecord(startAt: start, endAt: end, kind: kind, createdAt: end)
    }

    static func sleepRows(_ source: InMemoryScheduleDataSource, _ day: Day) -> [DayScheduledTask] {
        let sleepId = S2.category(source, "睡眠").id
        return day.scheduled.filter { $0.task.categoryId == sleepId }
    }

    static func sleepIds(_ source: InMemoryScheduleDataSource) -> Set<UUID> {
        [S2.category(source, "睡眠").id]
    }
}

// MARK: - どの夜か (nightKey / kind / displayDay / nights)

@MainActor
struct SleepNightKeyTests {
    let cal = SL.cal

    @Test func nightKeyAndDisplayDay() {
        // 23:40 → 7:10: 鍵 = 就寝の日、朝 = 翌日
        let usual = SL.record(S1.date(9, 29, 23, 40), S1.date(9, 30, 7, 10))
        #expect(SleepRules.nightKey(of: usual, calendar: cal) == S1.date(9, 29))
        #expect(SleepRules.displayDay(of: usual, calendar: cal) == S1.date(9, 30))
        // 0:30 → 7:30: 鍵 = 前日 (予定タブの「前日から続く行」の回の日と同じ数え方)
        let late = SL.record(S1.date(9, 30, 0, 30), S1.date(9, 30, 7, 30))
        #expect(SleepRules.nightKey(of: late, calendar: cal) == S1.date(9, 29))
        #expect(SleepRules.displayDay(of: late, calendar: cal) == S1.date(9, 30))
        // 夕方の寝落ち 18:00–23:00 (通常の睡眠と選んだ) は鍵 = その日
        let evening = SL.record(S1.date(9, 29, 18), S1.date(9, 29, 23))
        #expect(SleepRules.nightKey(of: evening, calendar: cal) == S1.date(9, 29))
    }

    @Test func kindComesFromColumnNotTime() {
        // 仮眠: 鍵・見出しとも開始の日
        let nap = SL.record(S1.date(9, 30, 14), S1.date(9, 30, 15), .nap)
        #expect(SleepRules.kind(of: nap) == .nap)
        #expect(SleepRules.nightKey(of: nap, calendar: cal) == S1.date(9, 30))
        #expect(SleepRules.displayDay(of: nap, calendar: cal) == S1.date(9, 30))
        // 時刻からは判定しない: 23:00 の仮眠は仮眠のまま、徹夜明けの 6:10–12:00 を通常の睡眠と選べば通常の睡眠 (鍵 = 前日)
        let lateNap = SL.record(S1.date(9, 29, 23), S1.date(9, 29, 23, 30), .nap)
        #expect(SleepRules.kind(of: lateNap) == .nap && SleepRules.nightKey(of: lateNap, calendar: cal) == S1.date(9, 29))
        let morningSleep = SL.record(S1.date(9, 30, 6, 10), S1.date(9, 30, 12))
        #expect(SleepRules.kind(of: morningSleep) == .sleep)
        #expect(SleepRules.nightKey(of: morningSleep, calendar: cal) == S1.date(9, 29))
        #expect(SleepKind(rawValue: "sleep") == .sleep && SleepKind(rawValue: "nap") == .nap)
        #expect(SleepKind.nap.label == "仮眠")
    }

    @Test func splitNightIsOneNightAndNapsAreSeparate() {
        let first = SL.record(S1.date(9, 29, 22), S1.date(9, 29, 23, 50))
        let second = SL.record(S1.date(9, 30, 0, 30), S1.date(9, 30, 7))
        let nap = SL.record(S1.date(9, 30, 13, 10), S1.date(9, 30, 13, 40), .nap)
        #expect(SleepRules.nightKey(of: first, calendar: cal) == SleepRules.nightKey(of: second, calendar: cal))
        let nights = SleepRules.nights([nap, second, first], calendar: cal)
        #expect(nights.count == 1, "仮眠はまとめない")
        let night = try! #require(nights.first)
        #expect(night.key == S1.date(9, 29))
        #expect(night.records.map(\.id) == [first.id, second.id])
        #expect(night.start == S1.date(9, 29, 22) && night.end == S1.date(9, 30, 7))
        #expect(night.total == (8 * 60 + 20) * 60)
        #expect(SleepRules.morning([nap, first, second], today: S1.today, calendar: cal)?.key == S1.date(9, 29))
        #expect(SleepRules.morningKey(today: S1.today, calendar: cal) == S1.date(9, 29))
    }
}

// MARK: - 今朝のカード・＋ の既定 (予定の就寝〜起床。2026-10-04 本人決定①②)

@MainActor
struct SleepCardDefaultTests {
    let cal = SL.cal

    /// 9/29 の夜の予定 23:00〜7:00
    let plan = SleepPlan(start: S1.date(9, 29, 23), end: S1.date(9, 30, 7))
    /// 前回の通常の睡眠 (9/27 の夜 0:30〜7:20)
    let previous = SleepNight(key: S1.date(9, 27), records: [SL.record(S1.date(9, 28, 0, 30), S1.date(9, 28, 7, 20))])

    @Test func cardIsPlanThenPreviousThenFallback() {
        let now = S1.date(9, 30, 10, 12)
        // 予定あり: 就寝・起床とも予定どおり (起床 = 今 ではない)
        let planned = SleepRules.cardDefault(plan: plan, previous: nil, now: now, calendar: cal)
        #expect(planned?.start == S1.date(9, 29, 23) && planned?.end == S1.date(9, 30, 7))
        // 予定があれば前回より予定
        let both = SleepRules.cardDefault(plan: plan, previous: previous, now: now, calendar: cal)
        #expect(both?.start == S1.date(9, 29, 23) && both?.end == S1.date(9, 30, 7))
        // 予定が無い夜: 前回の通常の睡眠の就寝・起床の時計の時刻をその夜に当てる
        let fromPrevious = SleepRules.cardDefault(plan: nil, previous: previous, now: now, calendar: cal)
        #expect(fromPrevious?.start == S1.date(9, 30, 0, 30) && fromPrevious?.end == S1.date(9, 30, 7, 20))
        // 予定も前回も無い: 23:00 / 7:00
        let fallback = SleepRules.cardDefault(plan: nil, previous: nil, now: now, calendar: cal)
        #expect(fallback?.start == S1.date(9, 29, 23) && fallback?.end == S1.date(9, 30, 7))
        // 夜遅く (まだ今朝の鍵は 9/29) に開いても予定どおり (24 時間超にならない)
        let late = SleepRules.cardDefault(plan: plan, previous: nil, now: S1.date(9, 30, 23, 30), calendar: cal)
        #expect(late?.start == S1.date(9, 29, 23) && late?.end == S1.date(9, 30, 7))
    }

    @Test func cardWakeInFutureIsNowOrNil() {
        // 予定の起床 7:00 がまだ: 起床 = 今 (5 分切り捨て)
        let early = SleepRules.cardDefault(plan: plan, previous: nil, now: S1.date(9, 30, 6, 12), calendar: cal)
        #expect(early?.start == S1.date(9, 29, 23) && early?.end == S1.date(9, 30, 6, 10))
        // 予定の起床ちょうど: 寄せない
        let exact = SleepRules.cardDefault(plan: plan, previous: nil, now: S1.date(9, 30, 7), calendar: cal)
        #expect(exact?.end == S1.date(9, 30, 7))
        // 予定が無く 23:00 / 7:00 の起床がまだ: 今に寄せる
        let fallback = SleepRules.cardDefault(plan: nil, previous: nil, now: S1.date(9, 30, 5, 3), calendar: cal)
        #expect(fallback?.start == S1.date(9, 29, 23) && fallback?.end == S1.date(9, 30, 5))
        // 1:00〜9:00 の世代で 0:40 に開いた: 寄せても起床 ≤ 就寝 → nil (「起きたら記録できます」)
        let afterMidnight = SleepPlan(start: S1.date(9, 30, 1), end: S1.date(9, 30, 9))
        #expect(SleepRules.cardDefault(plan: afterMidnight, previous: nil, now: S1.date(9, 30, 0, 40), calendar: cal) == nil)
        #expect(SleepRules.cardDefault(plan: afterMidnight, previous: nil, now: S1.date(9, 30, 1, 4), calendar: cal) == nil, "切り捨てで 1:00 = 就寝")
        let partial = SleepRules.cardDefault(plan: afterMidnight, previous: nil, now: S1.date(9, 30, 3, 7), calendar: cal)
        #expect(partial?.start == S1.date(9, 30, 1) && partial?.end == S1.date(9, 30, 3, 5))
    }

    @Test func plannedSleepFromScheduleResolvesVersionsAndExdates() async throws {
        let source = S1.source()
        let ids = SL.sleepIds(source)
        func rows(_ key: Date) async throws -> [DayScheduledTask] {
            let next = cal.date(byAdding: .day, value: 1, to: key)!
            return try await S1.build(source, key).scheduled + S1.build(source, next).scheduled
        }
        // 9/29 の夜 = 9/29 23:00〜9/30 7:00 (9/30 の一覧の前日から続く行は除く。終了は clip 前)
        #expect(SleepRules.plannedSleep(rows: try await rows(S1.date(9, 29)), sleepCategoryIds: ids, nightKey: S1.date(9, 29),
                                        calendar: cal) == SleepPlan(start: S1.date(9, 29, 23), end: S1.date(9, 30, 7)))
        // 除外日の夜は予定なし
        let sleepId = S1.series(source, "睡眠")
        try await source.apply(.deleteOccurrence(templateId: sleepId, date: S1.date(10, 1)))
        #expect(SleepRules.plannedSleep(rows: try await rows(S1.date(10, 1)), sleepCategoryIds: ids, nightKey: S1.date(10, 1),
                                        calendar: cal) == nil)
        // 0 時過ぎに始まる世代 (10/2 から 1:00〜9:00): 10/2 の夜は翌日 10/3 の一覧の 1:00〜9:00 の行 (10/2 の一覧の 1:00 は 10/1 の夜)
        try await source.apply(.saveFollowing(templateId: sleepId, date: S1.date(10, 2), content: S1.content("睡眠", ids.first!, 60, 480),
                                              repeatRule: ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: true)))
        let generation = try #require(SleepRules.plannedSleep(rows: try await rows(S1.date(10, 2)), sleepCategoryIds: ids,
                                                              nightKey: S1.date(10, 2), calendar: cal))
        #expect(generation == SleepPlan(start: S1.date(10, 3, 1), end: S1.date(10, 3, 9)))
        // その朝 (10/3) のカード: 10 時に開けば 1:00〜9:00、8:02 に開けば 1:00〜8:00
        let card = SleepRules.cardDefault(plan: generation, previous: nil, now: S1.date(10, 3, 10), calendar: cal)
        #expect(card?.start == S1.date(10, 3, 1) && card?.end == S1.date(10, 3, 9))
        let early = SleepRules.cardDefault(plan: generation, previous: nil, now: S1.date(10, 3, 8, 2), calendar: cal)
        #expect(early?.start == S1.date(10, 3, 1) && early?.end == S1.date(10, 3, 8))
        // ＋ で起床の日 10/3 を選んでも同じ予定
        let add = SleepRules.addDefault(wakeDay: S1.date(10, 3), plan: generation, previous: nil, now: S1.date(10, 4, 12), calendar: cal)
        #expect(add.start == S1.date(10, 3, 1) && add.end == S1.date(10, 3, 9))
        // 睡眠以外の種類は見ない
        #expect(SleepRules.plannedSleep(rows: try await rows(S1.date(9, 29)), sleepCategoryIds: [], nightKey: S1.date(9, 29),
                                        calendar: cal) == nil)
    }

    @Test func addDefaultFollowsWakeDay() {
        let now = S1.date(9, 30, 13, 42)
        // 予定あり: 選んだ起床の日の前夜の予定どおり
        let past = SleepPlan(start: S1.date(9, 26, 23, 30), end: S1.date(9, 27, 6, 30))
        let planned = SleepRules.addDefault(wakeDay: S1.date(9, 27), plan: past, previous: previous, now: now, calendar: cal)
        #expect(planned.start == S1.date(9, 26, 23, 30) && planned.end == S1.date(9, 27, 6, 30))
        // 予定なし: 前回の通常の睡眠の時計の時刻をその日の前夜に当てる
        let fromPrevious = SleepRules.addDefault(wakeDay: S1.date(9, 29), plan: nil, previous: previous, now: now, calendar: cal)
        #expect(fromPrevious.start == S1.date(9, 29, 0, 30) && fromPrevious.end == S1.date(9, 29, 7, 20))
        // 予定も前回も無い: 前夜 23:00〜その日 7:00
        let fallback = SleepRules.addDefault(wakeDay: S1.date(9, 28), plan: nil, previous: nil, now: now, calendar: cal)
        #expect(fallback.start == S1.date(9, 27, 23) && fallback.end == S1.date(9, 28, 7))
        // 今日を選んで予定の起床がまだ: 起床 = 今 (5 分切り捨て)
        let today = SleepRules.addDefault(wakeDay: S1.date(9, 30), plan: plan, previous: nil, now: S1.date(9, 30, 6, 12), calendar: cal)
        #expect(today.start == S1.date(9, 29, 23) && today.end == S1.date(9, 30, 6, 10))
        // 予定の就寝もまだ (1:00〜9:00 の世代で 0:40): 寄せずに予定のまま (シートが未来として保存を止める)
        let afterMidnight = SleepPlan(start: S1.date(9, 30, 1), end: S1.date(9, 30, 9))
        let notYet = SleepRules.addDefault(wakeDay: S1.date(9, 30), plan: afterMidnight, previous: nil, now: S1.date(9, 30, 0, 40), calendar: cal)
        #expect(notYet.start == S1.date(9, 30, 1) && notYet.end == S1.date(9, 30, 9))
        #expect(SleepRules.validate(start: notYet.start, end: notYet.end, now: S1.date(9, 30, 0, 40), others: [], excluding: nil) == .future)
    }

    @Test func pastMorningAndNapDefaults() {
        let previous = SleepNight(key: S1.date(9, 26), records: [SL.record(S1.date(9, 26, 23, 40), S1.date(9, 27, 7, 10))])
        let past = SleepRules.pastMorningDefault(nightKey: S1.date(9, 28), previous: previous, calendar: cal)
        #expect(past.start == S1.date(9, 28, 23, 40) && past.end == S1.date(9, 29, 7, 10))
        let first = SleepRules.pastMorningDefault(nightKey: S1.date(9, 28), previous: nil, calendar: cal)
        #expect(first.start == S1.date(9, 28, 23) && first.end == S1.date(9, 29, 7))
        let nap = SleepRules.napDefault(now: S1.date(9, 30, 13, 42), calendar: cal)
        #expect(nap.start == S1.date(9, 30, 13, 10) && nap.end == S1.date(9, 30, 13, 40))
    }
}

// MARK: - 時刻の解釈・検査

@MainActor
struct SleepTimeRuleTests {
    let cal = SL.cal

    @Test func resolveFromClockTimes() {
        let r = SleepRules.resolve(bedMinutes: 1420, wakeMinutes: 430, anchorDay: S1.date(9, 30), calendar: cal)
        #expect(r?.start == S1.date(9, 29, 23, 40) && r?.end == S1.date(9, 30, 7, 10), "就寝は前日")
        #expect(SleepRules.resolve(bedMinutes: 430, wakeMinutes: 430, anchorDay: S1.date(9, 30), calendar: cal) == nil, "同じ時刻は不可")
        // 24 時間を超えない (起床の 5 分後の時刻を就寝にすると 23 時間 55 分前)
        let long = SleepRules.resolve(bedMinutes: 435, wakeMinutes: 430, anchorDay: S1.date(9, 30), calendar: cal)!
        #expect(long.end.timeIntervalSince(long.start) == (23 * 60 + 55) * 60)
        let nap = SleepRules.resolve(bedMinutes: 790, wakeMinutes: 820, anchorDay: S1.date(9, 30), calendar: cal)
        #expect(nap?.start == S1.date(9, 30, 13, 10))
    }

    @Test func validateRejects() {
        let now = S1.today
        let existing = SL.record(S1.date(9, 29, 23, 30), S1.date(9, 30, 7, 30))
        #expect(SleepRules.validate(start: S1.date(9, 30, 8), end: S1.date(9, 30, 8), now: now, others: [], excluding: nil) == .invalidTime)
        #expect(SleepRules.validate(start: S1.date(9, 30, 8), end: S1.date(9, 30, 7), now: now, others: [], excluding: nil) == .invalidTime)
        #expect(SleepRules.validate(start: S1.date(9, 28, 7), end: S1.date(9, 29, 7, 5), now: now, others: [], excluding: nil) == .tooLong)
        #expect(SleepRules.validate(start: S1.date(9, 28, 7), end: S1.date(9, 29, 7), now: now, others: [], excluding: nil) == nil, "24 時間ちょうどは可")
        #expect(SleepRules.validate(start: S1.date(9, 30, 9), end: S1.date(9, 30, 10, 5), now: now, others: [], excluding: nil) == .future)
        #expect(SleepRules.validate(start: S1.date(9, 30, 7), end: S1.date(9, 30, 8), now: now, others: [existing], excluding: nil)
                == .overlap(existing.id))
        #expect(SleepRules.validate(start: S1.date(9, 30, 7), end: S1.date(9, 30, 8), now: now, others: [existing], excluding: existing.id) == nil,
                "自分は除く")
        // 端がくっつく 2 件 (7:30 起床と 7:30 就寝) は通る
        #expect(SleepRules.validate(start: S1.date(9, 30, 7, 30), end: S1.date(9, 30, 8), now: now, others: [existing], excluding: nil) == nil)
    }

    @Test func messageForErrors() {
        #expect(SleepRules.message(for: PostgrestError(code: "23P01", message: "conflicting key value")) == "この時間には記録があります")
        #expect(SleepRules.message(for: PostgrestError(code: "23514", message: "violates check")) == "時刻を確かめてください")
        #expect(SleepRules.message(for: SleepRuleError.overlap(UUID())) == "この時間には記録があります")
        #expect(SleepRules.message(for: PostgrestError(code: "42501", message: "denied")) == "denied")
    }
}

// MARK: - 予定タブの行との結び (assign / planLine / fetchRange)

@MainActor
struct SleepAssignTests {
    let cal = SL.cal

    func line(_ source: InMemoryScheduleDataSource, _ day: Day, _ row: DayScheduledTask) -> String? {
        SleepRules.planLine(SleepRules.assign(rows: SL.sleepRows(source, day), records: day.sleepRecords)[row.id] ?? [], calendar: cal)
    }

    @Test func attachesByLongestOverlap() async throws {
        let source = S1.source()
        // 0:30–7:30 → 前日から続く行 (V-2)、14:00–15:00 の仮眠 → どの行にも付かない
        _ = try await source.insertSleepRecord(start: S1.date(9, 30, 0, 30), end: S1.date(9, 30, 7, 30), kind: .sleep)
        _ = try await source.insertSleepRecord(start: S1.date(9, 29, 14), end: S1.date(9, 29, 15), kind: .nap)
        let today = try await S1.build(source, S1.date(9, 30))
        #expect(today.sleepRecords.count == 2, "[D−1 0:00, D+2 0:00) に重なる記録を取る")
        #expect(line(source, today, S2.row(today, "睡眠", spillover: true)) == "実績 0:30–7:30（7時間）")
        #expect(line(source, today, S2.row(today, "睡眠")) == nil, "今夜の行には何も出さない (未入力も出さない)")
        let yesterday = try await S1.build(source, S1.date(9, 29))
        let assigned = SleepRules.assign(rows: SL.sleepRows(source, yesterday), records: yesterday.sleepRecords)
        #expect(!assigned.values.joined().contains { $0.kind == .nap }, "重ならない仮眠はどこにも付かない")
        // 1 件が 2 日の一覧で同じ回に付く (V-3): 9/29 の一覧では 9/29 23:00 の行
        #expect(line(source, yesterday, S2.row(yesterday, "睡眠")) == "実績 0:30–7:30（7時間）")
        #expect(CheckInKey.of(S2.row(yesterday, "睡眠"), calendar: cal) == CheckInKey.of(S2.row(today, "睡眠", spillover: true), calendar: cal))
    }

    @Test func kindDoesNotMatterAndMorningSleepAttaches() async throws {
        // 6:10–12:00 は 23:00–7:00 の行に付く (N-3)。仮眠でも睡眠の行と重なれば出る
        let source = S1.source()
        _ = try await source.insertSleepRecord(start: S1.date(9, 30, 6, 10), end: S1.date(9, 30, 9), kind: .nap)
        let today = try await S1.build(source, S1.date(9, 30))
        #expect(line(source, today, S2.row(today, "睡眠", spillover: true)) == "実績 6:10–9:00（2時間50分）")
    }

    @Test func versionBoundaryMorningPicksLongerOverlap() async throws {
        // 世代の境目の朝 (V-4・N-4): 10/1 から 1:00〜9:00。10/1 の一覧に睡眠の行が 2 本 (前日 23:00 から続く行・1:00 の行)
        let source = S1.source()
        let sleepId = S1.series(source, "睡眠"), category = S2.category(source, "睡眠").id
        try await source.apply(.saveFollowing(templateId: sleepId, date: S1.date(10, 1), content: S1.content("睡眠", category, 60, 480),
                                              repeatRule: ScheduleRepeatRule(weekdays: Set(ScheduleWeekday.allCases), showsOnHoliday: true)))
        let records = [SL.record(S1.date(10, 1, 0, 50), S1.date(10, 1, 8, 30))]
        let day = DayBuilder.build(date: S1.date(10, 1), context: try await source.loadDayContext(date: S1.date(10, 1)))
        let rows = SL.sleepRows(source, day)
        #expect(rows.count == 2)
        let assigned = SleepRules.assign(rows: rows, records: records)
        let oneAm = try #require(rows.first { $0.task.startAt == S1.date(10, 1, 1) })
        #expect(assigned[oneAm.id]?.count == 1, "前日継続の行 6 時間 10 分 < 1:00 の行 7 時間 30 分")
        #expect(assigned.count == 1)
        // 同じ長さなら早い行
        let spill = try #require(rows.first { $0.isSpillover })
        let equal = SL.record(S1.date(10, 1, 0, 30), S1.date(10, 1, 7, 30)) // 前日継続 6:30・1:00 の行 6:30
        #expect(SleepRules.assign(rows: rows, records: [equal])[spill.id]?.count == 1)
    }

    @Test func exdateNightShowsOnlyInSleepTab() async throws {
        // 除外日の夜の記録は予定タブに出ず、睡眠タブ (nights) には出る (V-5)
        let source = S1.source()
        try await source.apply(.deleteOccurrence(templateId: S1.series(source, "睡眠"), date: S1.date(10, 1)))
        let record = SL.record(S1.date(10, 1, 23, 30), S1.date(10, 2, 7))
        let day = DayBuilder.build(date: S1.date(10, 2), context: try await source.loadDayContext(date: S1.date(10, 2)))
        #expect(!SL.sleepRows(source, day).contains { $0.isSpillover })
        #expect(SleepRules.assign(rows: SL.sleepRows(source, day), records: [record]).isEmpty)
        #expect(SleepRules.nights([record], calendar: cal).map(\.key) == [S1.date(10, 1)])
    }

    @Test func planLineForSeveralRecords() {
        let records = [SL.record(S1.date(9, 29, 23, 30), S1.date(9, 30, 2)), SL.record(S1.date(9, 30, 2, 30), S1.date(9, 30, 7))]
        #expect(SleepRules.planLine(records, calendar: cal) == "実績 23:30–7:00（7時間 · 2 件）")
        #expect(SleepRules.planLine([SL.record(S1.date(9, 29, 23, 40), S1.date(9, 30, 7, 10))], calendar: cal) == "実績 23:40–7:10（7時間30分）")
        #expect(SleepRules.planLine([], calendar: cal) == nil)
    }

    @Test func fetchRangeCoversNeighbourDays() {
        let range = SleepRules.fetchRange(for: S1.date(9, 30, 15), calendar: cal)
        #expect(range.from == S1.date(9, 29) && range.to == S1.date(10, 2))
    }
}

// MARK: - 数字 (今週の 1 行・推移)

@MainActor
struct SleepStatsTests {
    let cal = SL.cal

    @Test func averagesAcrossMidnightAndCountsOnlyUsualSleep() {
        let records = [
            SL.record(S1.date(9, 27, 23, 30), S1.date(9, 28, 6, 30)),   // 9/28 の朝 7時間
            SL.record(S1.date(9, 29, 0, 30), S1.date(9, 29, 7, 30)),    // 9/29 の朝 7時間
            SL.record(S1.date(9, 29, 13), S1.date(9, 29, 14), .nap),    // 仮眠は数えない
        ]
        let nights = SleepRules.nights(records, calendar: cal)
        // 今週 (9/28 月〜) の経過した朝 = 9/28・9/29・9/30
        let stats = SleepRules.stats(nights: nights, firstMorning: S1.date(9, 28), lastMorning: S1.date(10, 4), today: S1.today, calendar: cal)
        #expect(stats.recordedCount == 2 && stats.elapsedCount == 3)
        #expect(stats.averageDuration == TimeInterval(7 * 3600))
        #expect(stats.averageBedtimeMinutes == 0, "23:30 と 0:30 の平均は 0:00 (12:00 にならない)")
        #expect(stats.averageWakeMinutes == 7 * 60)
        // 記録の無い期間
        let empty = SleepRules.stats(nights: [], firstMorning: S1.date(9, 21), lastMorning: S1.date(9, 27), today: S1.today, calendar: cal)
        #expect(empty.recordedCount == 0 && empty.elapsedCount == 7 && empty.averageDuration == nil)
    }

    @Test func movingAverageSkipsMissingNights() {
        let records = [
            SL.record(S1.date(9, 22, 23), S1.date(9, 23, 7)),   // 9/23 の朝 8 時間 (9/30 の 7 朝 = 9/24〜9/30 の外)
            SL.record(S1.date(9, 27, 23), S1.date(9, 28, 5)),   // 9/28 の朝 6 時間
            SL.record(S1.date(9, 28, 23), S1.date(9, 29, 7)),   // 9/29 の朝 8 時間
        ]
        let nights = SleepRules.nights(records, calendar: cal)
        #expect(SleepRules.movingAverage(nights: nights, morning: S1.date(9, 30), calendar: cal) == TimeInterval(7 * 3600), "未入力の朝は分母に入れない")
        #expect(SleepRules.movingAverage(nights: nights, morning: S1.date(9, 22), calendar: cal) == nil)
    }
}

// MARK: - InMemory と store

@MainActor
struct SleepDataSourceTests {
    let cal = SL.cal

    @Test func inMemoryRejectsWithSameRules() async throws {
        let source = S1.source()
        let record = try await source.insertSleepRecord(start: S1.date(9, 29, 23, 30), end: S1.date(9, 30, 7), kind: .sleep)
        await #expect(throws: SleepRuleError.overlap(record.id)) {
            _ = try await source.insertSleepRecord(start: S1.date(9, 30, 6), end: S1.date(9, 30, 8), kind: .nap)
        }
        await #expect(throws: SleepRuleError.future) {
            _ = try await source.insertSleepRecord(start: S1.date(9, 30, 9), end: S1.date(9, 30, 11), kind: .nap)
        }
        await #expect(throws: SleepRuleError.tooLong) {
            _ = try await source.insertSleepRecord(start: S1.date(9, 27, 7), end: S1.date(9, 28, 8), kind: .sleep)
        }
        // 自分とは重ならない扱いで書き換えられる・種別も変えられる
        try await source.updateSleepRecord(id: record.id, start: S1.date(9, 29, 23, 40), end: S1.date(9, 30, 7, 10), kind: .nap)
        #expect(source.snapshot.sleepRecords.first?.kind == .nap && source.snapshot.sleepRecords.first?.startAt == S1.date(9, 29, 23, 40))
        await #expect(throws: SleepRuleError.notFound) {
            try await source.updateSleepRecord(id: UUID(), start: S1.date(9, 28, 23), end: S1.date(9, 29, 7), kind: .sleep)
        }
        let fetched = try await source.fetchSleepRecords(from: S1.date(9, 30), to: S1.date(10, 1))
        #expect(fetched.map(\.id) == [record.id])
        try await source.deleteSleepRecord(id: record.id)
        #expect(source.snapshot.sleepRecords.isEmpty)
        // 予定の実績 (actual_task) には何も書いていない
        #expect(source.snapshot.actualTasks.isEmpty)
    }

    @Test func scheduleStoreRefreshDropsOtherDaysAndReloadsVisible() async throws {
        // V-7: 予定タブで昨日を見たまま睡眠タブで昨夜を直す → 予定タブに戻ると昨日の実績が新しい
        let source = S1.source()
        let store = ScheduleStore(dayDataSource: source, dataSource: source, calendar: cal, holidayChecker: S1.isHoliday)
        await store.ensureLoaded(S1.date(9, 30))
        await store.ensureLoaded(S1.date(9, 29))
        let yesterday = try #require(store.day(S1.date(9, 29)))
        let row = S2.row(yesterday, "睡眠")
        #expect(store.sleepLine(for: row, in: yesterday) == nil)
        _ = try await source.insertSleepRecord(start: S1.date(9, 29, 23, 40), end: S1.date(9, 30, 7, 10), kind: .sleep)
        await store.refresh(S1.date(9, 29))
        #expect(store.day(S1.date(9, 30)) == nil, "見ている日以外のキャッシュは捨てる")
        let reloaded = try #require(store.day(S1.date(9, 29)))
        #expect(store.sleepLine(for: S2.row(reloaded, "睡眠"), in: reloaded) == "実績 23:40–7:10（7時間30分）")
        #expect(store.sleepLine(for: S2.row(reloaded, "ジム"), in: reloaded) == nil)
    }

    @Test func sleepStoreLoadsPlanSavesAndDeletes() async throws {
        let source = S1.source()
        let store = SleepStore(dataSource: source, dayDataSource: source, scheduleDataSource: source, calendar: cal, now: { S1.today })
        await store.ensureLoaded(store.recentRange(today: S1.today))
        #expect(store.isLoaded && store.records.isEmpty)
        await store.loadPlan(today: S1.today)
        #expect(store.plan(nightKey: S1.date(9, 29)) == SleepPlan(start: S1.date(9, 29, 23), end: S1.date(9, 30, 7)))
        // 任意の夜も読める (＋ で起床の日を選んだとき)
        #expect(store.plan(nightKey: S1.date(9, 26)) == nil)
        await store.loadPlan(nightKey: S1.date(9, 26))
        #expect(store.plan(nightKey: S1.date(9, 26)) == SleepPlan(start: S1.date(9, 26, 23), end: S1.date(9, 27, 7)))
        let card = try #require(SleepRules.cardDefault(plan: store.plan(nightKey: S1.date(9, 29)), previous: nil, now: S1.today, calendar: cal))
        #expect(card.start == S1.date(9, 29, 23) && card.end == S1.date(9, 30, 7))
        #expect(await store.save(id: nil, start: card.start, end: card.end, kind: .sleep) == nil)
        #expect(store.records.count == 1 && SleepRules.morning(store.records, today: S1.today, calendar: cal) != nil)
        // 手元の記録と重なる保存は送らずに返す
        let error = await store.save(id: nil, start: S1.date(9, 30, 6), end: S1.date(9, 30, 6, 30), kind: .nap)
        #expect(error as? SleepRuleError == .overlap(store.records[0].id))
        let sleepId = store.records[0].id
        #expect(await store.save(id: nil, start: S1.date(9, 29, 13, 10), end: S1.date(9, 29, 13, 40), kind: .nap) == nil)
        #expect(store.records.map(\.kind) == [.nap, .sleep])
        // 書いた記録は予定タブの読み込みにも出る (同じインスタンス。M-1)
        #expect(try await S1.build(source, S1.date(9, 30)).sleepRecords.map(\.id).contains(sleepId))
        #expect(await store.delete(id: sleepId) == nil)
        #expect(store.records.map(\.kind) == [.nap])
    }

    @Test func sleepStorePlanMissingWhenExcluded() async throws {
        let source = S1.source()
        try await source.apply(.deleteOccurrence(templateId: S1.series(source, "睡眠"), date: S1.date(10, 1)))
        let today = S1.date(10, 2, 7)
        let store = SleepStore(dataSource: source, dayDataSource: source, scheduleDataSource: source, calendar: cal, now: { today })
        await store.loadPlan(today: today)
        #expect(store.plans.keys.contains(S1.date(10, 1)) && store.plan(nightKey: S1.date(10, 1)) == nil)
    }
}
