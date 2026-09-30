import Foundation

/// 繰り返しの予定の繰り返し (曜日＋祝日) と rrule の相互変換。pure。
/// DayBuilder が読める形 (FREQ=DAILY / FREQ=WEEKLY;BYDAY=…) だけを書く (docs/day-cycle-walkthrough.md)
enum ScheduleWeekday: Int, CaseIterable, Identifiable, Hashable {
    // 並びは月曜始まり (週帯・週分析と同じ)
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    var id: Int { rawValue }

    var token: String {
        ["MO", "TU", "WE", "TH", "FR", "SA", "SU"][rawValue]
    }

    var label: String {
        ["月", "火", "水", "木", "金", "土", "日"][rawValue]
    }
    /// Calendar の weekday (1 = 日曜) から
    init(calendarWeekday: Int) {
        self = ScheduleWeekday(rawValue: (calendarWeekday + 5) % 7)!
    }

    static func of(_ date: Date, calendar: Calendar) -> ScheduleWeekday {
        ScheduleWeekday(calendarWeekday: calendar.component(.weekday, from: date))
    }
}

enum ScheduleRepeat {
    static let weekdays: Set<ScheduleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let weekend: Set<ScheduleWeekday> = [.saturday, .sunday]

    /// 曜日なし = nil (祝日だけの予定。休日パターン経由でのみ出る)
    static func rrule(for days: Set<ScheduleWeekday>) -> String? {
        if days.isEmpty { return nil }
        if days.count == ScheduleWeekday.allCases.count { return "FREQ=DAILY" }
        return "FREQ=WEEKLY;BYDAY=" + ScheduleWeekday.allCases.filter(days.contains).map(\.token).joined(separator: ",")
    }

    /// DayBuilder と同じ読み方をする (DAILY = 毎日、WEEKLY で BYDAY なし = 毎日、それ以外は出ない)
    static func weekdays(from rrule: String?) -> Set<ScheduleWeekday> {
        guard let rrule else { return [] }
        var freq: String?
        var byday: [String] = []
        for part in rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            guard kv.count == 2 else { continue }
            if kv[0] == "FREQ" { freq = kv[1] }
            if kv[0] == "BYDAY" { byday = kv[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        switch freq {
        case "DAILY":
            return Set(ScheduleWeekday.allCases)
        case "WEEKLY":
            if byday.isEmpty { return Set(ScheduleWeekday.allCases) }
            return Set(ScheduleWeekday.allCases.filter { byday.contains($0.token) })
        default:
            return []
        }
    }

    /// 一覧に出す短い説明: 「毎日」「平日」「土日」「月・水・金」＋「祝日」
    static func summary(days: Set<ScheduleWeekday>, holiday: Bool) -> String {
        let dayText: String?
        switch days {
        case []: dayText = nil
        case Set(ScheduleWeekday.allCases): dayText = "毎日"
        case weekdays: dayText = "平日"
        case weekend: dayText = "土日"
        default: dayText = ScheduleWeekday.allCases.filter(days.contains).map(\.label).joined(separator: "・")
        }
        switch (dayText, holiday) {
        case (nil, true): return "祝日だけ"
        case (nil, false): return "出ない"
        case (let text?, true): return text + "・祝日"
        case (let text?, false): return text
        }
    }

    /// その日に出るか (DayBuilder と同じ規則: 祝日は「祝日も出す」だけ、それ以外は曜日)。
    /// 休日以外のパターン (曜日パターン・day_meta) は段階 1 では持たないので見ない
    static func appears(on date: Date, days: Set<ScheduleWeekday>, holiday: Bool,
                        isHoliday: (Date) -> Bool, calendar: Calendar) -> Bool {
        if isHoliday(date) { return holiday }
        return days.contains(ScheduleWeekday.of(date, calendar: calendar))
    }

    /// date の翌日以降で最初に出る日 (1 年先まで。無ければ nil)
    static func nextDate(after date: Date, days: Set<ScheduleWeekday>, holiday: Bool,
                         isHoliday: (Date) -> Bool, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in 1...366 {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            if appears(on: day, days: days, holiday: holiday, isHoliday: isHoliday, calendar: calendar) { return day }
        }
        return nil
    }

    /// 開始・終了 (0 時からの分) → 所要時間。終了が開始以前なら翌日まで。開始 = 終了は nil (0 分・24 時間の区別がつかないため作らせない)
    static func duration(startMinutes: Int, endMinutes: Int) -> Int? {
        let diff = (endMinutes - startMinutes + 1440) % 1440
        return diff == 0 ? nil : diff
    }

    /// 新規の予定の開始の既定: 今の時刻以降で一番近いキリのいい時刻 (:00 か :30)。14:58 → 15:00、14:20 → 14:30、15:00 → 15:00。
    /// 24:00 になるときは 23:30 (その日の中に収める)
    static func defaultStartMinutes(now: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return min((minutes + 29) / 30 * 30, 1410)
    }

    static func endMinutes(startMinutes: Int, duration: Int) -> Int {
        (startMinutes + duration) % 1440
    }

    static func timeText(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
