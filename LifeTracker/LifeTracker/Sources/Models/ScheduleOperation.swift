import Foundation

// 予定の編集 (段階 1)。操作の単位・編集の対象・保存/削除の分岐 (pure)。
// 仕様: docs/day-cycle-walkthrough.md「段階 1 確定仕様」の操作表。D = 見ている日 (≥ 今日)

/// 1 回分の中身 (名前・種類・時刻)
struct ScheduleContent: Hashable {
    var name: String
    var categoryId: UUID
    var startMinutes: Int
    var durationMinutes: Int

    /// その日の開始・終了
    func interval(on date: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(startMinutes * 60))
        return (start, start.addingTimeInterval(TimeInterval(durationMinutes * 60)))
    }

    var timeRangeText: String {
        let end = ScheduleRepeat.endMinutes(startMinutes: startMinutes, duration: durationMinutes)
        return "\(ScheduleRepeat.timeText(startMinutes))–\(ScheduleRepeat.timeText(end))"
    }
}

/// 繰り返し (曜日＋祝日)。どちらも無し = 繰り返さない (単発)
struct ScheduleRepeatRule: Hashable {
    var weekdays: Set<ScheduleWeekday>
    var showsOnHoliday: Bool

    static let none = ScheduleRepeatRule(weekdays: [], showsOnHoliday: false)

    var isRepeating: Bool { !weekdays.isEmpty || showsOnHoliday }
    var rrule: String? { ScheduleRepeat.rrule(for: weekdays) }
}

/// 編集画面の入力
struct ScheduleEntryInput: Hashable {
    var content: ScheduleContent
    var repeatRule: ScheduleRepeatRule
}

/// 書き込みの単位。Supabase 実装は 1 操作 = 1 RPC (1 トランザクション)、メモリ上の実装は同じ規則を Swift で持つ
enum ScheduleOperation: Hashable {
    /// 単発を作る (＋ で繰り返しなし)
    case createSingle(date: Date, content: ScheduleContent)
    /// 単発を書き換える (日は変えない)
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

    /// 系列のその日の中身と繰り返し (その日に効く世代から)。終了済み・開始前は nil
    func seriesInput(templateId: UUID, on date: Date, calendar: Calendar) -> ScheduleEntryInput? {
        guard let version = TemplateVersions.effectiveVersion(templateId: templateId, versions: versions, on: date, calendar: calendar) else {
            return nil
        }
        let holiday = holidayPatternId.map { pid in
            versionMemberships.contains { $0.patternId == pid && $0.versionId == version.id }
        } ?? false
        return ScheduleEntryInput(
            content: ScheduleContent(name: version.name, categoryId: version.categoryId,
                                     startMinutes: version.startMinutesFromMidnight, durationMinutes: version.durationMinutes),
            repeatRule: ScheduleRepeatRule(weekdays: ScheduleRepeat.weekdays(from: version.rrule), showsOnHoliday: holiday)
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
            return .apply(.createSingle(date: date, content: input.content))
        case .single(let id):
            if input.repeatRule.isRepeating {
                return .apply(.createSeries(date: date, content: input.content, repeatRule: input.repeatRule, replacingSingle: id))
            }
            if input == target.original { return .noChange }
            return .apply(.updateSingle(id: id, date: date, content: input.content))
        case .occurrence(let templateId, let patternId, _):
            if !input.repeatRule.isRepeating {
                return .confirmStopRepeating(.endSeriesToSingle(templateId: templateId, date: date, content: input.content))
            }
            let following = ScheduleOperation.saveFollowing(templateId: templateId, date: date, content: input.content,
                                                             repeatRule: input.repeatRule)
            // 繰り返しの設定を変えたときは「この予定」を選べない (Google と同じ) → 確認なしで「これ以降」
            if input.repeatRule != target.original?.repeatRule {
                return .apply(following)
            }
            if input == target.original { return .noChange }
            return .chooseScope(
                this: .saveOccurrence(templateId: templateId, date: date, patternId: patternId, content: input.content),
                following: following
            )
        }
    }

    /// 削除 (スワイプ・編集画面の下)。単発は確認なし (スワイプ) / 編集画面からは画面側で確認を出す
    static func delete(target: ScheduleEditTarget) -> Decision {
        switch target.kind {
        case .new:
            return .noChange
        case .single(let id):
            return .apply(.deleteSingle(id: id))
        case .occurrence(let templateId, _, _):
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
            durationMinutes: Int(row.task.endAt.timeIntervalSince(row.task.startAt) / 60)
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
