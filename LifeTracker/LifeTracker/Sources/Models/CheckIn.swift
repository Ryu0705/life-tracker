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
    /// 回数を +1 (record_tap_add。時刻なしの回と、時刻つきで目標 2 以上の回だけ)。at = 押した時刻。
    /// planned = 時刻つきの回の予定の時刻 (回の行を作るときの実績の時刻)。時刻なしは nil。
    /// tapId = アプリが作るタップの id (p_tap_id。同じ id は冪等。読み込んだタップに同じ id があれば楽観更新から外す。R5)
    case tap(key: CheckInKey, name: String, categoryId: UUID, at: Date, plannedStart: Date?, plannedEnd: Date?, tapId: UUID = UUID())
    /// 回数を −1 (record_tap_remove): asOf (見ている日) 以前の最新のタップを消す。0 回になったら記録なしに戻る
    case untap(key: CheckInKey, asOf: Date)
    /// 回数のある回のスキップ (record_skip_set): on = スキップした日 (一覧のスワイプでは見ている日)。タップは残す
    case skipCounted(key: CheckInKey, name: String, categoryId: UUID, on: Date)
    /// 回数のある回のスキップの取り消し (record_skip_clear): タップがあれば「やった」に戻る、無ければ記録なし
    case unskipCounted(key: CheckInKey)

    /// 回のキー (予定外の操作は nil)
    var key: CheckInKey? {
        switch self {
        case .set(let key, _, _, _, _, _), .clear(let key), .tap(let key, _, _, _, _, _, _), .untap(let key, _),
             .skipCounted(let key, _, _, _), .unskipCounted(let key):
            return key
        case .saveActual, .deleteActual:
            return nil
        }
    }

    /// 回数の操作 (record_tap_* / record_skip_*)。書いた後はキャッシュを全部捨てる (繰り越しは何日も先の一覧に出るため)
    var isCounted: Bool {
        switch self {
        case .tap, .untap, .skipCounted, .unskipCounted: return true
        case .set, .clear, .saveActual, .deleteActual: return false
        }
    }
}

enum CheckInRuleError: Error, LocalizedError, Equatable {
    /// 明日以降の回・予定外の実績は記録できない
    case futureDay
    case notFound
    /// 睡眠の種類は実績 (actual_task) に記録しない (DB の checkin_set / actual_save も拒否する)
    case sleepIsSeparate
    case invalidTime
    /// その回の日より前の日には記録できない (タップ・スキップの日)
    case beforeOccurrence
    /// 時刻つきで目標 1 の回は回数を数えない (丸は checkin_set / checkin_clear)
    case notCounted
    /// スキップした回は数えられない (先にスキップを取り消す)
    case skippedOccurrence

    var errorDescription: String? {
        switch self {
        case .beforeOccurrence: return "その予定の日より前には記録できません"
        case .notCounted: return "この予定は回数を数えません"
        case .skippedOccurrence: return "スキップを取り消してから記録してください"
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
    /// 目標 2 以上の回 (スキップ以外)。record = 回の実績 (1 回目のタップで status done の行ができる。0 回は nil)
    case progress(count: Int, target: Int, record: ActualTask?)

    /// やったか。目標 2 以上は status でなく「回数 ≥ 目標」で見る (1/3 でも status は done。計画 2-5)
    var isDone: Bool {
        switch self {
        case .done, .workout: return true
        case .progress(let count, let target, _): return count >= target
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
        case .progress(_, _, let a): return a
        case .none, .workout: return nil
        }
    }
}

/// 回数の楽観更新 (store が応答前の表示に使う)。同じ回が複数の日に出るので数で持たず、足した／消したタップで持ち、
/// 表示する日ごとに数え直す (計画 2-4)
struct TapAdjustment: Hashable {
    /// 応答前に足したタップ (アプリが作った id と押した時刻)
    var added: [ActualTaskTap] = []
    /// 応答前に消した (読み込み済みの) タップの id
    var removed: Set<UUID> = []
    enum Skip: Hashable {
        case skipped(on: Date)
        case unskipped
    }
    var skip: Skip?

    /// 読み込んだタップにこの上書きを重ねた押した時刻 (昇順)。読み込んだタップに同じ id があれば足した分からは数えない (R5)
    func times(_ taps: [ActualTaskTap]) -> [Date] {
        let loaded = Set(taps.map(\.id))
        return (taps.filter { !removed.contains($0.id) }.map(\.tappedAt)
                + added.filter { !loaded.contains($0.id) }.map(\.tappedAt)).sorted()
    }

    /// 上書きを足した後の形。untap は asOf 以前の最新のタップを消す
    static func applying(_ operation: CheckInOperation, to current: TapAdjustment, taps: [ActualTaskTap],
                         calendar: Calendar) -> TapAdjustment {
        var next = current
        switch operation {
        case .tap(_, _, _, let at, _, _, let tapId):
            next.added.append(ActualTaskTap(id: tapId, actualTaskId: UUID(), tappedAt: at))
        case .untap(_, let asOf):
            let limit = calendar.startOfDay(for: asOf)
            let loaded = Set(taps.map(\.id))
            let real = taps.filter { !next.removed.contains($0.id) && calendar.startOfDay(for: $0.tappedAt) <= limit }
            let latestReal = real.max { $0.tappedAt < $1.tappedAt }
            let latestAdded = next.added.filter { !loaded.contains($0.id) && calendar.startOfDay(for: $0.tappedAt) <= limit }
                .max { $0.tappedAt < $1.tappedAt }
            if let latestAdded, latestReal.map({ latestAdded.tappedAt >= $0.tappedAt }) ?? true {
                next.added.removeAll { $0.id == latestAdded.id }
            } else if let latestReal {
                next.removed.insert(latestReal.id)
            }
        case .skipCounted(_, _, _, let on):
            next.skip = .skipped(on: calendar.startOfDay(for: on))
        case .unskipCounted:
            next.skip = .unskipped
        case .set, .clear, .saveActual, .deleteActual:
            break
        }
        return next
    }
}

/// 回数のある回の進み (pure)。閉じた日・回数・スキップの判定の原本 (SQL の todo_closed_on はこの写し)
enum CountProgress {
    /// 閉じた日: 目標の回数目のタップの JST 日と、スキップした日 (skipped_on。nil なら回の日) の早い方。どちらも無ければ nil。
    /// 保存しない (タップ・目標・skipped_on から毎回求める。計画「用語」)
    static func closedOn(record: ActualTask?, tapTimes: [Date], target: Int, calendar: Calendar) -> Date? {
        let sorted = tapTimes.sorted()
        let reached = sorted.count >= max(target, 1) ? calendar.startOfDay(for: sorted[max(target, 1) - 1]) : nil
        let skipped: Date? = record.flatMap { record in
            guard record.status == .skipped else { return nil }
            return calendar.startOfDay(for: record.skippedOn ?? record.occurrenceDate)
        }
        return [reached, skipped].compactMap { $0 }.min()
    }

    /// その日 (asOf) の時点の回数 (JST 日が asOf 以前のタップ)。asOf nil = 全部 (時刻つきの回)
    static func count(tapTimes: [Date], asOf: Date?, calendar: Calendar) -> Int {
        guard let asOf else { return tapTimes.count }
        let limit = calendar.startOfDay(for: asOf)
        return tapTimes.filter { calendar.startOfDay(for: $0) <= limit }.count
    }

    /// その日 (asOf) の時点でスキップか (status skipped かつ スキップした日 ≤ asOf)。asOf nil = status だけで見る
    static func isSkipped(record: ActualTask?, asOf: Date?, calendar: Calendar) -> Bool {
        guard let record, record.status == .skipped else { return false }
        guard let asOf else { return true }
        return calendar.startOfDay(for: record.skippedOn ?? record.occurrenceDate) <= calendar.startOfDay(for: asOf)
    }

    /// 楽観更新を重ねた実績の行 (スキップ・取り消しの status だけ変える。回数はタップで数える)。
    /// 記録の無い回のスキップは、キーから仮の skipped の行を作る (R7)
    static func adjusted(record: ActualTask?, adjustment: TapAdjustment?, tapCount: Int,
                         key: CheckInKey, name: String, categoryId: UUID) -> ActualTask? {
        guard let skip = adjustment?.skip else { return record }
        switch skip {
        case .skipped(let on):
            guard var record = record ?? provisional(key: key, name: name, categoryId: categoryId) else { return nil }
            record.status = .skipped
            record.skippedOn = on
            record.startAt = nil
            record.endAt = nil
            return record
        case .unskipped:
            guard var record, tapCount > 0 else { return nil }
            record.status = .done
            record.skippedOn = nil
            return record
        }
    }

    /// 応答前の仮の実績の行 (id はキーから決める。描き直しで変わらないように)
    static func provisional(key: CheckInKey, name: String, categoryId: UUID) -> ActualTask? {
        switch key {
        case .occurrence(let templateId, let date):
            return ActualTask(id: UUID.virtual(templateId: templateId, startAt: date), name: name, categoryId: categoryId,
                              startAt: nil, endAt: nil, status: .done, templateId: templateId, occurrenceDate: date)
        case .single(let id):
            return ActualTask(id: id, name: name, categoryId: categoryId, startAt: nil, endAt: nil, status: .done,
                              occurrenceDate: nil, scheduledTaskId: id)
        }
    }
}

/// 行の長押しのメニュー (2026-10-14 本人「行の長押しでメニューを出して欲しい。メニューに表示させる処理は既存のものだけ。」)。
/// 項目は丸・スワイプ・回数の − と同じ操作だけ。nil = 出さない (コンテキストメニューは使えない項目を隠す)。削除は予定の操作なので view が足す。
/// 完了した回に完了の項目、記録のない回に取り消しの項目は出さない (2026-10-14 本人「完了しているものに対して完了にする というメニューは不要。逆も然り。」)
struct CheckInMenu {
    /// 完了にする (目標 2 以上は「1回追加」。目標に届いた回は出さない)
    var done: CheckInPlanner.CircleTap?
    /// 完了を取り消す (目標 2 以上は「1回取り消す」。0 回は出さない)
    var undone: CheckInOperation?
    /// スキップ / スキップを取り消す
    var skip: CheckInOperation?
    /// スキップした回 (skip を「スキップを取り消す」と出す)
    var isSkipped: Bool
    /// 目標 2 以上の回 (1 回ずつ足し引きする言い方で出す)
    var isCounted: Bool

    static let empty = CheckInMenu(done: nil, undone: nil, skip: nil, isSkipped: false, isCounted: false)
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
    /// 目標 2 以上の回 (taps・adjustments) は「1/3」の進み。時刻つきの回は繰り越さないので見ている日に依らず全部のタップを数える
    static func state(for row: DayScheduledTask, records: [ActualTask], overrides: [CheckInKey: CheckInOverride],
                      category: Category?, workoutSetTimes: [Date], calendar: Calendar) -> CheckInState {
        state(for: row, records: records, overrides: overrides, category: category, workoutSetTimes: workoutSetTimes,
              calendar: calendar, taps: [], adjustments: [:])
    }

    static func state(for row: DayScheduledTask, records: [ActualTask], overrides: [CheckInKey: CheckInOverride],
                      category: Category?, workoutSetTimes: [Date], calendar: Calendar,
                      taps: [ActualTaskTap], adjustments: [CheckInKey: TapAdjustment]) -> CheckInState {
        let key = CheckInKey.of(row, calendar: calendar)
        if category?.subInputKind == .gym, let first = workoutSetTimes.min(), let last = workoutSetTimes.max() {
            return .workout(first: first, last: last, count: workoutSetTimes.count)
        }
        var record: ActualTask?
        switch overrides[key] {
        case .record(let a): record = a
        case .cleared: record = nil
        case nil: record = records.first { CheckInKey.of($0, calendar: calendar) == key }
        }
        let target = targetCount(for: row, category: category)
        if target >= 2 {
            let adjustment = adjustments[key]
            let recordTaps = record.map { r in taps.filter { $0.actualTaskId == r.id } } ?? []
            let times = (adjustment ?? TapAdjustment()).times(recordTaps)
            record = CountProgress.adjusted(record: record, adjustment: adjustment, tapCount: times.count, key: key,
                                            name: row.task.name, categoryId: row.task.categoryId)
            if let record, record.status == .skipped { return .skipped(record) }
            if record == nil && times.isEmpty { return .progress(count: 0, target: target, record: nil) }
            return .progress(count: times.count, target: target, record: record)
        }
        guard let record else { return .none }
        return record.status == .skipped ? .skipped(record) : .done(record)
    }

    /// 回の目標の回数。ジム・睡眠は目標の回数を出さない (1 固定。AI 既定)
    static func targetCount(for row: DayScheduledTask, category: Category?) -> Int {
        guard category?.subInputKind == nil else { return 1 }
        return max(row.task.targetCount, 1)
    }

    /// 回数の +1 で残す押した時刻: 今日は今、過去日は「その日の、今と同じ時計の時刻」(AI 既定。計画 2-5)
    static func tapTime(viewDay: Date, now: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: viewDay)
        if day >= calendar.startOfDay(for: now) { return now }
        return day.addingTimeInterval(now.timeIntervalSince(calendar.startOfDay(for: now)))
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

    /// 丸のタップ: 記録なし → やった (予定の時刻どおり)。やった／スキップ → 記録なし。セットのあるジムは何もしない。
    /// 目標 2 以上の回は常に +1 (目標を超えても数える)、スキップした回は取り消し。tapAt = 押した時刻 (CheckInPlanner.tapTime)
    static func toggle(row: DayScheduledTask, state: CheckInState, calendar: Calendar, tapAt: Date = Date()) -> CheckInOperation? {
        let key = CheckInKey.of(row, calendar: calendar)
        switch state {
        case .none:
            return .set(key: key, status: .done, name: row.task.name, categoryId: row.task.categoryId,
                        start: row.task.startAt, end: row.task.endAt)
        case .progress:
            return .tap(key: key, name: row.task.name, categoryId: row.task.categoryId, at: tapAt,
                        plannedStart: row.task.startAt, plannedEnd: row.task.endAt)
        case .skipped where row.task.targetCount >= 2:
            return .unskipCounted(key: key)
        case .done, .skipped:
            return .clear(key: key)
        case .workout:
            return nil
        }
    }

    /// 一覧の丸を押したときにすること (2026-10-14 本人指示「時間ありのものはチェックを押すと実績時間の入力を求めるようにして。」)。
    /// 時刻つきで目標 1 の記録なしの回 = 実績の時刻を聞く (シート)。それ以外は toggle と同じ (やった・スキップ → 記録なし、
    /// 目標 2 以上 → +1。AI 既定)。セットのあるジムは nil
    enum CircleTap: Equatable {
        case askActualTime
        case apply(CheckInOperation)
    }

    static func circleTap(row: DayScheduledTask, state: CheckInState, calendar: Calendar, tapAt: Date = Date()) -> CircleTap? {
        if case .none = state { return .askActualTime }
        return toggle(row: row, state: state, calendar: calendar, tapAt: tapAt).map(CircleTap.apply)
    }

    /// 右スワイプ: スキップ／スキップを取り消す (記録なしに戻す)。セットのあるジムは出さない
    /// 目標 2 以上の回は record_skip_* (スキップした日 = 見ている日 skipOn。タップは残す)
    static func skip(row: DayScheduledTask, state: CheckInState, calendar: Calendar, skipOn: Date? = nil) -> CheckInOperation? {
        let key = CheckInKey.of(row, calendar: calendar)
        switch state {
        case .progress:
            return .skipCounted(key: key, name: row.task.name, categoryId: row.task.categoryId,
                                on: skipOn ?? calendar.startOfDay(for: row.task.startAt))
        case .skipped where row.task.targetCount >= 2:
            return .unskipCounted(key: key)
        case .skipped:
            return .clear(key: key)
        case .none, .done:
            return .set(key: key, status: .skipped, name: row.task.name, categoryId: row.task.categoryId,
                        start: nil, end: nil)
        case .workout:
            return nil
        }
    }

    // MARK: - 長押しのメニュー

    /// 時刻つきの行の長押しのメニュー。丸を出さない回 (未来の回・睡眠) とセットのあるジムは空 (スワイプのスキップも出ない回)。
    /// 完了にする = 丸と同じ (記録なし → 実績の時刻のシート、目標 2 以上 → +1。目標に届いた回は出さない)。完了を取り消す = 丸で
    /// 「やった」を取り消すのと同じ clear、目標 2 以上は編集画面の − と同じ untap (時刻つきは全部のタップの中で最新。asOf = now。R12)。
    /// スキップ = 左スワイプと同じ。スキップした回は取り消しだけ (スキップのままでは回数を足し引きできない)
    static func menu(row: DayScheduledTask, state: CheckInState, style: CheckInCircleStyle?, calendar: Calendar,
                     tapAt: Date, now: Date, skipOn: Date) -> CheckInMenu {
        guard let style, style != .hidden, style != .fixedDone else { return .empty }
        let key = CheckInKey.of(row, calendar: calendar)
        let skip = self.skip(row: row, state: state, calendar: calendar, skipOn: skipOn)
        let isCounted = row.task.targetCount >= 2
        switch state {
        case .none:
            return CheckInMenu(done: .askActualTime, undone: nil, skip: skip, isSkipped: false, isCounted: isCounted)
        case .done:
            return CheckInMenu(done: nil, undone: .clear(key: key), skip: skip, isSkipped: false, isCounted: isCounted)
        case .progress(let count, let target, _):
            return CheckInMenu(done: count < target ? circleTap(row: row, state: state, calendar: calendar, tapAt: tapAt) : nil,
                               undone: count > 0 ? .untap(key: key, asOf: now) : nil, skip: skip, isSkipped: false,
                               isCounted: true)
        case .skipped:
            return CheckInMenu(done: nil, undone: nil, skip: skip, isSkipped: true, isCounted: isCounted)
        case .workout:
            return .empty
        }
    }

    /// やることの行の長押しのメニュー (見ている日 ≤ 今日の行だけ。呼び出し側で分ける)。丸・スワイプと同じ操作:
    /// 完了にする = +1 (目標に届いた回は出さない)、完了を取り消す = 見ている日以前の最新のタップを消す (0 回は出さない)
    static func menu(todo: DayTodo, viewDay: Date, tapAt: Date) -> CheckInMenu {
        let isCounted = todo.target >= 2
        if todo.isSkipRecorded {
            return CheckInMenu(done: nil, undone: nil, skip: .unskipCounted(key: todo.key), isSkipped: true, isCounted: isCounted)
        }
        let tap = CheckInOperation.tap(key: todo.key, name: todo.name, categoryId: todo.categoryId, at: tapAt,
                                       plannedStart: nil, plannedEnd: nil)
        return CheckInMenu(done: todo.isDone ? nil : .apply(tap),
                           undone: todo.count > 0 ? .untap(key: todo.key, asOf: viewDay) : nil,
                           skip: .skipCounted(key: todo.key, name: todo.name, categoryId: todo.categoryId, on: viewDay),
                           isSkipped: false, isCounted: isCounted)
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
        case .saveActual, .deleteActual, .tap, .untap, .skipCounted, .unskipCounted:
            // 回数の操作は TapAdjustment で先に見せる
            return nil
        }
    }

    // MARK: - 一覧

    /// 予定の回と予定外の実績を時刻順に並べる。予定外 = その日が「一覧に出る日」で、どの行の回にも付かない「やった」。
    /// 回の無いスキップ (曜日の変更で出なくなった回など) は出さない (本人確認 2026-09-30 (b))。
    /// todoKeys = その日の「やること」の回のキー: 時刻つき → なしに切り替えた回の時刻つきの頃の「やった」を予定外として
    /// 2 か所に出さない (計画 2-2・再レビュー中 5)
    static func listItems(day: Day, calendar: Calendar) -> [ScheduleListItem] {
        listItems(day: day, calendar: calendar, todoKeys: [])
    }

    static func listItems(day: Day, calendar: Calendar, todoKeys: Set<CheckInKey>) -> [ScheduleListItem] {
        let keys = Set(day.scheduled.map { CheckInKey.of($0, calendar: calendar) }).union(todoKeys)
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

    /// 実績の時刻の欄の footer「7:00〜7:40 · 40分」。開始が回の日と違えば日付、終了が翌日なら「（翌日）」を付ける
    static func actualRangeSummary(_ range: (start: Date, end: Date), occurrenceDay: Date?, calendar: Calendar) -> String {
        let startDay = calendar.startOfDay(for: range.start)
        let dayNote = startDay == occurrenceDay ? "" : "\(WorkoutSummary.dayLabel(startDay, calendar: calendar)) "
        let nextDay = calendar.isDate(range.end, inSameDayAs: range.start) ? "" : "（翌日）"
        return "\(dayNote)\(ScheduleRepeat.timeText(minutesOfDay(range.start, calendar: calendar)))〜"
            + "\(ScheduleRepeat.timeText(minutesOfDay(range.end, calendar: calendar)))\(nextDay) · \(durationText(range.start, range.end))"
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
        case .done(let record), .progress(_, _, let record?):
            guard let start = record.startAt, let end = record.endAt,
                  start != row.task.startAt || end != row.task.endAt else { return nil }
            return "実績 \(rangeText(start, end, calendar: calendar))"
        case .progress(_, _, nil):
            return nil
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
        case .progress(let count, let target, _): return .progress(count: count, target: target)
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
    /// 目標 2 以上の回の「3/8」と、枠の進捗の輪 (目標に届いたら中も塗り)。押すたびに +1
    case progress(count: Int, target: Int)
}
