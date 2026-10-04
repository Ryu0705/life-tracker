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
    /// 記録済みの行の値 (重さ・回数・時間・距離・ウォームアップ) を書き換える。completed_at・set_index は変えない
    func updateSet(id: UUID, values: WorkoutSetInput.Validated) async throws -> WorkoutSet
    /// 削除して、同じ entry の残りの set_index を 1..n に詰め直す。残りが 0 件ならその entry も消し、
    /// 同じセッションの entry の sort_order を 1..n に詰める (RPC workout_set_delete で 1 トランザクション)。
    /// 無い id は何もしない
    func deleteSet(id: UUID) async throws

    /// セッションの entry (カード) を sort_order 順で返す
    func fetchEntries(sessionId: UUID) async throws -> [WorkoutEntry]
    /// 複数セッションの entry (過去日・前回の対応用)。実装側でまとめて取る
    func fetchEntries(sessionIds: [UUID]) async throws -> [WorkoutEntry]
    /// 最初の ✓ で作る。UNIQUE (session_id, sort_order) に当たったら失敗する (別端末と同時の作成)
    func addEntry(sessionId: UUID, exerciseId: UUID, sortOrder: Int) async throws -> WorkoutEntry
    /// 空の entry (セット INSERT 前に落ちた残骸) を消す。セットが残っている entry は複合 FK で失敗する
    func deleteEntry(id: UUID) async throws
    /// 配列順に sort_order = 1..k、配列に無いそのセッションの entry は旧順で後ろへ (RPC workout_entry_reorder)
    func reorderEntries(sessionId: UUID, entryIds: [UUID]) async throws

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
    let entryId: UUID
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

/// 今日の画面のカード 1 枚。entryId は最初の ✓ で入る (それまでは予定 = メモリだけ)。
/// 同じ種目のカードを何枚でも置ける (docs/gymwork-design-duplicate-and-reorder.md)
struct TodayCard: Identifiable, Hashable {
    let id: UUID
    let exerciseId: UUID
    var entryId: UUID?
}

/// 画面が使う pure な導出。DB / Singleton に触れない
enum WorkoutLogic {
    /// 画面のカードを DB の entry に合わせる: 未記録のカードは位置ごと残し、記録済みのカードの枠には
    /// entry を sort_order 順に入れ直す。カードの無い entry は末尾に足し、消えた entry のカードは未記録に戻す
    static func reconcile(_ cards: [TodayCard], with entries: [WorkoutEntry]) -> [TodayCard] {
        let alive = Set(entries.map(\.id))
        var result = cards.map { card -> TodayCard in
            var c = card
            if let id = c.entryId, !alive.contains(id) { c.entryId = nil }
            return c
        }
        let known = Dictionary(result.compactMap { c in c.entryId.map { ($0, c) } }, uniquingKeysWith: { first, _ in first })
        var ordered = entries.sorted { $0.sortOrder < $1.sortOrder }
            .map { known[$0.id] ?? TodayCard(id: $0.id, exerciseId: $0.exerciseId, entryId: $0.id) }[...]
        for index in result.indices where result[index].entryId != nil {
            if let next = ordered.popFirst() { result[index] = next } else { result[index].entryId = nil }
        }
        return result + ordered
    }

    /// 同じ entry (カード) の次の set_index (UNIQUE (entry_id, set_index) を満たす)
    static func nextSetIndex(forEntry entryId: UUID, in sets: [WorkoutSet]) -> Int {
        let current = sets.filter { $0.entryId == entryId }.map(\.setIndex).max() ?? 0
        return current + 1
    }

    /// 削除後の set_index の詰め直し (RPC workout_set_delete の写し)。消した行と同じ entry の残りを
    /// set_index 順に 1..n に振り直し、それ以外の行はそのまま返す。並び順は入力のまま
    static func removingAndRenumbering(_ removed: WorkoutSet, from sets: [WorkoutSet]) -> [WorkoutSet] {
        let remaining = sets.filter { $0.id != removed.id }
        let group = remaining
            .filter { $0.entryId == removed.entryId }
            .sorted { ($0.setIndex, $0.id.uuidString) < ($1.setIndex, $1.id.uuidString) }
        let newIndex = Dictionary(uniqueKeysWithValues: group.enumerated().map { ($1.id, $0 + 1) })
        return remaining.map { set in
            newIndex[set.id].map { set.with(setIndex: $0) } ?? set
        }
    }

    /// RPC workout_set_delete の entry 側の写し: entry のセットが 0 件なら entry を消し、
    /// 同じセッションの sort_order を 1..n に詰める。セットが残っていれば entries をそのまま返す
    static func pruningEntry(_ entryId: UUID, remainingSets: [WorkoutSet], entries: [WorkoutEntry]) -> [WorkoutEntry] {
        guard !remainingSets.contains(where: { $0.entryId == entryId }),
              let removed = entries.first(where: { $0.id == entryId }) else { return entries }
        let kept = entries.filter { $0.id != entryId }
        let sameSession = kept.filter { $0.sessionId == removed.sessionId }
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        let newOrder = Dictionary(uniqueKeysWithValues: sameSession.enumerated().map { ($1.id, $0 + 1) })
        return kept.map { entry in newOrder[entry.id].map { entry.with(sortOrder: $0) } ?? entry }
    }

    /// RPC workout_entry_reorder の写し: 指定セッションの entry を配列順に 1..k、配列に無いものは旧順で k+1.. に。
    /// 他のセッションの entry はそのまま。重複した id は最初の位置を使う
    static func reordering(_ entries: [WorkoutEntry], sessionId: UUID, entryIds: [UUID]) -> [WorkoutEntry] {
        var rank: [UUID: Int] = [:]
        for (i, id) in entryIds.enumerated() where rank[id] == nil { rank[id] = i }
        let sameSession = entries.filter { $0.sessionId == sessionId }.sorted { lhs, rhs in
            let l = (rank[lhs.id] == nil ? 1 : 0, rank[lhs.id] ?? 0, lhs.sortOrder, lhs.id.uuidString)
            let r = (rank[rhs.id] == nil ? 1 : 0, rank[rhs.id] ?? 0, rhs.sortOrder, rhs.id.uuidString)
            return l < r
        }
        let newOrder = Dictionary(uniqueKeysWithValues: sameSession.enumerated().map { ($1.id, $0 + 1) })
        return entries.map { entry in newOrder[entry.id].map { entry.with(sortOrder: $0) } ?? entry }
    }

    /// セッション内のセットを entry (カード) ごとにまとめる。並びは entry の sort_order 順 (セッションをまたぐ場合は
    /// セッションの最初の記録時刻順)、セットは set_index 順。セットの無い entry も返す (呼び出し側で除く)。
    /// entry が分からないセットは出さない
    static func groupByEntry(sets: [WorkoutSet], entries: [WorkoutEntry]) -> [(entry: WorkoutEntry, sets: [WorkoutSet])] {
        let bySet = Dictionary(grouping: sets, by: \.entryId)
        var sessionStart: [UUID: Date] = [:]
        for set in sets {
            let at = set.completedAt ?? .distantFuture
            sessionStart[set.sessionId] = min(sessionStart[set.sessionId] ?? .distantFuture, at)
        }
        return entries
            .sorted { lhs, rhs in
                let l = (sessionStart[lhs.sessionId] ?? .distantFuture, lhs.sessionId.uuidString, lhs.sortOrder)
                let r = (sessionStart[rhs.sessionId] ?? .distantFuture, rhs.sessionId.uuidString, rhs.sortOrder)
                return l < r
            }
            .map { ($0, (bySet[$0.id] ?? []).sorted { $0.setIndex < $1.setIndex }) }
    }

    /// 同じ種目の 1 日分のセットを entry ごとのかたまりに分ける (前回の対応・履歴の「｜」区切り)。
    /// entry が分かればその sort_order 順、分からなければ最初の completed_at 順 (近似)。セットは set_index 順
    static func blocks(of sets: [WorkoutSet], entriesById: [UUID: WorkoutEntry]) -> [[WorkoutSet]] {
        let grouped = Dictionary(grouping: sets, by: \.entryId)
        func firstAt(_ id: UUID) -> Date { grouped[id]?.compactMap(\.completedAt).min() ?? .distantFuture }
        var sessionStart: [UUID: Date] = [:]
        for set in sets {
            sessionStart[set.sessionId] = min(sessionStart[set.sessionId] ?? .distantFuture, set.completedAt ?? .distantFuture)
        }
        let keys = grouped.keys.sorted { lhs, rhs in
            let ls = grouped[lhs]![0].sessionId, rs = grouped[rhs]![0].sessionId
            let l = (sessionStart[ls] ?? .distantFuture, ls.uuidString, entriesById[lhs]?.sortOrder ?? .max, firstAt(lhs), lhs.uuidString)
            let r = (sessionStart[rs] ?? .distantFuture, rs.uuidString, entriesById[rhs]?.sortOrder ?? .max, firstAt(rhs), rhs.uuidString)
            return l < r
        }
        return keys.map { key in grouped[key]!.sorted { ($0.setIndex, $0.completedAt ?? .distantFuture) < ($1.setIndex, $1.completedAt ?? .distantFuture) } }
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
