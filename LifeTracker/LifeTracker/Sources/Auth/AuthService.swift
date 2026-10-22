import Foundation

/// 認証の層 (docs/auth-multiuser-implementation-plan.md §2-1)。
/// 本番は SupabaseAuthService (共有の SupabaseClient の auth を包む)、DEBUG とテストは MockAuthService。
/// 失敗は AuthFailure で投げる (画面の文言は AuthFailure.message。supabase-swift の型を画面側に出さない)
protocol AuthService {
    /// 状態の流れ。最初に必ず `.initialSession` が来る。呼ぶたびに新しい流れになるので、AuthStore は 1 本だけ購読する
    func authChanges() -> AsyncStream<AuthChange>
    /// メールに 6 桁のコードを送る (送り直しも同じ)。はじめての人も同じ (コードを確かめたときに登録が終わる。2026-10-22 パスワードレスに替えた)
    func sendEmailCode(email: String) async throws
    /// メールに届いた 6 桁のコードを確かめる。成功したらセッションができ、その UID を返す (新しい人も登録済みの人も同じ)
    func verifyEmailCode(email: String, code: String) async throws -> UUID
    /// Google の ID トークンでサインイン。`rawNonce` は Google に渡した値 (SHA-256) の元の値
    func signInWithGoogle(idToken: String, accessToken: String, rawNonce: String) async throws -> UUID
    /// `lifetracker://auth-callback?code=...` からセッションを作る。成功したら UID。
    /// メールはコードに替えた (2026-10-22)。メールのテンプレートを替える前に届いた、古いリンクのために残す
    func session(from url: URL) async throws -> UUID
    func signOut() async throws
    /// 端末のセッションの人のメールアドレス (期限切れのセッションでもそのまま。通信しない)。セッションかメールアドレスが無ければ nil。
    /// Google でサインインした人も、セッションの user の email (プロフィールのタブの「アカウント」に出す。2026-10-22)
    var currentEmail: String? { get }
}

/// 認証の状態の変化 (supabase-swift の AuthChangeEvent を AuthStore が見る分だけに縮めたもの)
enum AuthChange: Equatable {
    /// 起動時の端末のセッションの持ち主 (期限切れでもそのまま)。無ければ nil
    case initialSession(UUID?)
    case signedIn(UUID)
    case signedOut
    /// トークンの更新・ユーザーの更新など。画面の状態は変えない
    case updated
}

/// メールのリンクの戻り先 (Info.plist の CFBundleURLTypes に `lifetracker` を入れてある)。
/// メールはコードに替えた (2026-10-22) が、テンプレートを替える前の古いリンクが届いた場合のために受け口を残す
enum AuthCallback {
    static let url = URL(string: "lifetracker://auth-callback")!

    /// AuthStore に渡す URL か (`lifetracker://auth-callback...`)。ほかの URL (Google の戻り) は渡さない
    static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "lifetracker" && url.host?.lowercased() == "auth-callback"
    }

    /// implicit 形式の戻り (fragment に空でない `access_token` がある) か (純粋な関数)。
    /// supabase-swift 2.44.1 の `resend` は `code_challenge` を送らない (`ResendEmailParams` に欄が無い) ので、再送した確認メールの
    /// リンクはこの形 (`#access_token=...&type=signup`) で戻る見込み。PKCE の設定の `session(from:)` はこれを受け付けない
    /// (code が無いので `pkceGrantCodeExchange`)。fragment の中身は判定にだけ使い、持ち出さない
    static func isImplicitGrant(_ url: URL) -> Bool {
        guard let fragment = url.fragment, !fragment.isEmpty else { return false }
        return fragment.split(separator: "&").contains { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 && parts[0] == "access_token" && !parts[1].isEmpty
        }
    }
}
