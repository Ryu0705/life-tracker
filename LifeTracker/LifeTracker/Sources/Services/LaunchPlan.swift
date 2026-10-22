import Foundation

/// 起動時に、認証とデータを本物 (Supabase) にするかメモリ上にするかを決める (計画 §2-4・設計 §9)。純粋な関数。
///
/// - DEBUG で単体テストの環境 (環境変数 `XCTestConfigurationFilePath` がある) なら、メモリ上のデータと MockAuthService (サインイン済み)。
///   SupabaseClient を作らない (シミュレータに本人のセッションが残っていても、TEST_HOST のアプリが本番を読まないように)
/// - DEBUG の起動引数: `-mock-auth` = MockAuthService でサインイン済み、`-mock-auth-signed-out` = MockAuthService で未サインインから、
///   `-mock-day`・`-mock-workout` = メモリ上のデータ。`-mock-day`・`-mock-workout` だけなら本物の認証＋メモリ上のデータ
/// - Release は常に本物
struct LaunchPlan: Equatable {
    enum Auth: Equatable {
        case supabase
        case mockSignedIn
        case mockSignedOut
    }

    var auth: Auth
    /// 予定・睡眠をメモリ上に (`-mock-day`)
    var memoryDay: Bool
    /// トレーニングをメモリ上に (`-mock-workout`)
    var memoryWorkout: Bool

    static let testEnvironmentKey = "XCTestConfigurationFilePath"

    static func make(arguments: [String], environment: [String: String], isDebug: Bool) -> LaunchPlan {
        guard isDebug else {
            return LaunchPlan(auth: .supabase, memoryDay: false, memoryWorkout: false)
        }
        if environment[testEnvironmentKey] != nil {
            return LaunchPlan(auth: .mockSignedIn, memoryDay: true, memoryWorkout: true)
        }
        let auth: Auth
        if arguments.contains("-mock-auth-signed-out") {
            auth = .mockSignedOut
        } else if arguments.contains("-mock-auth") {
            auth = .mockSignedIn
        } else {
            auth = .supabase
        }
        return LaunchPlan(auth: auth,
                          memoryDay: arguments.contains("-mock-day"),
                          memoryWorkout: arguments.contains("-mock-workout"))
    }

    /// このプロセスの起動引数と環境変数から
    static var current: LaunchPlan {
        make(arguments: ProcessInfo.processInfo.arguments,
             environment: ProcessInfo.processInfo.environment,
             isDebug: isDebugBuild)
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
