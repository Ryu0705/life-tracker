import Foundation
import Combine

@MainActor
final class ClockTick: ObservableObject {
    @Published private(set) var now: Date

    private let interval: TimeInterval
    private let nowProvider: () -> Date
    private var cancellable: AnyCancellable?

    init(interval: TimeInterval = 60, now: @escaping () -> Date = { Date() }) {
        self.interval = interval
        self.nowProvider = now
        self.now = now()
    }

    var isRunning: Bool { cancellable != nil }

    func start() {
        guard cancellable == nil else { return }
        now = nowProvider()
        cancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.now = self.nowProvider()
            }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    func tick() {
        now = nowProvider()
    }
}
