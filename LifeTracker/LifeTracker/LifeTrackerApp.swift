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
                    Tab("予定", systemImage: "calendar") {
                        HomeView(dataSource: sources.day, scheduleSource: sources.schedule)
                            .environment(\.dayDataSource, sources.day)
                            .environmentObject(clockTick)
                    }
                    Tab("トレーニング", systemImage: "dumbbell") {
                        WorkoutView(dataSource: sources.workout)
                    }
                    Tab("睡眠", systemImage: "bed.double") {
                        SleepView(dataSource: sources.sleep, dayDataSource: sources.day, scheduleDataSource: sources.schedule)
                            .environmentObject(clockTick)
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
            var day: DayDataSource = dataSource
            var schedule: ScheduleDataSource = dataSource
            var sleep: SleepDataSource = dataSource
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-mock-workout") {
                workout = WorkoutFixtures.makeMockDataSource()
            }
            // 予定側もメモリ上にする (シミュレータ確認で本番 DB に書かない)。
            // 今日の前後に「その日だけ変えた回」「除外日」「単発」を 1 つずつ入れる
            if ProcessInfo.processInfo.arguments.contains("-mock-day") {
                let mock = InMemoryScheduleDataSource.makeFixture(calendar: calendar, holidayChecker: { date in
                    HolidayJp.isHoliday(date, calendar: calendar)
                }, withSamples: true)
                day = mock
                schedule = mock
                // 睡眠も同じインスタンス (睡眠タブで書いた記録が予定タブに出る)
                sleep = mock
            }
            #endif
            return .success(AppDataSources(day: day, workout: workout, schedule: schedule, sleep: sleep))
        } catch {
            return .failure(error)
        }
    }
}

/// 同じ SupabaseClient を共有する data source の組
struct AppDataSources {
    let day: DayDataSource
    let workout: WorkoutDataSource
    let schedule: ScheduleDataSource
    let sleep: SleepDataSource
}
