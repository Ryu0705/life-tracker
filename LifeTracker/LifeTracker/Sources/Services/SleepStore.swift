import Foundation
import Combine

/// 「睡眠」タブの読み取りと書き込み。docs/day-cycle-walkthrough.md「睡眠（確定仕様）」。
/// 記録は読み込んだ範囲 (直近・月・推移の期間) ごとに取り、書き込んだら同じ範囲を全部読み直す (store 間の配線は持たない。予定タブは V-7 で読み直す)。
/// 今朝のカード・＋ の既定は、その夜の睡眠の予定 (予定タブと同じ読み込み＋DayBuilder。世代・除外日・祝日を解決済み) から取る
@MainActor
final class SleepStore: ObservableObject {
    /// 読み込んだ範囲の記録 (就寝の順)
    @Published private(set) var records: [SleepRecord] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published private(set) var loadError: String?
    /// 読んだ夜 (鍵) ごとの睡眠の予定 (値が nil = 予定なし・読めなかった。鍵が無い = まだ読んでいない)
    @Published private(set) var plans: [Date: SleepPlan?] = [:]

    let calendar: Calendar
    private let dataSource: SleepDataSource
    private let dayDataSource: DayDataSource
    private let scheduleDataSource: ScheduleDataSource
    private let now: () -> Date
    /// 読み込んだ範囲 [from, to)
    private var ranges: [Range<Date>] = []
    /// 書き込みのたびに進める。書き込み前に始まった読み込みの結果を捨てる
    private var generation = 0

    init(dataSource: SleepDataSource, dayDataSource: DayDataSource, scheduleDataSource: ScheduleDataSource,
         calendar: Calendar, now: @escaping () -> Date = { Date() }) {
        self.dataSource = dataSource
        self.dayDataSource = dayDataSource
        self.scheduleDataSource = scheduleDataSource
        self.calendar = calendar
        self.now = now
    }

    // MARK: - 読み取り

    /// 1 画面目: 直近 14 朝 (7 朝＋前回の記録・今週の数字の分)
    static let recentDays = 14

    func recentRange(today: Date) -> Range<Date> {
        let start = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .day, value: -Self.recentDays, to: start)!..<calendar.date(byAdding: .day, value: 1, to: start)!
    }

    /// 月 [1 日 0:00, 翌月 1 日 0:00)
    func monthRange(containing day: Date) -> Range<Date> {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
        return start..<calendar.date(byAdding: .month, value: 1, to: start)!
    }

    /// まだ読んでいない範囲なら読む
    func ensureLoaded(_ range: Range<Date>) async {
        guard !ranges.contains(where: { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }) else { return }
        let started = generation
        do {
            let fetched = try await dataSource.fetchSleepRecords(from: range.lowerBound, to: range.upperBound)
            guard started == generation else { return }
            ranges.append(range)
            merge(fetched, replacing: range)
            isLoaded = true
            loadError = nil
        } catch {
            guard started == generation, !WorkoutSessionStore.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    /// 読み込んだ範囲を全部読み直す (書き込みの後・引っぱって更新・タブに戻ったとき)
    func reloadAll() async {
        generation += 1
        let started = generation
        let current = ranges
        do {
            var fetched: [UUID: SleepRecord] = [:]
            for range in current {
                for record in try await dataSource.fetchSleepRecords(from: range.lowerBound, to: range.upperBound) {
                    fetched[record.id] = record
                }
            }
            guard started == generation else { return }
            records = fetched.values.sorted { $0.startAt < $1.startAt }
            loadError = nil
        } catch {
            guard started == generation, !WorkoutSessionStore.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    private func merge(_ fetched: [SleepRecord], replacing range: Range<Date>) {
        var byId = Dictionary(uniqueKeysWithValues: records
            .filter { !($0.startAt < range.upperBound && $0.endAt > range.lowerBound) }
            .map { ($0.id, $0) })
        for record in fetched { byId[record.id] = record }
        records = byId.values.sorted { $0.startAt < $1.startAt }
    }

    /// 範囲に重なる記録
    func records(in range: Range<Date>) -> [SleepRecord] {
        records.filter { $0.startAt < range.upperBound && $0.endAt > range.lowerBound }
    }

    func record(_ id: UUID) -> SleepRecord? {
        records.first { $0.id == id }
    }

    /// 鍵の夜の睡眠の予定 (まだ読んでいない・予定なし・読めなかったは nil)
    func plan(nightKey key: Date) -> SleepPlan? {
        plans[calendar.startOfDay(for: key)] ?? nil
    }

    /// 今朝の鍵の夜の予定を読む
    func loadPlan(today: Date) async {
        await loadPlan(nightKey: SleepRules.morningKey(today: today, calendar: calendar))
    }

    /// 鍵の夜の睡眠の予定を読む (毎回読み直す。予定タブで変えた後にも合わせるため)。鍵の日と翌日の一覧から
    /// (0 時過ぎに始まる世代は翌日の一覧にある)。読めなければ予定なし扱い (既定は前回の記録 → 23:00 / 7:00)
    func loadPlan(nightKey: Date) async {
        let key = calendar.startOfDay(for: nightKey)
        let next = calendar.date(byAdding: .day, value: 1, to: key)!
        do {
            async let catalog = scheduleDataSource.fetchCatalog()
            async let keyContext = dayDataSource.loadDayContext(date: key)
            async let nextContext = dayDataSource.loadDayContext(date: next)
            let (resolvedCatalog, c1, c2) = try await (catalog, keyContext, nextContext)
            let sleepIds = Set(resolvedCatalog.categories.filter { $0.subInputKind == .sleep }.map(\.id))
            let rows = DayBuilder.build(date: key, context: c1).scheduled + DayBuilder.build(date: next, context: c2).scheduled
            plans[key] = .some(SleepRules.plannedSleep(rows: rows, sleepCategoryIds: sleepIds, nightKey: key, calendar: calendar))
        } catch {
            guard !WorkoutSessionStore.isCancellation(error) else { return }
            plans[key] = .some(nil)
        }
    }

    // MARK: - 書き込み

    /// 新規 (id nil) か書き換え。手元の記録で先に検査し (DB の CHECK・EXCLUDE と同じ規則)、書いたら読み直す。失敗は戻り値で返す
    func save(id: UUID?, start: Date, end: Date, kind: SleepKind) async -> Error? {
        guard !isSaving else { return ScheduleStore.SaveError.busy }
        if let error = SleepRules.validate(start: start, end: end, now: now(), others: records, excluding: id) { return error }
        isSaving = true
        defer { isSaving = false }
        var failure: Error?
        do {
            if let id {
                try await dataSource.updateSleepRecord(id: id, start: start, end: end, kind: kind)
            } else {
                _ = try await dataSource.insertSleepRecord(start: start, end: end, kind: kind)
            }
        } catch {
            failure = error
        }
        if !ranges.contains(where: { $0.lowerBound <= start && end <= $0.upperBound }) {
            ranges.append(start..<end)
        }
        await reloadAll()
        return failure
    }

    func delete(id: UUID) async -> Error? {
        guard !isSaving else { return ScheduleStore.SaveError.busy }
        isSaving = true
        defer { isSaving = false }
        var failure: Error?
        do {
            try await dataSource.deleteSleepRecord(id: id)
        } catch {
            failure = error
        }
        await reloadAll()
        return failure
    }
}
