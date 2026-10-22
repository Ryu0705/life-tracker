import Testing
import Foundation
@testable import LifeTracker

// 記録できる日の決まり (docs/training-day-implementation-plan.md 付録 A-3)

private let jst: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return cal
}()

private func jstDate(_ local: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: "\(local)+09:00")!
}

@Suite("RecordWindow — 前の日は翌日の 2:00 まで・今日に記録があれば閉じる")
struct RecordWindowTests {
    let today = jstDate("2026-10-23T00:00:00")
    let previous = jstDate("2026-10-22T00:00:00")

    private func days(_ local: String, todayHasRecords: Bool = false) -> [Date] {
        RecordWindow.recordableDays(now: jstDate(local), todayHasRecords: todayHasRecords, calendar: jst)
    }

    @Test("1:59:59 は前の日も開いている (今日が先頭)。2:00 ちょうどで前の日は閉じる")
    func closingBoundary() {
        #expect(days("2026-10-23T00:00:00") == [today, previous])
        #expect(days("2026-10-23T01:59:59") == [today, previous])
        #expect(days("2026-10-23T02:00:00") == [today])
        #expect(RecordWindow.closingTime(of: previous, calendar: jst) == jstDate("2026-10-23T02:00:00"))
    }

    @Test("今日に記録があれば 2:00 より前でも前の日は閉じる")
    func todayRecordsClosePrevious() {
        #expect(days("2026-10-23T00:30:00", todayHasRecords: true) == [today])
        #expect(days("2026-10-23T01:59:59", todayHasRecords: true) == [today])
    }

    @Test("23:00 は今日だけ")
    func lateEveningOnlyToday() {
        #expect(days("2026-10-23T23:00:00") == [today])
    }

    @Test("もう記録できない日: 前の日より前は常に・前の日は 2:00 から。今日と未来は閉じない")
    func permanentlyClosed() {
        func closed(_ day: Date, _ local: String) -> Bool {
            RecordWindow.isPermanentlyClosed(day: day, now: jstDate(local), calendar: jst)
        }
        let twoDaysAgo = jstDate("2026-10-21T00:00:00")
        #expect(closed(twoDaysAgo, "2026-10-23T00:00:00"))
        #expect(closed(twoDaysAgo, "2026-10-23T00:30:00"))
        #expect(!closed(previous, "2026-10-23T01:59:59"))
        #expect(closed(previous, "2026-10-23T02:00:00"))
        // 「今日に記録があるから閉じた」前の日はまた開きうるので、ここでは閉じない (時刻だけで決める)
        #expect(!closed(previous, "2026-10-23T00:30:00"))
        #expect(!closed(today, "2026-10-23T23:59:59"))
        #expect(!closed(jstDate("2026-10-24T00:00:00"), "2026-10-23T12:00:00"))
    }
}
