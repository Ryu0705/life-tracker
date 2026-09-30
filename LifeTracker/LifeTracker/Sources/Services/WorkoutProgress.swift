import Foundation

/// 推移グラフの指標。ウェイト種目は切り替えで全部見られる (2026-09-30 本人選択)
enum ProgressMetric: String, CaseIterable, Identifiable {
    case maxWeight
    case estimatedOneRM
    case volume
    case maxReps
    case maxDuration
    case maxDistance
    case totalDuration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .maxWeight: return "最高重量"
        case .estimatedOneRM: return "推定1RM"
        case .volume: return "ボリューム"
        case .maxReps: return "最多回数"
        case .maxDuration: return "最長時間"
        case .maxDistance: return "距離"
        case .totalDuration: return "時間"
        }
    }

    /// 先頭が初期表示
    static func available(for kind: MetricKind) -> [ProgressMetric] {
        switch kind {
        case .weightReps: return [.maxWeight, .estimatedOneRM, .volume]
        case .repsOnly: return [.maxReps]
        case .duration: return [.maxDuration]
        case .durationDistance: return [.maxDistance, .totalDuration]
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .maxWeight, .estimatedOneRM:
            return "\(WorkoutLogic.formatWeight((value * 10).rounded() / 10))kg"
        case .volume:
            return "\(WorkoutLogic.formatVolume(value))kg"
        case .maxReps:
            return "\(Int(value))回"
        case .maxDuration, .totalDuration:
            return WorkoutLogic.formatDuration(Int(value))
        case .maxDistance:
            return WorkoutLogic.formatDistance(value)
        }
    }
}

/// 1 日分のセット (JST の暦日でまとめる。1 日 = 1 セッションの運用)
struct DailySets: Identifiable, Equatable {
    let day: Date
    let sets: [WorkoutSet]
    var id: Date { day }
}

/// 前回参照・推移・履歴の導出。pure (DB / Singleton に触れない)
enum WorkoutProgress {
    /// 日ごとにまとめる。新しい日が先頭、日の中は記録順
    static func daily(_ sets: [WorkoutSet], calendar: Calendar) -> [DailySets] {
        let dated = sets.filter { $0.completedAt != nil }
        let grouped = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.completedAt!) }
        return grouped
            .map { day, sets in
                DailySets(day: day, sets: sets.sorted { ($0.completedAt!, $0.setIndex) < ($1.completedAt!, $1.setIndex) })
            }
            .sorted { $0.day > $1.day }
    }

    /// 今日より前で最も新しい日 (「前回」)
    static func previousDay(_ sets: [WorkoutSet], today: Date, calendar: Calendar) -> DailySets? {
        let todayStart = calendar.startOfDay(for: today)
        return daily(sets, calendar: calendar).first { $0.day < todayStart }
    }

    /// 1 日分の指標値。ウォームアップは除外し、該当セットが無ければ nil
    static func value(of metric: ProgressMetric, in sets: [WorkoutSet]) -> Double? {
        let working = sets.filter { !$0.isWarmup }
        let values: [Double]
        switch metric {
        case .maxWeight:
            values = working.compactMap(\.weight)
            return values.max()
        case .estimatedOneRM:
            values = working.compactMap { set in
                guard let weight = set.weight, let reps = set.reps else { return nil }
                return estimatedOneRM(weight: weight, reps: reps)
            }
            return values.max()
        case .volume:
            values = working.compactMap { set in
                guard let weight = set.weight, let reps = set.reps else { return nil }
                return weight * Double(reps)
            }
            return values.isEmpty ? nil : values.reduce(0, +)
        case .maxReps:
            return working.compactMap(\.reps).max().map(Double.init)
        case .maxDuration:
            return working.compactMap(\.durationSec).max().map(Double.init)
        case .maxDistance:
            return working.compactMap(\.distanceM).max()
        case .totalDuration:
            let durations = working.compactMap(\.durationSec)
            return durations.isEmpty ? nil : Double(durations.reduce(0, +))
        }
    }

    /// グラフ用の点。古い日が先頭
    static func points(_ daily: [DailySets], metric: ProgressMetric) -> [(day: Date, value: Double)] {
        daily
            .compactMap { entry in value(of: metric, in: entry.sets).map { (entry.day, $0) } }
            .sorted { $0.day < $1.day }
    }

    /// 本番セットの推定1RMの最大値 (重量×回数のあるセットのみ)
    static func bestOneRM(_ sets: [WorkoutSet]) -> Double? {
        value(of: .estimatedOneRM, in: sets)
    }

    /// Epley 式。1 回ならその重量そのもの (domain-model.md 判断 D の既定)
    static func estimatedOneRM(weight: Double, reps: Int) -> Double {
        reps <= 1 ? weight : weight * (1 + Double(reps) / 30)
    }
}
