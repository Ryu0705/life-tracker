import Testing
import Foundation
@testable import LifeTracker

@Suite("Continuity — 週 N 回基準の連続日数・今週のリング")
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

    @Test("休みの日があっても、週 N 回に届いた週が続くかぎり休息日も含めて数える")
    func restDaysDoNotBreak() throws {
        // 先週 月水金 (3/3 達成)、今週は月だけ。今日は水曜
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25), day(9, 28)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 30, hour: 20), calendar: calendar))
        #expect(status.streakDays == 10) // 9/21〜9/30
        #expect(status.weekCount == 1 && status.weekTarget == 3 && status.remaining == 2)
        #expect(status.daysLeftInWeek == 5) // 水〜日
        #expect(status.weekDone == [true, false, false, false, false, false, false])
        #expect(!status.isWeekAchieved)
    }

    @Test("今週まだ届いていなくても、週が終わるまでは途切れない (月曜でまだ 0 回でも続く)")
    func currentWeekPendingKeepsStreak() throws {
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 28), calendar: calendar))
        #expect(status.streakDays == 8) // 9/21〜9/28
        #expect(status.weekCount == 0 && status.daysLeftInWeek == 7)
    }

    @Test("N 回に届かずに週が終わると途切れ、今週の最初のトレーニング日から数え直す")
    func weekEndBreaks() throws {
        let goals = [goal(3, from: day(9, 14))]
        // 9/14 週 3 回 (達成)、9/21 週 2 回 (未達)、今週は火曜に 1 回
        let days: Set<Date> = [day(9, 14), day(9, 16), day(9, 18), day(9, 21), day(9, 23), day(9, 29)]
        let status = try #require(Continuity.status(trainingDays: days, goals: goals, today: day(9, 30), calendar: calendar))
        #expect(status.streakDays == 2) // 9/29〜9/30
        // 今週まだ 0 回なら 0
        let none = try #require(Continuity.status(trainingDays: days.subtracting([day(9, 29)]), goals: goals, today: day(9, 30), calendar: calendar))
        #expect(none.streakDays == 0)
    }

    @Test("目標を変えても過去の週は当時の目標で判定する。最初の目標より前の週は最初の目標で判定する")
    func goalHistory() throws {
        // 9/14 週 2 回、9/21 週 4 回、今日 9/30 (今週 0 回)
        let days: Set<Date> = [day(9, 15), day(9, 17), day(9, 21), day(9, 22), day(9, 24), day(9, 26)]
        // 目標 3 だけ (9/21〜): 9/14 週は最初の目標 3 で判定 → 未達。連続は 9/21 から
        let onlyThree = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 30), calendar: calendar))
        #expect(onlyThree.streakDays == 10)
        // 9/14〜 は週 2、9/21〜 は週 3: 9/14 週も達成 → 連続は 9/15 から
        let history = [goal(2, from: day(9, 14)), goal(3, from: day(9, 21))]
        let withHistory = try #require(Continuity.status(trainingDays: days, goals: history, today: day(9, 30), calendar: calendar))
        #expect(withHistory.streakDays == 16)
        #expect(withHistory.weekTarget == 3)
        // 今週から週 5 に上げても、過去の連続は消えない
        let raised = try #require(Continuity.status(trainingDays: days, goals: history + [goal(5, from: day(9, 28))], today: day(9, 30), calendar: calendar))
        #expect(raised.streakDays == 16 && raised.weekTarget == 5)
    }

    @Test("今週達成したらリングは満ちる。未来の日付は数えない")
    func achievedAndFuture() throws {
        let days: Set<Date> = [day(9, 28), day(9, 29), day(10, 2)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(2, from: day(9, 28))], today: day(9, 29), calendar: calendar))
        #expect(status.weekCount == 2 && status.isWeekAchieved && status.progress == 1)
        #expect(status.streakDays == 2)
    }

    @Test("記録がまったく無ければ連続 0")
    func empty() throws {
        let status = try #require(Continuity.status(trainingDays: [], goals: [goal(3, from: day(9, 28))], today: day(9, 30), calendar: calendar))
        #expect(status.streakDays == 0 && status.weekCount == 0)
    }

    @Test("ヒートマップの段階: 記録なし 0、あとはボリュームの 4 分位で 1〜4")
    func heatmapLevels() {
        let thresholds = TrainingHeatmap.thresholds([1000, 2000, 3000, 4000])
        #expect(TrainingHeatmap.level(nil, thresholds: thresholds) == 0)
        #expect(TrainingHeatmap.level(0, thresholds: thresholds) == 0)
        #expect(TrainingHeatmap.level(1000, thresholds: thresholds) == 1)
        #expect(TrainingHeatmap.level(4000, thresholds: thresholds) == 4)
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
