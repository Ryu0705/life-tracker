import Foundation

// 予定の予実の記録 (段階 2 チェックイン)。回のキー・丸の状態・書き込みの単位・実績時刻の解釈 (すべて pure)。
// 仕様: docs/day-cycle-walkthrough.md「段階 2 確定仕様」「設計レビューの反映」。
// 睡眠は actual_task に記録しない (専用の表 sleep_record と睡眠タブ。SleepRules・「睡眠（確定仕様）」)

/// 回の同一性 (レビュー §1-5)。店・行・RPC 引数の 3 か所がこれを使う
enum CheckInKey: Hashable {
    /// 繰り返しの予定の回。date = その回の日 (JST 0 時)。前日から続く行は前日になる
    case occurrence(templateId: UUID, date: Date)
    /// 繰り返さない予定 (単発)
    case single(id: UUID)

    /// 一覧の行 → キー。仮想の回も O(D) (その日だけ変えた回) も template_id ＋開始の日で同じキーになる
    static func of(_ row: DayScheduledTask, calendar: Calendar) -> CheckInKey {
        if let templateId = row.task.templateId {
            return .occurrence(templateId: templateId, date: calendar.startOfDay(for: row.task.startAt))
        }
        return .single(id: row.task.id)
    }

    /// 実績 → キー。nil = 予定外の実績
    static func of(_ actual: ActualTask, calendar: Calendar) -> CheckInKey? {
        if let templateId = actual.templateId {
            return .occurrence(templateId: templateId, date: calendar.startOfDay(for: actual.occurrenceDate))
        }
        if let id = actual.scheduledTaskId { return .single(id: id) }
        return nil
    }
}

/// 実績の書き込みの単位。ScheduleOperation とは別 (「D ≥ 今日」の検査を混ぜないため。レビュー §6-1)
enum CheckInOperation: Hashable {
    /// 回の実績を作るか書き換える (1 つの回に 1 行)。skipped は時刻を捨てる。睡眠の種類は受けない
    case set(key: CheckInKey, status: ActualTask.Status, name: String, categoryId: UUID,
             start: Date?, end: Date?)
    /// 回の実績を消す (記録なしに戻す)
    case clear(key: CheckInKey)
    /// 予定外の実績を作るか書き換える。id nil = 新規
    case saveActual(id: UUID?, name: String, categoryId: UUID, start: Date, end: Date)
    /// 実績を消す (予定外として出ている行)
    case deleteActual(id: UUID)
}

enum CheckInRuleError: Error, LocalizedError, Equatable {
    /// 明日以降の回・予定外の実績は記録できない
    case futureDay
    case notFound
    /// 睡眠の種類は実績 (actual_task) に記録しない (DB の checkin_set / actual_save も拒否する)
    case sleepIsSeparate
    case invalidTime

    var errorDescription: String? {
        switch self {
        case .futureDay: return "明日以降の実績は記録できません"
        case .notFound: return "記録が見つかりません。読み直してください"
        case .sleepIsSeparate: return "睡眠は睡眠タブで記録します"
        case .invalidTime: return "開始と終了を別の時刻にしてください"
        }
    }
}

/// 行の左の丸の状態
enum CheckInState: Hashable {
    /// 記録なし (空の丸)
    case none
    /// やった (手で付けた実績。時刻は実績の行)
    case done(ActualTask)
    /// スキップ (行を薄く)
    case skipped(ActualTask)
    /// ジムの回で、その日にトレーニングのセットがある (丸は固定。時刻は最初〜最後のセット)
    case workout(first: Date, last: Date, count: Int)

    var isDone: Bool {
        switch self {
        case .done, .workout: return true
        case .none, .skipped: return false
        }
    }

    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    /// 手で付けた実績の行 (無ければ nil)
    var record: ActualTask? {
        switch self {
        case .done(let a), .skipped(let a): return a
        case .none, .workout: return nil
        }
    }
}

/// 楽観更新の上書き (store が応答前の表示に使う)
enum CheckInOverride: Hashable {
    case record(ActualTask)
    case cleared
}

/// 一覧の 1 行 (予定の回か、予定外の実績)
enum ScheduleListItem: Identifiable, Hashable {
    case planned(DayScheduledTask)
    case unplanned(ActualTask)

    var id: UUID {
        switch self {
        case .planned(let row): return row.id
        case .unplanned(let actual): return actual.id
        }
    }

    var sortDate: Date {
        switch self {
        case .planned(let row): return row.visibleRange.start
        case .unplanned(let actual): return actual.startAt ?? actual.occurrenceDate
        }
    }
}

enum CheckInPlanner {
    // MARK: - 丸の状態

    /// 回の丸の状態。セットのあるジムは実績の行 (スキップを含む) より優先 (決定 C4・レビュー §4-2)。
    /// workoutSetTimes はその回の日のセット (当日の一覧では当日の回にだけ渡す)
    static func state(for row: DayScheduledTask, records: [ActualTask], overrides: [CheckInKey: CheckInOverride],
                      category: Category?, workoutSetTimes: [Date], calendar: Calendar) -> CheckInState {
        let key = CheckInKey.of(row, calendar: calendar)
        if category?.subInputKind == .gym, let first = workoutSetTimes.min(), let last = workoutSetTimes.max() {
            return .workout(first: first, last: last, count: workoutSetTimes.count)
        }
        let record: ActualTask?
        switch overrides[key] {
        case .record(let a): record = a
        case .cleared: record = nil
        case nil: record = records.first { CheckInKey.of($0, calendar: calendar) == key }
        }
        guard let record else { return .none }
        return record.status == .skipped ? .skipped(record) : .done(record)
    }

    /// その日のセットのうち、回の日に完了したもの (前日から続く行には当日のセットを付けない)
    static func workoutSets(for row: DayScheduledTask, day: Day, calendar: Calendar) -> [Date] {
        calendar.startOfDay(for: row.task.startAt) == day.date ? day.workoutSetTimes : []
    }

    /// 丸 (チェックイン) を出すか。回の日で決める (見ている日ではない。レビュー §3-5): 回の日 ≤ 今日。
    /// 睡眠は丸を出さない (C5 見直し)
    static func showsCircle(for row: DayScheduledTask, category: Category?, today: Date, calendar: Calendar) -> Bool {
        guard category?.subInputKind != .sleep else { return false }
        return calendar.startOfDay(for: row.task.startAt) <= calendar.startOfDay(for: today)
    }

    /// 実績欄を出すか。丸と同じ日の条件 (回の日 ≤ 今日)。睡眠の行は実績欄を持たない (記録は睡眠タブだけ。synthesis §5 Q3 = A)
    static func acceptsActual(for row: DayScheduledTask, category: Category?, now: Date, calendar: Calendar) -> Bool {
        guard category?.subInputKind != .sleep else { return false }
        return calendar.startOfDay(for: row.task.startAt) <= calendar.startOfDay(for: now)
    }

    // MARK: - 操作

    /// 丸のタップ: 記録なし → やった (予定の時刻どおり)。やった／スキップ → 記録なし。セットのあるジムは何もしない
    static func toggle(row: DayScheduledTask, state: CheckInState, calendar: Calendar) -> CheckInOperation? {
        let key = CheckInKey.of(row, calendar: calendar)
        switch state {
        case .none:
            return .set(key: key, status: .done, name: row.task.name, categoryId: row.task.categoryId,
                        start: row.task.startAt, end: row.task.endAt)
        case .done, .skipped:
            return .clear(key: key)
        case .workout:
            return nil
        }
    }

    /// 右スワイプ: スキップ／スキップを取り消す (記録なしに戻す)。セットのあるジムは出さない
    static func skip(row: DayScheduledTask, state: CheckInState, calendar: Calendar) -> CheckInOperation? {
        let key = CheckInKey.of(row, calendar: calendar)
        switch state {
        case .skipped:
            return .clear(key: key)
        case .none, .done:
            return .set(key: key, status: .skipped, name: row.task.name, categoryId: row.task.categoryId,
                        start: nil, end: nil)
        case .workout:
            return nil
        }
    }

    /// 楽観更新で先に見せる形 (store が使う)。予定外の操作は nil
    static func override(for operation: CheckInOperation, existing: ActualTask?, calendar: Calendar) -> (CheckInKey, CheckInOverride)? {
        switch operation {
        case .set(let key, let status, let name, let categoryId, let start, let end):
            let (templateId, date, scheduledId): (UUID?, Date?, UUID?) = {
                switch key {
                case .occurrence(let t, let d): return (t, d, nil)
                case .single(let id): return (nil, existing?.occurrenceDate ?? start.map { calendar.startOfDay(for: $0) }, id)
                }
            }()
            let skipped = status == .skipped
            let record = ActualTask(id: existing?.id ?? UUID(), name: name, categoryId: categoryId,
                                    startAt: skipped ? nil : start, endAt: skipped ? nil : end, status: status,
                                    templateId: templateId, occurrenceDate: date, scheduledTaskId: scheduledId)
            return (key, .record(record))
        case .clear(let key):
            return (key, .cleared)
        case .saveActual, .deleteActual:
            return nil
        }
    }

    // MARK: - 一覧

    /// 予定の回と予定外の実績を時刻順に並べる。予定外 = その日が「一覧に出る日」で、どの行の回にも付かない「やった」。
    /// 回の無いスキップ (曜日の変更で出なくなった回など) は出さない (本人確認 2026-09-30 (b))
    static func listItems(day: Day, calendar: Calendar) -> [ScheduleListItem] {
        let keys = Set(day.scheduled.map { CheckInKey.of($0, calendar: calendar) })
        let unplanned = day.records.filter { actual in
            guard actual.status == .done, actual.startAt != nil,
                  calendar.startOfDay(for: actual.occurrenceDate) == day.date else { return false }
            guard let key = CheckInKey.of(actual, calendar: calendar) else { return true }
            return !keys.contains(key)
        }
        let items = day.scheduled.map(ScheduleListItem.planned) + unplanned.map(ScheduleListItem.unplanned)
        return items.sorted { $0.sortDate < $1.sortDate }
    }

    // MARK: - 実績の時刻 (レビュー §3-2)

    /// 時計の時刻 (0 時からの分) を、基準 (予定の開始) の ±12 時間で最も近い時刻にする。
    /// 例: 予定 9/30 23:00・入力 0:30 → 10/1 0:30 / 入力 22:30 → 9/30 22:30
    static func nearest(minutes: Int, around base: Date, calendar: Calendar) -> Date {
        let baseDay = calendar.startOfDay(for: base)
        let candidates = [-1, 0, 1].map { offset -> Date in
            let day = calendar.date(byAdding: .day, value: offset, to: baseDay)!
            return day.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return candidates.min { abs($0.timeIntervalSince(base)) < abs($1.timeIntervalSince(base)) }!
    }

    /// 開始より後で最初にその時計の時刻になる時刻 (24 時間以内)。開始と同じ時計の時刻は nil (0 分・24 時間を区別しない)
    static func end(minutes: Int, after start: Date, calendar: Calendar) -> Date? {
        let startMinutes = minutesOfDay(start, calendar: calendar)
        guard let duration = ScheduleRepeat.duration(startMinutes: startMinutes, endMinutes: minutes) else { return nil }
        return start.addingTimeInterval(TimeInterval(duration * 60))
    }

    /// 回の実績の時刻: 開始は予定の開始の近く、終了は開始の後
    static func occurrenceRange(startMinutes: Int, endMinutes: Int, plannedStart: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let start = nearest(minutes: startMinutes, around: plannedStart, calendar: calendar)
        guard let end = end(minutes: endMinutes, after: start, calendar: calendar) else { return nil }
        return (start, end)
    }

    /// 予定外の実績の時刻: 開始は見ている日 D のその時刻 (一覧に出る日 = D)、終了は開始の後 (翌日になることがある)
    static func unplannedRange(day: Date, startMinutes: Int, endMinutes: Int, calendar: Calendar) -> (start: Date, end: Date)? {
        let start = calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(startMinutes * 60))
        guard let end = end(minutes: endMinutes, after: start, calendar: calendar) else { return nil }
        return (start, end)
    }

    /// 予定外の実績の新規の既定の時刻 (AI 既定): 今日は終了 = 今の直前の :00/:30・開始 = その 1 時間前。過去日は 12:00〜13:00
    static func defaultUnplannedMinutes(day: Date, now: Date, calendar: Calendar) -> (start: Int, end: Int) {
        guard calendar.isDate(day, inSameDayAs: now) else { return (720, 780) }
        let end = minutesOfDay(now, calendar: calendar) / 30 * 30
        if end < 60 { return (0, 60) }
        return (end - 60, end)
    }

    static func minutesOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// 「23:40–7:10」
    static func rangeText(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        "\(ScheduleRepeat.timeText(minutesOfDay(start, calendar: calendar)))–\(ScheduleRepeat.timeText(minutesOfDay(end, calendar: calendar)))"
    }

    /// 「7時間30分」
    static func durationText(_ start: Date, _ end: Date) -> String {
        let total = Int(end.timeIntervalSince(start) / 60)
        let hours = total / 60, minutes = total % 60
        return [hours > 0 ? "\(hours)時間" : nil, minutes > 0 ? "\(minutes)分" : nil].compactMap { $0 }.joined()
    }
}

/// 編集画面の「実績」欄で扱う回 (どの回の実績か)。前日から続く行では前日の回になる
struct CheckInSlot: Hashable {
    /// その回 (予定の時刻は本来の範囲。前日から続く行でも clip 前)
    let row: DayScheduledTask
    let key: CheckInKey
    let occurrenceDay: Date
    /// セットのあるジムの回 (実績欄は読むだけ)
    let workout: CheckInState?

    init(row: DayScheduledTask, category: Category?, state: CheckInState, calendar: Calendar) {
        self.row = row
        self.key = CheckInKey.of(row, calendar: calendar)
        self.occurrenceDay = calendar.startOfDay(for: row.task.startAt)
        if case .workout = state { self.workout = state } else { self.workout = nil }
    }
}

extension CheckInPlanner {
    /// 行の 3 行目 (実績)。予定と違う時刻の「やった」・セットのあるジム・スキップだけ出す。
    /// 睡眠の行は sleep_record から SleepRules.assign / planLine で出す (呼び出し側で分ける)
    static func actualLine(row: DayScheduledTask, state: CheckInState, category: Category?, now: Date, calendar: Calendar) -> String? {
        switch state {
        case .none:
            return nil
        case .skipped:
            return "スキップ"
        case .workout(let first, let last, let count):
            // セット 1 件は時刻を出さない (トレーニングの timeRangeText と同じ。レビュー §4-2)
            return count >= 2 ? "実績 \(rangeText(first, last, calendar: calendar))（トレーニング）" : "トレーニングの記録あり"
        case .done(let record):
            guard let start = record.startAt, let end = record.endAt,
                  start != row.task.startAt || end != row.task.endAt else { return nil }
            return "実績 \(rangeText(start, end, calendar: calendar))"
        }
    }

    /// 丸の見た目
    static func circleStyle(row: DayScheduledTask, state: CheckInState, category: Category?, today: Date,
                            calendar: Calendar) -> CheckInCircleStyle? {
        let rowShows = showsCircle(for: row, category: category, today: today, calendar: calendar)
        if category?.subInputKind == .sleep {
            // 並びを揃える幅だけ取る。一覧に丸が出る日 (見ている日 ≤ 今日) だけ: 前日から続く行は回の日 < 今日、それ以外は回の日 ≤ 今日
            let occurrenceDay = calendar.startOfDay(for: row.task.startAt), todayStart = calendar.startOfDay(for: today)
            return (row.isSpillover ? occurrenceDay < todayStart : occurrenceDay <= todayStart) ? .hidden : nil
        }
        guard rowShows else { return nil }
        switch state {
        case .none: return .empty
        case .done: return .done
        case .skipped: return .skipped
        case .workout: return .fixedDone
        }
    }
}

/// 行の左の丸の見た目
enum CheckInCircleStyle: Hashable {
    /// 記録なし (空の丸)
    case empty
    /// やった (塗りの丸・チェック)
    case done
    /// スキップ
    case skipped
    /// やった・押しても変わらない (セットのあるジム・予定外の実績)
    case fixedDone
    /// 丸を出さない回 (睡眠)。並びを揃えるため幅だけ取る
    case hidden
}
