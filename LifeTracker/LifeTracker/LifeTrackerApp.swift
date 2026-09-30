import SwiftUI
import Supabase
import HolidayJp

@main
struct LifeTrackerApp: App {
    @StateObject private var clockTick = ClockTick()
    @Environment(\.scenePhase) private var scenePhase
    private let initResult: Result<AppDataSources, Error>

    init() {
        self.initResult = Self.makeDataSource()
    }

    var body: some Scene {
        WindowGroup {
            switch initResult {
            case .success(let sources):
                TabView {
                    Tab("今日", systemImage: "calendar") {
                        HomeView(dataSource: sources.day)
                            .environment(\.dayDataSource, sources.day)
                            .environmentObject(clockTick)
                    }
                    Tab("トレーニング", systemImage: "dumbbell") {
                        WorkoutView(dataSource: sources.workout)
                    }
                }
            case .failure(let error):
                ConfigErrorView(error: error)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                clockTick.start()
            case .inactive, .background:
                clockTick.stop()
            @unknown default:
                break
            }
        }
    }

    private static func makeDataSource() -> Result<AppDataSources, Error> {
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
            var workout: WorkoutDataSource = SupabaseWorkoutDataSource(client: client)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-mock-workout") {
                workout = WorkoutFixtures.makeMockDataSource()
            }
            #endif
            return .success(AppDataSources(day: dataSource, workout: workout))
        } catch {
            return .failure(error)
        }
    }
}

/// 同じ SupabaseClient を共有する data source の組
struct AppDataSources {
    let day: DayDataSource
    let workout: WorkoutDataSource
}
