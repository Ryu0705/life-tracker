import Foundation

/// トレーニングを記録できる日の決まり (2026-10-22〜23 本人決定。docs/training-day-implementation-plan.md 付録 A-3)。pure。
/// 今日はいつでも記録できる。前の日は翌日の 2:00 まで記録できるが、今日 (0:00 以降) に記録があれば 2:00 より前でも閉じる
/// (今日の記録を全部消せばまた開く)。DB (0015) は時刻の窓 (日の 0:00〜翌日 2:00) だけを守り、「今日に記録があれば閉じる」はアプリだけで守る
enum RecordWindow {
    /// 前の日を締める時刻 (翌日の 2:00。0015 の CHECK と同じ)
    static let closingHour = 2

    /// 記録できる日 (日の始まり)。今日は必ず (先頭)。前の日は now < 今日の 2:00 かつ todayHasRecords == false のとき (2 番目)
    static func recordableDays(now: Date, todayHasRecords: Bool, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let previous = calendar.date(byAdding: .day, value: -1, to: today)!
        guard !todayHasRecords, now < closingTime(of: previous, calendar: calendar) else { return [today] }
        return [today, previous]
    }

    /// もう二度と記録できない日 (サーバーのセッションを閉じてよい): 前の日より前、または前の日で now >= 今日の 2:00。今日と未来は false。
    /// 「今日に記録があるから閉じた」だけの前の日は false (今日の記録を消せばまた開く)
    static func isPermanentlyClosed(day: Date, now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: day)
        guard target < today else { return false }
        return now >= closingTime(of: target, calendar: calendar)
    }

    /// その日の締め (翌日の closingHour 時)。この時刻より前に記録したセットだけがその日に入れる (0015 の CHECK の上端)
    static func closingTime(of day: Date, calendar: Calendar) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        return calendar.date(byAdding: .hour, value: closingHour, to: next)!
    }
}
