import Foundation

/// 週の目標回数 (その週から有効)。effectiveFrom は週頭 (月曜 0:00)
nonisolated struct WeeklyGoal: Codable, Hashable {
    var weeklyTarget: Int
    var effectiveFrom: Date
}

/// 継続の表示 (連続日数・今週のリング・今週 7 日の点)
nonisolated struct ContinuityStatus: Equatable {
    /// 連続日数 (休息日も含む)。0 = 連続なし
    let streakDays: Int
    let weekCount: Int
    let weekTarget: Int
    /// 今週の月〜日にトレーニングした日があるか (7 要素)
    let weekDone: [Bool]
    /// 今日を含めた今週の残り日数
    let daysLeftInWeek: Int

    var remaining: Int { max(0, weekTarget - weekCount) }
    var progress: Double { weekTarget > 0 ? min(1, Double(weekCount) / Double(weekTarget)) : 0 }
    var isWeekAchieved: Bool { weekCount >= weekTarget }
}

/// 週 N 回の目標を基準にした継続の計算。pure (アプリとウィジェットで共有)。
/// 週は月曜始まり。目標を満たした週が続くかぎり休息日も連続に数え、N 回に届かず週が終わった時点で途切れる
nonisolated enum Continuity {
    static func weekStart(containing day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        let offset = (calendar.component(.weekday, from: start) - 2 + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start)!
    }

    /// その週に有効な目標。最初の目標より前の週は最初の目標で判定する
    static func target(forWeek week: Date, goals: [WeeklyGoal]) -> Int? {
        let sorted = goals.sorted { $0.effectiveFrom < $1.effectiveFrom }
        return (sorted.last { $0.effectiveFrom <= week } ?? sorted.first)?.weeklyTarget
    }

    /// trainingDays はトレーニングした日 (startOfDay)。目標が無ければ nil
    static func status(trainingDays: Set<Date>, goals: [WeeklyGoal], today: Date, calendar: Calendar) -> ContinuityStatus? {
        let todayKey = calendar.startOfDay(for: today)
        let currentWeek = weekStart(containing: todayKey, calendar: calendar)
        guard let currentTarget = target(forWeek: currentWeek, goals: goals) else { return nil }
        let days = trainingDays.map { calendar.startOfDay(for: $0) }.filter { $0 <= todayKey }
        let byWeek = Dictionary(grouping: days) { weekStart(containing: $0, calendar: calendar) }.mapValues { Set($0) }

        // 前週から遡って、目標を満たした週が続く最古の週を探す (前週が未達なら今週が起点)
        var chainStart = currentWeek
        var week = calendar.date(byAdding: .day, value: -7, to: currentWeek)!
        let oldest = days.min() ?? todayKey
        while week >= weekStart(containing: oldest, calendar: calendar),
              let target = target(forWeek: week, goals: goals),
              (byWeek[week]?.count ?? 0) >= target {
            chainStart = week
            week = calendar.date(byAdding: .day, value: -7, to: week)!
        }
        let streakDays: Int
        if let first = days.filter({ $0 >= chainStart }).min() {
            streakDays = (calendar.dateComponents([.day], from: first, to: todayKey).day ?? 0) + 1
        } else {
            streakDays = 0
        }

        let weekDays = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: currentWeek)! }
        let thisWeek = byWeek[currentWeek] ?? []
        let daysLeft = weekDays.filter { $0 >= todayKey }.count
        return ContinuityStatus(
            streakDays: streakDays,
            weekCount: thisWeek.count,
            weekTarget: currentTarget,
            weekDone: weekDays.map { thisWeek.contains($0) },
            daysLeftInWeek: daysLeft
        )
    }
}

/// アプリ → ウィジェットの受け渡し (App Group の UserDefaults)。数字ではなく元データを渡し、
/// ウィジェット側で日付・週の切り替わりごとに計算し直す
nonisolated enum ContinuityShare {
    static let appGroup = "group.com.ryunosuke.LifeTracker"
    private static let key = "continuity.v1"

    struct Snapshot: Codable, Equatable {
        var trainingDays: [Date]
        var goals: [WeeklyGoal]
    }

    static func save(_ snapshot: Snapshot) {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> Snapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
