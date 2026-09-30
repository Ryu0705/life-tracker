import Foundation
import Combine

/// 「予定」タブの読み取り (日単位のキャッシュ) と書き込み。docs/day-cycle-walkthrough.md「段階 1 確定仕様」
@MainActor
final class ScheduleStore: ObservableObject {
    /// 日 (0 時) → 組み立て済みの日。切り替え時に前の日の行を見せないよう、日ごとに持つ (UI U-10)
    @Published private(set) var days: [Date: Day] = [:]
    @Published private(set) var dayErrors: [Date: String] = [:]
    @Published private(set) var catalog: ScheduleCatalog = .empty
    @Published private(set) var isCatalogLoaded = false
    @Published private(set) var isSaving = false
    /// 一覧の footer に出す失敗 (スワイプ削除など)
    @Published var listMessage: String?

    let calendar: Calendar
    let holidayChecker: (Date) -> Bool
    private let dayDataSource: DayDataSource
    private let dataSource: ScheduleDataSource
    private var loadingDays: Set<Date> = []
    /// 書き込みのたびに進める。書き込み前に始まった読み込みの結果を捨てる
    private var generation = 0

    init(dayDataSource: DayDataSource, dataSource: ScheduleDataSource, calendar: Calendar,
         holidayChecker: @escaping (Date) -> Bool) {
        self.dayDataSource = dayDataSource
        self.dataSource = dataSource
        self.calendar = calendar
        self.holidayChecker = holidayChecker
    }

    func key(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    func day(_ date: Date) -> Day? { days[key(date)] }

    var categories: [Category] {
        catalog.categories.sorted { $0.name < $1.name }
    }

    func categoryName(_ id: UUID) -> String? {
        catalog.category(id)?.name
    }

    /// 過去日は予定を編集できない (日単位。段階 2 の実績入力とは別のゲート)
    func canEditSchedule(on date: Date, today: Date) -> Bool {
        key(date) >= key(today)
    }

    // MARK: - 読み取り

    func ensureLoaded(_ date: Date) async {
        if !isCatalogLoaded { await loadCatalog() }
        let day = key(date)
        guard days[day] == nil, !loadingDays.contains(day) else { return }
        await load(day)
    }

    /// 再試行・引っぱって更新
    func reload(_ date: Date) async {
        await loadCatalog()
        await load(key(date))
    }

    private func load(_ day: Date) async {
        loadingDays.insert(day)
        defer { loadingDays.remove(day) }
        let started = generation
        do {
            let context = try await dayDataSource.loadDayContext(date: day)
            guard started == generation else { return }
            days[day] = DayBuilder.build(date: day, context: context)
            dayErrors[day] = nil
        } catch {
            guard started == generation, !WorkoutSessionStore.isCancellation(error) else { return }
            dayErrors[day] = error.localizedDescription
        }
    }

    func loadCatalog() async {
        do {
            catalog = try await dataSource.fetchCatalog()
            isCatalogLoaded = true
        } catch {
            if !WorkoutSessionStore.isCancellation(error) { listMessage = "読み込みに失敗しました: \(error.localizedDescription)" }
        }
    }

    // MARK: - 編集

    func editTarget(for row: DayScheduledTask, viewDay: Date, today: Date) -> ScheduleEditTarget? {
        guard let day = day(viewDay) else { return nil }
        return SchedulePlanner.editTarget(row: row, viewDay: viewDay, day: day, today: today, catalog: catalog, calendar: calendar)
    }

    enum SaveError: Error, LocalizedError, Equatable {
        case emptyName, zeroDuration, noCategory
        var errorDescription: String? {
            switch self {
            case .emptyName: return "名前を入れてください"
            case .zeroDuration: return "開始と終了を別の時刻にしてください"
            case .noCategory: return "種類を選んでください"
            }
        }
    }

    /// 保存できない条件は「名前が空」「開始＝終了」だけ (曜日も祝日もなし = 繰り返さない、として保存できる)
    nonisolated static func validate(_ input: ScheduleEntryInput) -> SaveError? {
        if input.content.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if input.content.durationMinutes <= 0 { return .zeroDuration }
        return nil
    }

    /// 書き込んで、キャッシュを捨てて見ている日を読み直す (「これ以降」は未来のすべての日に効くため)。
    /// 読み直しの間は直前の内容を残す。失敗は戻り値で返す (編集画面を開いたまま、同じ操作でやり直せる)
    func perform(_ operation: ScheduleOperation, reloading visibleDay: Date) async -> Error? {
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        var failure: Error?
        do {
            try await dataSource.apply(normalized(operation))
        } catch {
            failure = error
        }
        generation += 1
        let visible = key(visibleDay)
        let kept = days[visible]
        days = kept.map { [visible: $0] } ?? [:]
        dayErrors = [:]
        await loadCatalog()
        await load(visible)
        return failure
    }

    /// 名前の前後の空白を落とす
    private func normalized(_ operation: ScheduleOperation) -> ScheduleOperation {
        func trim(_ c: ScheduleContent) -> ScheduleContent {
            var c = c
            c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return c
        }
        switch operation {
        case .createSingle(let d, let c): return .createSingle(date: d, content: trim(c))
        case .updateSingle(let id, let d, let c): return .updateSingle(id: id, date: d, content: trim(c))
        case .createSeries(let d, let c, let r, let s): return .createSeries(date: d, content: trim(c), repeatRule: r, replacingSingle: s)
        case .saveOccurrence(let t, let d, let p, let c): return .saveOccurrence(templateId: t, date: d, patternId: p, content: trim(c))
        case .saveFollowing(let t, let d, let c, let r): return .saveFollowing(templateId: t, date: d, content: trim(c), repeatRule: r)
        case .endSeriesToSingle(let t, let d, let c): return .endSeriesToSingle(templateId: t, date: d, content: trim(c))
        case .deleteSingle, .deleteOccurrence, .deleteFollowing: return operation
        }
    }

    /// 同じ名前の種類があればそれを返す (重複を作らない)
    func createCategory(name: String) async -> Result<Category, Error> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(SaveError.emptyName) }
        if let existing = catalog.categories.first(where: { $0.name == trimmed }) { return .success(existing) }
        do {
            let category = try await dataSource.createCategory(name: trimmed)
            catalog.categories.append(category)
            return .success(category)
        } catch {
            return .failure(error)
        }
    }
}
