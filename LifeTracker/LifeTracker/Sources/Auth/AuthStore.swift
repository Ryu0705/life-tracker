import Combine
import Foundation
import os
import Supabase

/// 認証の状態 (計画 §2-1)。LifeTrackerApp がこの状態で画面を出し分ける (起動中 → 起動画面・サインイン済み → TabView・ほか → 認証の画面)。
///
/// - `authStateChanges` は 1 本だけ購読する (`start()`)。`.initialSession` を受けるまで「起動中」
/// - 期限切れのセッションでも「サインイン済み」として扱い、`.signedOut` が来たときだけ「未サインイン」に戻す
///   (更新がネットワークで失敗してもサインアウトにはならない。`.signedOut` はサインアウトと、サーバーがセッション無効と返したときだけ)
/// - サインイン済みになったら `ensureUserDefaults` を UID ごとに 1 回呼ぶ。失敗しても画面は出す (ログだけ。次の起動でまた呼ぶ)
/// - サインインはメールの 6 桁のコードと Google だけ (2026-10-22 本人の決定。パスワードは使わない):
///   コードを送る → コードの入力 → `verifyEmailCode` でセッション → サインイン済み。登録とサインインは同じ流れ
///   (はじめての人は、コードを確かめたときに登録が終わる)
///   - コードの確かめとリンクの処理の間に supabase-swift が流す `.signedIn` は使わず、処理の側がサインイン済みにする
///     (片付けと初期データを、処理の側の 1 か所から 1 回ずつ呼ぶ)
/// - リンク (`handle(url:)`・`lifetracker://auth-callback`) は、メールのテンプレートを替える前の古いリンクのために残す。
///   PKCE の `code` ならセッションを作ってサインイン済み、implicit 形式なら知らせ、失敗は文言
/// - 端末の側の片付け (計画 §2-6) はフックで受ける (中身は LifeTrackerApp が渡す `SignInSideEffects`)。
///   `onSignedIn` はサインイン済みに移ったとき、`onSignedOut` はサインイン済みか起動中から未サインインに移ったとき
///   (サインアウト・サーバーの `.signedOut`・起動して端末にセッションが無い)。
///   起動中も含めるのは、片付けを経ずにセッションが無くなった端末で、ウィジェットに前の人の記録を残さないため (2026-10-21 AI 既定)。
///   サインアウトを経ずに人が変わったとき (サインイン済みから別の人のサインイン済みへ) は、`onSignedOut` → `onSignedIn` の順に呼ぶ。
///   呼ぶのは `enterSignedIn`・`enterSignedOut` の 2 か所だけ
/// - 再送した確認メールの古いリンクは implicit 形式 (fragment にトークン) で戻る。セッションは作らず、サインインの画面に
///   「メールアドレスを確認しました」を出す (`AuthCallback.isImplicitGrant`)
@MainActor
final class AuthStore: ObservableObject {
    enum Phase: Equatable {
        /// `.initialSession` を待っている
        case launching
        case signedOut
        /// コードを送った (そのメールアドレス)。コードを入れてもらう (セッションは無い)
        case awaitingCode(email: String)
        case signedIn(userID: UUID)
    }

    /// コードの送り直しの待ち (Supabase は同じ人へのメールを 60 秒に 1 回まで)
    static let resendInterval: TimeInterval = 60
    /// implicit 形式の確認のリンクを開いた後に、サインインの画面に出す知らせ
    static let emailConfirmedNotice = "メールアドレスを確認しました。サインインしてください"

    @Published private(set) var phase: Phase = .launching
    /// コードのメールを最後に送った時刻 (送り直しの 60 秒の待ちに使う)
    @Published private(set) var codeSentAt: Date?
    /// リンクを開けなかったときの文言 (画面の一番上の alert で出す)
    @Published var linkFailureMessage: String?
    /// サインインの画面の上に出す知らせ (確認のリンクを開いた後)。サインイン済みになったら消す
    @Published private(set) var signInNotice: String?
    /// 最後に入れたメールアドレス (コードを送ろうとしたもの)。コードの画面からサインインの画面に戻ったとき、欄に入れておく。
    /// メモリの中だけ (保存しない)。サインイン済みになったら消す
    @Published private(set) var lastEmail = ""
    /// サインイン中のメールアドレス (プロフィールのタブの「アカウント」に読むだけで出す。2026-10-22)。
    /// 認証の層の `currentEmail` (セッションの user の email。Google でサインインした人も同じ) を、サインイン済みに入ったときと
    /// `.updated` (トークン・ユーザーの更新) のときに読み直す。未サインインで消す。取れない・空なら nil (行を出さない)
    @Published private(set) var signedInEmail: String?

    private let service: AuthService
    private let now: () -> Date
    private let googleSignIn: () async throws -> GoogleIDToken
    private let ensureUserDefaults: () async throws -> Void
    private let onSignedIn: () -> Void
    private let onSignedOut: () -> Void
    private let logger = Logger(subsystem: "LifeTracker", category: "auth")

    private var listenTask: Task<Void, Never>?
    /// `ensureUserDefaults` を呼んだ UID (UID ごとに 1 回)
    private var ensuredUserID: UUID?
    /// 処理中のコードの確かめ・リンクの数。この間の `.signedIn` は、処理の側 (戻ってからサインイン済みにする) に任せる
    private var sessionHandoffsInFlight = 0
    /// `apply` で反映した出来事の数 (`@testable` 用。テストが「流した出来事が届いた」を待つのに使う)
    private(set) var appliedChanges = 0

    init(service: AuthService,
         now: @escaping () -> Date = { Date() },
         googleSignIn: @escaping () async throws -> GoogleIDToken = { try await GoogleSignInHelper.signIn() },
         ensureUserDefaults: @escaping () async throws -> Void,
         onSignedIn: @escaping () -> Void = {},
         onSignedOut: @escaping () -> Void = {}) {
        self.service = service
        self.now = now
        self.googleSignIn = googleSignIn
        self.ensureUserDefaults = ensureUserDefaults
        self.onSignedIn = onSignedIn
        self.onSignedOut = onSignedOut
    }

    deinit {
        listenTask?.cancel()
    }

    /// 状態の流れを購読する (何度呼んでも 1 本だけ)
    func start() {
        guard listenTask == nil else { return }
        let stream = service.authChanges()
        listenTask = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                self.apply(change)
            }
        }
    }

    /// 状態の流れの 1 件を反映する
    func apply(_ change: AuthChange) {
        defer { appliedChanges += 1 }
        switch change {
        case .initialSession(let userID):
            guard phase == .launching else { return }
            if let userID {
                enterSignedIn(userID)
            } else {
                enterSignedOut()
            }
        case .signedIn(let userID):
            // コードの確かめ・リンクの処理中は、そちらが戻ってからサインイン済みにする
            if sessionHandoffsInFlight > 0 { return }
            enterSignedIn(userID)
        case .signedOut:
            switch phase {
            case .launching, .signedIn:
                enterSignedOut()
            case .signedOut, .awaitingCode:
                // セッションの無い画面 (コードの入力) は、遅れて届いた .signedOut で動かさない
                break
            }
        case .updated:
            // ユーザーの更新でメールアドレスが変わっていれば合わせる (画面の状態は変えない)
            if case .signedIn = phase { signedInEmail = Self.displayEmail(service.currentEmail) }
        }
    }

    // MARK: - 操作 (戻り値は画面に出す失敗の文言。nil なら成功)

    /// コードを送る (サインインの画面の「コードを送る」)。送れたらコードの入力へ (60 秒の送り直しの待ちが始まる)。
    /// はじめての人も同じ (送れたときのサーバーの答えは、いる人もいない人も同じ)。断られたら文言を返し、サインインの画面のまま
    /// (新規登録を閉じている・送れないアドレス・送りすぎ・通信できない など)
    func sendCode(email rawEmail: String) async -> String? {
        let email = EmailInput.normalized(rawEmail)
        guard EmailInput.looksValid(email) else { return "メールアドレスを入れてください" }
        lastEmail = email
        do {
            try await service.sendEmailCode(email: email)
        } catch {
            let failure = AuthFailure.from(error, during: .sendCode)
            log(failure, during: "sendCode")
            return failure.message
        }
        codeSentAt = now()
        signInNotice = nil
        phase = .awaitingCode(email: email)
        return nil
    }

    /// コードの送り直し (コードの入力)。60 秒の待ちの間は送らない。送れたら待ちが始まり直す。断られたら文言 (待ちは始まらない)
    func resendCode() async -> String? {
        guard case .awaitingCode(let email) = phase else { return nil }
        guard resendRemainingSeconds(at: now()) == 0 else { return nil }
        do {
            try await service.sendEmailCode(email: email)
        } catch {
            let failure = AuthFailure.from(error, during: .sendCode)
            log(failure, during: "resendCode")
            return failure.message
        }
        codeSentAt = now()
        return nil
    }

    /// 送り直せるまでの残りの秒 (0 なら送れる)
    func resendRemainingSeconds(at date: Date) -> Int {
        guard let sentAt = codeSentAt else { return 0 }
        let left = Self.resendInterval - date.timeIntervalSince(sentAt)
        return left > 0 ? Int(left.rounded(.up)) : 0
    }

    /// メールに届いたコードを確かめる (コードの入力)。空白とハイフンは取り除き、6 桁の数字でなければ送らない。通ればサインイン済みへ
    func verifyCode(_ rawCode: String) async -> String? {
        guard case .awaitingCode(let email) = phase else { return nil }
        let code = EmailCodeInput.normalized(rawCode)
        guard EmailCodeInput.isComplete(code) else { return EmailCodeInput.guidance }
        sessionHandoffsInFlight += 1
        defer { sessionHandoffsInFlight -= 1 }
        do {
            let userID = try await service.verifyEmailCode(email: email, code: code)
            enterSignedIn(userID)
            return nil
        } catch {
            let failure = AuthFailure.from(error, during: .verifyCode)
            log(failure, during: "verifyCode")
            return failure.message
        }
    }

    /// `lifetracker://auth-callback?code=...` を受ける (メールのテンプレートを替える前の、古いメールのリンク)。
    /// 通ればサインイン済み。失敗は `linkFailureMessage` に出す。
    /// implicit 形式 (fragment に access_token。再送した確認メール) はセッションを作らずに受ける
    func handle(url: URL) async {
        if AuthCallback.isImplicitGrant(url) {
            acceptImplicitConfirmation()
            return
        }
        sessionHandoffsInFlight += 1
        defer { sessionHandoffsInFlight -= 1 }
        do {
            let userID = try await service.session(from: url)
            enterSignedIn(userID)
        } catch {
            let failure = AuthFailure.from(error, during: .link)
            log(failure, during: "link")
            linkFailureMessage = failure.message
        }
    }

    func signInWithGoogle() async -> String? {
        do {
            let token = try await googleSignIn()
            let userID = try await service.signInWithGoogle(idToken: token.idToken, accessToken: token.accessToken,
                                                            rawNonce: token.rawNonce)
            enterSignedIn(userID)
            return nil
        } catch {
            let failure = AuthFailure.from(error, during: .google)
            if failure != .cancelled { log(failure, during: "google") }
            return failure.message
        }
    }

    /// サインアウト。失敗しても端末側はサインアウト済みとして扱い、結果に依らずサインインの画面へ (計画 §2-6)。
    /// サーバーの `.signedOut` が先に届いて未サインインになっていれば、片付けはそちらで済んでいる
    func signOut() async {
        do {
            try await service.signOut()
        } catch {
            log(AuthFailure.from(error, during: .signOut), during: "signOut")
        }
        enterSignedOut()
    }

    /// コードの入力をやめて (送り先の「変更」)、サインインの画面に戻る (セッションは無い)。欄には送ったメールアドレスが残る (`lastEmail`)
    func backToSignIn() {
        switch phase {
        case .awaitingCode:
            codeSentAt = nil
            phase = .signedOut
        case .launching, .signedOut, .signedIn:
            break
        }
    }

    // MARK: - 内部

    /// サインイン済みへ (コード・Google・リンク・サーバーの .signedIn・起動時のセッション)。送り直しの待ちも消す
    private func enterSignedIn(_ userID: UUID) {
        let next = Phase.signedIn(userID: userID)
        signInNotice = nil
        lastEmail = ""
        codeSentAt = nil
        // 画面 (TabView) が出る前に入れておく
        signedInEmail = Self.displayEmail(service.currentEmail)
        cleanUpIfUserChanges(to: userID)
        if phase != next {
            phase = next
            onSignedIn()
        }
        guard ensuredUserID != userID else { return }
        ensuredUserID = userID
        let ensure = ensureUserDefaults
        let logger = logger
        Task {
            do {
                try await ensure()
            } catch {
                logger.error("ensure_user_defaults failed: \(Self.logDescription(of: error), privacy: .public)")
            }
        }
    }

    /// サインアウトを経ずに人が変わる (別の人のリンク・サーバーの .signedIn) なら、先に前の人の端末の側を片付ける (`enterSignedIn` から呼ぶ)
    private func cleanUpIfUserChanges(to userID: UUID) {
        switch phase {
        case .signedIn(let previous):
            if previous != userID { onSignedOut() }
        case .launching, .signedOut, .awaitingCode:
            break
        }
    }

    /// 未サインインへ。セッションのある状態 (サインイン済み) か起動中からなら端末の側を片付ける (ここだけから呼ぶ)
    private func enterSignedOut() {
        let hadSession: Bool
        switch phase {
        // 起動中も片付ける (端末にセッションが無いと分かった。片付けを経ずに無くなった場合を含む)
        case .launching, .signedIn: hadSession = true
        case .signedOut, .awaitingCode: hadSession = false
        }
        ensuredUserID = nil
        signedInEmail = nil
        codeSentAt = nil
        phase = .signedOut
        if hadSession { onSignedOut() }
    }

    /// 画面に出すメールアドレス (前後の空白を取る。空なら nil)
    static func displayEmail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let email = EmailInput.normalized(raw)
        return email.isEmpty ? nil : email
    }

    /// 再送した確認メールの古いリンク (implicit 形式) を開いた。メールアドレスの確認はサーバーで済んでいる
    /// (そのぶん、入れかけの確認のコードはもう使えない)。
    /// セッションは作らない (setSession は使わない。他人のトークンのリンクで入らされる、ログインの CSRF を避ける)。
    /// コードの入力・未サインインならサインインの画面へ移って知らせを出す (コードを送り直してもらう)。起動中なら知らせだけ置く
    /// (サインインの画面に出たときに見える)。サインイン済みの間は何もしない。URL (トークン) はログに出さない
    private func acceptImplicitConfirmation() {
        logger.info("auth link: implicit confirmation (no session created)")
        switch phase {
        case .awaitingCode, .signedOut:
            codeSentAt = nil
            signInNotice = Self.emailConfirmedNotice
            phase = .signedOut
        case .launching:
            signInNotice = Self.emailConfirmedNotice
        case .signedIn:
            break
        }
    }

    private func log(_ failure: AuthFailure, during operation: String) {
        logger.error("auth \(operation, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
    }

    /// データの呼び出しの失敗をログに出す形。中身 (URL などを含む説明) は出さず、型と、PostgrestError なら code だけ
    private static func logDescription(of error: Error) -> String {
        let typeName = String(describing: type(of: error))
        if let code = (error as? PostgrestError)?.code { return "\(typeName) code=\(code)" }
        return typeName
    }
}
