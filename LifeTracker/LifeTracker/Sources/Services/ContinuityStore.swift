import Foundation
import Combine
import WidgetKit

/// 継続の元データ (トレーニングした日の全期間と、週の目標回数の履歴)。
/// 連続週数・リングは保存せず、表示のたびに Continuity で計算する (docs/continuity-design.md)。
/// 開いている日 (今日と、開いていれば前の日) の分は記録の store のセットから合成する (記録・削除のたびに DB を読み直さない)。
/// 日はセットの day (トレーニングの日。前の日に 0:30 に記録すると前の日の週の回数に入る)
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

    /// 開いている日の分を記録の store に差し替えた、トレーニングした日。
    /// live = 開いている日 → その日に記録の store のセットがあるか (DB の分から開いている日を除き、記録がある日を足す)
    func days(live: [Date: Bool]) -> Set<Date> {
        let open = Set(live.keys.map { calendar.startOfDay(for: $0) })
        let recorded = live.filter(\.value).keys.map { calendar.startOfDay(for: $0) }
        return trainingDays.subtracting(open).union(recorded)
    }

    func status(today: Date, live: [Date: Bool]) -> ContinuityStatus? {
        Continuity.status(trainingDays: days(live: live), goals: goals, today: today, calendar: calendar)
    }

    /// 今週の目標 (today は記録の store の今日。-mock-now でずらした時計でも同じ週を見る)
    func currentTarget(today: Date) -> Int? {
        Continuity.target(forWeek: Continuity.weekStart(containing: today, calendar: calendar), goals: goals)
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
    func share(live: [Date: Bool]) {
        guard isLoaded else { return }
        let snapshot = ContinuityShare.Snapshot(trainingDays: days(live: live).sorted(), goals: goals)
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
