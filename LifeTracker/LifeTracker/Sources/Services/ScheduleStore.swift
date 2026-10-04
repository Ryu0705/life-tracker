import Foundation
import Combine

/// 「予定」タブの読み取り (日単位のキャッシュ) と書き込み。docs/day-cycle-walkthrough.md「段階 1 確定仕様」「段階 2 確定仕様」。
/// 実績 (チェックイン) は楽観更新＋回ごとの直列化 (レビュー §5-3): 丸を押した瞬間に表示を変え、同じ回への続く操作は前の応答を待って順に送る
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
    /// 応答前の実績の表示 (回ごと)。読み直しで反映されたら外す
    @Published private(set) var overrides: [CheckInKey: CheckInOverride] = [:]

    let calendar: Calendar
    let holidayChecker: (Date) -> Bool
    private let dayDataSource: DayDataSource
    private let dataSource: ScheduleDataSource
    private var loadingDays: Set<Date> = []
    /// 書き込みのたびに進める。書き込み前に始まった読み込みの結果を捨てる
    private var generation = 0
    /// 実績の書き込みの直列化 (回ごと。予定外の実績は 1 本の列)
    private var checkInChains: [AnyHashable: Task<Error?, Never>] = [:]
    /// 回ごとの操作の通し番号 (最後の操作だけが上書きを外す)
    private var checkInSerials: [CheckInKey: Int] = [:]
    /// 上書きを外してよくなった世代 (この世代以降に始まった読み込みが反映されたら外す)
    private var overrideSettledAt: [CheckInKey: Int] = [:]

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

    func category(_ id: UUID) -> Category? {
        catalog.category(id)
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
            // この読み込みより前に確定した実績の上書きは、読み込んだ中身に入っている
            for (key, settled) in overrideSettledAt where settled <= started {
                overrides[key] = nil
                overrideSettledAt[key] = nil
            }
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
        case emptyName, zeroDuration, noCategory, busy
        var errorDescription: String? {
            switch self {
            case .busy: return "保存中です。少し待ってからやり直してください"
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
        // 2 度目を黙って成功扱いにしない (レビュー §5-3)
        guard !isSaving else { return SaveError.busy }
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

    // MARK: - 実績 (段階 2)

    /// 回の丸の状態 (上書き → 読み込んだ実績の順。セットのあるジムが最優先)
    func checkInState(for row: DayScheduledTask, in day: Day) -> CheckInState {
        CheckInPlanner.state(for: row, records: day.records, overrides: overrides, category: category(row.task.categoryId),
                             workoutSetTimes: CheckInPlanner.workoutSets(for: row, day: day, calendar: calendar), calendar: calendar)
    }

    /// 一覧の行 (予定の回＋予定外の実績、時刻順)
    func listItems(_ day: Day) -> [ScheduleListItem] {
        CheckInPlanner.listItems(day: day, calendar: calendar)
    }

    /// 実績を書き込む。回の操作は先に表示を変え (楽観更新)、同じ回の前の操作の応答を待ってから送る。
    /// 失敗したら表示を戻し、戻り値で返す (一覧は footer、編集画面は画面の中に出す)
    @discardableResult
    func checkIn(_ operation: CheckInOperation, reloading visibleDay: Date) async -> Error? {
        let visible = key(visibleDay)
        let operation = Self.normalized(operation)
        var serial: (key: CheckInKey, number: Int)?
        let existing: ActualTask? = {
            guard case .set(let key, _, _, _, _, _) = operation else { return nil }
            if case .record(let record)? = overrides[key] { return record }
            return days[visible]?.records.first { CheckInKey.of($0, calendar: calendar) == key }
        }()
        if let (key, override) = CheckInPlanner.override(for: operation, existing: existing, calendar: calendar) {
            let number = (checkInSerials[key] ?? 0) + 1
            checkInSerials[key] = number
            serial = (key, number)
            overrides[key] = override
            overrideSettledAt[key] = nil
        }
        let chainKey: AnyHashable = serial.map { AnyHashable($0.key) } ?? AnyHashable("actual")
        let previous = checkInChains[chainKey]
        let dataSource = self.dataSource
        let task = Task<Error?, Never> {
            _ = await previous?.value
            do {
                try await dataSource.applyCheckIn(operation)
                return nil
            } catch {
                return error
            }
        }
        checkInChains[chainKey] = task
        let failure = await task.value
        if checkInChains[chainKey] == task { checkInChains[chainKey] = nil }

        generation += 1
        if let serial, checkInSerials[serial.key] == serial.number {
            if failure != nil {
                overrides[serial.key] = nil
            } else {
                overrideSettledAt[serial.key] = generation
            }
        }
        // 実績は前日・翌日の一覧にも出る (前日から続く行・一覧に出る日) ので、隣の日のキャッシュは捨てる
        for offset in [-1, 1] {
            if let other = calendar.date(byAdding: .day, value: offset, to: visible) { days[other] = nil }
        }
        await load(visible)
        return failure
    }

    /// 名前の前後の空白を落とす
    private static func normalized(_ operation: CheckInOperation) -> CheckInOperation {
        let trim = { (name: String) in name.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch operation {
        case .set(let k, let st, let n, let c, let s, let e):
            return .set(key: k, status: st, name: trim(n), categoryId: c, start: s, end: e)
        case .saveActual(let id, let n, let c, let s, let e):
            return .saveActual(id: id, name: trim(n), categoryId: c, start: s, end: e)
        case .clear, .deleteActual:
            return operation
        }
    }

    /// タブに戻ったとき: 見ている日以外のキャッシュを捨て、見ている日を読み直す (V-7)。
    /// トレーニングタブで付けたセット (ジムの丸。レビュー §4-1) と、睡眠タブで書いた記録 (前日・翌日の一覧にも出る) を反映する。
    /// 読み込み中は前の内容を見せたまま
    func refresh(_ date: Date) async {
        let day = key(date)
        days = days.filter { $0.key == day }
        dayErrors = dayErrors.filter { $0.key == day }
        guard days[day] != nil, !loadingDays.contains(day) else { return }
        await load(day)
    }

    /// 睡眠の行の 3 行目 (「実績 23:40–7:10（7時間30分）」)。その日の睡眠の行の中で重なりが最長の行にだけ付く。未入力は出さない
    func sleepLine(for row: DayScheduledTask, in day: Day) -> String? {
        let rows = day.scheduled.filter { category($0.task.categoryId)?.subInputKind == .sleep }
        let assigned = SleepRules.assign(rows: rows, records: day.sleepRecords)
        return SleepRules.planLine(assigned[row.id] ?? [], calendar: calendar)
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
