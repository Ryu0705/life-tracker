import Foundation

/// 週の目標回数 (その週から有効)。effectiveFrom は週頭 (月曜 0:00)
nonisolated struct WeeklyGoal: Codable, Hashable {
    var weeklyTarget: Int
    var effectiveFrom: Date
}

/// 継続の表示 (連続週数・今週のリング・今週 7 日の点)
nonisolated struct ContinuityStatus: Equatable {
    /// 連続週数 = 前週から遡って目標を満たした週が続いた数 + 今週が目標に届いていれば 1。0 = 連続なし
    let streakWeeks: Int
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
/// 週は月曜始まり。目標を満たした週が続くかぎり休息日で途切れず (数えもしない)、N 回に届かず週が終わった時点で途切れる。
/// 2026-10-16 本人変更: 連続は日数ではなく、目標を満たした週の数 (日数だと前週が未達のとき今週の回数と同じ数字になる)
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

        // 前週から遡って、目標を満たした週が続く数を数える (前週が未達なら 0)。今週は目標に届いた時点で 1 足す
        var achievedWeeks = 0
        var week = calendar.date(byAdding: .day, value: -7, to: currentWeek)!
        let oldest = days.min() ?? todayKey
        while week >= weekStart(containing: oldest, calendar: calendar),
              let target = target(forWeek: week, goals: goals),
              (byWeek[week]?.count ?? 0) >= target {
            achievedWeeks += 1
            week = calendar.date(byAdding: .day, value: -7, to: week)!
        }

        let weekDays = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: currentWeek)! }
        let thisWeek = byWeek[currentWeek] ?? []
        let daysLeft = weekDays.filter { $0 >= todayKey }.count
        return ContinuityStatus(
            streakWeeks: achievedWeeks + (thisWeek.count >= currentTarget ? 1 : 0),
            weekCount: thisWeek.count,
            weekTarget: currentTarget,
            weekDone: weekDays.map { thisWeek.contains($0) },
            daysLeftInWeek: daysLeft
        )
    }
}

/// アプリ → ウィジェットの受け渡し (App Group の UserDefaults)。数字ではなく元データを渡し、
/// ウィジェット側で日付・週の切り替わりごとに計算し直す。
/// サインインしているかは Snapshot とは別のキー (Snapshot の形を変えると今の保存が読めなくなるため。計画 §2-6・P8)
nonisolated enum ContinuityShare {
    static let appGroup = "group.com.ryunosuke.LifeTracker"
    static let snapshotKey = "continuity.v1"
    /// サインインしているか (Bool)。サインアウトで false、サインインで true
    static let signedInKey = "auth.signedIn.v1"

    struct Snapshot: Codable, Equatable {
        var trainingDays: [Date]
        var goals: [WeeklyGoal]
    }

    /// App Group の UserDefaults (テストは別の UserDefaults を差し込む)
    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func save(_ snapshot: Snapshot, defaults: UserDefaults? = ContinuityShare.sharedDefaults) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func load(defaults: UserDefaults? = ContinuityShare.sharedDefaults) -> Snapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// スナップショットを消す (サインアウトの後片付け。前の人の記録をウィジェットに残さない)
    static func clearSnapshot(defaults: UserDefaults? = ContinuityShare.sharedDefaults) {
        defaults?.removeObject(forKey: snapshotKey)
    }

    /// サインインしているか。キーが無い (サインインの入る前のビルドから移った直後) ときはサインイン済みとみなす
    /// (新しいビルドを入れた直後に、ウィジェットが「サインインしてください」に変わらないように)
    static func isSignedIn(defaults: UserDefaults? = ContinuityShare.sharedDefaults) -> Bool {
        guard let value = defaults?.object(forKey: signedInKey) as? Bool else { return true }
        return value
    }

    static func setSignedIn(_ signedIn: Bool, defaults: UserDefaults? = ContinuityShare.sharedDefaults) {
        defaults?.set(signedIn, forKey: signedInKey)
    }
}
