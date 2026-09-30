import Foundation
import Combine
import WidgetKit

/// 継続の元データ (トレーニングした日の全期間と、週の目標回数の履歴)。
/// 連続日数・リングは保存せず、表示のたびに Continuity で計算する (docs/continuity-design.md)。
/// 今日の分は今日の store のセットから合成する (記録・削除のたびに DB を読み直さない)
@MainActor
final class ContinuityStore: ObservableObject {
    @Published private(set) var trainingDays: Set<Date> = []
    @Published private(set) var goals: [WeeklyGoal] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published var error: Error?

    private let dataSource: WorkoutDataSource
    private let calendar: Calendar
    private var lastShared: ContinuityShare.Snapshot?

    init(dataSource: WorkoutDataSource, calendar: Calendar) {
        self.dataSource = dataSource
        self.calendar = calendar
    }

    func load() async {
        do {
            async let days = dataSource.fetchTrainingDays()
            async let goals = dataSource.fetchWeeklyGoals()
            trainingDays = Set(try await days.map { calendar.startOfDay(for: $0) })
            self.goals = try await goals
            isLoaded = true
        } catch {
            report(error)
        }
    }

    /// 今日の store のセットの有無で今日の分を差し替えた、トレーニングした日
    func days(today: Date, recordedToday: Bool) -> Set<Date> {
        let key = calendar.startOfDay(for: today)
        return trainingDays.subtracting([key]).union(recordedToday ? [key] : [])
    }

    func status(today: Date, recordedToday: Bool) -> ContinuityStatus? {
        Continuity.status(trainingDays: days(today: today, recordedToday: recordedToday), goals: goals, today: today, calendar: calendar)
    }

    var currentTarget: Int? {
        Continuity.target(forWeek: Continuity.weekStart(containing: Date(), calendar: calendar), goals: goals)
    }

    /// 今週から有効な目標にする (同じ週に変えたら上書き)。過去の週は当時の目標のまま
    func setWeeklyTarget(_ target: Int, today: Date) async -> Error? {
        let goal = WeeklyGoal(weeklyTarget: target, effectiveFrom: Continuity.weekStart(containing: today, calendar: calendar))
        isSaving = true
        defer { isSaving = false }
        do {
            try await dataSource.saveWeeklyGoal(goal)
            goals = try await dataSource.fetchWeeklyGoals()
            return nil
        } catch {
            return error
        }
    }

    /// ウィジェットへ渡す。中身が変わったときだけ書いてタイムラインを作り直させる
    func share(today: Date, recordedToday: Bool) {
        guard isLoaded else { return }
        let snapshot = ContinuityShare.Snapshot(trainingDays: days(today: today, recordedToday: recordedToday).sorted(), goals: goals)
        guard snapshot != lastShared else { return }
        lastShared = snapshot
        ContinuityShare.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func report(_ error: Error) {
        guard !WorkoutSessionStore.isCancellation(error) else { return }
        self.error = error
    }
}
