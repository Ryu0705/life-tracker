import Testing
import Foundation
@testable import LifeTracker

@Suite("Continuity — 週 N 回基準の連続週数 (目標を満たした週の数)・今週のリング")
struct ContinuityTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// 2026-09-28 は月曜
    func day(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    func goal(_ target: Int, from monday: Date) -> WeeklyGoal {
        WeeklyGoal(weeklyTarget: target, effectiveFrom: monday)
    }

    @Test("目標が無ければ出さない")
    func noGoal() {
        #expect(Continuity.status(trainingDays: [day(9, 28)], goals: [], today: day(9, 30), calendar: calendar) == nil)
    }

    @Test("休みの日があっても、週 N 回に届いた週が続くかぎり途切れない。数えるのは届いた週")
    func restDaysDoNotBreak() throws {
        // 先週 月水金 (3/3 達成)、今週は月だけ。今日は水曜
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25), day(9, 28)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 30, hour: 20), calendar: calendar))
        #expect(status.streakWeeks == 1) // 9/21 の週
        #expect(status.weekCount == 1 && status.weekTarget == 3 && status.remaining == 2)
        #expect(status.daysLeftInWeek == 5) // 水〜日
        #expect(status.weekDone == [true, false, false, false, false, false, false])
        #expect(!status.isWeekAchieved)
    }

    @Test("今週まだ届いていなくても、週が終わるまでは途切れない (月曜でまだ 0 回でも続く)")
    func currentWeekPendingKeepsStreak() throws {
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 28), calendar: calendar))
        #expect(status.streakWeeks == 1)
        #expect(status.weekCount == 0 && status.daysLeftInWeek == 7)
    }

    @Test("届いた週が続けば 1 週ずつ増え、今週は目標に届いた時点で 1 足す")
    func consecutiveWeeksCount() throws {
        let goals = [goal(2, from: day(9, 7))]
        // 9/7・9/14・9/21 の週に 2 回ずつ (3 週連続)、今週は月曜に 1 回
        let past: Set<Date> = [day(9, 8), day(9, 10), day(9, 15), day(9, 17), day(9, 22), day(9, 24), day(9, 28)]
        let pending = try #require(Continuity.status(trainingDays: past, goals: goals, today: day(9, 30), calendar: calendar))
        #expect(pending.streakWeeks == 3 && pending.weekCount == 1)
        let achieved = try #require(Continuity.status(trainingDays: past.union([day(9, 30, hour: 7)]), goals: goals, today: day(9, 30, hour: 20), calendar: calendar))
        #expect(achieved.streakWeeks == 4 && achieved.weekCount == 2)
    }

    @Test("前週が未達なら、今週の回数とは別に 0 から (2026-10-16 本人報告: 炎の数字が n/m の n と同じになる)")
    func freshStartDiffersFromWeekCount() throws {
        let goals = [goal(4, from: day(9, 21))]
        // 先週 2 回 (未達)、今週 2 回
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 28), day(9, 29)]
        let status = try #require(Continuity.status(trainingDays: days, goals: goals, today: day(9, 30), calendar: calendar))
        #expect(status.weekCount == 2 && status.streakWeeks == 0)
    }

    @Test("N 回に届かずに週が終わると 0 に戻り、今週が届いた時点で 1 週")
    func weekEndBreaks() throws {
        let goals = [goal(3, from: day(9, 14))]
        // 9/14 週 3 回 (達成)、9/21 週 2 回 (未達)、今週は火曜に 1 回
        let days: Set<Date> = [day(9, 14), day(9, 16), day(9, 18), day(9, 21), day(9, 23), day(9, 29)]
        let status = try #require(Continuity.status(trainingDays: days, goals: goals, today: day(9, 30), calendar: calendar))
        #expect(status.streakWeeks == 0)
        let restarted = try #require(Continuity.status(trainingDays: days.union([day(9, 30), day(10, 1)]), goals: goals, today: day(10, 1), calendar: calendar))
        #expect(restarted.streakWeeks == 1) // 9/14 の週は 9/21 の未達で切れたまま
    }

    @Test("目標を変えても過去の週は当時の目標で判定する。最初の目標より前の週は最初の目標で判定する")
    func goalHistory() throws {
        // 9/14 週 2 回、9/21 週 4 回、今日 9/30 (今週 0 回)
        let days: Set<Date> = [day(9, 15), day(9, 17), day(9, 21), day(9, 22), day(9, 24), day(9, 26)]
        // 目標 3 だけ (9/21〜): 9/14 週は最初の目標 3 で判定 → 未達。連続は 9/21 の週だけ
        let onlyThree = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 30), calendar: calendar))
        #expect(onlyThree.streakWeeks == 1)
        // 9/14〜 は週 2、9/21〜 は週 3: 9/14 週も達成 → 2 週
        let history = [goal(2, from: day(9, 14)), goal(3, from: day(9, 21))]
        let withHistory = try #require(Continuity.status(trainingDays: days, goals: history, today: day(9, 30), calendar: calendar))
        #expect(withHistory.streakWeeks == 2)
        #expect(withHistory.weekTarget == 3)
        // 今週から週 5 に上げても、過去の連続は消えない
        let raised = try #require(Continuity.status(trainingDays: days, goals: history + [goal(5, from: day(9, 28))], today: day(9, 30), calendar: calendar))
        #expect(raised.streakWeeks == 2 && raised.weekTarget == 5)
    }

    @Test("今週達成したらリングは満ちる。未来の日付は数えない")
    func achievedAndFuture() throws {
        let days: Set<Date> = [day(9, 28), day(9, 29), day(10, 2)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(2, from: day(9, 28))], today: day(9, 29), calendar: calendar))
        #expect(status.weekCount == 2 && status.isWeekAchieved && status.progress == 1)
        #expect(status.streakWeeks == 1)
        // 未来の 10/2 だけでは届かない
        let before = try #require(Continuity.status(trainingDays: days, goals: [goal(2, from: day(9, 28))], today: day(9, 28), calendar: calendar))
        #expect(before.weekCount == 1 && before.streakWeeks == 0)
    }

    @Test("休んだ日は増えない (2026-10-10 本人報告のウィジェットの不具合)。週の途中のトレーニングでも増えない")
    func restDayDoesNotIncrement() throws {
        // 先週 月水金 (3/3 達成)、今週は月だけ。水曜・木曜・日曜のどれで見ても同じ数
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25), day(9, 28)]
        let goals = [goal(3, from: day(9, 21))]
        let counts = try [day(9, 30), day(10, 1), day(10, 4, hour: 23)].map {
            try #require(Continuity.status(trainingDays: days, goals: goals, today: $0, calendar: calendar)).streakWeeks
        }
        #expect(counts == [1, 1, 1])
        // 今週 2 回目では増えず、同じ日に何度記録しても 1 回
        let twice = try #require(Continuity.status(trainingDays: days.union([day(10, 1, hour: 7), day(10, 1, hour: 19)]), goals: goals, today: day(10, 1, hour: 20), calendar: calendar))
        #expect(twice.weekCount == 2 && twice.streakWeeks == 1)
        // 3 回目で今週が届き 2 週
        let third = try #require(Continuity.status(trainingDays: days.union([day(10, 1), day(10, 3)]), goals: goals, today: day(10, 3), calendar: calendar))
        #expect(third.streakWeeks == 2)
        // 今週 1 回のまま週が終わると、翌週の月曜に 0 へ
        let broken = try #require(Continuity.status(trainingDays: days, goals: goals, today: day(10, 5), calendar: calendar))
        #expect(broken.streakWeeks == 0)
    }

    @Test("記録がまったく無ければ連続 0")
    func empty() throws {
        let status = try #require(Continuity.status(trainingDays: [], goals: [goal(3, from: day(9, 28))], today: day(9, 30), calendar: calendar))
        #expect(status.streakWeeks == 0 && status.weekCount == 0)
    }

    @Test("ヒートマップの段階: 記録なし 0、あとはボリュームの 4 分位で 1〜4")
    func heatmapLevels() {
        let thresholds = TrainingHeatmap.thresholds([1000, 2000, 3000, 4000])
        #expect(TrainingHeatmap.level(nil, thresholds: thresholds) == 0)
        #expect(TrainingHeatmap.level(0, thresholds: thresholds) == 0)
        #expect(TrainingHeatmap.level(1000, thresholds: thresholds) == 1)
        #expect(TrainingHeatmap.level(4000, thresholds: thresholds) == 4)
    }

    @Test("ヒートマップの色の基準の窓: 今週を含む 26 個の月曜 (JST・古い順)。25 週だけ読めていてもそろっていない")
    func heatmapWindowWeekStarts() {
        let weeks = TrainingHeatmap.windowWeekStarts(today: day(10, 11, hour: 23), calendar: calendar)
        #expect(weeks.count == 26)
        #expect(weeks.last == day(10, 5))
        #expect(weeks.first == calendar.date(byAdding: .day, value: -7 * 25, to: day(10, 5)))
        #expect(weeks == weeks.sorted())
        #expect(weeks.allSatisfy { calendar.component(.weekday, from: $0) == 2 && calendar.component(.hour, from: $0) == 0 })
        // 月曜 0:00 で次の週に進む
        #expect(TrainingHeatmap.windowWeekStarts(today: day(10, 12), calendar: calendar).last == day(10, 12))
        let loaded = Set(weeks.dropFirst())
        #expect(!weeks.allSatisfy { loaded.contains($0) })
        #expect(weeks.allSatisfy { loaded.union([weeks[0]]).contains($0) })
    }

    @Test("目標の保存は今週の週頭で、同じ週に変えたら上書き")
    @MainActor
    func saveGoalSameWeekOverwrites() async throws {
        let source = MockWorkoutDataSource()
        let store = ContinuityStore(dataSource: source, calendar: calendar)
        await store.load()
        #expect(await store.setWeeklyTarget(3, today: day(9, 30, hour: 12)) == nil)
        #expect(await store.setWeeklyTarget(4, today: day(10, 1)) == nil)
        #expect(store.goals == [goal(4, from: day(9, 28))])
        #expect(await store.setWeeklyTarget(2, today: day(10, 5)) == nil)
        #expect(store.goals.map(\.weeklyTarget) == [4, 2])
    }
}
