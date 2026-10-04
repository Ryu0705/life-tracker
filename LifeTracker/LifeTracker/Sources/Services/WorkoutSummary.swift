import Foundation

/// トレーニングタブの日・週・組み合わせ・カード見出しの導出。pure (DB / Singleton に触れない)。
/// 日の基準は completed_at の暦日 (WorkoutProgress.daily と同じ。session.started_at は日の判定に使わない)
enum WorkoutSummary {
    /// 週は月曜始まり (Gymwork に合わせる)。端末ロケール (ja_JP は日曜始まり) と calendar.firstWeekday に依存しない
    static let firstWeekday = 2

    static func dayKey(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    static func dayTotals(_ sets: [WorkoutSet]) -> DayTotals {
        let times = sets.compactMap(\.completedAt)
        return DayTotals(
            volume: WorkoutProgress.value(of: .volume, in: sets),
            workingSets: sets.filter { !$0.isWarmup }.count,
            exerciseCount: Set(sets.map(\.exerciseId)).count,
            totalSets: sets.count,
            firstAt: times.min(),
            lastAt: times.max()
        )
    }

    /// "7:02–7:40 · 38分"。最初と最後のセットの時刻から出す (開始操作なし・now を使わない)。2 セット未満は nil
    static func timeRangeText(_ totals: DayTotals, calendar: Calendar) -> String? {
        guard totals.totalSets >= 2, let first = totals.firstAt, let last = totals.lastAt else { return nil }
        func clock(_ date: Date) -> String {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        return "\(clock(first))–\(clock(last)) · \(Int(last.timeIntervalSince(first)) / 60)分"
    }

    /// "9/30(火)"
    static func dayLabel(_ day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day, .weekday], from: day)
        return "\(c.month ?? 0)/\(c.day ?? 0)(\(weekdaySymbol(day, calendar: calendar)))"
    }

    static func weekdaySymbol(_ day: Date, calendar: Calendar) -> String {
        ["日", "月", "火", "水", "木", "金", "土"][calendar.component(.weekday, from: day) - 1]
    }

    static func weekStart(containing day: Date, calendar: Calendar) -> Date {
        let start = dayKey(day, calendar: calendar)
        let offset = (calendar.component(.weekday, from: start) - firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start)!
    }

    static func weekDays(containing day: Date, calendar: Calendar) -> [Date] {
        let start = weekStart(containing: day, calendar: calendar)
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    /// 半開区間 [月 0:00, 翌月 0:00)。DateInterval.contains は閉区間で翌月曜 0:00 を含んでしまうため使わない
    static func weekInterval(containing day: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = weekStart(containing: day, calendar: calendar)
        return (start, calendar.date(byAdding: .day, value: 7, to: start)!)
    }

    /// 今週から数えて過去 count 週の週頭 (新しい順)。組み合わせ用に 28 日前まで = 5 週を読む
    static func recentWeekStarts(today: Date, count: Int, calendar: Calendar) -> [Date] {
        let start = weekStart(containing: today, calendar: calendar)
        return (0..<count).map { calendar.date(byAdding: .day, value: -7 * $0, to: start)! }
    }

    /// 同じ曜日の前後の週へ。未来になるなら今日に丸める
    static func shiftWeek(selected: Date, by weeks: Int, today: Date, calendar: Calendar) -> Date {
        let moved = calendar.date(byAdding: .day, value: 7 * weeks, to: dayKey(selected, calendar: calendar))!
        return min(moved, dayKey(today, calendar: calendar))
    }

    static func isSelectable(day: Date, today: Date, calendar: Calendar) -> Bool {
        dayKey(day, calendar: calendar) <= dayKey(today, calendar: calendar)
    }

    static func recordedDays(_ sets: [WorkoutSet], calendar: Calendar) -> Set<Date> {
        Set(sets.compactMap(\.completedAt).map { dayKey($0, calendar: calendar) })
    }

    /// 履歴の今日の分を今日の store のセットに差し替える (合計バー・週帯・分析の数字を一致させる)
    static func mergeToday(historySets: [WorkoutSet], todaySets: [WorkoutSet], today: Date, calendar: Calendar) -> [WorkoutSet] {
        let todayKey = dayKey(today, calendar: calendar)
        return historySets.filter { $0.completedAt.map { dayKey($0, calendar: calendar) != todayKey } ?? false } + todaySets
    }

    /// 部位は exercise.muscleGroup (1 種目 1 部位)。種目マスタに無い (アーカイブ済み) 種目は部位別に出さない。
    /// through を渡すと、その日 (を含む) までに絞る (週の途中の前週比: 前週の同じ曜日までと比べる。D-4)
    static func weekTotals(sets: [WorkoutSet], exercisesById: [UUID: Exercise], week: Date, through: Date? = nil,
                           calendar: Calendar) -> WeekTotals {
        let interval = weekInterval(containing: week, calendar: calendar)
        let end = through.flatMap { calendar.date(byAdding: .day, value: 1, to: dayKey($0, calendar: calendar)) }
            .map { min($0, interval.end) } ?? interval.end
        let inWeek = sets.filter { $0.completedAt.map { interval.start <= $0 && $0 < end } ?? false }
        let known = inWeek.compactMap { set in exercisesById[set.exerciseId].map { (set, $0.muscleGroup) } }
        let byDay = Dictionary(grouping: known) { DayMuscleKey(day: dayKey($0.0.completedAt!, calendar: calendar), muscle: $0.1) }
        let byDayMuscle = byDay
            .map { key, entries in WeekTotals.DayMuscle(day: key.day, muscle: key.muscle, volume: WorkoutProgress.value(of: .volume, in: entries.map(\.0)) ?? 0) }
            .sorted { ($0.day, muscleOrder($0.muscle)) < ($1.day, muscleOrder($1.muscle)) }
        let counts = Dictionary(grouping: known.filter { !$0.0.isWarmup }, by: \.1)
            .map { WeekTotals.MuscleCount(muscle: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.muscle.displayName) < ($0.count, $1.muscle.displayName) }
        return WeekTotals(
            volume: WorkoutProgress.value(of: .volume, in: inWeek),
            byDayMuscle: byDayMuscle,
            workingSetsByMuscle: counts,
            totalWorkingSets: inWeek.filter { !$0.isWarmup }.count
        )
    }

    /// 前週比 (%)。前週が無い / 0 なら nil
    static func volumeChange(current: Double, previous: Double?) -> Int? {
        guard let previous, previous > 0 else { return nil }
        return Int(((current - previous) / previous * 100).rounded())
    }

    /// 種目ごとの「今日より前で最も新しい日」のセット (プログラムの確認シートの前回表示)。
    /// 読み込み済みの期間 (履歴 store の先読み分) の中だけで探す
    static func latestDaySets(_ sets: [WorkoutSet], today: Date, calendar: Calendar) -> [UUID: [WorkoutSet]] {
        let todayKey = dayKey(today, calendar: calendar)
        var result: [UUID: [WorkoutSet]] = [:]
        for (exerciseId, entries) in Dictionary(grouping: sets.filter { $0.completedAt != nil }, by: \.exerciseId) {
            if let latest = WorkoutProgress.daily(entries, calendar: calendar).first(where: { $0.day < todayKey }) {
                result[exerciseId] = latest.sets
            }
        }
        return result
    }

    /// 1 日分の同じ種目のセットの表記: カード (entry) ごとに「 / 」で、カードの間は「 ｜ 」で区切る
    /// (例「60×10 / 65×8 ｜ 50×12 / 50×10」)。ウォームアップには「W 」を付けるかを選べる
    static func blocksText(_ sets: [WorkoutSet], kind: MetricKind, entriesById: [UUID: WorkoutEntry], markWarmup: Bool) -> String {
        WorkoutLogic.blocks(of: sets, entriesById: entriesById)
            .map { block in block.map { (markWarmup && $0.isWarmup ? "W " : "") + WorkoutLogic.summary(of: $0, kind: kind) }.joined(separator: " / ") }
            .joined(separator: " ｜ ")
    }

    /// カード見出しのサブ行。weight_reps は「今日 1,105kg · e1RM 69kg（前回 67.5kg）」、今日の本番が無ければ「前回 e1RM 67.5kg」
    static func cardHeadline(kind: MetricKind, todaySets: [WorkoutSet], previousSets: [WorkoutSet]) -> String? {
        let metric = headlineMetric(kind: kind, sets: todaySets + previousSets)
        let previous = WorkoutProgress.value(of: metric, in: previousSets).map(metric.format)
        if let today = setsSummary(kind: kind, sets: todaySets, metric: metric) {
            return "今日 \(today)" + (previous.map { "（前回 \($0)）" } ?? "")
        }
        return previous.map { "前回 \(shortLabel(metric)) \($0)" }
    }

    /// 過去日のカード用: 「1,105kg · e1RM 69kg」/「最多 12回」
    static func setsSummary(kind: MetricKind, sets: [WorkoutSet]) -> String? {
        setsSummary(kind: kind, sets: sets, metric: headlineMetric(kind: kind, sets: sets))
    }

    private static func setsSummary(kind: MetricKind, sets: [WorkoutSet], metric: ProgressMetric) -> String? {
        if kind == .weightReps {
            guard let volume = WorkoutProgress.value(of: .volume, in: sets),
                  let oneRM = WorkoutProgress.value(of: .estimatedOneRM, in: sets) else { return nil }
            return "\(ProgressMetric.volume.format(volume)) · e1RM \(ProgressMetric.estimatedOneRM.format(oneRM))"
        }
        return WorkoutProgress.value(of: metric, in: sets).map { "\(shortLabel(metric)) \(metric.format($0))" }
    }

    /// weight_reps は推定1RM、それ以外は推移グラフの初期指標 (値がある最初の指標。距離なしの有酸素は時間)
    private static func headlineMetric(kind: MetricKind, sets: [WorkoutSet]) -> ProgressMetric {
        if kind == .weightReps { return .estimatedOneRM }
        let available = ProgressMetric.available(for: kind)
        return available.first { WorkoutProgress.value(of: $0, in: sets) != nil } ?? available[0]
    }

    private static func shortLabel(_ metric: ProgressMetric) -> String {
        switch metric {
        case .estimatedOneRM: return "e1RM"
        case .maxReps: return "最多"
        case .maxDuration: return "最長"
        default: return metric.displayName
        }
    }

    private struct DayMuscleKey: Hashable {
        let day: Date
        let muscle: Exercise.MuscleGroup
    }

    private static func muscleOrder(_ muscle: Exercise.MuscleGroup) -> Int {
        Exercise.MuscleGroup.allCases.firstIndex(of: muscle) ?? 0
    }
}
