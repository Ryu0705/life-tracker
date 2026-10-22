import Foundation
import Combine

/// 過去日・週帯・分析・組み合わせ用の読み取り専用 store。書き込み API は持たない。
/// 記録の store (WorkoutSessionStore) とは分ける: 日付選択の状態を記録の store に持ち込むと、
/// 過去日を見ただけで今日の未保存の行が消える事故になるため。開いている日 (今日と、開いていれば前の日) の分は
/// 常に記録の store から合成する (WorkoutSummary.mergeLive)。日はセットの day (トレーニングの日。0015)
@MainActor
final class WorkoutHistoryStore: ObservableObject {
    /// 週頭 (月曜 0:00) → その週のセット
    @Published private(set) var weeks: [Date: [WorkoutSet]] = [:]
    /// ロード済みの週のセッションの entry (過去日のカードの単位と並び)
    @Published private(set) var entriesById: [UUID: WorkoutEntry] = [:]
    /// 1 回でも記録がある種目 (分析画面の推移一覧用)
    @Published private(set) var recordedExerciseIds: Set<UUID> = []
    @Published private(set) var isLoading = false
    @Published var error: Error?

    private let dataSource: WorkoutDataSource
    private let calendar: Calendar
    /// 取得中の週 → その取得 (同じ週を並行して二重に取りに行かず、後から頼んだ側は同じ取得を待つ)
    private var inFlight: [Date: Task<Void, Never>] = [:]
    /// invalidate より前に始まった取得の結果を捨てるための世代。invalidate のたびに 1 増える (分析の先読みの読み直しの合図)
    @Published private(set) var generation = 0

    init(dataSource: WorkoutDataSource, calendar: Calendar) {
        self.dataSource = dataSource
        self.calendar = calendar
    }

    /// 記録がある日 (週帯の点)。開いている日の分は呼び出し側で記録の store と合成する
    var recordedDays: Set<Date> {
        WorkoutSummary.recordedDays(weeks.values.flatMap { $0 }, calendar: calendar)
    }

    /// ロード済みの全セット (組み合わせの元データ)
    var loadedSets: [WorkoutSet] {
        weeks.values.flatMap { $0 }
    }

    /// 未ロードの週がそろうまで待つ。取得中でない週だけを 1 リクエスト (最古の週頭〜最新の週末) で取り、取得中の週はその取得を待つ。
    /// 取得は store が持つ Task で走らせる: 呼び出し元 (View の .task) が取り消されても取得は続いて weeks に入り、
    /// 同じ週を待っている別の呼び出しが「読み込み中」のまま取り残されない (docs/analysis-tabs-discussion/40-integration.md §3-2)
    func ensureLoaded(weekStarts: [Date]) async {
        let missing = Set(weekStarts.map { WorkoutSummary.weekStart(containing: $0, calendar: calendar) }).filter { weeks[$0] == nil }
        var waiting = Set(missing.compactMap { inFlight[$0] })
        let targets = missing.filter { inFlight[$0] == nil }
        if let from = targets.min(), let last = targets.max() {
            let to = WorkoutSummary.weekInterval(containing: last, calendar: calendar).end
            let startedGeneration = generation
            let task = Task { await fetch(targets, from: from, to: to, startedGeneration: startedGeneration) }
            for start in targets { inFlight[start] = task }
            isLoading = true
            waiting.insert(task)
        }
        for task in waiting { await task.value }
    }

    private func fetch(_ targets: Set<Date>, from: Date, to: Date, startedGeneration: Int) async {
        defer {
            // invalidate 後は inFlight が空から作り直されている (別の取得の分を消さない)
            if startedGeneration == generation {
                for start in targets { inFlight[start] = nil }
            }
            isLoading = !inFlight.isEmpty
        }
        do {
            let fetched = try await dataSource.fetchSets(daysFrom: from, to: to)
            let sessionIds = Set(fetched.map(\.sessionId)).subtracting(entriesById.values.map(\.sessionId))
            let entries = sessionIds.isEmpty ? [] : try await dataSource.fetchEntries(sessionIds: Array(sessionIds))
            guard startedGeneration == generation else { return }
            for entry in entries { entriesById[entry.id] = entry }
            // 週はセットの day で振り分ける (取得も day の範囲。日曜に 0:30 まで記録したセットは日曜の週)
            let byWeek = Dictionary(grouping: fetched) { WorkoutSummary.weekStart(containing: $0.day, calendar: calendar) }
            for start in targets { weeks[start] = byWeek[start] ?? [] }
        } catch {
            report(error)
        }
    }

    func loadRecordedExerciseIds() async {
        do {
            recordedExerciseIds = try await dataSource.fetchRecordedExerciseIds()
        } catch {
            report(error)
        }
    }

    /// キャッシュを捨てる (開いている日が閉じたとき・引っ張って更新。閉じた日の分は記録の store から履歴へ移るので、
    /// 開いている間に記録した分を取りこぼさないため)
    func invalidate() {
        generation += 1
        inFlight = [:] // 取得中の結果は捨てるので、同じ週をすぐ取り直せるようにする
        weeks = [:]
        entriesById = [:]
    }

    /// その日 (セットの day) のセット
    func sets(on day: Date) -> [WorkoutSet] {
        let key = WorkoutSummary.dayKey(day, calendar: calendar)
        return sets(inWeekStarting: WorkoutSummary.weekStart(containing: day, calendar: calendar))
            .filter { WorkoutSummary.dayKey($0.day, calendar: calendar) == key }
    }

    /// その日の entry (セットのある entry だけ。セッションのセットはすべて同じ日 = セッションの day)
    func entries(on day: Date) -> [WorkoutEntry] {
        Set(sets(on: day).map(\.entryId)).compactMap { entriesById[$0] }
    }

    func sets(inWeekStarting weekStart: Date) -> [WorkoutSet] {
        weeks[weekStart] ?? []
    }

    func isLoaded(weekStart: Date) -> Bool {
        weeks[weekStart] != nil
    }

    private func report(_ error: Error) {
        guard !WorkoutSessionStore.isCancellation(error) else { return }
        self.error = error
    }
}
