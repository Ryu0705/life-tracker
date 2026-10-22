#if DEBUG
import Foundation

/// メモリ上の認証 (DEBUG とテスト。起動引数 `-mock-auth`・`-mock-auth-signed-out` と単体テストの環境)。
/// どのメールアドレスにもコードを送れる (送ったことにする) し、決まったコードで通る (2026-10-22 パスワードレスに替えた)。本物の Supabase にはつながない
final class MockAuthService: AuthService {
    /// 起動したときからサインイン済みの人・Google でサインインした人のメールアドレス
    static let email = "test@example.com"
    /// メールのコード。ほかのコードは `codeInvalid`
    static let code = "123456"
    /// メモリ上の人の UID (本物の UID ではない。どのメールアドレスでも同じ)
    static let userID = UUID(uuidString: "00000000-0000-0000-0000-00000000a001")!

    private var currentUserID: UUID?
    /// サインインしている人のメールアドレス (コードでサインインした人はそのアドレス)
    private var signedInEmail: String?
    private var continuations: [AsyncStream<AuthChange>.Continuation] = []

    init(signedIn: Bool) {
        if signedIn {
            currentUserID = Self.userID
            signedInEmail = Self.email
        }
    }

    func authChanges() -> AsyncStream<AuthChange> {
        let (stream, continuation) = AsyncStream<AuthChange>.makeStream()
        continuation.yield(.initialSession(currentUserID))
        continuations.append(continuation)
        return stream
    }

    /// メモリ上では送ったことにする (コードの画面を見るため)
    func sendEmailCode(email: String) async throws {}

    /// 本物と同じく、通ったらセッションを持ち `.signedIn` を流してから返す
    func verifyEmailCode(email: String, code: String) async throws -> UUID {
        guard code == Self.code else { throw AuthFailure.codeInvalid }
        return signInMockUser(email: email)
    }

    func signInWithGoogle(idToken: String, accessToken: String, rawNonce: String) async throws -> UUID {
        signInMockUser(email: Self.email)
    }

    /// `lifetracker://auth-callback?code=mock` だけ通す (シミュレータで `xcrun simctl openurl` から確かめる用)
    func session(from url: URL) async throws -> UUID {
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
        guard code == "mock" else { throw AuthFailure.linkInvalid }
        return signInMockUser(email: Self.email)
    }

    func signOut() async throws {
        currentUserID = nil
        signedInEmail = nil
        emit(.signedOut)
    }

    /// サインインしている間はその人のメールアドレス
    var currentEmail: String? {
        currentUserID == nil ? nil : signedInEmail
    }

    private func signInMockUser(email: String) -> UUID {
        currentUserID = Self.userID
        signedInEmail = email
        emit(.signedIn(Self.userID))
        return Self.userID
    }

    private func emit(_ change: AuthChange) {
        continuations.forEach { $0.yield(change) }
    }
}
#endif
