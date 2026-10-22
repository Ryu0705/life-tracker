import SwiftUI
import Supabase
import HolidayJp

@main
struct LifeTrackerApp: App {
    @StateObject private var clockTick = ClockTick()
    @Environment(\.scenePhase) private var scenePhase
    private let initResult: Result<AppSetup, Error>

    init() {
        // もう使わない再設定の印を消す (2026-10-22 コードに替えた)
        ObsoleteAuthKeys.remove(from: .standard)
        self.initResult = Self.makeSetup(plan: .current)
    }

    var body: some Scene {
        WindowGroup {
            switch initResult {
            case .success(let setup):
                AppRootView(sources: setup.sources, auth: setup.auth, clockTick: clockTick)
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

    /// 起動の組み立て (計画 §2-4)。認証とデータを本物にするかメモリ上にするかは LaunchPlan が決める。
    /// SupabaseClient は本物を使うときだけ `makeClient` で作る (単体テストの環境では作らない。テストは `makeClient` を差し込んで確かめる)。
    /// `sideEffects` はサインイン・サインアウトの端末の側 (本物の認証のときだけ使う。メモリ上の認証では何もしない)
    static func makeSetup(plan: LaunchPlan,
                          makeClient: @MainActor () throws -> SupabaseClient = { try LifeTrackerApp.makeClient() },
                          sideEffects: SignInSideEffects = .live) -> Result<AppSetup, Error> {
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            let holidayChecker: (Date) -> Bool = { date in
                HolidayJp.isHoliday(date, calendar: calendar)
            }

            var madeClient: SupabaseClient?
            func client() throws -> SupabaseClient {
                if let madeClient { return madeClient }
                let made = try makeClient()
                madeClient = made
                return made
            }
            // 42501・PGRST3xx を「もう一度」「サインインし直して」に変える境界 (計画 §2-5・P9)。
            // 予定・睡眠とトレーニングで 1 つを共有する (セッションの更新が同時に何本も走らないように)
            var madeAccess: DataAccessGuard?
            func access() throws -> DataAccessGuard {
                if let madeAccess { return madeAccess }
                let made = DataAccessGuard(session: SupabaseSessionAccess(client: try client()))
                madeAccess = made
                return made
            }

            let day: DayDataSource
            let schedule: ScheduleDataSource
            let sleep: SleepDataSource
            if plan.memoryDay {
                // 予定側をメモリ上にする (シミュレータ確認で本番 DB に書かない)。
                // 今日の前後に「その日だけ変えた回」「除外日」「単発」を 1 つずつ入れる
                let mock = InMemoryScheduleDataSource.makeFixture(calendar: calendar, holidayChecker: holidayChecker,
                                                                  withSamples: true)
                day = mock
                schedule = mock
                // 睡眠も同じインスタンス (睡眠タブで書いた記録が予定タブに出る)
                sleep = mock
            } else {
                let dataSource = SupabaseDayDataSource(client: try client(), calendar: calendar,
                                                       holidayChecker: holidayChecker, access: try access())
                day = dataSource
                schedule = dataSource
                sleep = dataSource
            }

            let workout: WorkoutDataSource
            #if DEBUG
            if plan.memoryWorkout {
                let arguments = ProcessInfo.processInfo.arguments
                let mock = WorkoutFixtures.makeMockDataSource(withProfile: !arguments.contains("-mock-no-profile"))
                // 期間の取得を 1.5 秒遅らせる (分析のページ切替中の取得の確認用)
                if arguments.contains("-mock-fetch-delay") { mock.fetchSetsDelayNanoseconds = 1_500_000_000 }
                workout = mock
            } else {
                workout = SupabaseWorkoutDataSource(client: try client(), access: try access())
            }
            #else
            workout = SupabaseWorkoutDataSource(client: try client(), access: try access())
            #endif

            let authService: AuthService
            switch plan.auth {
            case .supabase:
                authService = SupabaseAuthService(client: try client())
            case .mockSignedIn, .mockSignedOut:
                #if DEBUG
                authService = MockAuthService(signedIn: plan.auth == .mockSignedIn)
                #else
                authService = SupabaseAuthService(client: try client())
                #endif
            }
            // 初期データは data source を通す (メモリ上の実装は何もしない)。
            // サインイン・サインアウトの端末の側 (ウィジェットの印とスナップショット・休憩の通知・Google) はフックで渡す (計画 §2-6)。
            // メモリ上の認証では何もしない (実機で -mock-* を付けて起動しても、本人のウィジェットを消さない)
            let effects = plan.auth == .supabase ? sideEffects : .disabled
            let auth = AuthStore(service: authService,
                                 ensureUserDefaults: { try await schedule.ensureUserDefaults() },
                                 onSignedIn: { effects.signedIn() },
                                 onSignedOut: { effects.signedOut() })
            auth.start()

            let sources = AppDataSources(day: day, workout: workout, schedule: schedule, sleep: sleep)
            return .success(AppSetup(sources: sources, auth: auth))
        } catch {
            return .failure(error)
        }
    }

    /// data source と認証で共有するクライアント。リンクは lifetracker://auth-callback に戻し、PKCE を明示する (設計 §7)。
    /// `emitLocalSessionAsInitialSession: true`: 端末のセッションを (期限切れでも) すぐ初期セッションとして流す (計画 §2-1)
    static func makeClient() throws -> SupabaseClient {
        let url = try SupabaseConfig.loadURL()
        let key = try SupabaseConfig.loadAnonKey()
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                db: .init(encoder: .supabase, decoder: .supabase),
                auth: .init(redirectToURL: AuthCallback.url, flowType: .pkce,
                            emitLocalSessionAsInitialSession: true)
            )
        )
    }
}

/// 同じ SupabaseClient を共有する data source の組
struct AppDataSources {
    let day: DayDataSource
    let workout: WorkoutDataSource
    let schedule: ScheduleDataSource
    let sleep: SleepDataSource
}

/// 起動時に作るものの組
struct AppSetup {
    let sources: AppDataSources
    let auth: AuthStore
}

/// 認証の状態で画面を出し分ける (起動中 → 起動画面／未サインイン → サインインの画面／コードの入力 → コードの画面／サインイン済み → TabView)。
/// データの読み込みはサインイン済みのときだけ始まる (TabView の中の store が読む。設計 §7・M20)
struct AppRootView: View {
    let sources: AppDataSources
    @ObservedObject var auth: AuthStore
    let clockTick: ClockTick

    var body: some View {
        Group {
            switch auth.phase {
            case .launching:
                AuthLaunchView()
            case .signedOut:
                SignInView(store: auth)
            case .awaitingCode(let email):
                EmailCodeView(store: auth, email: email)
            case .signedIn(let userID):
                // 人が変わったら store を作り直させる (設計 §7・M21)。サインアウトはプロフィールのタブから (計画 §2-6。2026-10-22 分析から移した)
                MainTabView(sources: sources, clockTick: clockTick, email: auth.signedInEmail)
                    .environment(\.signOutAction, SignOutAction { await auth.signOut() })
                    .id(userID)
            }
        }
        .onOpenURL { url in
            if AuthCallback.matches(url) {
                Task { await auth.handle(url: url) }
            } else {
                GoogleSignInHelper.handle(url)
            }
        }
        .alert("リンクを開けませんでした", isPresented: linkFailureShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(auth.linkFailureMessage ?? "")
        }
    }

    private var linkFailureShown: Binding<Bool> {
        Binding(
            get: { auth.linkFailureMessage != nil },
            set: { shown in
                if !shown { auth.linkFailureMessage = nil }
            }
        )
    }
}

/// サインイン済みの画面 (今までの TabView)。最後のタブがプロフィール (2026-10-22 本人の決定)
struct MainTabView: View {
    let sources: AppDataSources
    let clockTick: ClockTick
    /// サインイン中のメールアドレス (プロフィールのタブの「アカウント」に出す)。nil なら行を出さない
    let email: String?
    /// プロフィールと体重。トレーニングのタブ (分析の強さ) とプロフィールのタブで同じものを見る (どちらで直してもすぐもう片方に出る)。
    /// 人が変わればこの画面ごと `.id(userID)` で作り直すので、store も作り直される
    @StateObject private var profileStore: ProfileStore

    init(sources: AppDataSources, clockTick: ClockTick, email: String?) {
        self.sources = sources
        self.clockTick = clockTick
        self.email = email
        _profileStore = StateObject(wrappedValue: ProfileStore(dataSource: sources.workout, calendar: HomeView.defaultCalendar))
    }

    var body: some View {
        TabView {
            Tab("予定", systemImage: "calendar") {
                HomeView(dataSource: sources.day, scheduleSource: sources.schedule)
                    .environment(\.dayDataSource, sources.day)
                    .environmentObject(clockTick)
            }
            .accessibilityIdentifier("tab.schedule")
            Tab("トレーニング", systemImage: "dumbbell") {
                WorkoutView(dataSource: sources.workout, profileStore: profileStore)
            }
            .accessibilityIdentifier("tab.workout")
            Tab("睡眠", systemImage: "bed.double") {
                SleepView(dataSource: sources.sleep, dayDataSource: sources.day, scheduleDataSource: sources.schedule)
                    .environmentObject(clockTick)
            }
            .accessibilityIdentifier("tab.sleep")
            Tab("プロフィール", systemImage: "person.crop.circle") {
                ProfileView(profileStore: profileStore, email: email, calendar: HomeView.defaultCalendar)
            }
            .accessibilityIdentifier("tab.profile")
        }
    }
}
