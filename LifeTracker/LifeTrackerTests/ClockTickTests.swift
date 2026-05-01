import Testing
import Foundation
@testable import LifeTracker

@Suite("ClockTick")
@MainActor
struct ClockTickTests {
    private func makeFixedDate(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test("初期化時に now provider の値が now にセットされる")
    func initialNow() {
        let fixed = makeFixedDate("2026-05-01T10:00:00+09:00")
        let clock = ClockTick(interval: 60, now: { fixed })
        #expect(clock.now == fixed)
        #expect(clock.isRunning == false)
    }

    @Test("start で isRunning が true になり、stop で false に戻る")
    func startAndStop() {
        let clock = ClockTick(interval: 60, now: { Date() })
        #expect(clock.isRunning == false)

        clock.start()
        #expect(clock.isRunning == true)

        clock.stop()
        #expect(clock.isRunning == false)
    }

    @Test("start を 2 回呼んでも cancellable は 1 つに保たれる")
    func startIsIdempotent() {
        let clock = ClockTick(interval: 60, now: { Date() })
        clock.start()
        clock.start()
        #expect(clock.isRunning == true)

        clock.stop()
        #expect(clock.isRunning == false)
    }

    @Test("tick で now provider の値が now に反映される")
    func tickUpdatesNow() {
        var current = makeFixedDate("2026-05-01T10:00:00+09:00")
        let clock = ClockTick(interval: 60, now: { current })
        #expect(clock.now == current)

        current = makeFixedDate("2026-05-01T10:01:00+09:00")
        clock.tick()
        #expect(clock.now == current)
    }
}
