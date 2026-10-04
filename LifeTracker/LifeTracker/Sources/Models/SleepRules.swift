import Foundation
import Supabase

// 睡眠の記録 (sleep_record) と、どの夜か・予定タブの行との結び・既定の時刻・数字の規則 (すべて pure)。
// 睡眠に関わる日付の計算はこのファイルだけが持つ。calendar は JST 固定のものを注入する (端末のタイムゾーンを使わない)。
// 仕様: docs/day-cycle-walkthrough.md「睡眠（確定仕様）」、docs/sleep-design/implementation-plan.md (synthesis.md §3 からの差分)

/// 睡眠の種別。本人が記録シートで選ぶ (既定は通常の睡眠。時刻からは判定しない。2026-10-03 本人決定)
enum SleepKind: String, Codable, Hashable, CaseIterable, Identifiable {
    /// 通常の睡眠 (夜の睡眠。一覧の 1 朝・平均・推移に入る)
    case sleep
    /// 仮眠 (一覧に行として出すだけ。平均・推移に入れない)
    case nap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sleep: return "通常の睡眠"
        case .nap: return "仮眠"
        }
    }
}

/// 睡眠の記録 1 件 (sleep_record の 1 行)。どの夜かは保存しない (SleepRules.nightKey で表示時に計算)
struct SleepRecord: Identifiable, Hashable, Codable {
    let id: UUID
    /// 就寝
    var startAt: Date
    /// 起床
    var endAt: Date
    var kind: SleepKind
    let createdAt: Date

    init(id: UUID = UUID(), startAt: Date, endAt: Date, kind: SleepKind = .sleep, createdAt: Date = Date()) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.kind = kind
        self.createdAt = createdAt
    }

    var duration: TimeInterval { endAt.timeIntervalSince(startAt) }
}

/// 鍵ごとにまとめた 1 夜 (通常の睡眠だけ。表示用で保存しない)
struct SleepNight: Hashable {
    /// 夜の鍵 (就寝 − 12 時間の JST 日の 0 時)
    let key: Date
    /// 開始順
    let records: [SleepRecord]

    /// 就寝 = 最初の記録の就寝
    var start: Date { records.map(\.startAt).min()! }
    /// 起床 = 最後の記録の起床
    var end: Date { records.map(\.endAt).max()! }
    /// 睡眠時間 = 各記録の合計 (分けた夜の間の覚醒は入れない)
    var total: TimeInterval { records.reduce(0) { $0 + $1.duration } }
}

/// その夜の睡眠の予定 (予定タブの睡眠の行の開始〜終了。clip 前)
struct SleepPlan: Hashable {
    let start: Date
    let end: Date
}

/// 推移・1 画面目の数字 (通常の睡眠だけ)
struct SleepStats: Hashable {
    /// 記録がある朝の数
    let recordedCount: Int
    /// 期間のうち経過した朝の数 (今日まで)
    let elapsedCount: Int
    let averageDuration: TimeInterval?
    /// 平均の就寝・起床 (0 時からの分)
    let averageBedtimeMinutes: Int?
    let averageWakeMinutes: Int?
}

/// 保存前の検査の失敗 (InMemory も同じ関数で拒否する)
enum SleepRuleError: Error, LocalizedError, Equatable {
    /// 起床 ≤ 就寝
    case invalidTime
    /// 24 時間を超える
    case tooLong
    /// 起床が今より後
    case future
    /// 他の記録と重なる (その記録の id)
    case overlap(UUID)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidTime: return "就寝と起床を別の時刻にしてください"
        case .tooLong: return "24 時間を超える記録はできません"
        case .future: return "まだ起きていない時刻は記録できません"
        case .overlap: return "この時間には記録があります"
        case .notFound: return "記録が見つかりません。読み直してください"
        }
    }
}

enum SleepRules {
    /// 夜の鍵のずらし幅 (就寝 − 12 時間の日 = どの夜か)
    static let nightKeyOffset: TimeInterval = 12 * 3600
    /// 上限 (DB の sleep_record_span_chk と同じ)
    static let maxDuration: TimeInterval = 24 * 3600
    /// 予定も前回の記録も無いときの就寝 (23:00)
    static let fallbackBedtimeMinutes = 23 * 60
    /// 過去の朝を記録するときの起床の既定 (前回の記録が無いとき 7:00)
    static let fallbackWakeMinutes = 7 * 60
    /// 時刻の刻み (分)
    static let minuteStep = 5
    /// 平均の就寝・起床は 18:00 を 0 とした分で平均する (0 時またぎで平均が昼にならないように)
    static let averageOriginMinutes = 18 * 60

    // MARK: - どの夜か

    static func kind(of record: SleepRecord) -> SleepKind { record.kind }

    /// 通常の睡眠: startOfDay(就寝 − 12h)。仮眠: startOfDay(就寝)
    static func nightKey(of record: SleepRecord, calendar: Calendar) -> Date {
        switch record.kind {
        case .sleep: return nightKey(bedtime: record.startAt, calendar: calendar)
        case .nap: return calendar.startOfDay(for: record.startAt)
        }
    }

    static func nightKey(bedtime: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: bedtime.addingTimeInterval(-nightKeyOffset))
    }

    /// 見出しの日: 通常の睡眠 = 鍵 + 1 日 (「10/2(金) の朝」)、仮眠 = 鍵 (その日)
    static func displayDay(of record: SleepRecord, calendar: Calendar) -> Date {
        let key = nightKey(of: record, calendar: calendar)
        switch record.kind {
        case .sleep: return morning(ofKey: key, calendar: calendar)
        case .nap: return key
        }
    }

    /// 鍵 → 朝 (鍵 + 1 日)
    static func morning(ofKey key: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: key)!
    }

    /// 朝 → 鍵 (朝 − 1 日)
    static func key(ofMorning morning: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: morning))!
    }

    /// 通常の睡眠を鍵ごとにまとめる (鍵の昇順。仮眠はまとめない)
    static func nights(_ records: [SleepRecord], calendar: Calendar) -> [SleepNight] {
        let grouped = Dictionary(grouping: records.filter { $0.kind == .sleep }) { nightKey(of: $0, calendar: calendar) }
        return grouped
            .map { SleepNight(key: $0.key, records: $0.value.sorted { $0.startAt < $1.startAt }) }
            .sorted { $0.key < $1.key }
    }

    /// 今朝の鍵 = startOfDay(今日) − 1 日
    static func morningKey(today: Date, calendar: Calendar) -> Date {
        key(ofMorning: today, calendar: calendar)
    }

    static func morning(_ records: [SleepRecord], today: Date, calendar: Calendar) -> SleepNight? {
        let key = morningKey(today: today, calendar: calendar)
        return nights(records, calendar: calendar).first { $0.key == key }
    }

    /// 鍵より前の最後の夜 (前回の通常の睡眠)
    static func previousNight(_ records: [SleepRecord], before key: Date, calendar: Calendar) -> SleepNight? {
        nights(records, calendar: calendar).last { $0.key < key }
    }

    // MARK: - 既定の時刻

    /// 5 分単位に切り捨てる
    static func floorToStep(_ date: Date, calendar: Calendar) -> Date {
        let minutes = minutesOfDay(date, calendar: calendar)
        let floored = minutes / minuteStep * minuteStep
        return calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(floored * 60))
    }

    /// その夜 (鍵の日) の睡眠の予定 (行の開始〜終了): 睡眠の種類の行のうち、就寝の鍵がその夜になるもの (前日から続く行は除く) で最も遅く始まる行。
    /// rows は鍵の日と翌日の一覧を合わせたもの (DayBuilder が世代・除外日・祝日を解決済み。行の範囲は clip 前の本来の範囲)。
    /// 0 時過ぎに始まる世代 (1:00〜9:00) では翌日の一覧の 1:00 の行がその夜になる
    static func plannedSleep(rows: [DayScheduledTask], sleepCategoryIds: Set<UUID>, nightKey key: Date, calendar: Calendar) -> SleepPlan? {
        rows.filter { row in
            guard sleepCategoryIds.contains(row.task.categoryId) else { return false }
            if case .spillover = row.membership { return false }
            return nightKey(bedtime: row.task.startAt, calendar: calendar) == key
        }
        .max { $0.task.startAt < $1.task.startAt }
        .map { SleepPlan(start: $0.task.startAt, end: $0.task.endAt) }
    }

    /// 鍵の夜の既定の就寝〜起床 (起床の調整前): その夜の睡眠の予定 → 無ければ前回の通常の睡眠の時計の時刻 → 23:00 / 7:00
    static func plannedRange(nightKey key: Date, plan: SleepPlan?, previous: SleepNight?, calendar: Calendar) -> (start: Date, end: Date) {
        if let plan { return (plan.start, plan.end) }
        return pastMorningDefault(nightKey: key, previous: previous, calendar: calendar)
    }

    /// 起床が今より後 (まだ来ていない) なら起床 = 今 (5 分切り捨て) に寄せる。寄せた結果 起床 ≤ 就寝、または 24 時間超なら nil
    static func clampWakeToNow(_ range: (start: Date, end: Date), now: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let end = range.end > now ? floorToStep(now, calendar: calendar) : range.end
        guard end > range.start, end.timeIntervalSince(range.start) <= maxDuration else { return nil }
        return (range.start, end)
    }

    /// 今朝のカードの既定 (2026-10-04 本人決定①): 就寝・起床とも今朝の鍵の夜の予定どおり (無ければ前回の通常の睡眠 → 23:00 / 7:00)。
    /// 予定の起床がまだ来ていなければ起床 = 今 (5 分切り捨て)。それでも起床 ≤ 就寝なら nil (「起きたら記録できます」)
    static func cardDefault(plan: SleepPlan?, previous: SleepNight?, now: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let key = morningKey(today: now, calendar: calendar)
        return clampWakeToNow(plannedRange(nightKey: key, plan: plan, previous: previous, calendar: calendar), now: now, calendar: calendar)
    }

    /// 過去の未入力の朝の既定 (AI 既定): 就寝・起床とも前回の通常の睡眠の時計の時刻 (無ければ 23:00 / 7:00) をその夜に当てる
    static func pastMorningDefault(nightKey key: Date, previous: SleepNight?, calendar: Calendar) -> (start: Date, end: Date) {
        let bedMinutes = previous.map { minutesOfDay($0.start, calendar: calendar) } ?? fallbackBedtimeMinutes
        let wakeMinutes = previous.map { minutesOfDay($0.end, calendar: calendar) } ?? fallbackWakeMinutes
        let morning = morning(ofKey: key, calendar: calendar)
        let end = morning.addingTimeInterval(TimeInterval(wakeMinutes * 60))
        let resolved = resolve(bedMinutes: bedMinutes, wakeMinutes: wakeMinutes, anchorDay: morning, calendar: calendar)
        return resolved ?? (end.addingTimeInterval(-8 * 3600), end)
    }

    /// 新規の仮眠の既定: 今 − 30 分 〜 今 (5 分切り捨て)
    static func napDefault(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let end = floorToStep(now, calendar: calendar)
        return (end.addingTimeInterval(-30 * 60), end)
    }

    /// すべての記録の ＋ の既定 (2026-10-04 本人決定②。種別は通常の睡眠): 選んだ起床の日の前夜の睡眠の予定どおり
    /// (無ければ前回の通常の睡眠 → 前夜 23:00〜その日 7:00)。起床がまだ来ていなければ今朝のカードと同じく起床 = 今 (5 分切り捨て)。
    /// 寄せても起床 ≤ 就寝 (予定の就寝もまだ来ていない) ときは寄せずに予定のまま返す (シートが「まだ起きていない時刻は記録できません」で保存を止める)
    static func addDefault(wakeDay: Date, plan: SleepPlan?, previous: SleepNight?, now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let key = key(ofMorning: wakeDay, calendar: calendar)
        let base = plannedRange(nightKey: key, plan: plan, previous: previous, calendar: calendar)
        return clampWakeToNow(base, now: now, calendar: calendar) ?? base
    }

    /// 時計の時刻 → 日時。起床 = anchorDay のその時刻、就寝 = 起床より前で 24 時間以内の最初のその時刻。同じ時刻は nil
    static func resolve(bedMinutes: Int, wakeMinutes: Int, anchorDay: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let gap = ((wakeMinutes - bedMinutes) % 1440 + 1440) % 1440
        guard gap > 0 else { return nil }
        let end = calendar.startOfDay(for: anchorDay).addingTimeInterval(TimeInterval(wakeMinutes * 60))
        return (end.addingTimeInterval(-TimeInterval(gap * 60)), end)
    }

    // MARK: - 検査

    /// 保存前の検査 (InMemory も同じ関数): 起床 > 就寝、24 時間以内、起床 ≤ 今、他の記録と重ならない (自分は除く。端がくっつくのは可)
    static func validate(start: Date, end: Date, now: Date, others: [SleepRecord], excluding: UUID?) -> SleepRuleError? {
        guard end > start else { return .invalidTime }
        guard end.timeIntervalSince(start) <= maxDuration else { return .tooLong }
        guard end <= now else { return .future }
        if let other = others.first(where: { $0.id != excluding && $0.startAt < end && start < $0.endAt }) {
            return .overlap(other.id)
        }
        return nil
    }

    // MARK: - 予定タブ

    /// その日の睡眠の行 (複数) に記録を割り当てる。行の範囲は clip 前の本来の範囲。
    /// 1 件の記録は重なりが最も長い行 1 つにだけ付く (同じなら早い行)。種別に依らない。重ならない記録はどこにも付かない
    static func assign(rows: [DayScheduledTask], records: [SleepRecord]) -> [UUID: [SleepRecord]] {
        var result: [UUID: [SleepRecord]] = [:]
        let ordered = rows.sorted { $0.task.startAt < $1.task.startAt }
        for record in records {
            var best: (row: DayScheduledTask, overlap: TimeInterval)?
            for row in ordered {
                let overlap = min(record.endAt, row.task.endAt).timeIntervalSince(max(record.startAt, row.task.startAt))
                guard overlap > 0 else { continue }
                if best == nil || overlap > best!.overlap { best = (row, overlap) }
            }
            if let best { result[best.row.id, default: []].append(record) }
        }
        return result.mapValues { $0.sorted { $0.startAt < $1.startAt } }
    }

    /// 「実績 23:40–7:10（7時間30分）」／2 件以上「実績 23:30–7:00（7時間 · 2 件）」(就寝 = 最初・起床 = 最後・時間 = 合計)。0 件は nil
    static func planLine(_ records: [SleepRecord], calendar: Calendar) -> String? {
        guard let start = records.map(\.startAt).min(), let end = records.map(\.endAt).max() else { return nil }
        let range = CheckInPlanner.rangeText(start, end, calendar: calendar)
        if records.count == 1 {
            return "実績 \(range)（\(durationText(records[0].duration))）"
        }
        return "実績 \(range)（\(durationText(records.reduce(0) { $0 + $1.duration })) · \(records.count) 件）"
    }

    /// 予定タブの日 D の読み込み範囲 [D−1 0:00, D+2 0:00)。この範囲に重なる記録 (start_at < to AND end_at > from) を取る
    static func fetchRange(for day: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let start = calendar.startOfDay(for: day)
        return (calendar.date(byAdding: .day, value: -1, to: start)!, calendar.date(byAdding: .day, value: 2, to: start)!)
    }

    // MARK: - 数字

    /// 朝の期間 [first, last] (両端を含む日) の数字。経過した朝 = 今日まで。通常の睡眠の夜だけ
    static func stats(nights: [SleepNight], firstMorning: Date, lastMorning: Date, today: Date, calendar: Calendar) -> SleepStats {
        let first = calendar.startOfDay(for: firstMorning)
        let last = min(calendar.startOfDay(for: lastMorning), calendar.startOfDay(for: today))
        let inPeriod = nights.filter {
            let morning = morning(ofKey: $0.key, calendar: calendar)
            return morning >= first && morning <= last
        }
        let elapsed = last < first ? 0 : (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        func average(_ values: [Int]) -> Int? {
            values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        }
        func shifted(_ date: Date) -> Int { (minutesOfDay(date, calendar: calendar) - averageOriginMinutes + 1440) % 1440 }
        func unshift(_ minutes: Int?) -> Int? { minutes.map { ($0 + averageOriginMinutes) % 1440 } }
        return SleepStats(
            recordedCount: inPeriod.count,
            elapsedCount: elapsed,
            averageDuration: inPeriod.isEmpty ? nil : inPeriod.reduce(0) { $0 + $1.total } / Double(inPeriod.count),
            averageBedtimeMinutes: unshift(average(inPeriod.map { shifted($0.start) })),
            averageWakeMinutes: unshift(average(inPeriod.map { shifted($0.end) }))
        )
    }

    /// 7 日平均: その朝を含む直近 7 朝のうち記録がある夜の平均 (未入力は分母に入れない)。記録が無ければ nil
    static func movingAverage(nights: [SleepNight], morning: Date, calendar: Calendar) -> TimeInterval? {
        let last = calendar.startOfDay(for: morning)
        let first = calendar.date(byAdding: .day, value: -6, to: last)!
        let window = nights.filter {
            let m = Self.morning(ofKey: $0.key, calendar: calendar)
            return m >= first && m <= last
        }
        return window.isEmpty ? nil : window.reduce(0) { $0 + $1.total } / Double(window.count)
    }

    // MARK: - 文言

    /// 「7時間30分」(0 分は「0分」)
    static func durationText(_ interval: TimeInterval) -> String {
        let total = Int(interval / 60)
        guard total > 0 else { return "0分" }
        return CheckInPlanner.durationText(Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: TimeInterval(total * 60)))
    }

    /// 「0:30」
    static func clockText(_ date: Date, calendar: Calendar) -> String {
        ScheduleRepeat.timeText(minutesOfDay(date, calendar: calendar))
    }

    static func minutesOfDay(_ date: Date, calendar: Calendar) -> Int {
        CheckInPlanner.minutesOfDay(date, calendar: calendar)
    }

    /// 保存・削除の失敗の文言。PostgREST の code: 23P01 (重なり) →「この時間には記録があります」、23514 (CHECK) →「時刻を確かめてください」
    static func message(for error: Error) -> String {
        if let rule = error as? SleepRuleError { return rule.errorDescription ?? "" }
        switch (error as? PostgrestError)?.code {
        case "23P01": return "この時間には記録があります"
        case "23514": return "時刻を確かめてください"
        default: return error.localizedDescription
        }
    }
}
