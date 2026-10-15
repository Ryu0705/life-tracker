import Foundation

// 予定の編集 (段階 1)。操作の単位・編集の対象・保存/削除の分岐 (pure)。
// 仕様: docs/day-cycle-walkthrough.md「段階 1 確定仕様」の操作表。D = 見ている日 (≥ 今日)

/// 時刻の有無 (0012)。時刻なし = やること (その日のうちにやる。時刻の範囲を持たない)
enum ScheduleTiming: Hashable {
    case timed(startMinutes: Int, durationMinutes: Int)
    case untimed

    var isTimed: Bool {
        if case .timed = self { return true }
        return false
    }
}

/// 1 回分の中身 (名前・種類・時刻の有無・目標の回数)
struct ScheduleContent: Hashable {
    var name: String
    var categoryId: UUID
    var timing: ScheduleTiming
    /// 目標の回数 (1〜99。回数は時刻と独立。docs/untimed-tasks-implementation-plan.md「本人の決定 2」)
    var targetCount: Int

    init(name: String, categoryId: UUID, timing: ScheduleTiming, targetCount: Int = 1) {
        self.name = name
        self.categoryId = categoryId
        self.timing = timing
        self.targetCount = targetCount
    }

    /// 時刻つき
    init(name: String, categoryId: UUID, startMinutes: Int, durationMinutes: Int, targetCount: Int = 1) {
        self.init(name: name, categoryId: categoryId, timing: .timed(startMinutes: startMinutes, durationMinutes: durationMinutes),
                  targetCount: targetCount)
    }

    /// 時刻つきの開始 (0 時からの分)。時刻なしは nil。代入は時刻つきのときだけ効く
    var startMinutes: Int? {
        get {
            if case .timed(let start, _) = timing { return start }
            return nil
        }
        set {
            if case .timed(_, let duration) = timing, let newValue { timing = .timed(startMinutes: newValue, durationMinutes: duration) }
        }
    }

    var durationMinutes: Int? {
        if case .timed(_, let duration) = timing { return duration }
        return nil
    }

    /// その日の開始・終了 (時刻なしは nil)
    func interval(on date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        guard case .timed(let startMinutes, let durationMinutes) = timing else { return nil }
        let start = calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(startMinutes * 60))
        return (start, start.addingTimeInterval(TimeInterval(durationMinutes * 60)))
    }

    var timeRangeText: String {
        guard case .timed(let startMinutes, let durationMinutes) = timing else { return "時刻なし" }
        let end = ScheduleRepeat.endMinutes(startMinutes: startMinutes, duration: durationMinutes)
        return "\(ScheduleRepeat.timeText(startMinutes))–\(ScheduleRepeat.timeText(end))"
    }
}

/// 繰り返し (曜日＋祝日)。どちらも無し = 繰り返さない (単発)
struct ScheduleRepeatRule: Hashable {
    var weekdays: Set<ScheduleWeekday>
    var showsOnHoliday: Bool
    /// 終わらなければ翌日以降にも出す (時刻なしの繰り返しのときだけ意味を持つ。既定オフ)
    var carriesOver: Bool = false

    static let none = ScheduleRepeatRule(weekdays: [], showsOnHoliday: false)

    var isRepeating: Bool { !weekdays.isEmpty || showsOnHoliday }
    var rrule: String? { ScheduleRepeat.rrule(for: weekdays) }
}

/// 編集画面の入力
struct ScheduleEntryInput: Hashable {
    var content: ScheduleContent
    var repeatRule: ScheduleRepeatRule
    /// 時刻なしの単発で日付を変えたときの新しい日 (nil = 変えない。今日以降だけ)
    var singleDate: Date? = nil
}

/// 書き込みの単位。Supabase 実装は 1 操作 = 1 RPC (1 トランザクション)、メモリ上の実装は同じ規則を Swift で持つ
enum ScheduleOperation: Hashable {
    /// 単発を作る (＋ で繰り返しなし)
    case createSingle(date: Date, content: ScheduleContent)
    /// 単発を書き換える。date = 単発の日 (時刻なしの繰り越し中は元の日のまま。日付を変えたときだけ新しい日)
    case updateSingle(id: UUID, date: Date, content: ScheduleContent)
    case deleteSingle(id: UUID)
    /// D からの系列を作る。replacingSingle = 単発に繰り返しを付けたとき、その単発を消して置き換える
    case createSeries(date: Date, content: ScheduleContent, repeatRule: ScheduleRepeatRule, replacingSingle: UUID?)
    /// 「この予定」で保存: O(D) を作るか書き換え。patternId = 祝日パターン経由の回ならその id
    case saveOccurrence(templateId: UUID, date: Date, patternId: UUID?, content: ScheduleContent)
    /// 「この予定」を削除: X(D) を足し、O(D) を消す
    case deleteOccurrence(templateId: UUID, date: Date)
    /// 「これ以降のすべての予定」で保存: D の世代 (D より後の世代は消す)。O(D) は消す、D より後の O・X は残す
    case saveFollowing(templateId: UUID, date: Date, content: ScheduleContent, repeatRule: ScheduleRepeatRule)
    /// 「これ以降のすべての予定」を削除: D に終了の世代 (最初の世代が D 以降なら系列ごと)。D 以降の O はすべて消す
    case deleteFollowing(templateId: UUID, date: Date)
    /// 繰り返しをやめる: 「これ以降」削除 ＋ D の単発
    case endSeriesToSingle(templateId: UUID, date: Date, content: ScheduleContent)
}

/// 編集シートを開く単位 (どの日の、どの回か)
struct ScheduleEditTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case new
        case single(id: UUID)
        /// 繰り返しの回。isOverridden = その日だけ変えた回 (実体 O(D)) を開いている
        case occurrence(templateId: UUID, patternId: UUID?, isOverridden: Bool)
    }

    let id = UUID()
    /// 編集する日 (D)。前日から続く行を押したときは前日になることがある
    let date: Date
    let kind: Kind
    /// 開いた時点の中身と繰り返し。新規は nil
    let original: ScheduleEntryInput?
    /// その日だけ変えた回のとき、系列のいつもの中身 (「いつもは 6:45–7:30」)
    let usual: ScheduleContent?
    /// 時刻なしの単発の元の日 (繰り越し中は date = 見ている日と違う)。時刻つきは nil
    var occurrenceDate: Date? = nil
    /// 今日以降の一覧に出ている、繰り越し中の繰り返しの回 (回の日 < 今日)。予定は読むだけで、その回だけを消せる
    /// (2026-10-15 本人決定 1。「これ以降」は出さない)
    var isCarried = false

    var isNew: Bool { kind == .new }
    var isOverridden: Bool {
        if case .occurrence(_, _, true) = kind { return true }
        return false
    }
    var isOccurrence: Bool {
        if case .occurrence = kind { return true }
        return false
    }
}

/// 予定側の全件の読み取り (編集画面の選択肢と、編集の対象の組み立てに使う)
struct ScheduleCatalog: Equatable {
    var categories: [Category]
    var patterns: [Pattern]
    var versions: [TaskTemplateVersion]
    var versionMemberships: [PatternVersionMembership]

    static let empty = ScheduleCatalog(categories: [], patterns: [], versions: [], versionMemberships: [])

    var holidayPatternId: UUID? {
        patterns.first { $0.applyDay == .holiday }?.id
    }

    func category(_ id: UUID) -> Category? {
        categories.first { $0.id == id }
    }

    /// 系列のその日の中身と繰り返し (その日に効く世代から。時刻の有無を問わない)。終了済み・開始前は nil
    func seriesInput(templateId: UUID, on date: Date, calendar: Calendar) -> ScheduleEntryInput? {
        guard let version = TemplateVersions.effectiveVersion(templateId: templateId, versions: versions, on: date, calendar: calendar) else {
            return nil
        }
        let holiday = holidayPatternId.map { pid in
            versionMemberships.contains { $0.patternId == pid && $0.versionId == version.id }
        } ?? false
        return ScheduleEntryInput(
            content: ScheduleContent(name: version.name, categoryId: version.categoryId, timing: version.timing,
                                     targetCount: version.targetCount),
            repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays(from: version.rrule), showsOnHoliday: holiday,
                                           carriesOver: version.carryOver)
        )
    }
}

/// 保存・削除の分岐と、行 → 編集の対象 (pure)
enum SchedulePlanner {
    enum Decision: Hashable {
        /// 確認なしで実行
        case apply(ScheduleOperation)
        /// 確認「この予定」「これ以降のすべての予定」
        case chooseScope(this: ScheduleOperation, following: ScheduleOperation)
        /// 確認「繰り返しをやめますか？ この日の予定は残ります」
        case confirmStopRepeating(ScheduleOperation)
        case noChange
    }

    /// 保存を押したとき (操作表の「保存」列)
    static func save(target: ScheduleEditTarget, input: ScheduleEntryInput) -> Decision {
        let date = target.date
        switch target.kind {
        case .new:
            if input.repeatRule.isRepeating {
                return .apply(.createSeries(date: date, content: input.content, repeatRule: input.repeatRule, replacingSingle: nil))
            }
            return .apply(.createSingle(date: input.singleDate ?? date, content: input.content))
        case .single(let id):
            if input.repeatRule.isRepeating {
                // 繰り越し中の時刻なしの単発も見ている日 (date) から繰り返す。記録はその日の回へつなぎ直す
                return .apply(.createSeries(date: date, content: input.content, repeatRule: input.repeatRule, replacingSingle: id))
            }
            if input == target.original { return .noChange }
            // 時刻なしの単発は元の日のまま (日付を変えたときだけ新しい日)。時刻ありへ変えたら見ている日の予定にする
            let singleDate = input.singleDate ?? (input.content.timing.isTimed ? date : (target.occurrenceDate ?? date))
            return .apply(.updateSingle(id: id, date: singleDate, content: input.content))
        case .occurrence(let templateId, let patternId, _):
            if !input.repeatRule.isRepeating {
                return .confirmStopRepeating(.endSeriesToSingle(templateId: templateId, date: date, content: input.content))
            }
            let following = ScheduleOperation.saveFollowing(templateId: templateId, date: date, content: input.content,
                                                             repeatRule: input.repeatRule)
            // 繰り返しの設定・時刻の有無を変えたときは「この予定」を選べない (Google と同じ) → 確認なしで「これ以降」
            if input.repeatRule != target.original?.repeatRule
                || input.content.timing.isTimed != target.original?.content.timing.isTimed {
                return .apply(following)
            }
            if input == target.original { return .noChange }
            return .chooseScope(
                this: .saveOccurrence(templateId: templateId, date: date, patternId: patternId, content: input.content),
                following: following
            )
        }
    }

    /// 削除 (スワイプ・長押し・編集画面の下)。単発と繰り越し中の繰り返しの回は確認なし (スワイプ・長押し) /
    /// 編集画面からは画面側で確認を出す
    static func delete(target: ScheduleEditTarget) -> Decision {
        switch target.kind {
        case .new:
            return .noChange
        case .single(let id):
            return .apply(.deleteSingle(id: id))
        case .occurrence(let templateId, _, _):
            // 繰り越し中の回はその回だけ (「これ以降」は過去の日から先をまとめて消すことになるため出さない。本人決定 1)
            if target.isCarried { return .apply(.deleteOccurrence(templateId: templateId, date: target.date)) }
            return .chooseScope(this: .deleteOccurrence(templateId: templateId, date: target.date),
                                following: .deleteFollowing(templateId: templateId, date: target.date))
        }
    }

    /// 行を押したときに開く対象。nil = 押せない。
    /// - 過去の回は押せない (過去日は編集できない。日単位。今日の過ぎた回は編集できる)
    /// - 前日から続く行は、いちばん近い編集できる回を開く: 前日が今日以降なら前日の回、前日が過去なら同じ系列のその日の回 (UI U-2)
    static func editTarget(row: DayScheduledTask, viewDay: Date, day: Day, today: Date,
                           catalog: ScheduleCatalog, calendar: Calendar) -> ScheduleEditTarget? {
        let todayStart = calendar.startOfDay(for: today)
        let occurrenceDay = calendar.startOfDay(for: row.task.startAt)
        if occurrenceDay >= todayStart {
            return target(for: row, on: occurrenceDay, catalog: catalog, calendar: calendar)
        }
        guard case .spillover = row.membership, let templateId = row.task.templateId else { return nil }
        let viewStart = calendar.startOfDay(for: viewDay)
        guard viewStart >= todayStart,
              let sameSeries = day.scheduled.first(where: {
                  $0.task.templateId == templateId && calendar.startOfDay(for: $0.task.startAt) == viewStart
              }) else {
            return nil
        }
        return target(for: sameSeries, on: viewStart, catalog: catalog, calendar: calendar)
    }

    /// その回の中身・繰り返しから編集の対象を作る
    static func target(for row: DayScheduledTask, on date: Date, catalog: ScheduleCatalog, calendar: Calendar) -> ScheduleEditTarget? {
        let dayStart = calendar.startOfDay(for: date)
        let content = ScheduleContent(
            name: row.task.name,
            categoryId: row.task.categoryId,
            startMinutes: Int(row.task.startAt.timeIntervalSince(dayStart) / 60),
            durationMinutes: Int(row.task.endAt.timeIntervalSince(row.task.startAt) / 60),
            targetCount: row.task.targetCount
        )
        guard let templateId = row.task.templateId else {
            return ScheduleEditTarget(date: dayStart, kind: .single(id: row.task.id),
                                      original: ScheduleEntryInput(content: content, repeatRule: .none), usual: nil)
        }
        guard let series = catalog.seriesInput(templateId: templateId, on: dayStart, calendar: calendar) else { return nil }
        let isOverridden = !row.isVirtual
        return ScheduleEditTarget(
            date: dayStart,
            kind: .occurrence(templateId: templateId, patternId: row.task.patternId, isOverridden: isOverridden),
            original: ScheduleEntryInput(content: content, repeatRule: series.repeatRule),
            usual: isOverridden ? series.content : nil
        )
    }
}

extension SchedulePlanner {
    /// 予定の欄を読むだけで開く対象 (過去の回。段階 2 で実績欄だけ入力する)。回の日で組み立てる。
    /// 系列の世代が引けない (終了済みなど) ときは、その回の中身だけを持つ形にする (予定の操作には使わない)
    static func readOnlyTarget(for row: DayScheduledTask, catalog: ScheduleCatalog, calendar: Calendar) -> ScheduleEditTarget {
        let day = calendar.startOfDay(for: row.task.startAt)
        if let target = target(for: row, on: day, catalog: catalog, calendar: calendar) { return target }
        let content = ScheduleContent(
            name: row.task.name, categoryId: row.task.categoryId,
            startMinutes: Int(row.task.startAt.timeIntervalSince(day) / 60),
            durationMinutes: Int(row.task.endAt.timeIntervalSince(row.task.startAt) / 60),
            targetCount: row.task.targetCount
        )
        return ScheduleEditTarget(date: day, kind: .single(id: row.task.id),
                                  original: ScheduleEntryInput(content: content, repeatRule: .none), usual: nil)
    }
}

extension SchedulePlanner {
    /// 「やること」の行を押したときに開く対象。canEditPlan = 予定の欄を編集できるか、canDelete = 削除を出すか。
    /// 回の日 ≥ 今日の回と、閉じていない単発 (見ている日 ≥ 今日) は編集画面。繰り越し中の繰り返しの回 (回の日 < 今日) と過去日は
    /// 予定を読むだけ＋回数の − ＋・スキップ (本人決定 1 2026-10-14)。繰り越し中の繰り返しの回は読むだけでもその回だけを消せる
    /// (2026-10-15 本人決定 1)。過去日の行は消せない (決定 3)。単発の date は見ている日、元の日は occurrenceDate
    static func todoTarget(for todo: DayTodo, viewDay: Date, today: Date, catalog: ScheduleCatalog,
                           calendar: Calendar) -> (target: ScheduleEditTarget, canEditPlan: Bool, canDelete: Bool) {
        let viewStart = calendar.startOfDay(for: viewDay), todayStart = calendar.startOfDay(for: today)
        let content = ScheduleContent(name: todo.name, categoryId: todo.categoryId, timing: .untimed, targetCount: todo.target)
        switch todo.key {
        case .single(let id):
            let target = ScheduleEditTarget(date: viewStart, kind: .single(id: id),
                                            original: ScheduleEntryInput(content: content, repeatRule: .none), usual: nil,
                                            occurrenceDate: todo.occurrenceDate)
            return (target, viewStart >= todayStart, viewStart >= todayStart)
        case .occurrence(let templateId, let date):
            let series = catalog.seriesInput(templateId: templateId, on: date, calendar: calendar)
            let isOverridden = todo.origin == .override
            let isCarried = date < todayStart && viewStart >= todayStart
            var target = ScheduleEditTarget(
                date: date,
                kind: .occurrence(templateId: templateId, patternId: todo.patternId, isOverridden: isOverridden),
                original: ScheduleEntryInput(content: content, repeatRule: series?.repeatRule ?? .none),
                usual: isOverridden ? series?.content : nil
            )
            target.isCarried = isCarried
            let canEditPlan = series != nil && date >= todayStart && viewStart >= todayStart
            return (target, canEditPlan, canEditPlan || isCarried)
        }
    }

    /// 消せない予定の行の理由 (長押しの灰色の「削除」の 2 行目。2026-10-15 本人決定 2・3)。nil = 理由を出さない。
    /// - 過去の日の行は、時刻つき・やること・繰り返しかどうかに関係なく「過去の日の予定は変えられません」の一つ (決定 3)
    /// - 今日以降の日の、前日から続く時刻つきの行 (spilloverFrom = その行の回の日) は回の日を出す (決定 2)。
    ///   回の日 < 今日 は「前の日の予定は変えられません」、回の日 ≥ 今日 (明日以降を見ているとき) は前の日の予定を
    ///   ここからは消せない、とだけ言う (どこで消せるかの補足は足さない。2026-10-15 本人の指摘で取り下げた案と同じ形になるため)
    static func deleteBlockedReason(viewDay: Date, spilloverFrom: Date?, today: Date, calendar: Calendar) -> String? {
        let viewStart = calendar.startOfDay(for: viewDay), todayStart = calendar.startOfDay(for: today)
        if viewStart < todayStart { return "過去の日の予定は変えられません" }
        guard let spilloverFrom else { return nil }
        let day = calendar.startOfDay(for: spilloverFrom)
        let parts = calendar.dateComponents([.month, .day], from: day)
        let label = "\(parts.month ?? 0)/\(parts.day ?? 0) の予定です。"
        return label + (day < todayStart ? "前の日の予定は変えられません" : "前の日の予定はここからは消せません")
    }
}
