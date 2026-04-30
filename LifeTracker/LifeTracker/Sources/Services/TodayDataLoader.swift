import Foundation
import Combine

@MainActor
final class TodayDataLoader: ObservableObject {
    @Published private(set) var day: Day?
    @Published private(set) var error: Error?
    @Published private(set) var isLoading: Bool = false

    private let dataSource: DayDataSource
    private let calendar: Calendar
    private let now: () -> Date

    init(
        dataSource: DayDataSource,
        calendar: Calendar,
        now: @escaping () -> Date = { Date() }
    ) {
        self.dataSource = dataSource
        self.calendar = calendar
        self.now = now
    }

    func refresh() async {
        isLoading = true
        error = nil
        let today = now()
        do {
            let context = try await dataSource.loadDayContext(date: today)
            let day = DayBuilder.build(date: today, context: context)
            self.day = day
        } catch {
            self.error = error
        }
        isLoading = false
    }
}
