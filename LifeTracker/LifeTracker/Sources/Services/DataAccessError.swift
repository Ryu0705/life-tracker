import Foundation
import os
import Supabase

/// データの読み書きが、権限が無い (42501) かトークンが無効 (PGRST3xx。JWT の問題) で断られた (計画 §2-5・P9)。
/// Supabase の data source の境界 (`DataAccessGuard`) で PostgrestError から変えて投げ直す。
/// 文言は `errorDescription` に入れるので、画面の各所の `error.localizedDescription` がそのまま新しい文言になる。
///
/// 期限切れのセッションの更新が通信で落ちた直後は、クライアントが anon キーで送るので 42501 になる。
/// このときセッションは端末に残り `.signedOut` も来ないので、サインインの画面には戻さず「もう一度」と出す
///
/// 42501 は RLS の WITH CHECK 違反でも返る。アプリは書き込みに user_id を送らないこと (設計 §1)
enum DataAccessError: LocalizedError, Equatable {
    /// 端末にセッションがある (裏でセッションの更新を 1 回試す)
    case couldNotVerify
    /// 端末にセッションが無い
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .couldNotVerify: return "確認できませんでした。もう一度お試しください"
        case .signInRequired: return "サインインし直してください"
        }
    }

    /// 42501 (insufficient_privilege) か PGRST3xx (PGRST301・302・303 など JWT の問題) の PostgrestError か (純粋な関数)
    static func isAccessDenied(_ error: Error) -> Bool {
        guard let code = (error as? PostgrestError)?.code else { return false }
        return code == "42501" || code.hasPrefix("PGRST3")
    }
}

/// 端末のセッション。data source の境界が「セッションがあるか」を見て、更新を頼む (テストで差し込めるように protocol)
protocol SessionAccess: AnyObject {
    /// 端末にセッションがあるか (期限切れでも true)
    var hasStoredSession: Bool { get }
    /// セッションを更新する
    func refreshSession() async throws
}

/// 共有の SupabaseClient の auth (supabase-swift 2.44.1: `currentSession` は端末に保存したセッションを期限を見ずに返す・
/// `refreshSession()` は保存した refresh token で更新する。無効と返されたらセッションを消し `.signedOut` を流す)
final class SupabaseSessionAccess: SessionAccess {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    var hasStoredSession: Bool {
        client.auth.currentSession != nil
    }

    func refreshSession() async throws {
        try await client.auth.refreshSession()
    }
}

/// Supabase の data source の境界。42501・PGRST3xx を `DataAccessError` に変え、ほかのエラーはそのまま返す。
/// セッションがあればその場でセッションの更新を 1 回試す (待たない。走っている間は新しく始めない)。
/// 予定・睡眠とトレーニングの data source で 1 つを共有する (更新が同時に何本も走らないように)。
/// data source は main actor の外から並んで呼ばれるので、更新中かどうかはロックで守る
final class DataAccessGuard: @unchecked Sendable {
    private let session: SessionAccess
    private let lock = NSLock()
    private var refreshing = false
    private let logger = Logger(subsystem: "LifeTracker", category: "data-access")

    init(session: SessionAccess) {
        self.session = session
    }

    /// 42501・PGRST3xx なら DataAccessError (セッションがあれば更新を始める)。ほかはそのまま
    func translate(_ error: Error) -> Error {
        guard DataAccessError.isAccessDenied(error) else { return error }
        guard session.hasStoredSession else { return DataAccessError.signInRequired }
        startRefreshIfIdle()
        return DataAccessError.couldNotVerify
    }

    /// 1 回の読み書きを包む (失敗は translate を通して投げ直す)
    @discardableResult
    func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw translate(error)
        }
    }

    private func startRefreshIfIdle() {
        let start = lock.withLock {
            if refreshing { return false }
            refreshing = true
            return true
        }
        guard start else { return }
        let session = session
        let logger = logger
        Task { [weak self] in
            do {
                try await session.refreshSession()
            } catch {
                logger.error("refresh after access denied failed: \(String(describing: type(of: error)), privacy: .public)")
            }
            guard let self else { return }
            self.lock.withLock { self.refreshing = false }
        }
    }
}
