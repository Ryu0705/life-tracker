import Foundation

// 時刻のないやること (0012)。取得の形 (todo_fetch)・一覧の 1 行・回数の欄で扱う回 (すべて pure)。
// 仕様: docs/untimed-tasks-design.md・docs/untimed-tasks-implementation-plan.md「2. Swift」

/// todo_fetch(p_date, p_from, p_count_from) の結果。範囲で絞っただけの行 (どの回を出すかは TodoBuilder が決める)
struct TodoFetch: Decodable, Hashable {
    /// 時刻なしの単発で、回の日 ≤ V かつ V より前に閉じていないもの
    var singles: [TodoEntity]
    /// 時刻なしのその日だけ変えた回 O(d) で、d ∈ [p_from, V]
    var overrides: [TodoEntity]
    /// 上の単発の実績＋系列の回の実績 (回の日 ∈ [p_from, V])
    var actuals: [ActualTask]
    /// 上の実績のタップ (JST 日 ≤ V)
    var taps: [ActualTaskTap]
    /// 除外日・day_meta (日付 ∈ [p_count_from, V])
    var exdates: [TemplateExdate]
    var dayMetas: [DayMeta]
    /// 系列の回で回の日 ∈ [p_count_from, p_from) かつ V より前に閉じたもの (「ほか N 件」から引く)
    var olderClosed: [TodoOccurrenceRef]

    static let empty = TodoFetch(singles: [], overrides: [], actuals: [], taps: [], exdates: [], dayMetas: [], olderClosed: [])

    init(singles: [TodoEntity], overrides: [TodoEntity], actuals: [ActualTask], taps: [ActualTaskTap],
         exdates: [TemplateExdate], dayMetas: [DayMeta], olderClosed: [TodoOccurrenceRef]) {
        self.singles = singles
        self.overrides = overrides
        self.actuals = actuals
        self.taps = taps
        self.exdates = exdates
        self.dayMetas = dayMetas
        self.olderClosed = olderClosed
    }

    private enum CodingKeys: String, CodingKey {
        case singles, overrides, actuals, taps, exdates, dayMetas, olderClosed
    }

    /// 要素は既存の表の列名の行 (decoder の convertFromSnakeCase で読む)。null の配列は空として読む
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        singles = (try c.decodeIfPresent([ScheduledTaskRow].self, forKey: .singles) ?? []).compactMap(\.todo)
        overrides = (try c.decodeIfPresent([ScheduledTaskRow].self, forKey: .overrides) ?? []).compactMap(\.todo)
        actuals = try c.decodeIfPresent([ActualTask].self, forKey: .actuals) ?? []
        taps = try c.decodeIfPresent([ActualTaskTap].self, forKey: .taps) ?? []
        exdates = try c.decodeIfPresent([TemplateExdate].self, forKey: .exdates) ?? []
        dayMetas = try c.decodeIfPresent([DayMeta].self, forKey: .dayMetas) ?? []
        olderClosed = try c.decodeIfPresent([TodoOccurrenceRef].self, forKey: .olderClosed) ?? []
    }
}

/// 系列の回 (template_id ＋ occurrence_date)
struct TodoOccurrenceRef: Codable, Hashable {
    let templateId: UUID
    @DateOnly var occurrenceDate: Date
}

/// 「やること」の節の 1 行 (時刻なしの回)。回数・スキップ・閉じた日は見ている日 V の時点
struct DayTodo: Identifiable, Hashable {
    enum Origin: Hashable {
        /// 時刻なしの単発
        case single
        /// 繰り返しの回 (世代から組み立てた仮想の回)
        case series
        /// 繰り返しのその日だけ変えた回 O(d)
        case override
    }

    let key: CheckInKey
    let name: String
    let categoryId: UUID
    let target: Int
    /// 回の日 (元の日)。V より前なら繰り越し中 (「10/10 から」)
    let occurrenceDate: Date
    let origin: Origin
    /// 祝日パターン経由の回 (「この予定」の保存に使う)
    let patternId: UUID?
    /// 回の実績 (1 回 1 行)
    let record: ActualTask?
    /// record のタップ (JST 日が V 以前)
    let taps: [ActualTaskTap]
    /// V の時点の回数 (JST 日が V 以前のタップの数)
    let count: Int
    /// V の時点で求めた閉じた日 (CountProgress.closedOn)
    let closedOn: Date?
    /// V の時点でスキップ (skipped_on ≤ V)
    let isSkipped: Bool
    /// 並び (単発は作成順、系列は系列の最初の世代の作成順)
    let sortDate: Date

    var id: CheckInKey { key }
    var templateId: UUID? {
        if case .occurrence(let templateId, _) = key { return templateId }
        return nil
    }
    var isDone: Bool { count >= target }
    var isFinished: Bool { isDone || isSkipped }
    /// スキップの記録がある (V < skipped_on の日でも)。記録の操作は出さず、取り消しだけにする (R6)
    var isSkipRecorded: Bool { record?.status == .skipped }

    /// 楽観更新を重ねた形 (V の時点で数え直す)
    func adjusted(by adjustment: TapAdjustment?, asOf viewDay: Date, calendar: Calendar) -> DayTodo {
        guard let adjustment else { return self }
        let limit = calendar.startOfDay(for: viewDay)
        let times = adjustment.times(taps).filter { calendar.startOfDay(for: $0) <= limit }
        let record = CountProgress.adjusted(record: record, adjustment: adjustment, tapCount: times.count, key: key, name: name,
                                            categoryId: categoryId)
        return DayTodo(key: key, name: name, categoryId: categoryId, target: target, occurrenceDate: occurrenceDate, origin: origin,
                       patternId: patternId, record: record, taps: taps, count: times.count,
                       closedOn: CountProgress.closedOn(record: record, tapTimes: times, target: target, calendar: calendar),
                       isSkipped: CountProgress.isSkipped(record: record, asOf: viewDay, calendar: calendar), sortDate: sortDate)
    }
}

/// 7 日より前の終わっていない繰り越しの回 (系列ごとに 1 行。押せない文字)
struct TodoOlderOpen: Hashable {
    let templateId: UUID
    let name: String
    let count: Int
}

/// 見ている日の「やること」(予定タブだけが読む。Day には入れない。レビュー中 5)
struct TodoDay: Hashable {
    let date: Date
    var todos: [DayTodo]
    var olderOpen: [TodoOlderOpen]

    var keys: Set<CheckInKey> { Set(todos.map(\.key)) }
}

/// 編集画面の「回数」欄で扱う回 (時刻なしの回と、時刻つきで目標 2 以上の回)
struct CountSlot: Hashable {
    let key: CheckInKey
    let name: String
    let categoryId: UUID
    let target: Int
    /// 回の日
    let occurrenceDay: Date
    /// 時刻つきの回の予定の時刻 (回の行を作るときの実績の時刻)。時刻なしは nil
    let plannedStart: Date?
    let plannedEnd: Date?

    var isTimed: Bool { plannedStart != nil }

    init(todo: DayTodo) {
        key = todo.key
        name = todo.name
        categoryId = todo.categoryId
        target = todo.target
        occurrenceDay = todo.occurrenceDate
        plannedStart = nil
        plannedEnd = nil
    }

    init(row: DayScheduledTask, target: Int, calendar: Calendar) {
        key = CheckInKey.of(row, calendar: calendar)
        name = row.task.name
        categoryId = row.task.categoryId
        self.target = target
        occurrenceDay = calendar.startOfDay(for: row.task.startAt)
        plannedStart = row.task.startAt
        plannedEnd = row.task.endAt
    }
}
