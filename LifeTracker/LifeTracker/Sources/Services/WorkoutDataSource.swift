import Foundation

/// トレーニング記録の読み書き。workout は独立アグリゲートのため DayDataSource とは別 protocol
/// (Round 1 で保留された「write 系を DayDataSource 拡張か別 protocol か」= 別 protocol で確定、training-domain-design.md 判断 A)。
protocol WorkoutDataSource {
    /// is_archived = false の種目を sort_order 順で返す
    func fetchExercises() async throws -> [Exercise]
    /// is_archived = false のルーティンを sort_order 順で返す
    func fetchRoutines() async throws -> [Routine]
    func fetchRoutineExercises(routineId: UUID) async throws -> [RoutineExercise]
    /// 全ルーティンの種目 (プログラム一覧を 1 リクエストで組むため)。routine_id・sort_order 順
    func fetchAllRoutineExercises() async throws -> [RoutineExercise]
    /// プログラムの保存。id が nil なら新規。種目は並び順で丸ごと置き換える (target は NULL)。
    /// routine → 種目の DELETE → INSERT の順で、原子的ではない。途中で失敗しても同じ呼び出しのやり直しで揃う
    func saveRoutine(id: UUID?, name: String, exerciseIds: [UUID]) async throws -> Routine
    /// 論理削除 (workout_session.routine_id の参照を残す)
    func archiveRoutine(id: UUID) async throws

    /// 進行中 (ended_at IS NULL) のセッション。DB の部分 UNIQUE で同時 1 件まで
    func fetchInProgressSession() async throws -> WorkoutSession?
    func startSession(routineId: UUID?, startedAt: Date) async throws -> WorkoutSession
    func endSession(id: UUID, endedAt: Date) async throws
    /// セットが 1 件もないセッションを破棄する用途。workout_set は ON DELETE CASCADE
    func deleteSession(id: UUID) async throws

    func fetchSets(sessionId: UUID) async throws -> [WorkoutSet]
    func addSet(_ set: NewWorkoutSet) async throws -> WorkoutSet
    func deleteSet(id: UUID) async throws

    /// 指定種目の全セット (前回参照・推移グラフ・履歴の元データ。日ごとのまとめは WorkoutProgress)
    func fetchExerciseSets(exerciseId: UUID) async throws -> [WorkoutSet]
    /// 1 回でも記録がある種目の id (推移一覧用)
    func fetchRecordedExerciseIds() async throws -> Set<UUID>
    /// 期間内 (completed_at の半開区間 [from, to)) の全種目のセット。completed_at IS NULL は含まない。
    /// 1 リクエスト上限 (PostgREST max-rows 1000) を越えないよう実装側でページングする
    func fetchSets(completedFrom from: Date, to: Date) async throws -> [WorkoutSet]

    /// トレーニングした日 (completed_at の JST 暦日) の全期間。連続日数の計算用 (view workout_training_day)
    func fetchTrainingDays() async throws -> Set<Date>
    /// 週の目標回数の履歴 (effective_from 順)
    func fetchWeeklyGoals() async throws -> [WeeklyGoal]
    /// 同じ週頭の目標があれば上書きする (effective_from の UNIQUE で upsert)
    func saveWeeklyGoal(_ goal: WeeklyGoal) async throws
}

/// INSERT 用。id / DB 既定値は DB 側で採番する
struct NewWorkoutSet: Encodable, Hashable {
    let sessionId: UUID
    let exerciseId: UUID
    let setIndex: Int
    let weight: Double?
    let reps: Int?
    let durationSec: Int?
    let distanceM: Double?
    let isWarmup: Bool
    let completedAt: Date
}

/// 入力画面の生値。metric_kind に応じて必要な列だけを残す (DB CHECK で表現できない整合をモデル層で担保)
struct WorkoutSetInput: Hashable {
    var weight: Double?
    var reps: Int?
    var durationSec: Int?
    var distanceM: Double?
    var isWarmup: Bool = false

    enum ValidationError: Error, Equatable {
        case missingWeight
        case missingReps
        case missingDuration
        case negativeValue
    }

    struct Validated: Equatable {
        let weight: Double?
        let reps: Int?
        let durationSec: Int?
        let distanceM: Double?
        let isWarmup: Bool
    }

    func validate(for kind: MetricKind) -> Result<Validated, ValidationError> {
        if let weight, weight < 0 { return .failure(.negativeValue) }
        if let distanceM, distanceM < 0 { return .failure(.negativeValue) }

        switch kind {
        case .weightReps:
            guard let weight else { return .failure(.missingWeight) }
            guard let reps, reps > 0 else { return .failure(.missingReps) }
            return .success(Validated(weight: weight, reps: reps, durationSec: nil, distanceM: nil, isWarmup: isWarmup))
        case .repsOnly:
            guard let reps, reps > 0 else { return .failure(.missingReps) }
            return .success(Validated(weight: nil, reps: reps, durationSec: nil, distanceM: nil, isWarmup: isWarmup))
        case .duration:
            guard let durationSec, durationSec > 0 else { return .failure(.missingDuration) }
            return .success(Validated(weight: nil, reps: nil, durationSec: durationSec, distanceM: nil, isWarmup: isWarmup))
        case .durationDistance:
            guard let durationSec, durationSec > 0 else { return .failure(.missingDuration) }
            return .success(Validated(weight: nil, reps: nil, durationSec: durationSec, distanceM: distanceM, isWarmup: isWarmup))
        }
    }
}

/// 画面が使う pure な導出。DB / Singleton に触れない
enum WorkoutLogic {
    /// 同一セッション・同一種目の次の set_index (UNIQUE (session_id, exercise_id, set_index) を満たす)
    static func nextSetIndex(for exerciseId: UUID, in sets: [WorkoutSet]) -> Int {
        let current = sets.filter { $0.exerciseId == exerciseId }.map(\.setIndex).max() ?? 0
        return current + 1
    }

    /// セッション内のセットを種目ごとにまとめる。種目の並びは最初に記録した順、セットは set_index 順
    static func groupByExercise(_ sets: [WorkoutSet]) -> [(exerciseId: UUID, sets: [WorkoutSet])] {
        var order: [UUID] = []
        var bucket: [UUID: [WorkoutSet]] = [:]
        let sorted = sets.sorted { lhs, rhs in
            (lhs.completedAt ?? .distantPast, lhs.setIndex) < (rhs.completedAt ?? .distantPast, rhs.setIndex)
        }
        for set in sorted {
            if bucket[set.exerciseId] == nil { order.append(set.exerciseId) }
            bucket[set.exerciseId, default: []].append(set)
        }
        return order.map { id in (id, bucket[id]!.sorted { $0.setIndex < $1.setIndex }) }
    }

    /// 種目を今日の画面に出したときに並べる未保存の行 (Gymwork 型: 前回の日のセットを行ごとに写す)。
    /// 今日すでに記録した行数ぶんは前回の先頭から消化済みとみなす。前回も今回も無ければ空の 1 行
    static func initialDrafts(currentSets: [WorkoutSet], previousSets: [WorkoutSet]) -> [WorkoutSetInput] {
        if currentSets.isEmpty && previousSets.isEmpty { return [WorkoutSetInput()] }
        return previousSets.dropFirst(currentSets.count).map { input(from: $0, keepWarmup: true) }
    }

    /// 「＋セット」で足す行: 直前の行のコピー (ウォームアップは外す) → 前回の同じ位置のセット → 空
    static func nextDraft(lastRow: WorkoutSetInput?, previousAtPosition: WorkoutSet?) -> WorkoutSetInput {
        if var copy = lastRow {
            copy.isWarmup = false
            return copy
        }
        return previousAtPosition.map { input(from: $0, keepWarmup: false) } ?? WorkoutSetInput()
    }

    static func input(from set: WorkoutSet, keepWarmup: Bool) -> WorkoutSetInput {
        WorkoutSetInput(
            weight: set.weight,
            reps: set.reps,
            durationSec: set.durationSec,
            distanceM: set.distanceM,
            isWarmup: keepWarmup && set.isWarmup
        )
    }

    /// 重量の刻み (小・大, kg)。プレート系 (バーベル等) は 1.25kg / 5kg、ダンベル・ケトルベルは 2kg / 4kg
    /// (2026-09-30 本人指定「0.5kg はいただけない。プレート系は 1.25kg、ダンベル系は 2kg が最小刻み」)
    static func weightSteps(for equipment: Exercise.Equipment?) -> (small: Double, large: Double) {
        switch equipment {
        case .dumbbell, .kettlebell: return (2, 4)
        default: return (1.25, 5)
        }
    }

    /// ended_at > started_at の CHECK を満たす終了時刻
    static func endDate(startedAt: Date, now: Date) -> Date {
        max(now, startedAt.addingTimeInterval(1))
    }

    /// 表示用: 60×10 / 12回 / 1:30 / 20:00・3.2km
    static func summary(of set: WorkoutSet, kind: MetricKind) -> String {
        switch kind {
        case .weightReps:
            return "\(formatWeight(set.weight ?? 0))×\(set.reps ?? 0)"
        case .repsOnly:
            return "\(set.reps ?? 0)回"
        case .duration:
            return formatDuration(set.durationSec ?? 0)
        case .durationDistance:
            let time = formatDuration(set.durationSec ?? 0)
            guard let distance = set.distanceM, distance > 0 else { return time }
            return "\(time)・\(formatDistance(distance))"
        }
    }

    static func formatWeight(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(weight))
            : String(format: "%.2f", weight).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    /// ボリューム表示: "1,440" / "402.5" (桁区切り・小数 1 桁まで)
    static func formatVolume(_ volume: Double) -> String {
        volume.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
    }

    static func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2fkm", meters / 1000) : "\(Int(meters))m"
    }
}
