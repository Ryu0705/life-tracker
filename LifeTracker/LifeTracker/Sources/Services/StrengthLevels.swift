import Foundation

// 部位ごとの強さの級 (docs/body-strength-and-heatmap-period.md「級の計算」)。pure (DB / Singleton に触れない)。
// 計算の順序は セット → 種目 (最大) → 部位 (平均。本人 Q4)。級は保存しない (INV-5)

/// 強さ・1 か月ヒートマップの期間 (本人 2026-10-10「直近30日、先月（yyyy/mm形式）、先々月」・月単位でさらに戻れる)。
/// offset 0 = 直近 30 日 (今日−29〜今日)、offset n ≥ 1 = 当月から n か月前のカレンダー月 (1 日〜末日)。
/// 期間ナビで前後に動かす (本人 2026-10-10「タブにすべきではない」)
struct StrengthPeriod: Hashable {
    var offset: Int

    static let days = 30
    static let recent = StrengthPeriod(offset: 0)
    /// 先月
    static let previous = StrengthPeriod(offset: 1)
    /// 先々月
    static let earlier = StrengthPeriod(offset: 2)

    var isRecent: Bool { offset == 0 }
    var older: StrengthPeriod { StrengthPeriod(offset: offset + 1) }
    var newer: StrengthPeriod { StrengthPeriod(offset: max(offset - 1, 0)) }

    /// 半開区間 [start, end)。recent = [今日−29 の 0:00, 明日 0:00)、月 = [その月 1 日 0:00, 翌月 1 日 0:00)
    func interval(today: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let startOfToday = calendar.startOfDay(for: today)
        guard offset > 0 else {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            return (calendar.date(byAdding: .day, value: -Self.days, to: tomorrow)!, tomorrow)
        }
        let thisMonth = calendar.dateInterval(of: .month, for: startOfToday)!.start
        let start = calendar.date(byAdding: .month, value: -offset, to: thisMonth)!
        return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    /// 直近 = "9/11〜10/10"、月 = "2026/09"
    func label(today: Date, calendar: Calendar) -> String {
        let range = interval(today: today, calendar: calendar)
        guard isRecent else {
            let c = calendar.dateComponents([.year, .month], from: range.start)
            return String(format: "%04d/%02d", c.year ?? 0, c.month ?? 0)
        }
        let last = calendar.date(byAdding: .day, value: -1, to: range.end)!
        func md(_ d: Date) -> String {
            let c = calendar.dateComponents([.month, .day], from: d)
            return "\(c.month ?? 0)/\(c.day ?? 0)"
        }
        return "\(md(range.start))〜\(md(last))"
    }

    /// 期間内の日か (1 か月ヒートマップで範囲外のセルを空白にする)
    func contains(_ day: Date, today: Date, calendar: Calendar) -> Bool {
        let range = interval(today: today, calendar: calendar)
        return range.start <= day && day < range.end
    }

    /// 期間を含む週頭 (月曜) の一覧。全部読み込めるまで級を出さない (レビュー A-6)
    func weekStarts(today: Date, calendar: Calendar) -> [Date] {
        let range = interval(today: today, calendar: calendar)
        var starts: [Date] = []
        var week = WorkoutSummary.weekStart(containing: range.start, calendar: calendar)
        while week < range.end {
            starts.append(week)
            week = calendar.date(byAdding: .day, value: 7, to: week)!
        }
        return starts
    }
}

/// 部位の状態 (レビュー A-7)
enum MuscleState: Equatable {
    /// 期間内に記録なし (対象外の種目だけの場合も含む)。灰
    case noRecord
    /// 記録はあるが基準のある種目がない (n 種目)
    case noStandard(Int)
    /// 0〜5 の連続値 (1 = Beginner … 5 = Elite、1 未満 = Beginner 未満)
    case level(Double)
}

struct ExerciseStrength: Identifiable, Equatable {
    enum Status: Equatable {
        /// best = 最大を出したセット、bodyWeight = そのセットに当てた体重
        case level(Double, best: WorkoutSet, bodyWeight: Double)
        case noStandard
        case excluded
    }
    let exercise: Exercise
    let status: Status
    /// 近似・換算の印 (代用元)。exact は nil
    let label: String?
    var id: UUID { exercise.id }

    var level: Double? {
        if case .level(let v, _, _) = status { return v }
        return nil
    }
}

struct MuscleStrength: Identifiable, Equatable {
    let muscle: Exercise.MuscleGroup
    let state: MuscleState
    /// 期間内にやった種目 (級の高い順 → 基準なし → 対象外)
    let exercises: [ExerciseStrength]
    var id: Exercise.MuscleGroup { muscle }
}

/// 心肺ブロック: 期間内の有酸素の合計 (級なし。レビュー A-12)
struct CardioTotals: Equatable {
    /// 本番セットの件数
    let count: Int
    let durationSec: Int
    let distanceM: Double
}

enum StrengthLevels {
    /// 人体図と一覧の部位 (cardio は除外。full_body は図に乗せず一覧だけ)
    static let muscles: [Exercise.MuscleGroup] = Exercise.MuscleGroup.allCases.filter { $0 != .cardio }

    /// 閾値 5 値に対する 0〜5 の値。「値 ≥ 閾値[i] を満たす最大の i」を下端に線形補間する
    /// (同値の隣接閾値は自動的に上の段に倒れる。A-2)。Elite 以上は 5。
    /// Beginner 未満は 0〜1 の比例: 加重の表 (負の閾値がある) は体重＋値の総負荷の比、それ以外は値の比
    static func score(_ value: Double, thresholds t: [Double], totalLoadBodyWeight: Double? = nil) -> Double {
        guard t.count == 5 else { return 0 }
        if value >= t[4] { return 5 }
        if value < t[0] {
            if let bw = totalLoadBodyWeight {
                let base = bw + t[0]
                return base > 0 ? min(1, max(0, (bw + value) / base)) : 0
            }
            return t[0] > 0 ? min(1, max(0, value / t[0])) : 0
        }
        let i = (0..<4).last { value >= t[$0] }!
        return Double(i + 1) + (value - t[i]) / (t[i + 1] - t[i])
    }

    /// 1 セットの級。値が無いセット (回数・秒の欠け) は nil
    static func setLevel(_ set: WorkoutSet, kind: MetricKind, mapping: StrengthStandards.Mapping, standard: StrengthStandards.Standard,
                         standards: StrengthStandards, sex: Sex, bodyWeight: Double) -> Double? {
        func main(_ value: Double) -> Double? {
            standards.thresholds(mapping, standard: standard, sex: sex, bodyWeight: bodyWeight).map { score(value, thresholds: $0) }
        }
        func added(_ value: Double) -> Double? {
            standards.thresholds(mapping, standard: standard, sex: sex, bodyWeight: bodyWeight, added: true)
                .map { score(value, thresholds: $0, totalLoadBodyWeight: bodyWeight) }
        }
        switch mapping.transform {
        case nil:
            switch kind {
            case .weightReps:
                guard let reps = set.reps else { return nil }
                return main(WorkoutProgress.estimatedOneRM(weight: set.weight ?? 0, reps: reps))
            case .repsOnly:
                return set.reps.flatMap { main(Double($0)) }
            case .duration:
                return set.durationSec.flatMap { main(Double($0)) }
            case .durationDistance:
                return nil
            }
        case .bodyweightAdded:
            // weight NULL は加重なし (レビュー A-5)
            guard let reps = set.reps else { return nil }
            let extra = set.weight ?? 0
            if extra == 0 { return main(Double(reps)) }
            return added(WorkoutProgress.estimatedOneRM(weight: bodyWeight + extra, reps: reps) - bodyWeight)
        case .assistToAdded:
            guard let reps = set.reps else { return nil }
            let assist = set.weight ?? 0
            if assist == 0 { return main(Double(reps)) }
            return added(WorkoutProgress.estimatedOneRM(weight: max(0, bodyWeight - assist), reps: reps) - bodyWeight)
        case .weightedRepsEquivalent:
            guard let reps = set.reps else { return nil }
            let extra = set.weight ?? 0
            if extra == 0 { return main(Double(reps)) }
            let upper = bodyWeight * 0.3
            return main(((upper + extra) * (1 + Double(reps) / 30) / upper - 1) * 30)
        }
    }

    /// その日以前で最新の体重。以前が無ければ最新の記録 (T-5)。0 件は nil
    static func bodyWeight(on day: Date, records: [BodyWeightRecord]) -> Double? {
        bodyWeight(on: day, sortedRecords: records.sorted { $0.recordedOn < $1.recordedOn })
    }

    private static func bodyWeight(on day: Date, sortedRecords: [BodyWeightRecord]) -> Double? {
        (sortedRecords.last { $0.recordedOn <= day } ?? sortedRecords.last)?.weightKg
    }

    /// 期間内の部位ごとの級。W 除外・アーカイブ済み種目 (exercisesById に無い) は除外 (週分析と同じ)。
    /// sets には開いている日の分を合成したものを渡す (WorkoutSummary.mergeLive)。
    /// 期間とセットに当てる体重の日は、セットの day (トレーニングの日。前の日に 0:30 に記録したセットは前の日)
    static func summarize(sets: [WorkoutSet], exercisesById: [UUID: Exercise], standards: StrengthStandards,
                          sex: Sex, bodyWeights: [BodyWeightRecord], interval: (start: Date, end: Date),
                          calendar: Calendar) -> [MuscleStrength] {
        let inPeriod = sets.filter { set in
            !set.isWarmup && set.completedAt != nil && isInPeriod(set, interval)
        }
        let byExercise = Dictionary(grouping: inPeriod, by: \.exerciseId)
        let weights = bodyWeights.sorted { $0.recordedOn < $1.recordedOn }
        var byMuscle: [Exercise.MuscleGroup: [ExerciseStrength]] = [:]
        for (exerciseId, exerciseSets) in byExercise {
            guard let exercise = exercisesById[exerciseId], exercise.muscleGroup != .cardio else { continue }
            let result: ExerciseStrength
            switch standards.resolve(exercise) {
            case .excluded:
                result = ExerciseStrength(exercise: exercise, status: .excluded, label: nil)
            case .none:
                result = ExerciseStrength(exercise: exercise, status: .noStandard, label: nil)
            case .standard(let mapping, let standard):
                var best: (level: Double, set: WorkoutSet, bodyWeight: Double)?
                for set in exerciseSets {
                    guard let bw = bodyWeight(on: calendar.startOfDay(for: set.day), sortedRecords: weights),
                          let level = setLevel(set, kind: exercise.metricKind, mapping: mapping, standard: standard,
                                               standards: standards, sex: sex, bodyWeight: bw) else { continue }
                    if best == nil || level > best!.level { best = (level, set, bw) }
                }
                let status: ExerciseStrength.Status = best.map { .level($0.level, best: $0.set, bodyWeight: $0.bodyWeight) } ?? .noStandard
                result = ExerciseStrength(exercise: exercise, status: status, label: mapping.label)
            }
            byMuscle[exercise.muscleGroup, default: []].append(result)
        }
        return muscles.map { muscle in
            let exercises = (byMuscle[muscle] ?? []).sorted { order($0, $1) }
            let levels = exercises.compactMap(\.level)
            let state: MuscleState
            if !levels.isEmpty {
                state = .level(levels.reduce(0, +) / Double(levels.count))
            } else {
                let missing = exercises.filter { $0.status == .noStandard }.count
                state = missing > 0 ? .noStandard(missing) : .noRecord
            }
            return MuscleStrength(muscle: muscle, state: state, exercises: exercises)
        }
    }

    /// ランク (2026-10-11 本人 F-7): 級の段 → Bronze〜Master、小数部 → 細分 IV〜I (.00〜.24 = IV … .75〜.99 = I)。Master は細分なし
    enum Rank: Int, CaseIterable {
        case bronze, silver, gold, platinum, diamond, master

        var name: String {
            switch self {
            case .bronze: return "Bronze"
            case .silver: return "Silver"
            case .gold: return "Gold"
            case .platinum: return "Platinum"
            case .diamond: return "Diamond"
            case .master: return "Master"
            }
        }
    }

    /// 0〜5 の値 → ランクと細分 (1〜4。Master は nil)。段は級の名前と同じく切り捨て
    static func rank(_ value: Double) -> (rank: Rank, division: Int?) {
        let step = max(0, min(5, Int(value.rounded(.down))))
        let rank = Rank(rawValue: step)!
        guard rank != .master else { return (rank, nil) }
        let fraction = max(0, value - Double(step))
        return (rank, 4 - min(3, Int(fraction * 4)))
    }

    /// "Gold I" / "Master"
    static func rankName(_ value: Double) -> String {
        let r = rank(value)
        guard let division = r.division else { return r.rank.name }
        return "\(r.rank.name) \(["I", "II", "III", "IV"][division - 1])"
    }

    /// 級の名前 (切り捨て。1 未満は「Beginner 未満」)
    static func levelName(_ value: Double) -> String {
        value < 1 ? "Beginner 未満" : StrengthStandards.levelNames[min(4, Int(value) - 1)]
    }

    /// 心肺: 期間内の有酸素 (muscle_group = cardio) の本番セット。距離 nil は 0
    static func cardioTotals(sets: [WorkoutSet], exercisesById: [UUID: Exercise], interval: (start: Date, end: Date)) -> CardioTotals {
        let cardio = sets.filter { set in
            !set.isWarmup && exercisesById[set.exerciseId]?.muscleGroup == .cardio
                && set.completedAt != nil && isInPeriod(set, interval)
        }
        return CardioTotals(count: cardio.count,
                            durationSec: cardio.compactMap(\.durationSec).reduce(0, +),
                            distanceM: cardio.compactMap(\.distanceM).reduce(0, +))
    }

    /// 期間 (日の始まりの半開区間) にセットの day が入るか
    private static func isInPeriod(_ set: WorkoutSet, _ interval: (start: Date, end: Date)) -> Bool {
        interval.start <= set.day && set.day < interval.end
    }

    private static func order(_ a: ExerciseStrength, _ b: ExerciseStrength) -> Bool {
        func rank(_ e: ExerciseStrength) -> Int {
            switch e.status {
            case .level: return 0
            case .noStandard: return 1
            case .excluded: return 2
            }
        }
        return (rank(a), -(a.level ?? 0), a.exercise.sortOrder ?? .max, a.exercise.name)
            < (rank(b), -(b.level ?? 0), b.exercise.sortOrder ?? .max, b.exercise.name)
    }
}
