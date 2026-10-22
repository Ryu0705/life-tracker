import Foundation

/// 予定側のメモリ上の実装 (シミュレータ確認 `-mock-day` とテスト用)。本番 DB に触れない。
/// 規則は supabase/migrations/0006_template_version.sql・0007_actual_checkin.sql・0012_untimed_tasks.sql の RPC と同じ
/// (こちらが原本、SQL が写し)。睡眠の記録 (0009 sleep_record) も持つ (`-mock-day` では睡眠タブにも同じインスタンスを渡す)
final class InMemoryScheduleDataSource: DayDataSource, ScheduleDataSource, TodoDataSource, SleepDataSource, @unchecked Sendable {
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
        /// 時刻なしの実体 (scheduled_task の start_at が NULL の行: 単発と O(d)。0012)
        var todoEntities: [TodoEntity] = []
        /// 回数のタップ (actual_task_tap。actual_task を消すと一緒に消える = CASCADE)
        var taps: [ActualTaskTap] = []
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
        // 実績は一覧に出る日が前日か当日 (段階 2。Supabase と同じ条件)
        let actuals = current.actualTasks.filter {
            let d = cal.startOfDay(for: $0.occurrenceDate)
            return d == dayStart || d == previousDay
        }
        let actualIds = Set(actuals.map(\.id))
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
            actualTasks: actuals,
            taps: current.taps.filter { actualIds.contains($0.actualTaskId) },
            workoutSetTimes: current.workoutSetTimes.filter { $0 >= dayStart && $0 < dayEnd },
            sleepRecords: Self.overlapping(current.sleepRecords, SleepRules.fetchRange(for: dayStart, calendar: cal)),
            holidayChecker: holidayChecker,
            calendar: cal
        )
    }

    /// todo_fetch と同じ形 (範囲で絞るだけ。どの回を出すかは TodoBuilder)
    func loadTodos(date: Date) async throws -> TodoFetch {
        let current = withLock { $0 }
        return Self.todoFetch(current, date: date, calendar: calendar)
    }

    static func todoFetch(_ s: State, date: Date, calendar: Calendar) -> TodoFetch {
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        let viewDay = day(date)
        let range = TodoBuilder.fetchRange(for: viewDay, calendar: calendar)
        let singles = s.todoEntities.filter { entity in
            guard entity.templateId == nil, day(entity.occurrenceDate) <= viewDay else { return false }
            let record = s.actualTasks.first { $0.scheduledTaskId == entity.id }
            guard let closed = record.flatMap({ closedOn($0, in: s, calendar: calendar) }) else { return true }
            return closed >= viewDay
        }
        let singleIds = Set(singles.map(\.id))
        let overrides = s.todoEntities.filter {
            $0.templateId != nil && day($0.occurrenceDate) >= range.from && day($0.occurrenceDate) <= viewDay
        }
        /// 系列の回が時刻なしか (O(d) があればその実体、無ければ d に効く世代。0012 todo_occurrence と同じ)
        func isUntimedOccurrence(_ actual: ActualTask) -> Bool {
            guard let key = CheckInKey.of(actual, calendar: calendar),
                  let info = occurrenceInfo(key, in: s, calendar: calendar) else { return false }
            return info.planned == nil
        }
        // 実績は時刻なしの回の分だけ (計画 1-2)
        let actuals = s.actualTasks.filter { actual in
            if let id = actual.scheduledTaskId { return singleIds.contains(id) }
            guard actual.templateId != nil else { return false }
            let d = day(actual.occurrenceDate)
            return d >= range.from && d <= viewDay && isUntimedOccurrence(actual)
        }
        let actualIds = Set(actuals.map(\.id))
        let olderClosed = s.actualTasks.compactMap { actual -> TodoOccurrenceRef? in
            guard let templateId = actual.templateId else { return nil }
            let d = day(actual.occurrenceDate)
            guard d >= range.countFrom, d < range.from, isUntimedOccurrence(actual),
                  let closed = closedOn(actual, in: s, calendar: calendar), closed < viewDay else { return nil }
            return TodoOccurrenceRef(templateId: templateId, occurrenceDate: d)
        }
        return TodoFetch(
            singles: singles,
            overrides: overrides,
            actuals: actuals,
            taps: s.taps.filter { actualIds.contains($0.actualTaskId) && day($0.tappedAt) <= viewDay },
            exdates: s.exdates.filter { day($0.date) >= range.countFrom && day($0.date) <= viewDay },
            dayMetas: s.dayMetas.filter { day($0.date) >= range.countFrom && day($0.date) <= viewDay },
            olderClosed: olderClosed
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

    /// メモリ上は 1 人で、初期データは makeFixture が入れるので何もしない
    func ensureUserDefaults() async throws {}

    // MARK: - 回の規則 (0012 の内部関数 todo_target・todo_closed_on の原本)

    /// 回の日・予定の時刻 (時刻つきの回だけ)・目標の回数。単発 → その実体、系列 → O(d) があればその中身、無ければ d に効く世代
    struct OccurrenceInfo {
        let day: Date
        let planned: (start: Date, end: Date)?
        let target: Int
    }

    static func occurrenceInfo(_ key: CheckInKey, in s: State, calendar: Calendar) -> OccurrenceInfo? {
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        switch key {
        case .single(let id):
            if let task = s.scheduledTasks.first(where: { $0.id == id && $0.templateId == nil }) {
                return OccurrenceInfo(day: day(task.startAt), planned: (task.startAt, task.endAt), target: task.targetCount)
            }
            if let todo = s.todoEntities.first(where: { $0.id == id && $0.templateId == nil }) {
                return OccurrenceInfo(day: day(todo.occurrenceDate), planned: nil, target: todo.targetCount)
            }
            return nil
        case .occurrence(let templateId, let date):
            let d = day(date)
            if let task = s.scheduledTasks.first(where: { $0.templateId == templateId && day($0.startAt) == d }) {
                return OccurrenceInfo(day: d, planned: (task.startAt, task.endAt), target: task.targetCount)
            }
            if let todo = s.todoEntities.first(where: { $0.templateId == templateId && day($0.occurrenceDate) == d }) {
                return OccurrenceInfo(day: d, planned: nil, target: todo.targetCount)
            }
            guard let version = TemplateVersions.effectiveVersion(templateId: templateId, versions: s.versions, on: d,
                                                                  calendar: calendar) else { return nil }
            let content = ScheduleContent(name: version.name, categoryId: version.categoryId, timing: version.timing)
            return OccurrenceInfo(day: d, planned: content.interval(on: d, calendar: calendar), target: version.targetCount)
        }
    }

    /// 閉じた日 (目標の回数目のタップの JST 日とスキップした日の早い方)。保存しない
    static func closedOn(_ record: ActualTask, in s: State, calendar: Calendar) -> Date? {
        let target = CheckInKey.of(record, calendar: calendar).flatMap { occurrenceInfo($0, in: s, calendar: calendar) }?.target ?? 1
        let times = s.taps.filter { $0.actualTaskId == record.id }.map(\.tappedAt)
        return CountProgress.closedOn(record: record, tapTimes: times, target: target, calendar: calendar)
    }

    /// 実績の行を消す (タップも消える = CASCADE)
    private static func removeRecords(_ s: inout State, where predicate: (ActualTask) -> Bool) {
        let removed = Set(s.actualTasks.filter(predicate).map(\.id))
        guard !removed.isEmpty else { return }
        s.actualTasks.removeAll { removed.contains($0.id) }
        s.taps.removeAll { removed.contains($0.actualTaskId) }
    }

    // MARK: - 書き込み (1 操作 = 全部成功か全部取り消し: 作業用のコピーに書いて、最後に差し替える)

    func apply(_ operation: ScheduleOperation) async throws {
        let now = self.now()
        let today = calendar.startOfDay(for: now)
        try withLock { state in
            var work = state
            try Self.apply(operation, to: &work, today: today, calendar: calendar, now: now)
            state = work
        }
    }

    static func apply(_ operation: ScheduleOperation, to s: inout State, today: Date, calendar: Calendar, now: Date? = nil) throws {
        let createdAt = now ?? today
        func assertEditable(_ date: Date) throws {
            guard calendar.startOfDay(for: date) >= today else { throw ScheduleRuleError.pastDay }
        }
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        func isOn(_ task: ScheduledTask, _ templateId: UUID, _ date: Date) -> Bool {
            task.templateId == templateId && day(task.startAt) == day(date)
        }
        func isOn(_ todo: TodoEntity, _ templateId: UUID, _ date: Date) -> Bool {
            todo.templateId == templateId && day(todo.occurrenceDate) == day(date)
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
        /// 目標の回数は 1〜99 (DB の CHECK と同じ。範囲外は丸めずに拒否する。範囲は画面の − ＋ で守る)
        func target(_ content: ScheduleContent) -> Int { content.targetCount }
        func assertTarget(_ content: ScheduleContent) throws {
            guard (1...99).contains(content.targetCount) else { throw ScheduleRuleError.invalidTarget }
        }
        func makeVersion(id: UUID, templateId: UUID, date: Date, content: ScheduleContent, rule: ScheduleRepeatRule,
                         createdAt: Date?) -> TaskTemplateVersion {
            // 繰り越しは時刻なしだけ (carry_chk)
            TaskTemplateVersion(id: id, templateId: templateId, effectiveFrom: day(date), isEnded: false, name: content.name,
                                categoryId: content.categoryId, startMinutesFromMidnight: content.startMinutes,
                                durationMinutes: content.durationMinutes, rrule: rule.rrule, targetCount: target(content),
                                carryOver: !content.timing.isTimed && rule.carriesOver, createdAt: createdAt)
        }
        /// 実体 (単発・O(d)) を時刻の有無に合わせて置く。同じ id の前の実体は消す (時刻あり↔なしの移動)
        func putEntity(id: UUID, date: Date, content: ScheduleContent, templateId: UUID?, patternId: UUID?) {
            // 作成時刻は時刻あり↔なしを切り替えても残す (新しい実体だけ今)
            let createdAtKept = s.todoEntities.first { $0.id == id }?.createdAt
                ?? s.scheduledTasks.first { $0.id == id }?.createdAt ?? createdAt
            s.scheduledTasks.removeAll { $0.id == id }
            s.todoEntities.removeAll { $0.id == id }
            if let range = content.interval(on: date, calendar: calendar) {
                s.scheduledTasks.append(ScheduledTask(id: id, name: content.name, categoryId: content.categoryId, startAt: range.start,
                                                      endAt: range.end, templateId: templateId, patternId: patternId,
                                                      targetCount: target(content), createdAt: createdAtKept))
            } else {
                s.todoEntities.append(TodoEntity(id: id, name: content.name, categoryId: content.categoryId, templateId: templateId,
                                                 patternId: patternId, occurrenceDate: day(date), targetCount: target(content),
                                                 createdAt: createdAtKept))
            }
        }
        /// 単発の元の日 (時刻つきは開始の日、時刻なしは回の日)
        func singleDate(_ id: UUID) throws -> Date {
            if let task = s.scheduledTasks.first(where: { $0.id == id && $0.templateId == nil }) { return day(task.startAt) }
            if let todo = s.todoEntities.first(where: { $0.id == id && $0.templateId == nil }) { return day(todo.occurrenceDate) }
            throw ScheduleRuleError.notFound
        }
        /// 単発を変えられるか (0012 private.schedule_assert_single_editable と同じ規則)。newDate nil = 日を変えない (削除)、
        /// newUntimed = 保存後も時刻なしか (削除は nil)。
        /// 時刻なしで今日の時点で閉じていない (閉じた日が nil か ≥ 今日) 単発:
        /// - 元の日のままは通す。ただし時刻ありへ切り替えるなら元の日 ≥ 今日 (過去日の時刻つきの単発を作らない)
        /// - 日付の変更は閉じた日の無い単発だけ・新しい日 ≥ 今日 (今日閉じた単発を明日へ移すとどの日にも出なくなるため)
        /// それ以外 (時刻つきの単発・今日より前に閉じた単発) は今と同じ「元の日 ≥ 今日 かつ 新しい日 ≥ 今日」
        func assertSingleEditable(_ id: UUID, newDate: Date?, newUntimed: Bool?) throws {
            let original = try singleDate(id)
            if s.todoEntities.contains(where: { $0.id == id }) {
                let record = s.actualTasks.first { $0.scheduledTaskId == id }
                let closed = record.flatMap { closedOn($0, in: s, calendar: calendar) }
                if closed == nil || closed! >= today {
                    if newDate == nil || day(newDate!) == original {
                        if newUntimed == false && original < today { throw ScheduleRuleError.pastDay }
                        return
                    }
                    if closed != nil { throw ScheduleRuleError.closedSingleDate }
                    guard day(newDate!) >= today else { throw ScheduleRuleError.pastDay }
                    return
                }
            }
            guard original >= today, day(newDate ?? original) >= today else { throw ScheduleRuleError.pastDay }
        }
        /// 繰り越し中で今日の時点で閉じていない繰り返しの回か (0012 private.todo_is_open_carried と同じ規則)。
        /// 回の日 < 今日・時刻なしの回・回の日に効く世代が繰り越しオン・閉じた日が nil か ≥ 今日。
        /// 真なら「この予定」の削除を過去の日でも通す (2026-10-15 本人決定 1)
        func isOpenCarried(_ templateId: UUID, _ date: Date) -> Bool {
            let d = day(date)
            guard d < today,
                  let info = occurrenceInfo(.occurrence(templateId: templateId, date: d), in: s, calendar: calendar), info.planned == nil,
                  let version = TemplateVersions.effectiveVersion(templateId: templateId, versions: s.versions, on: d, calendar: calendar),
                  version.carryOver else { return false }
            let closed = s.actualTasks.first { $0.templateId == templateId && day($0.occurrenceDate) == d }
                .flatMap { closedOn($0, in: s, calendar: calendar) }
            return closed.map { $0 >= today } ?? true
        }
        func deleteSingle(_ id: UUID) throws {
            try assertSingleEditable(id, newDate: nil, newUntimed: nil)
            // スキップは消す、やったはつながりを外して残す (FK の SET NULL 相当。migration 0007)。タップも残る
            removeRecords(&s) { $0.scheduledTaskId == id && $0.status == .skipped }
            for i in s.actualTasks.indices where s.actualTasks[i].scheduledTaskId == id { s.actualTasks[i].scheduledTaskId = nil }
            s.scheduledTasks.removeAll { $0.id == id }
            s.todoEntities.removeAll { $0.id == id }
        }
        func deleteFollowing(_ templateId: UUID, _ date: Date) throws {
            try assertEditable(date)
            let d = day(date)
            // D より前の回 (閉じていない繰り越し) の記録は残す (本人決定 3)
            removeRecords(&s) { $0.templateId == templateId && day($0.occurrenceDate) >= d && $0.status == .skipped }
            s.scheduledTasks.removeAll { $0.templateId == templateId && day($0.startAt) >= d }
            s.todoEntities.removeAll { $0.templateId == templateId && day($0.occurrenceDate) >= d }
            removeVersions { $0.templateId == templateId && day($0.effectiveFrom) > d }
            let remaining = s.versions.filter { $0.templateId == templateId }
            let first = remaining.map { day($0.effectiveFrom) }.min()
            if first == nil || first! >= d {
                // 系列ごと消す (世代・除外日・祝日の登録は CASCADE 相当)。D より前の実体があれば止める (FK RESTRICT 相当)
                guard !s.scheduledTasks.contains(where: { $0.templateId == templateId }),
                      !s.todoEntities.contains(where: { $0.templateId == templateId }) else {
                    throw ScheduleRuleError.referencedByPast
                }
                removeVersions { $0.templateId == templateId }
                s.exdates.removeAll { $0.templateId == templateId }
                // 実績: スキップは消す、やったはつながりを外して残す (SET NULL 相当)
                removeRecords(&s) { $0.templateId == templateId && $0.status == .skipped }
                for i in s.actualTasks.indices where s.actualTasks[i].templateId == templateId { s.actualTasks[i].templateId = nil }
                s.templateIds.remove(templateId)
                return
            }
            // 終了の世代 (中身は直前の世代のコピー: 時刻の有無・目標・繰り越しも。rrule なし、祝日の登録なし)
            guard let previous = remaining.filter({ day($0.effectiveFrom) < d }).max(by: { $0.effectiveFrom < $1.effectiveFrom }) else { return }
            let existing = remaining.first { day($0.effectiveFrom) == d }
            let source = existing ?? previous
            let ended = TaskTemplateVersion(
                id: existing?.id ?? UUID(), templateId: templateId, effectiveFrom: d, isEnded: true,
                name: source.name, categoryId: source.categoryId,
                startMinutesFromMidnight: source.startMinutesFromMidnight,
                durationMinutes: source.durationMinutes, rrule: nil, targetCount: source.targetCount, carryOver: source.carryOver,
                createdAt: existing?.createdAt ?? createdAt)
            s.versions.removeAll { $0.id == ended.id }
            s.versions.append(ended)
            setHoliday(versionId: ended.id, false)
        }
        @discardableResult
        func createSingle(_ date: Date, _ content: ScheduleContent) throws -> UUID {
            try assertEditable(date)
            let id = UUID()
            putEntity(id: id, date: date, content: content, templateId: nil, patternId: nil)
            return id
        }

        switch operation {
        case .createSingle(let date, let content):
            try assertTarget(content)
            try createSingle(date, content)

        case .updateSingle(let id, let date, let content):
            try assertTarget(content)
            try assertSingleEditable(id, newDate: date, newUntimed: !content.timing.isTimed)
            // 時刻の有無を変えても記録は残す (本人決定 2)。実績の一覧に出る日も単発の日に合わせる
            putEntity(id: id, date: date, content: content, templateId: nil, patternId: nil)
            for i in s.actualTasks.indices where s.actualTasks[i].scheduledTaskId == id { s.actualTasks[i].occurrenceDate = day(date) }

        case .deleteSingle(let id):
            try deleteSingle(id)

        case .createSeries(let date, let content, let rule, let replacingSingle):
            try assertTarget(content)
            try assertEditable(date)
            guard rule.isRepeating else { throw ScheduleRuleError.noRepeat }
            let templateId = UUID()
            if let replacingSingle {
                // つなぎ直す前に単発の検査 (削除と同じ)。つなぎ直した後だと閉じた日が求まらず、今日より前に閉じた単発も通ってしまう
                // (2026-10-14 穴の修正。SQL も同じ順)。拒否されたら作業用のコピーごと捨てる = 全部取り消し
                try assertSingleEditable(replacingSingle, newDate: nil, newUntimed: nil)
                // 単発の実績は外さず、新しい系列の D の回へつなぎ直す (本人確認 (a)。SQL と同じく単発を消す前に)。
                // タップは押した時刻のまま残り、D の回の進みに入る (AI 既定)
                for i in s.actualTasks.indices where s.actualTasks[i].scheduledTaskId == replacingSingle {
                    s.actualTasks[i].scheduledTaskId = nil
                    s.actualTasks[i].templateId = templateId
                    s.actualTasks[i].occurrenceDate = day(date)
                }
                try deleteSingle(replacingSingle)
            }
            s.templateIds.insert(templateId)
            let version = makeVersion(id: UUID(), templateId: templateId, date: date, content: content, rule: rule, createdAt: createdAt)
            s.versions.append(version)
            setHoliday(versionId: version.id, rule.showsOnHoliday)

        case .saveFollowing(let templateId, let date, let content, let rule):
            try assertTarget(content)
            try assertEditable(date)
            guard rule.isRepeating else { throw ScheduleRuleError.noRepeat }
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            let d = day(date)
            removeVersions { $0.templateId == templateId && day($0.effectiveFrom) > d }
            // D の世代があれば id を保って書き換える
            let existing = s.versions.first { $0.templateId == templateId && day($0.effectiveFrom) == d }
            let version = makeVersion(id: existing?.id ?? UUID(), templateId: templateId, date: d, content: content, rule: rule,
                                      createdAt: existing?.createdAt ?? createdAt)
            s.versions.removeAll { $0.id == version.id }
            s.versions.append(version)
            setHoliday(versionId: version.id, rule.showsOnHoliday)
            // O(D) は消す (本人決定 1)。D より後の O・X は残す。時刻の有無を変えても D の回の記録は残す (本人決定 2)
            s.scheduledTasks.removeAll { isOn($0, templateId, d) }
            s.todoEntities.removeAll { isOn($0, templateId, d) }
            // D より後の O(d) で時刻の有無が新しい中身と違うものは消す (残すと 2 か所に出る・記録できない回が繰り越し続ける。R1)。
            // その回のスキップは消す。やったは系列＋回の日でつながっているので、そのまま新しい世代の回に付く (O(D) を消すときと同じ)
            let mismatched: [Date] = content.timing.isTimed
                ? s.todoEntities.filter { $0.templateId == templateId && day($0.occurrenceDate) > d }.map { day($0.occurrenceDate) }
                : s.scheduledTasks.filter { $0.templateId == templateId && day($0.startAt) > d }.map { day($0.startAt) }
            if !mismatched.isEmpty {
                let days = Set(mismatched)
                s.scheduledTasks.removeAll { $0.templateId == templateId && days.contains(day($0.startAt)) }
                s.todoEntities.removeAll { $0.templateId == templateId && days.contains(day($0.occurrenceDate)) }
                removeRecords(&s) { $0.templateId == templateId && days.contains(day($0.occurrenceDate)) && $0.status == .skipped }
            }

        case .deleteFollowing(let templateId, let date):
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            try deleteFollowing(templateId, date)

        case .endSeriesToSingle(let templateId, let date, let content):
            try assertTarget(content)
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
            try assertTarget(content)
            try assertEditable(date)
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            // 「その日だけ」で時刻の有無は変えない (系列の世代と違う保存は拒否)
            if let version = TemplateVersions.effectiveVersion(templateId: templateId, versions: s.versions, on: date, calendar: calendar),
               version.timing.isTimed != content.timing.isTimed {
                throw ScheduleRuleError.timingMismatch
            }
            let existingId = s.scheduledTasks.first(where: { isOn($0, templateId, date) })?.id
                ?? s.todoEntities.first(where: { isOn($0, templateId, date) })?.id
            putEntity(id: existingId ?? UUID(), date: date, content: content, templateId: templateId, patternId: patternId)

        case .deleteOccurrence(let templateId, let date):
            if !isOpenCarried(templateId, date) { try assertEditable(date) }
            guard s.templateIds.contains(templateId) else { throw ScheduleRuleError.notFound }
            if !s.exdates.contains(where: { $0.templateId == templateId && day($0.date) == day(date) }) {
                s.exdates.append(TemplateExdate(templateId: templateId, date: day(date)))
            }
            s.scheduledTasks.removeAll { isOn($0, templateId, date) }
            s.todoEntities.removeAll { isOn($0, templateId, date) }
            // その日のスキップは消す (やったは残り、時刻つきは予定外として出る。時刻なしは見えない記録として残る)
            removeRecords(&s) { $0.templateId == templateId && day($0.occurrenceDate) == day(date) && $0.status == .skipped }
        }
    }

    // MARK: - 実績の書き込み (migration 0007 の checkin_set / checkin_clear / actual_save / actual_delete、
    // 0012 の record_tap_add / record_tap_remove / record_skip_set / record_skip_clear と同じ規則)

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
        func link(_ key: CheckInKey) -> (templateId: UUID?, scheduledId: UUID?) {
            switch key {
            case .occurrence(let t, _): return (t, nil)
            case .single(let id): return (nil, id)
            }
        }
        func info(_ key: CheckInKey) throws -> OccurrenceInfo {
            guard let info = occurrenceInfo(key, in: s, calendar: calendar) else { throw CheckInRuleError.notFound }
            return info
        }
        /// 回数の操作の共通の検査 (0012 private.record_occurrence_checked): 回がある・明日以降の回でない・時刻つきで目標 1 でない
        /// (時刻つきで目標 1 の回は今の丸 = checkin_set / checkin_clear)
        func checkedInfo(_ key: CheckInKey) throws -> OccurrenceInfo {
            let info = try info(key)
            guard info.day <= today else { throw CheckInRuleError.futureDay }
            if info.planned != nil && info.target < 2 { throw CheckInRuleError.notCounted }
            return info
        }
        /// タップ・スキップの日: 回の日以上・今日以下
        func assertInRange(_ date: Date, _ info: OccurrenceInfo) throws {
            guard day(date) <= today else { throw CheckInRuleError.futureDay }
            guard day(date) >= info.day else { throw CheckInRuleError.beforeOccurrence }
        }

        switch operation {
        case .set(let key, let status, let name, let categoryId, let start, let end):
            let occurrenceDay: Date
            switch key {
            case .occurrence(_, let date):
                occurrenceDay = day(date)
            case .single(let id):
                // O(D) (template_id 付き) は受けない。単発の日は単発の回の日 (0012 occurrence_date)
                if let task = s.scheduledTasks.first(where: { $0.id == id && $0.templateId == nil }) {
                    occurrenceDay = day(task.startAt)
                } else if let todo = s.todoEntities.first(where: { $0.id == id && $0.templateId == nil }) {
                    occurrenceDay = day(todo.occurrenceDate)
                } else {
                    throw CheckInRuleError.notFound
                }
            }
            guard occurrenceDay <= today else { throw CheckInRuleError.futureDay }
            try assertNotSleep(categoryId)
            let skipped = status == .skipped
            if !skipped {
                guard let start, let end, end > start else { throw CheckInRuleError.invalidTime }
            }
            let (templateId, scheduledId) = link(key)
            let existing = s.actualTasks.firstIndex { matches($0, key) }
            let previous = existing.map { s.actualTasks[$0] }
            // スキップ → やったでは skipped_on を外す。スキップのままなら前の skipped_on を保つ (0012 再レビュー重大 3)
            let record = ActualTask(
                id: previous?.id ?? UUID(), name: name, categoryId: categoryId,
                startAt: skipped ? nil : start, endAt: skipped ? nil : end, status: status,
                templateId: templateId, occurrenceDate: occurrenceDay, scheduledTaskId: scheduledId,
                skippedOn: skipped && previous?.status == .skipped ? previous?.skippedOn : nil)
            if let existing {
                s.actualTasks[existing] = record
            } else {
                s.actualTasks.append(record)
            }
            // やったにしたときタップが無ければ 1 つ (押した時刻 = 終了。後で時刻なしへ切り替えても回数 1 で残る)。タップは減らさない
            if !skipped, let end, !s.taps.contains(where: { $0.actualTaskId == record.id }) {
                s.taps.append(ActualTaskTap(id: UUID(), actualTaskId: record.id, tappedAt: end))
            }

        case .clear(let key):
            // 行ごと消す (タップは CASCADE。目標 1 の丸の 2 度目のタップ = 今の取り消し)
            removeRecords(&s) { matches($0, key) }

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
            removeRecords(&s) { $0.id == id }

        case .tap(let key, let name, let categoryId, let at, let plannedStart, let plannedEnd, let tapId):
            // 同じ id のタップは 1 回だけ (送り直しても増えない。R5)
            if s.taps.contains(where: { $0.id == tapId }) { return }
            let info = try checkedInfo(key)
            try assertInRange(at, info)
            try assertNotSleep(categoryId)
            // 時刻つきの回は予定の時刻を渡す (回の行を作るときの実績の時刻)
            if info.planned != nil {
                guard let plannedStart, let plannedEnd, plannedEnd > plannedStart else { throw CheckInRuleError.invalidTime }
            }
            let recordId: UUID
            if let existing = s.actualTasks.first(where: { matches($0, key) }) {
                guard existing.status == .done else { throw CheckInRuleError.skippedOccurrence }
                recordId = existing.id
            } else {
                // 回の行が無ければ done で作る (時刻つきは実績の時刻 = 予定の時刻、時刻なしは時刻なし)。行があれば実績の時刻は保つ
                let timed = info.planned != nil
                let (templateId, scheduledId) = link(key)
                let record = ActualTask(id: UUID(), name: name, categoryId: categoryId, startAt: timed ? plannedStart : nil,
                                        endAt: timed ? plannedEnd : nil, status: .done,
                                        templateId: templateId, occurrenceDate: info.day, scheduledTaskId: scheduledId)
                s.actualTasks.append(record)
                recordId = record.id
            }
            s.taps.append(ActualTaskTap(id: tapId, actualTaskId: recordId, tappedAt: at))

        case .untap(let key, let asOf):
            _ = try checkedInfo(key)
            // 記録が無ければ何もしない
            guard let record = s.actualTasks.first(where: { matches($0, key) }) else { return }
            guard record.status == .done else { throw CheckInRuleError.skippedOccurrence }
            // JST 日が asOf 以前のタップのうち最も新しい 1 つ (無ければ消さない)
            if let latest = s.taps.filter({ $0.actualTaskId == record.id && day($0.tappedAt) <= day(asOf) })
                .max(by: { $0.tappedAt < $1.tappedAt }) {
                s.taps.removeAll { $0.id == latest.id }
            }
            // 0 回になったら行も消す (実績の時刻も消える = 記録なしに戻る)
            if !s.taps.contains(where: { $0.actualTaskId == record.id }) {
                removeRecords(&s) { $0.id == record.id }
            }

        case .skipCounted(let key, let name, let categoryId, let on):
            let info = try checkedInfo(key)
            try assertInRange(on, info)
            try assertNotSleep(categoryId)
            if let index = s.actualTasks.firstIndex(where: { matches($0, key) }) {
                // タップは残す
                s.actualTasks[index].status = .skipped
                s.actualTasks[index].skippedOn = day(on)
                s.actualTasks[index].startAt = nil
                s.actualTasks[index].endAt = nil
                s.actualTasks[index].name = name
                s.actualTasks[index].categoryId = categoryId
                s.actualTasks[index].occurrenceDate = info.day
            } else {
                let (templateId, scheduledId) = link(key)
                s.actualTasks.append(ActualTask(id: UUID(), name: name, categoryId: categoryId, startAt: nil, endAt: nil,
                                                status: .skipped, templateId: templateId, occurrenceDate: info.day,
                                                scheduledTaskId: scheduledId, skippedOn: day(on)))
            }

        case .unskipCounted(let key):
            let info = try checkedInfo(key)
            // スキップでなければ何もしない
            guard let index = s.actualTasks.firstIndex(where: { matches($0, key) && $0.status == .skipped }) else { return }
            let record = s.actualTasks[index]
            if s.taps.contains(where: { $0.actualTaskId == record.id }) {
                // タップがあれば「やった」に戻す (時刻つきは実績の時刻 = 予定の時刻を入れ直す)
                let planned = info.planned
                s.actualTasks[index].status = .done
                s.actualTasks[index].skippedOn = nil
                s.actualTasks[index].startAt = planned?.start
                s.actualTasks[index].endAt = planned?.end
            } else {
                removeRecords(&s) { $0.id == record.id }
            }
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
                    .interval(on: date, calendar: calendar)!
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

            // 時刻なしのやること (0012) の確認用
            let life = Category(id: UUID(), name: "生活", subInputKind: nil)
            state.categories.append(life)
            func todoSeries(_ name: String, from: Date, rrule: String, target: Int, carryOver: Bool) -> UUID {
                let id = UUID()
                state.templateIds.insert(id)
                state.versions.append(TaskTemplateVersion(id: UUID(), templateId: id, effectiveFrom: from, isEnded: false, name: name,
                                                          categoryId: life.id, startMinutesFromMidnight: nil, durationMinutes: nil,
                                                          rrule: rrule, targetCount: target, carryOver: carryOver, createdAt: from))
                return id
            }
            func tap(_ record: ActualTask, _ times: [Date]) {
                state.actualTasks.append(record)
                state.taps += times.map { ActualTaskTap(id: UUID(), actualTaskId: record.id, tappedAt: $0) }
            }
            // 3 日前の単発「書類を出す」(閉じていない → 今日も「3 日前 から」で出る)
            let paperwork = TodoEntity(id: UUID(), name: "書類を出す", categoryId: errand.id, templateId: nil, patternId: nil,
                                       occurrenceDate: offset(-3), targetCount: 1, createdAt: offset(-3))
            state.todoEntities.append(paperwork)
            // 毎日「水を飲む」目標 8・繰り越しオン (昨日から。昨日 3/8 → 今日は「昨日から」の行と今日の行の 2 行)
            let water = todoSeries("水を飲む", from: yesterday, rrule: "FREQ=DAILY", target: 8, carryOver: true)
            tap(ActualTask(id: UUID(), name: "水を飲む", categoryId: life.id, startAt: nil, endAt: nil, templateId: water,
                           occurrenceDate: yesterday), [at(yesterday, 480), at(yesterday, 720), at(yesterday, 900)])
            // 平日「掃除」目標 1・繰り越しオフ (昨日の回は今日に出ない)
            _ = todoSeries("掃除", from: offset(-7), rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", target: 1, carryOver: false)
            // 毎日「ストレッチ」目標 3 (今日 1 回押した)
            let stretch = todoSeries("ストレッチ", from: offset(-7), rrule: "FREQ=DAILY", target: 3, carryOver: false)
            tap(ActualTask(id: UUID(), name: "ストレッチ", categoryId: life.id, startAt: nil, endAt: nil, templateId: stretch,
                           occurrenceDate: today), [max(today, now().addingTimeInterval(-3600))])
        }
        return InMemoryScheduleDataSource(state: state, calendar: calendar, holidayChecker: holidayChecker, now: now)
    }
}
