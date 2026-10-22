import Foundation
import Supabase

/// 今の共有の SupabaseClient の `auth` を包む (計画 §2-1)。data source と同じクライアントなので、サインインするとデータの呼び出しにトークンが付く。
/// クライアントの設定 (`redirectToURL`・`flowType: .pkce`・`emitLocalSessionAsInitialSession: true`) は LifeTrackerApp.makeClient()
final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func authChanges() -> AsyncStream<AuthChange> {
        let upstream = client.auth.authStateChanges
        let (stream, continuation) = AsyncStream<AuthChange>.makeStream()
        let task = Task {
            for await (event, session) in upstream {
                continuation.yield(AuthChange.from(event: event, userID: session?.user.id))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// `signInWithOTP` は `POST /otp`。`shouldCreateUser: true` なので、まだいない人もここで登録される (確かめるまでは確認がまだの人)。
    /// GoTrue は、まだいない人・確認がまだの人には「Confirm signup」のテンプレート、確認済みの人には「Magic Link」のテンプレートで送る
    /// (どちらも `{{ .Token }}` で 6 桁のコードになる)【事実: GoTrue の magic_link.go の MagicLink・mail.go の sendConfirmation・sendMagicLink】。
    /// 戻り先 (`AuthCallback.url`) はテンプレートがまだリンクのときのため (PKCE の `code` で戻り、`handle(url:)` が受ける)
    func sendEmailCode(email: String) async throws {
        do {
            try await client.auth.signInWithOTP(email: email, redirectTo: AuthCallback.url, shouldCreateUser: true)
        } catch {
            throw AuthFailure.from(error, during: .sendCode)
        }
    }

    /// コードの種類。`.email` なら GoTrue は確認のコード (新しい人・確認がまだの人) と Magic Link のコード (確認済みの人) の
    /// 両方と比べるので、新しい人と登録済みの人のどちらも通る (`.signup` は確認のコードだけ、`.magiclink` は Magic Link のコードだけ)
    /// 【事実: GoTrue の verify.go の verifyUserAndToken の `mail.EmailOTPVerification`・Supabase の文書 auth-email-passwordless】
    static let emailCodeType: EmailOTPType = .email

    /// supabase-swift 2.44.1 の `verifyOTP(email:token:type:)` は `POST /verify` で、成功するとセッションを持ち、`.signedIn` を流してから返る
    /// (AuthClient の `_verifyOTP`)。コードは PKCE で頼んでいても (`signInWithOTP` は `prepareForPKCE`)、
    /// GoTrue が `pkce_` を付けた形と比べるので通る【事実: GoTrue の verify.go の isOtpValid】
    func verifyEmailCode(email: String, code: String) async throws -> UUID {
        do {
            let response = try await client.auth.verifyOTP(email: email, token: code, type: Self.emailCodeType)
            guard let session = response.session else { throw AuthFailure.sessionMissing }
            return session.user.id
        } catch {
            throw AuthFailure.from(error, during: .verifyCode)
        }
    }

    func signInWithGoogle(idToken: String, accessToken: String, rawNonce: String) async throws -> UUID {
        do {
            let credentials = OpenIDConnectCredentials(provider: .google, idToken: idToken,
                                                       accessToken: accessToken, nonce: rawNonce)
            return try await client.auth.signInWithIdToken(credentials: credentials).user.id
        } catch {
            throw AuthFailure.from(error, during: .google)
        }
    }

    /// `handle(_:)` は使わない (失敗をログに流すだけで、画面に何も出ないため。計画 §2-1 P19)。
    /// メールはコードに替えた (2026-10-22)。テンプレートを替える前の古いリンクのために残す
    func session(from url: URL) async throws -> UUID {
        do {
            return try await client.auth.session(from: url).user.id
        } catch {
            throw AuthFailure.from(error, during: .link)
        }
    }

    func signOut() async throws {
        do {
            try await client.auth.signOut()
        } catch {
            throw AuthFailure.from(error, during: .signOut)
        }
    }

    /// `currentUser` は端末に保存してあるセッションの user を読むだけ (期限切れでもそのまま。通信しない)。
    /// Google の ID トークンでサインインした人も、そのセッションの user の email
    var currentEmail: String? {
        client.auth.currentUser?.email
    }
}

extension AuthChange {
    /// supabase-swift の出来事から変える (純粋な関数)。
    /// `.initialSession` は期限切れのセッションでもそのまま持ち主を返す (`emitLocalSessionAsInitialSession: true`。計画 §2-1)。
    /// `.passwordRecovery` は PKCE のリンクでもコード (`verifyOTP`) でも来ない (`.signedIn` だけ)。
    /// パスワードの再設定は無くした (2026-10-22 パスワードレス)。来ても状態は変えない
    static func from(event: AuthChangeEvent, userID: UUID?) -> AuthChange {
        switch event {
        case .initialSession:
            return .initialSession(userID)
        case .signedIn:
            if let userID { return .signedIn(userID) }
            return .updated
        case .signedOut:
            return .signedOut
        case .tokenRefreshed, .userUpdated, .userDeleted, .passwordRecovery, .mfaChallengeVerified:
            return .updated
        }
    }
}
