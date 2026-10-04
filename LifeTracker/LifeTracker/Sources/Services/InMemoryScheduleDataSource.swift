import Foundation

/// 予定側のメモリ上の実装 (シミュレータ確認 `-mock-day` とテスト用)。本番 DB に触れない。
/// 規則は supabase/migrations/0006_template_version.sql・0007_actual_checkin.sql の RPC と同じ (こちらが原本、SQL が写し)。
/// 睡眠の記録 (0009 sleep_record) も持つ (`-mock-day` では睡眠タブにも同じインスタンスを渡す)
final class InMemoryScheduleDataSource: DayDataSource, ScheduleDataSource, SleepDataSource, @unchecked Sendable {
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
        /// トレーニングのセットの completed_at (`-mock-day` のジムの判定用。`-mock-workout` とは独立)
        var workoutSetTimes: [Date] = []
        /// 睡眠の記録 (sleep_record)
        var sleepRecords: [SleepRecord] = []
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
            // 実績は一覧に出る日が前日か当日 (段階 2。Supabase と同じ条件)
            actualTasks: current.actualTasks.filter {
                let d = cal.startOfDay(for: $0.occurrenceDate)
                return d == dayStart || d == previousDay
            },
            workoutSetTimes: current.workoutSetTimes.filter { $0 >= dayStart && $0 < dayEnd },
            sleepRecords: Self.overlapping(current.sleepRecords, SleepRules.fetchRange(for: dayStart, calendar: cal)),
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
            // スキップは消す、やったはつながりを外して残す (FK の SET NULL 相当。migration 0007)
            s.actualTasks.removeAll { $0.scheduledTaskId == id && $0.status == .skipped }
            for i in s.actualTasks.indices where s.actualTasks[i].scheduledTaskId == id { s.actualTasks[i].scheduledTaskId = nil }
            s.scheduledTasks.remove(at: index)
        }
        func deleteFollowing(_ templateId: UUID, _ date: Date) throws {
            try assertEditable(date)
            let d = day(date)
            s.actualTasks.removeAll { $0.templateId == templateId && day($0.occurrenceDate) >= d && $0.status == .skipped }
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
                // 実績: スキップは消す、やったはつながりを外して残す (SET NULL 相当)
                s.actualTasks.removeAll { $0.templateId == templateId && $0.status == .skipped }
                for i in s.actualTasks.indices where s.actualTasks[i].templateId == templateId { s.actualTasks[i].templateId = nil }
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
        @discardableResult
        func createSingle(_ date: Date, _ content: ScheduleContent) throws -> UUID {
            try assertEditable(date)
            let task = makeTask(date: date, content: content, templateId: nil, patternId: nil)
            s.scheduledTasks.append(task)
            return task.id
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
            let templateId = UUID()
            if let replacingSingle {
                _ = try singleIndex(replacingSingle)
                // 単発の実績は外さず、新しい系列の D の回へつなぎ直す (本人確認 (a)。SQL と同じく単発を消す前に)
                for i in s.actualTasks.indices where s.actualTasks[i].scheduledTaskId == replacingSingle {
                    s.actualTasks[i].scheduledTaskId = nil
                    s.actualTasks[i].templateId = templateId
                    s.actualTasks[i].occurrenceDate = day(date)
                }
                try deleteSingle(replacingSingle)
            }
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
            // 単発を作って D の回の実績をつなぎ直してから「これ以降」削除 (つなぎ直した行はスキップでも消えない)
            let single = try createSingle(date, content)
            for i in s.actualTasks.indices
            where s.actualTasks[i].templateId == templateId && day(s.actualTasks[i].occurrenceDate) == day(date) {
                s.actualTasks[i].templateId = nil
                s.actualTasks[i].scheduledTaskId = single
            }
            try deleteFollowing(templateId, date)

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
            // その日のスキップは消す (やったは残り、予定外として出る)
            s.actualTasks.removeAll { $0.templateId == templateId && day($0.occurrenceDate) == day(date) && $0.status == .skipped }
        }
    }

    // MARK: - 実績の書き込み (migration 0007 の checkin_set / checkin_clear / actual_save / actual_delete と同じ規則)

    func applyCheckIn(_ operation: CheckInOperation) async throws {
        let today = calendar.startOfDay(for: now())
        try withLock { state in
            var work = state
            try Self.applyCheckIn(operation, to: &work, today: today, calendar: calendar)
            state = work
        }
    }

    static func applyCheckIn(_ operation: CheckInOperation, to s: inout State, today: Date, calendar: Calendar) throws {
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        func matches(_ actual: ActualTask, _ key: CheckInKey) -> Bool {
            CheckInKey.of(actual, calendar: calendar) == key
        }
        // 睡眠の種類は actual_task に書かない (0007 の checkin_set / actual_save と同じ拒否。記録は sleep_record)
        func assertNotSleep(_ categoryId: UUID) throws {
            if s.categories.first(where: { $0.id == categoryId })?.subInputKind == .sleep { throw CheckInRuleError.sleepIsSeparate }
        }

        switch operation {
        case .set(let key, let status, let name, let categoryId, let start, let end):
            let occurrenceDay: Date
            switch key {
            case .occurrence(_, let date):
                occurrenceDay = day(date)
            case .single(let id):
                // O(D) (template_id 付き) は受けない。単発の日は単発の開始の日
                guard let task = s.scheduledTasks.first(where: { $0.id == id && $0.templateId == nil }) else {
                    throw CheckInRuleError.notFound
                }
                occurrenceDay = day(task.startAt)
            }
            guard occurrenceDay <= today else { throw CheckInRuleError.futureDay }
            try assertNotSleep(categoryId)
            let skipped = status == .skipped
            if !skipped {
                guard let start, let end, end > start else { throw CheckInRuleError.invalidTime }
            }
            let (templateId, scheduledId): (UUID?, UUID?) = {
                switch key {
                case .occurrence(let t, _): return (t, nil)
                case .single(let id): return (nil, id)
                }
            }()
            let existing = s.actualTasks.firstIndex { matches($0, key) }
            let record = ActualTask(
                id: existing.map { s.actualTasks[$0].id } ?? UUID(), name: name, categoryId: categoryId,
                startAt: skipped ? nil : start, endAt: skipped ? nil : end, status: status,
                templateId: templateId, occurrenceDate: occurrenceDay, scheduledTaskId: scheduledId)
            if let existing {
                s.actualTasks[existing] = record
            } else {
                s.actualTasks.append(record)
            }

        case .clear(let key):
            s.actualTasks.removeAll { matches($0, key) }

        case .saveActual(let id, let name, let categoryId, let start, let end):
            try assertNotSleep(categoryId)
            guard day(start) <= today else { throw CheckInRuleError.futureDay }
            guard end > start else { throw CheckInRuleError.invalidTime }
            if let id {
                guard let index = s.actualTasks.firstIndex(where: { $0.id == id && $0.status == .done }) else {
                    throw CheckInRuleError.notFound
                }
                var record = s.actualTasks[index]
                record.name = name
                record.categoryId = categoryId
                record.startAt = start
                record.endAt = end
                // つながりの無い行だけ、一覧に出る日を開始の日に合わせる
                if record.isUnplanned { record.occurrenceDate = day(start) }
                s.actualTasks[index] = record
            } else {
                s.actualTasks.append(ActualTask(id: UUID(), name: name, categoryId: categoryId, startAt: start, endAt: end,
                                                status: .done, occurrenceDate: day(start)))
            }

        case .deleteActual(let id):
            s.actualTasks.removeAll { $0.id == id }
        }
    }

    // MARK: - 睡眠の記録 (0009 sleep_record と同じ規則: 時刻・24 時間・重なり。未来はアプリの検査と同じく拒否)

    static func overlapping(_ records: [SleepRecord], _ range: (from: Date, to: Date)) -> [SleepRecord] {
        records.filter { $0.startAt < range.to && $0.endAt > range.from }.sorted { $0.startAt < $1.startAt }
    }

    func fetchSleepRecords(from: Date, to: Date) async throws -> [SleepRecord] {
        withLock { Self.overlapping($0.sleepRecords, (from, to)) }
    }

    func insertSleepRecord(start: Date, end: Date, kind: SleepKind) async throws -> SleepRecord {
        let now = self.now()
        return try withLock { state in
            if let error = SleepRules.validate(start: start, end: end, now: now, others: state.sleepRecords, excluding: nil) { throw error }
            let record = SleepRecord(id: UUID(), startAt: start, endAt: end, kind: kind, createdAt: now)
            state.sleepRecords.append(record)
            return record
        }
    }

    func updateSleepRecord(id: UUID, start: Date, end: Date, kind: SleepKind) async throws {
        let now = self.now()
        try withLock { state in
            guard let index = state.sleepRecords.firstIndex(where: { $0.id == id }) else { throw SleepRuleError.notFound }
            if let error = SleepRules.validate(start: start, end: end, now: now, others: state.sleepRecords, excluding: id) { throw error }
            state.sleepRecords[index].startAt = start
            state.sleepRecords[index].endAt = end
            state.sleepRecords[index].kind = kind
        }
    }

    func deleteSleepRecord(id: UUID) async throws {
        withLock { $0.sleepRecords.removeAll { $0.id == id } }
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

            // 段階 2 (チェックイン) の確認用
            func at(_ date: Date, _ minutes: Int) -> Date { date.addingTimeInterval(TimeInterval(minutes * 60)) }
            // 数日前のジムの日にセット 3 件 (6:50・7:10・7:35) → その日のジムは「やった」で固定
            if let day = (2...8).map({ offset(-$0) }).first(where: isGymDay) {
                state.workoutSetTimes = [at(day, 410), at(day, 430), at(day, 455)]
            }
            let yesterday = offset(-1)
            // 昨日のジムはスキップ (平日なら)
            if isGymDay(yesterday) {
                state.actualTasks.append(ActualTask(id: UUID(), name: "ジム", categoryId: gym.id, startAt: nil, endAt: nil,
                                                    status: .skipped, templateId: gymId, occurrenceDate: yesterday))
            }
            // 一昨日の夜の睡眠は 23:40–7:10 (sleep_record。昨日の一覧の「前日から継続」の行・睡眠タブの昨日の朝に出る)。
            // 昨夜の睡眠は未入力 (睡眠タブの今朝のカード)。昨日の 13:10–13:40 に仮眠 1 件
            let twoDaysAgo = offset(-2)
            state.sleepRecords = [
                SleepRecord(startAt: at(twoDaysAgo, 1420), endAt: at(yesterday, 430), kind: .sleep, createdAt: at(yesterday, 430)),
                SleepRecord(startAt: at(yesterday, 790), endAt: at(yesterday, 820), kind: .nap, createdAt: at(yesterday, 820)),
            ]
            // 昨日の予定外の実績「読書」14:00–16:00 (種類「用事」)
            state.actualTasks.append(ActualTask(id: UUID(), name: "読書", categoryId: errand.id, startAt: at(yesterday, 840),
                                                endAt: at(yesterday, 960), occurrenceDate: yesterday))
        }
        return InMemoryScheduleDataSource(state: state, calendar: calendar, holidayChecker: holidayChecker, now: now)
    }
}
