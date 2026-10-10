import Testing
import Foundation
@testable import LifeTracker

@Suite("Continuity — 週 N 回基準の連続日数 (トレーニングした日の数)・今週のリング")
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

    @Test("休みの日があっても、週 N 回に届いた週が続くかぎり途切れない。数えるのはトレーニングした日だけ")
    func restDaysDoNotBreak() throws {
        // 先週 月水金 (3/3 達成)、今週は月だけ。今日は水曜
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25), day(9, 28)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 30, hour: 20), calendar: calendar))
        #expect(status.streakDays == 4) // 9/21・23・25・28
        #expect(status.weekCount == 1 && status.weekTarget == 3 && status.remaining == 2)
        #expect(status.daysLeftInWeek == 5) // 水〜日
        #expect(status.weekDone == [true, false, false, false, false, false, false])
        #expect(!status.isWeekAchieved)
    }

    @Test("今週まだ届いていなくても、週が終わるまでは途切れない (月曜でまだ 0 回でも続く)")
    func currentWeekPendingKeepsStreak() throws {
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(3, from: day(9, 21))], today: day(9, 28), calendar: calendar))
        #expect(status.streakDays == 3) // 9/21・23・25
        #expect(status.weekCount == 0 && status.daysLeftInWeek == 7)
    }

    @Test("N 回に届かずに週が終わると途切れ、今週の最初のトレーニング日から数え直す")
    func weekEndBreaks() throws {
        let goals = [goal(3, from: day(9, 14))]
        // 9/14 週 3 回 (達成)、9/21 週 2 回 (未達)、今週は火曜に 1 回
        let days: Set<Date> = [day(9, 14), day(9, 16), day(9, 18), day(9, 21), day(9, 23), day(9, 29)]
        let status = try #require(Continuity.status(trainingDays: days, goals: goals, today: day(9, 30), calendar: calendar))
        #expect(status.streakDays == 1) // 9/29
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
        #expect(onlyThree.streakDays == 4) // 9/21・22・24・26
        // 9/14〜 は週 2、9/21〜 は週 3: 9/14 週も達成 → 連続は 9/15 から
        let history = [goal(2, from: day(9, 14)), goal(3, from: day(9, 21))]
        let withHistory = try #require(Continuity.status(trainingDays: days, goals: history, today: day(9, 30), calendar: calendar))
        #expect(withHistory.streakDays == 6) // 9/15 から 6 日
        #expect(withHistory.weekTarget == 3)
        // 今週から週 5 に上げても、過去の連続は消えない
        let raised = try #require(Continuity.status(trainingDays: days, goals: history + [goal(5, from: day(9, 28))], today: day(9, 30), calendar: calendar))
        #expect(raised.streakDays == 6 && raised.weekTarget == 5)
    }

    @Test("今週達成したらリングは満ちる。未来の日付は数えない")
    func achievedAndFuture() throws {
        let days: Set<Date> = [day(9, 28), day(9, 29), day(10, 2)]
        let status = try #require(Continuity.status(trainingDays: days, goals: [goal(2, from: day(9, 28))], today: day(9, 29), calendar: calendar))
        #expect(status.weekCount == 2 && status.isWeekAchieved && status.progress == 1)
        #expect(status.streakDays == 2)
    }

    @Test("休んだ日は連続日数が増えない (2026-10-10 本人報告のウィジェットの不具合)")
    func restDayDoesNotIncrement() throws {
        // 先週 月水金 (3/3 達成)、今週は月だけ。水曜・木曜・日曜のどれで見ても同じ数
        let days: Set<Date> = [day(9, 21), day(9, 23), day(9, 25), day(9, 28)]
        let goals = [goal(3, from: day(9, 21))]
        let counts = try [day(9, 30), day(10, 1), day(10, 4, hour: 23)].map {
            try #require(Continuity.status(trainingDays: days, goals: goals, today: $0, calendar: calendar)).streakDays
        }
        #expect(counts == [4, 4, 4])
        // トレーニングした日にだけ 1 増える
        let trained = try #require(Continuity.status(trainingDays: days.union([day(10, 1, hour: 7)]), goals: goals, today: day(10, 1, hour: 20), calendar: calendar))
        #expect(trained.streakDays == 5)
        // 同じ日に何度記録しても 1 日
        let twice = try #require(Continuity.status(trainingDays: days.union([day(10, 1, hour: 7), day(10, 1, hour: 19)]), goals: goals, today: day(10, 1, hour: 20), calendar: calendar))
        #expect(twice.streakDays == 5)
        // 今週 1 回のまま週が終わると、翌週の月曜に 0 へ
        let broken = try #require(Continuity.status(trainingDays: days, goals: goals, today: day(10, 5), calendar: calendar))
        #expect(broken.streakDays == 0)
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
