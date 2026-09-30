import Foundation
import Combine

/// 過去日・週帯・分析・組み合わせ用の読み取り専用 store。書き込み API は持たない。
/// 今日の store (WorkoutSessionStore) とは分ける: 日付選択の状態を今日の store に持ち込むと、
/// 過去日を見ただけで今日の未保存の行が消える事故になるため。今日の分は常に今日の store から合成する (WorkoutSummary.mergeToday)
@MainActor
final class WorkoutHistoryStore: ObservableObject {
    /// 週頭 (月曜 0:00) → その週のセット
    @Published private(set) var weeks: [Date: [WorkoutSet]] = [:]
    /// 1 回でも記録がある種目 (分析画面の推移一覧用)
    @Published private(set) var recordedExerciseIds: Set<UUID> = []
    @Published private(set) var isLoading = false
    @Published var error: Error?

    private let dataSource: WorkoutDataSource
    private let calendar: Calendar
    /// 取得中の週 (同じ週を並行して二重に取りに行かない)
    private var inFlight: Set<Date> = []
    /// invalidate より前に始まった取得の結果を捨てるための世代
    private var generation = 0

    init(dataSource: WorkoutDataSource, calendar: Calendar) {
        self.dataSource = dataSource
        self.calendar = calendar
    }

    /// 記録がある日 (週帯の点)。今日の分は呼び出し側で今日の store と合成する
    var recordedDays: Set<Date> {
        WorkoutSummary.recordedDays(weeks.values.flatMap { $0 }, calendar: calendar)
    }

    /// ロード済みの全セット (組み合わせの元データ)
    var loadedSets: [WorkoutSet] {
        weeks.values.flatMap { $0 }
    }

    /// 未ロードの週だけを 1 リクエスト (最古の週頭〜最新の週末) で取得する
    func ensureLoaded(weekStarts: [Date]) async {
        let targets = Set(weekStarts.map { WorkoutSummary.weekStart(containing: $0, calendar: calendar) })
            .filter { weeks[$0] == nil && !inFlight.contains($0) }
        guard let from = targets.min(), let last = targets.max() else { return }
        let to = WorkoutSummary.weekInterval(containing: last, calendar: calendar).end
        let startedGeneration = generation
        inFlight.formUnion(targets)
        isLoading = true
        defer {
            inFlight.subtract(targets)
            isLoading = !inFlight.isEmpty
        }
        do {
            let fetched = try await dataSource.fetchSets(completedFrom: from, to: to)
            guard startedGeneration == generation else { return }
            let byWeek = Dictionary(grouping: fetched) { WorkoutSummary.weekStart(containing: $0.completedAt!, calendar: calendar) }
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

    /// キャッシュを捨てる (今日のセッションが変わったとき。日跨ぎで昨日の分を取りこぼさないため)
    func invalidate() {
        generation += 1
        inFlight = [] // 取得中の結果は捨てるので、同じ週をすぐ取り直せるようにする
        weeks = [:]
    }

    func sets(on day: Date) -> [WorkoutSet] {
        let key = WorkoutSummary.dayKey(day, calendar: calendar)
        return sets(inWeekStarting: WorkoutSummary.weekStart(containing: day, calendar: calendar))
            .filter { $0.completedAt.map { WorkoutSummary.dayKey($0, calendar: calendar) == key } ?? false }
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
