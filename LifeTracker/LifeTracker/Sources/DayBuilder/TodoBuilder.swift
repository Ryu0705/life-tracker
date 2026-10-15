import Foundation

/// 「やること」(時刻なしの回) の組み立て (pure)。どの回を出すかの規則の原本 (SQL の todo_fetch は範囲で絞るだけ)。
/// docs/untimed-tasks-implementation-plan.md 2-2:
/// - 系列: 日 d ∈ [V−7, V] ごとに、d に効く世代が時刻なしで、DayBuilder と同じ規則 (OccurrenceRule) で d に回があるもの。
///   d < V の回は d の世代の「繰り越す」がオンのものだけ。O(d) があればその中身
/// - 単発: 回の日 ≤ V のもの全部
/// - 見せる条件: 閉じた日が nil か ≥ V。回数・スキップは V の時点
/// - 「ほか N 件」: d ∈ [V−366, V−8] の繰り越しオンの回から、V より前に閉じた回を引いた数
enum TodoBuilder {
    /// 繰り越しを遡る日数 (本人決定 2026-10-13: 7 日)
    static let carryDays = 7
    /// 「ほか N 件」を数える日数 (1 年より前は数えない。AI 既定)
    static let countDays = 366

    /// todo_fetch の範囲 (p_from = V−7、p_count_from = V−366)
    static func fetchRange(for date: Date, calendar: Calendar) -> (from: Date, countFrom: Date) {
        let day = calendar.startOfDay(for: date)
        return (calendar.date(byAdding: .day, value: -carryDays, to: day)!, calendar.date(byAdding: .day, value: -countDays, to: day)!)
    }

    static func build(date: Date, versions: [TaskTemplateVersion], versionMemberships: [PatternVersionMembership],
                      patterns: [Pattern], fetch: TodoFetch, holidayChecker: (Date) -> Bool, calendar: Calendar) -> TodoDay {
        let viewDay = calendar.startOfDay(for: date)
        func day(_ d: Date) -> Date { calendar.startOfDay(for: d) }
        func offset(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: viewDay)! }
        let seriesIds = Set(versions.map(\.templateId))
        let membershipsByVersion = Dictionary(grouping: versionMemberships, by: \.versionId)
        let exdates = Set(fetch.exdates.map { "\($0.templateId)|\(day($0.date).timeIntervalSince1970)" })
        func isExcluded(_ templateId: UUID, _ d: Date) -> Bool { exdates.contains("\(templateId)|\(d.timeIntervalSince1970)") }
        func mode(_ d: Date) -> OccurrenceRule.Mode {
            OccurrenceRule.mode(dayStart: d, dayMeta: fetch.dayMetas.first { day($0.date) == d }, patterns: patterns,
                                holidayChecker: holidayChecker, calendar: calendar)
        }
        /// d の世代で d に回があるか (時刻なしの世代だけ)
        func occurrence(_ templateId: UUID, on d: Date, mode: OccurrenceRule.Mode) -> (version: TaskTemplateVersion, patternId: UUID?)? {
            guard let version = TemplateVersions.effectiveVersion(templateId: templateId, versions: versions, on: d, calendar: calendar),
                  !version.timing.isTimed, !isExcluded(templateId, d) else { return nil }
            let memberships = (membershipsByVersion[version.id] ?? []).map {
                PatternTemplateMembership(patternId: $0.patternId, templateId: templateId)
            }
            let result = OccurrenceRule.occurs(templateId: templateId, rrule: version.rrule, mode: mode, memberships: memberships,
                                               on: d, calendar: calendar)
            return result.occurs ? (version, result.patternId) : nil
        }
        /// 系列の並び: 最初の世代の作成順 (作成時刻が無ければ最初の世代の日)
        let seriesSortDate: [UUID: Date] = Dictionary(grouping: versions, by: \.templateId).mapValues { list in
            list.compactMap(\.createdAt).min() ?? list.map(\.effectiveFrom).min()!
        }
        func make(key: CheckInKey, name: String, categoryId: UUID, target: Int, occurrenceDate: Date, origin: DayTodo.Origin,
                  patternId: UUID?, sortDate: Date) -> DayTodo? {
            let record = fetch.actuals.first { CheckInKey.of($0, calendar: calendar) == key }
            let taps = record.map { r in
                fetch.taps.filter { $0.actualTaskId == r.id && day($0.tappedAt) <= viewDay }.sorted { $0.tappedAt < $1.tappedAt }
            } ?? []
            let times = taps.map(\.tappedAt)
            let closedOn = CountProgress.closedOn(record: record, tapTimes: times, target: target, calendar: calendar)
            if let closedOn, closedOn < viewDay { return nil }
            return DayTodo(key: key, name: name, categoryId: categoryId, target: target, occurrenceDate: occurrenceDate, origin: origin,
                           patternId: patternId, record: record, taps: taps, count: times.count, closedOn: closedOn,
                           isSkipped: CountProgress.isSkipped(record: record, asOf: viewDay, calendar: calendar), sortDate: sortDate)
        }

        var todos: [DayTodo] = []
        // 系列 (V から 7 日前まで)
        for n in 0...carryDays {
            let d = offset(n)
            let m = mode(d)
            for templateId in seriesIds {
                let override = fetch.overrides.first { $0.templateId == templateId && day($0.occurrenceDate) == d }
                let version = TemplateVersions.effectiveVersion(templateId: templateId, versions: versions, on: d, calendar: calendar)
                let patternId: UUID?
                if let override {
                    // その日だけ変えた回は規則に依らず出る (DayBuilder の実体と同じ)。繰り越しは d の世代で決める
                    if d < viewDay && !(version?.carryOver ?? false) { continue }
                    patternId = override.patternId
                } else {
                    guard let found = occurrence(templateId, on: d, mode: m) else { continue }
                    if d < viewDay && !found.version.carryOver { continue }
                    patternId = found.patternId
                }
                guard let content = override.map({ ($0.name, $0.categoryId, $0.targetCount) })
                        ?? version.map({ ($0.name, $0.categoryId, $0.targetCount) }) else { continue }
                if let todo = make(key: .occurrence(templateId: templateId, date: d), name: content.0, categoryId: content.1,
                                   target: content.2, occurrenceDate: d, origin: override == nil ? .series : .override,
                                   patternId: patternId, sortDate: seriesSortDate[templateId] ?? d) {
                    todos.append(todo)
                }
            }
        }
        // 単発 (繰り越しに上限なし)
        for single in fetch.singles where single.templateId == nil && day(single.occurrenceDate) <= viewDay {
            if let todo = make(key: .single(id: single.id), name: single.name, categoryId: single.categoryId, target: single.targetCount,
                               occurrenceDate: day(single.occurrenceDate), origin: .single, patternId: nil,
                               sortDate: single.createdAt ?? day(single.occurrenceDate)) {
                todos.append(todo)
            }
        }

        // 7 日より前の終わっていない回 (系列ごと)
        let closed = Set(fetch.olderClosed.map { "\($0.templateId)|\(day($0.occurrenceDate).timeIntervalSince1970)" })
        var olderOpen: [TodoOlderOpen] = []
        let olderDays = ((carryDays + 1)...countDays).map { offset($0) }
        let olderModes = olderDays.map(mode)
        for templateId in seriesIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            var count = 0
            for (d, m) in zip(olderDays, olderModes) {
                guard let found = occurrence(templateId, on: d, mode: m), found.version.carryOver,
                      !closed.contains("\(templateId)|\(d.timeIntervalSince1970)") else { continue }
                count += 1
            }
            guard count > 0 else { continue }
            let latest = versions.filter { $0.templateId == templateId }.max { $0.effectiveFrom < $1.effectiveFrom }!
            olderOpen.append(TodoOlderOpen(templateId: templateId, name: latest.name, count: count))
        }
        return TodoDay(date: viewDay, todos: sorted(todos), olderOpen: olderOpen.sorted { $0.name < $1.name })
    }

    /// 並び: 終わっていない → 終わった。同じ中は作った順。同じ系列の重なる回は古い回が上
    static func sorted(_ todos: [DayTodo]) -> [DayTodo] {
        todos.sorted { a, b in
            if a.isFinished != b.isFinished { return !a.isFinished }
            if a.sortDate != b.sortDate { return a.sortDate < b.sortDate }
            if a.name != b.name { return a.name < b.name }
            if a.occurrenceDate != b.occurrenceDate { return a.occurrenceDate < b.occurrenceDate }
            return a.key.sortText < b.key.sortText
        }
    }
}

extension CheckInKey {
    /// 並びを安定させるための文字列
    var sortText: String {
        switch self {
        case .occurrence(let templateId, let date): return "o\(templateId.uuidString)\(date.timeIntervalSince1970)"
        case .single(let id): return "s\(id.uuidString)"
        }
    }
}
