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
                ContentView()
                    .environment(\.dayDataSource, dataSource)
                    .task {
                        await Self.debugPrintToday(dataSource: dataSource)
                    }
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

    private static func debugPrintToday(dataSource: DayDataSource) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let today = Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd (EEE)"

        do {
            let context = try await dataSource.loadDayContext(date: today)
            let day = DayBuilder.build(date: today, context: context)
            print("=== LifeTracker debug: \(formatter.string(from: today)) ===")
            print("templates: \(context.templates.count), patterns: \(context.patterns.count), memberships: \(context.memberships.count)")
            print("dayMeta: \(context.dayMeta.map { "applied=\($0.appliedPatternId?.uuidString ?? "nil")" } ?? "none")")
            print("scheduled (合成 \(day.scheduled.count) 件):")
            for dt in day.scheduled {
                print("  - \(dt.task.name) [\(dt.membership)] origin=\(dt.origin) range=\(dt.visibleRange)")
            }
            print("actual: \(day.actual.count) 件")
        } catch {
            print("=== LifeTracker debug: loadDayContext failed: \(error) ===")
        }
    }
}

private struct ConfigErrorView: View {
    let error: Error

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("設定エラー")
                .font(.title2)
                .bold()
            Text(error.localizedDescription)
                .font(.body)
            Text("対処手順:")
                .font(.headline)
                .padding(.top, 8)
            Text("""
            1. LifeTracker.xcconfig.example を LifeTracker.xcconfig にコピー
            2. SUPABASE_URL / SUPABASE_ANON_KEY を Supabase Dashboard の値で埋める
            3. Xcode で Project → Configurations → Debug/Release に
               "Based on Configuration File" で LifeTracker.xcconfig を割り当て
            4. アプリ再ビルド
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}
