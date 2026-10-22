import Foundation
import Supabase

/// 認証の失敗を、画面の文言の分け方に縮めたもの。SupabaseAuthService が supabase-swift のエラーから変える
/// (2026-10-22 パスワードレスに替え、パスワードと「確認がまだ」の失敗は消した)
enum AuthFailure: Error, Equatable {
    /// 新規登録を閉じている (ダッシュボードのトグル)。まだいない人・確認がまだの人にコードを送ろうとした
    case signupDisabled
    /// メールのサインインを閉じている (ダッシュボードのメールの provider・Magic Link)。どの人でも同じ
    case emailSignInDisabled
    /// 標準のメール送信 (外部の SMTP なし) で、Supabase の組織のメンバーでないアドレスに送ろうとした。
    /// どのアドレスでも同じに起きる (アカウントがあるかは分からない)
    case emailAddressNotAuthorized
    /// 送る前の確かめでアドレスが断られた (形が違う・ドメインが DNS に無い・`.test` などの決まった無効な名前ほか。2026-10-22 本番で見つけた)
    case emailAddressInvalid
    /// リンクを、フローを始めた端末とは別の端末で開いた (この端末に PKCE の verifier が無い)
    case linkOpenedOnAnotherDevice
    /// リンクが使い切り・期限切れ・無効
    case linkInvalid
    /// メールのコードが違うか、期限が切れている (GoTrue はどちらも `otp_expired`)
    case codeInvalid
    /// セッションが無い
    case sessionMissing
    /// 送りすぎ
    case rateLimited
    /// 通信できない
    case network
    /// Google のクライアント ID がまだ入っていない (xcconfig が `unset`)
    case googleNotConfigured
    /// 本人がやめた (Google の画面を閉じた)。文言は出さない
    case cancelled
    /// そのほか (ログ用の中身)
    case unknown(String)

    /// 画面に出す文言。`cancelled` は出さない
    var message: String? {
        switch self {
        case .signupDisabled: return "今はサインアップを受け付けていません"
        case .emailSignInDisabled: return "今はメールのコードでサインインできません"
        case .emailAddressNotAuthorized: return "このメールアドレスには、今はコードを送れません"
        case .emailAddressInvalid: return "メールアドレスが正しくありません。確かめて、もう一度入力してください"
        case .linkOpenedOnAnotherDevice: return "このメールは、「コードを送る」を押したこの iPhone で開いてください"
        case .linkInvalid: return "リンクが無効です。いちばん新しいメールのリンクを開くか、もう一度送ってください"
        case .codeInvalid: return "コードが違うか、期限が切れています。新しいコードを送ってください"
        case .sessionMissing: return "サインインし直してください"
        case .rateLimited: return "しばらく待ってから、もう一度お試しください"
        case .network: return "通信できませんでした。電波のよい所で、もう一度お試しください"
        case .googleNotConfigured: return "Google の設定がまだです"
        case .cancelled: return nil
        case .unknown: return "うまくいきませんでした。時間をおいて、もう一度お試しください"
        }
    }
}

/// どの操作の失敗か (同じエラーコードでも操作で意味が変わる: `validation_failed` はリンクのときだけ「verifier が無い」)
enum AuthOperation {
    case sendCode, verifyCode, google, link, signOut
}

extension AuthFailure {
    /// supabase-swift 2.44.1 のエラーから変える (純粋な関数)。
    ///
    /// リンク (`session(from:)`) の分け方【事実: supabase-swift の AuthClient.handlePKCEFlow・exchangeCodeForSession と GoTrue の token.go】
    /// - この端末に verifier が無いと、`code_verifier` が null で送られ、GoTrue は 400 `validation_failed`
    ///   (「both auth code and code verifier should be non-empty」)を返す → `linkOpenedOnAnotherDevice`
    /// - 使い切り (`flow_state_not_found`)・期限切れ (`flow_state_expired`・URL の `error_code=otp_expired`)・
    ///   verifier の食い違い (`bad_code_verifier`。この端末で後から別のフローを始めた場合もある)・
    ///   URL に code が無い (`pkceGrantCodeExchange`) とそのほか → `linkInvalid`
    /// - 通信の失敗だけは `network` (リンクはまだ使い切られていない)
    ///
    /// コードを送る (`signInWithOTP(email:)`・`POST /otp`) の分け方【事実: GoTrue の otp.go・magic_link.go・signup.go・mail.go】
    /// - まだいない人・確認がまだの人は中で新規登録に回り、新規登録を閉じていると 422 `signup_disabled`。
    ///   `shouldCreateUser: false` でまだいない人なら 422 `otp_disabled` (このアプリは true で送るので、ふつうは来ない) → どちらも `signupDisabled`
    /// - メールの provider・Magic Link を切ると 422 `email_provider_disabled` (確認済みの人も) → `emailSignInDisabled`
    /// - 標準のメール送信で組織のメンバーでないアドレスは 400 `email_address_not_authorized` (送る前に断る) → `emailAddressNotAuthorized`
    /// - 送る前のアドレスの確かめ (GoTrue の `internal/mailer/validateclient`: 形・`test@gmail.com` や `.test`・`.example`・`.local` などの決まった無効な名前・
    ///   gmail.com で @ の前が 6 文字未満・ドメインに MX か A の記録が無い) に落ちると 400 `email_address_invalid` → `emailAddressInvalid`。
    ///   supabase-swift 2.44.1 に定数が無いので `emailAddressInvalidCode` で比べる
    /// - 同じ人へ 60 秒の間にもう一度・メールの送信数の上限は 429 `over_email_send_rate_limit` → `rateLimited`
    ///
    /// コード (`verifyOTP(email:token:type:)`) の分け方【事実: GoTrue の verify.go の verifyUserAndToken】
    /// - コードの誤り・期限切れ・メールアドレスの人が見つからない、はどれも 403 `otp_expired`
    ///  (「Token has expired or is invalid」) → `codeInvalid`
    /// - `/verify` の送りすぎは 429 `over_request_rate_limit` (GoTrue の limitHandler) → `rateLimited`
    static let emailAddressInvalidCode = ErrorCode("email_address_invalid")

    static func from(_ error: Error, during operation: AuthOperation) -> AuthFailure {
        if let failure = error as? AuthFailure { return failure }
        if isNetworkError(error) { return .network }

        if case .link = operation {
            if case let AuthError.api(_, code, _, _) = error, code == .validationFailed {
                return .linkOpenedOnAnotherDevice
            }
            return .linkInvalid
        }

        guard let authError = error as? AuthError else {
            return .unknown(String(describing: error))
        }
        switch authError {
        case .sessionMissing:
            return .sessionMissing
        case let .api(message, code, _, _):
            switch code {
            case .signupDisabled, .otpDisabled: return .signupDisabled
            case .emailProviderDisabled: return .emailSignInDisabled
            case .emailAddressNotAuthorized: return .emailAddressNotAuthorized
            case emailAddressInvalidCode: return .emailAddressInvalid
            case .overRequestRateLimit, .overEmailSendRateLimit: return .rateLimited
            case .otpExpired: return .codeInvalid
            default: return .unknown("\(code.rawValue): \(message)")
            }
        default:
            return .unknown(authError.message)
        }
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }
}
