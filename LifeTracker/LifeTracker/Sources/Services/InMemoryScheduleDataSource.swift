import Foundation

/// 予定側のメモリ上の実装 (シミュレータ確認 `-mock-day` とテスト用)。本番 DB に触れない。
/// 規則は supabase/migrations/0006_template_version.sql の RPC と同じ (こちらが原本、SQL が写し)
final class InMemoryScheduleDataSource: DayDataSource, ScheduleDataSource, @unchecked Sendable {
    struct State {
        var categories: [Category] = []
        var patterns: [Pattern] = []
        /// 系列 (task_template) の id
        var templateIds: Set<UUID> = []
        var versions: [TaskTemplateVersion] = []
        var versionMemberships: [PatternVersionMembership] = []
        var exdates: [TemplateExdate] = []
        var scheduledTasks: [ScheduledTask] = []
        var dayMetas: [DayMeta] = []
        var actualTasks: [ActualTask] = []
    }

    private let lock = NSLock()
    private var state: State
    private let calendar: Calendar
    private let holidayChecker: (Date) -> Bool
    private let now: () -> Date

    init(state: State, calendar: Calendar, holidayChecker: @escaping (Date) -> Bool = { _ in false },
         now: @escaping () -> Date = { Date() }) {
        self.state = state
        self.calendar = calendar
        self.holidayChecker = holidayChecker
        self.now = now
    }

    /// テスト用: 今の中身
    var snapshot: State { withLock { $0 } }

    private func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    // MARK: - 読み取り

    func loadDayContext(date: Date) async throws -> DayBuilderContext {
        let current = withLock { $0 }
        let cal = calendar
        let dayStart = cal.startOfDay(for: date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let previousDay = cal.date(byAdding: .day, value: -1, to: dayStart)!
        return TemplateVersions.context(
            date: dayStart,
            versions: current.versions,
            versionMemberships: current.versionMemberships,
            patterns: current.patterns,
            exdates: current.exdates.filter { cal.isDate($0.date, inSameDayAs: dayStart) },
            previousExdates: current.exdates.filter { cal.isDate($0.date, inSameDayAs: previousDay) },
            dayMeta: current.dayMetas.first { cal.isDate($0.date, inSameDayAs: dayStart) },
            previousDayMeta: current.dayMetas.first { cal.isDate($0.date, inSameDayAs: previousDay) },
            // 前日 0 時から翌日 0 時までに重なる実体 (前日のその日だけ変えた回で前日の流入を抑制するため。レビュー DB §3-1)
            scheduledTasks: current.scheduledTasks.filter { $0.startAt < dayEnd && $0.endAt > previousDay },
            actualTasks: current.actualTasks.filter { $0.startAt < dayEnd && $0.endAt > dayStart },
            holidayChecker: holidayChecker,
            calendar: cal
        )
    }

    func fetchCatalog() async throws -> ScheduleCatalog {
        withLock { ScheduleCatalog(categories: $0.categories, patterns: $0.patterns, versions: $0.versions,
                                   versionMemberships: $0.versionMemberships) }
    }

    func createCategory(name: String) async throws -> Category {
        withLock { state in
            let category = Category(id: UUID(), name: name, subInputKind: nil)
            state.categories.append(category)
            return category
        }
    }

    // MARK: - 書き込み (1 操作 = 全部成功か全部取り消し: 作業用のコピーに書いて、最後に差し替える)

    func apply(_ operation: ScheduleOperation) async throws {
        let today = calendar.startOfDay(for: now())
        try withLock { state in
            var work = state
            try Self.apply(operation, to: &work, today: today, calendar: calendar)
            state = work
        }
    }

    static func apply(_ operation: ScheduleOperation, to s: inout State, today: Date, calendar: Calendar) throws {
        func assertEditable(_ date: Date) throws {
            guard calendar.startOfDay(for: date) >= today else { throw ScheduleRuleError.pastDay }
        }
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        func isOn(_ task: ScheduledTask, _ templateId: UUID, _ date: Date) -> Bool {
            task.templateId == templateId && day(task.startAt) == day(date)
        }
        func holidayPatternId() -> UUID? { s.patterns.first { $0.applyDay == .holiday }?.id }
        func setHoliday(versionId: UUID, _ on: Bool) {
            s.versionMemberships.removeAll { $0.versionId == versionId }
            if on, let pid = holidayPatternId() {
                s.versionMemberships.append(PatternVersionMembership(patternId: pid, versionId: versionId))
            }
        }
        func removeVersions(where predicate: (TaskTemplateVersion) -> Bool) {
            let removed = Set(s.versions.filter(predicate).map(\.id))
            s.versions.removeAll { removed.contains($0.id) }
            s.versionMemberships.removeAll { removed.contains($0.versionId) }
        }
        func makeTask(id: UUID = UUID(), date: Date, content: ScheduleContent, templateId: UUID?, patternId: UUID?) -> ScheduledTask {
            let range = content.interval(on: date, calendar: calendar)
            return ScheduledTask(id: id, name: content.name, categoryId: content.categoryId, startAt: range.start, endAt: range.end,
                                 templateId: templateId, patternId: patternId)
        }
        func singleIndex(_ id: UUID) throws -> Int {
            guard let index = s.scheduledTasks.firstIndex(where: { $0.id == id && $0.templateId == nil }) else {
                throw ScheduleRuleError.notFound
            }
            return index
        }
        func deleteSingle(_ id: UUID) throws {
            let index = try singleIndex(id)
            try assertEditable(s.scheduledTasks[index].startAt)
            s.scheduledTasks.remove(at: index)
        }
        func deleteFollowing(_ templateId: UUID, _ date: Date) throws {
            try assertEditable(date)
            let d = day(date)
            s.scheduledTasks.removeAll { $0.templateId == templateId && day($0.startAt) >= d }
            removeVersions { $0.templateId == templateId && day($0.effectiveFrom) > d }
            let remaining = s.versions.filter { $0.templateId == templateId }
            let first = remaining.map { day($0.effectiveFrom) }.min()
            if first == nil || first! >= d {
                // 系列ごと消す (世代・除外日・祝日の登録は CASCADE 相当)。D より前の実体があれば止める (FK RESTRICT 相当)
                guard !s.scheduledTasks.contains(where: { $0.templateId == templateId }) else {
                    throw ScheduleRuleError.referencedByPast
                }
                removeVersions { $0.templateId == templateId }
                s.exdates.removeAll { $0.templateId == templateId }
                s.templateIds.remove(templateId)
                return
            }
            // 終了の世代 (中身は直前の世代のコピー、rrule なし、祝日の登録なし)
            guard let previous = remaining.filter({ day($0.effectiveFrom) < d }).max(by: { $0.effectiveFrom < $1.effectiveFrom }) else { return }
            let existing = remaining.first { day($0.effectiveFrom) == d }
            let ended = TaskTemplateVersion(
                id: existing?.id ?? UUID(), templateId: templateId, effectiveFrom: d, isEnded: true,
                name: existing?.name ?? previous.name, categoryId: existing?.categoryId ?? previous.categoryId,
                startMinutesFromMidnight: existing?.startMinutesFromMidnight ?? previous.startMinutesFromMidnight,
                durationMinutes: existing?.durationMinutes ?? previous.durationMinutes, rrule: nil)
            s.versions.removeAll { $0.id == ended.id }
            s.versions.append(ended)
            setHoliday(versionId: ended.id, false)
        }
        func createSingle(_ date: Date, _ content: ScheduleContent) throws {
            try assertEditable(date)
            s.scheduledTasks.append(makeTask(date: date, content: content, templateId: nil, patternId: nil))
        }

        switch operation {
        case .createSingle(let date, let content):
            try createSingle(date, content)

        case .updateSingle(let id, let date, let content):
            try assertEditable(date)
            let index = try singleIndex(id)
            try assertEditable(s.scheduledTasks[index].startAt)
            s.scheduledTasks[index] = makeTask(id: id, date: date, content: content, templateId: nil, patternId: nil)

        case .deleteSingle(let id):
            try deleteSingle(id)

        case .createSeries(let date, let content, let rule, let replacingSingle):
            try assertEditable(date)
            guard rule.isRepeating else { throw ScheduleRuleError.noRepeat }
            if let replacingSingle { try deleteSingle(replacingSingle) }
            let templateId = UUID()
            s.templateIds.insert(templateId)
            let version = TaskTemplateVersion(
                id: UUID(), templateId: templateId, effectiveFrom: day(date), isEnded: false, name: content.name,
                categoryId: content.categoryId, startMinutesFromMidnight: content.startMinutes,
                durationMinutes: content.durationMinutes, rrule: rule.rrule)
            s.versions.append(version)
            setHoliday(versionId: version.id, rule.showsOnHoliday)

        case .saveFollowing(let templateId, let date, let content, let rule):
            try assertEditable(date)
            guard rule.isRepeating else { throw ScheduleRuleError.noRepeat }
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            let d = day(date)
            removeVersions { $0.templateId == templateId && day($0.effectiveFrom) > d }
            // D の世代があれば id を保って書き換える
            let existingId = s.versions.first { $0.templateId == templateId && day($0.effectiveFrom) == d }?.id
            let version = TaskTemplateVersion(
                id: existingId ?? UUID(), templateId: templateId, effectiveFrom: d, isEnded: false, name: content.name,
                categoryId: content.categoryId, startMinutesFromMidnight: content.startMinutes,
                durationMinutes: content.durationMinutes, rrule: rule.rrule)
            s.versions.removeAll { $0.id == version.id }
            s.versions.append(version)
            setHoliday(versionId: version.id, rule.showsOnHoliday)
            // O(D) は消す (本人決定 1)。D より後の O・X は残す
            s.scheduledTasks.removeAll { isOn($0, templateId, d) }

        case .deleteFollowing(let templateId, let date):
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            try deleteFollowing(templateId, date)

        case .endSeriesToSingle(let templateId, let date, let content):
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            try deleteFollowing(templateId, date)
            try createSingle(date, content)

        case .saveOccurrence(let templateId, let date, let patternId, let content):
            try assertEditable(date)
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            if let index = s.scheduledTasks.firstIndex(where: { isOn($0, templateId, date) }) {
                s.scheduledTasks[index] = makeTask(id: s.scheduledTasks[index].id, date: date, content: content,
                                                   templateId: templateId, patternId: patternId)
            } else {
                s.scheduledTasks.append(makeTask(date: date, content: content, templateId: templateId, patternId: patternId))
            }

        case .deleteOccurrence(let templateId, let date):
            try assertEditable(date)
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            if !s.exdates.contains(where: { $0.templateId == templateId && day($0.date) == day(date) }) {
                s.exdates.append(TemplateExdate(templateId: templateId, date: day(date)))
            }
            s.scheduledTasks.removeAll { isOn($0, templateId, date) }
        }
    }

    // MARK: - 初期データ

    /// 第 1 世代の日 (migration 0006 の backfill と同じ)
    static let firstVersionDate: (Calendar) -> Date = { calendar in
        calendar.date(from: DateComponents(year: 2026, month: 4, day: 26))!
    }

    /// 本番 DB と同じ初期状態 (2026-09-30 時点: 睡眠 23:00〜8h 毎日・祝日も出す / ジム 6:45〜45 分 平日。休日パターンあり)。
    /// withSamples = シミュレータ確認用に、今日の前後へ「その日だけ変えた回」「除外日」「単発」を 1 つずつ足す
    static func makeFixture(calendar: Calendar, holidayChecker: @escaping (Date) -> Bool,
                            now: @escaping () -> Date = { Date() }, withSamples: Bool = false) -> InMemoryScheduleDataSource {
        let sleep = Category(id: UUID(), name: "睡眠", subInputKind: .sleep)
        let gym = Category(id: UUID(), name: "ジム", subInputKind: .gym)
        let holiday = Pattern(id: UUID(), name: "休日", applyDay: .holiday)
        let sleepId = UUID(), gymId = UUID()
        let first = firstVersionDate(calendar)
        let sleepVersion = TaskTemplateVersion(id: UUID(), templateId: sleepId, effectiveFrom: first, isEnded: false, name: "睡眠",
                                               categoryId: sleep.id, startMinutesFromMidnight: 1380, durationMinutes: 480, rrule: "FREQ=DAILY")
        let gymVersion = TaskTemplateVersion(id: UUID(), templateId: gymId, effectiveFrom: first, isEnded: false, name: "ジム",
                                             categoryId: gym.id, startMinutesFromMidnight: 405, durationMinutes: 45,
                                             rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        var state = State(categories: [sleep, gym], patterns: [holiday], templateIds: [sleepId, gymId],
                          versions: [sleepVersion, gymVersion],
                          versionMemberships: [PatternVersionMembership(patternId: holiday.id, versionId: sleepVersion.id)])
        if withSamples {
            let today = calendar.startOfDay(for: now())
            func offset(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today)! }
            func isGymDay(_ date: Date) -> Bool {
                !holidayChecker(date) && ScheduleRepeat.weekdays.contains(ScheduleWeekday.of(date, calendar: calendar))
            }
            func task(_ date: Date, _ name: String, _ category: UUID, _ start: Int, _ duration: Int, _ templateId: UUID?) -> ScheduledTask {
                let range = ScheduleContent(name: name, categoryId: category, startMinutes: start, durationMinutes: duration)
                    .interval(on: date, calendar: calendar)
                return ScheduledTask(id: UUID(), name: name, categoryId: category, startAt: range.start, endAt: range.end,
                                     templateId: templateId, patternId: nil)
            }
            // 数日後のジム (平日) を 1 回だけ 8:00〜9:00 に
            if let day = (2...8).map(offset).first(where: isGymDay) {
                state.scheduledTasks.append(task(day, "ジム", gym.id, 480, 60, gymId))
            }
            // 数日前のジムもその日だけ変えた回 (過去日の見え方の確認)
            if let day = (2...8).map({ offset(-$0) }).first(where: isGymDay) {
                state.scheduledTasks.append(task(day, "ジム", gym.id, 420, 60, gymId))
            }
            // 3 日後の睡眠を除外日に (その夜と翌朝の流入が消える)
            state.exdates.append(TemplateExdate(templateId: sleepId, date: offset(3)))
            // 明日に単発を 1 つ (種類「用事」)
            let errand = Category(id: UUID(), name: "用事", subInputKind: nil)
            state.categories.append(errand)
            state.scheduledTasks.append(task(offset(1), "買い出し", errand.id, 1080, 60, nil))
        }
        return InMemoryScheduleDataSource(state: state, calendar: calendar, holidayChecker: holidayChecker, now: now)
    }
}
