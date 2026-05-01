import SwiftUI
import Supabase
import HolidayJp

@main
struct LifeTrackerApp: App {
    private let initResult: Result<DayDataSource, Error>

    init() {
        self.initResult = Self.makeDataSource()
    }

    var body: some Scene {
        WindowGroup {
            switch initResult {
            case .success(let dataSource):
                HomeView(dataSource: dataSource)
                    .environment(\.dayDataSource, dataSource)
            case .failure(let error):
                ConfigErrorView(error: error)
            }
        }
    }

    private static func makeDataSource() -> Result<DayDataSource, Error> {
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!

            let url = try SupabaseConfig.loadURL()
            let key = try SupabaseConfig.loadAnonKey()
            let client = SupabaseClient(
                supabaseURL: url,
                supabaseKey: key,
                options: SupabaseClientOptions(
                    db: .init(encoder: .supabase, decoder: .supabase)
                )
            )
            let dataSource = SupabaseDayDataSource(
                client: client,
                calendar: calendar,
                holidayChecker: { date in
                    HolidayJp.isHoliday(date, calendar: calendar)
                }
            )
            return .success(dataSource)
        } catch {
            return .failure(error)
        }
    }
}
