import Foundation
import Supabase
import Testing
import UIKit
@testable import LifeTracker

// サインインの層 (docs/auth-multiuser-implementation-plan.md §2-1〜§2-4・§2-7)。
// 2026-10-22 パスワードレス (メールの 6 桁のコード＋Google) に替えた

/// テスト用の認証。結果を差し替えられ、状態の流れは continuation で流す
@MainActor
final class FakeAuthService: AuthService {
    let stream: AsyncStream<AuthChange>
    let continuation: AsyncStream<AuthChange>.Continuation
    private(set) var authChangesCalls = 0
    private(set) var calls: [String] = []

    var sendError: Error?
    var googleResult: Result<UUID, Error> = .failure(AuthFailure.unknown("not set"))
    var sessionResult: Result<UUID, Error> = .failure(AuthFailure.linkInvalid)
    var verifyResult: Result<UUID, Error> = .failure(AuthFailure.codeInvalid)
    var signOutError: Error?
    /// 端末のセッションの人のメールアドレス (テストが直接入れる)
    var currentEmail: String?
    /// session(from:)・verifyEmailCode が返る前に、この出来事を流す (supabase-swift は exchangeCodeForSession・verifyOTP の中で
    /// .signedIn を流してから返る)。流したら `observedStore` がそれを反映する (`appliedChanges` が増える) まで待ってから返す
    var emitBeforeSessionReturns: AuthChange?
    /// `emitBeforeSessionReturns` を反映する AuthStore (start() で購読していること)
    weak var observedStore: AuthStore?
    /// `emitBeforeSessionReturns` を AuthStore が反映した直後の画面の状態 (処理の側が戻る前)
    private(set) var phaseAfterEmit: AuthStore.Phase?
    private(set) var googleArguments: (idToken: String, accessToken: String, rawNonce: String)?

    init() {
        (stream, continuation) = AsyncStream<AuthChange>.makeStream()
    }

    func authChanges() -> AsyncStream<AuthChange> {
        authChangesCalls += 1
        return stream
    }

    func sendEmailCode(email: String) async throws {
        calls.append("send:\(email)")
        if let sendError { throw sendError }
    }

    func verifyEmailCode(email: String, code: String) async throws -> UUID {
        calls.append("verify:\(email):\(code)")
        let userID = try verifyResult.get()
        await emitRequestedChange()
        return userID
    }

    func signInWithGoogle(idToken: String, accessToken: String, rawNonce: String) async throws -> UUID {
        calls.append("google")
        googleArguments = (idToken, accessToken, rawNonce)
        return try googleResult.get()
    }

    func session(from url: URL) async throws -> UUID {
        calls.append("session")
        let userID = try sessionResult.get()
        await emitRequestedChange()
        return userID
    }

    /// `emitBeforeSessionReturns` を流し、AuthStore が反映してから戻る (Task.yield の回数に頼らない。反映しても、処理の側が行き先を決める)。
    /// supabase-swift と同じく、成功したときだけ流す
    private func emitRequestedChange() async {
        guard let emitBeforeSessionReturns else { return }
        guard let store = observedStore else {
            Issue.record("emitBeforeSessionReturns には observedStore が要る")
            return
        }
        let applied = store.appliedChanges
        continuation.yield(emitBeforeSessionReturns)
        await AuthTestSupport.waitUntil { store.appliedChanges > applied }
        #expect(store.appliedChanges > applied, "流した出来事が AuthStore に届いていない")
        phaseAfterEmit = store.phase
    }

    func signOut() async throws {
        calls.append("signOut")
        if let signOutError { throw signOutError }
    }
}

@MainActor
final class CallCounter {
    var value = 0
}

@MainActor
enum AuthTestSupport {
    static let userA = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
    static let userB = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    final class Clock {
        var now: Date = AuthTestSupport.start
    }

    static func defaults() -> UserDefaults {
        let suite = "AuthStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// `hooks` を渡すと、端末の側のフックの呼び出しを "onSignedIn"・"onSignedOut" で記録する
    static func makeStore(_ service: FakeAuthService, clock: Clock? = nil,
                          ensureCount: CallCounter? = nil, ensureError: Error? = nil,
                          google: (() async throws -> GoogleIDToken)? = nil,
                          hooks: SideEffectLog? = nil) -> AuthStore {
        let clock = clock ?? Clock()
        let ensureCount = ensureCount ?? CallCounter()
        return AuthStore(service: service, now: { clock.now },
                         googleSignIn: google ?? { throw AuthFailure.googleNotConfigured },
                         ensureUserDefaults: {
                             ensureCount.value += 1
                             if let ensureError { throw ensureError }
                         },
                         onSignedIn: { hooks?.events.append("onSignedIn") },
                         onSignedOut: { hooks?.events.append("onSignedOut") })
    }

    /// 非同期の反映を待つ (最大 1 秒)
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static func apiError(_ code: ErrorCode, status: Int = 400) -> AuthError {
        .api(message: "server message", errorCode: code, underlyingData: Data(),
             underlyingResponse: HTTPURLResponse(url: URL(string: "https://example.invalid/auth/v1/otp")!,
                                                 statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    /// コードを送ってコードの入力にする (送るのは成功する前提)
    static func sendCode(_ store: AuthStore, to email: String = "a@example.com") async {
        #expect(await store.sendCode(email: email) == nil)
        #expect(store.phase == .awaitingCode(email: email))
    }

    static let callbackURL = URL(string: "lifetracker://auth-callback?code=abc")!
}

// MARK: - 状態の移り変わり

@MainActor
@Suite("AuthStore — 状態の移り変わり (起動中・未サインイン・サインイン済み)")
struct AuthStoreStateTests {
    typealias S = AuthTestSupport

    @Test("初期セッションがあればサインイン済み。ensure_user_defaults を 1 回呼ぶ")
    func initialSessionSignedIn() async {
        let service = FakeAuthService()
        let ensure = CallCounter()
        let store = S.makeStore(service, ensureCount: ensure)
        #expect(store.phase == .launching)
        store.apply(.initialSession(S.userA))
        #expect(store.phase == .signedIn(userID: S.userA))
        await S.waitUntil { ensure.value == 1 }
        #expect(ensure.value == 1)
        // 同じ人の .signedIn・トークンの更新では呼び直さない
        store.apply(.signedIn(S.userA))
        store.apply(.updated)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(ensure.value == 1)
        #expect(store.phase == .signedIn(userID: S.userA))
    }

    @Test("初期セッションが無ければ未サインイン。ensure_user_defaults は呼ばない")
    func initialSessionNone() async {
        let service = FakeAuthService()
        let ensure = CallCounter()
        let store = S.makeStore(service, ensureCount: ensure)
        store.apply(.initialSession(nil))
        #expect(store.phase == .signedOut)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(ensure.value == 0)
    }

    @Test("状態の流れは 1 本だけ購読し、.initialSession を受けるまで起動中")
    func subscribesOnce() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.start()
        store.start()
        #expect(service.authChangesCalls == 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(store.phase == .launching)
        service.continuation.yield(.initialSession(S.userA))
        await S.waitUntil { store.phase != .launching }
        #expect(store.phase == .signedIn(userID: S.userA))
        // 2 回目の .initialSession は無視する
        store.apply(.initialSession(nil))
        #expect(store.phase == .signedIn(userID: S.userA))
    }

    @Test("期限切れのセッションでもサインイン済み。更新の失敗では戻さず、.signedOut のときだけ未サインインへ")
    func signedOutOnlyOnSignedOutEvent() async {
        // supabase-swift の出来事の変換: 初期セッションは期限切れでも持ち主を返す。更新は状態を変えない
        #expect(AuthChange.from(event: .initialSession, userID: S.userA) == .initialSession(S.userA))
        #expect(AuthChange.from(event: .initialSession, userID: nil) == .initialSession(nil))
        #expect(AuthChange.from(event: .tokenRefreshed, userID: S.userA) == .updated)
        #expect(AuthChange.from(event: .userUpdated, userID: S.userA) == .updated)
        #expect(AuthChange.from(event: .passwordRecovery, userID: S.userA) == .updated)
        #expect(AuthChange.from(event: .signedIn, userID: S.userA) == .signedIn(S.userA))
        #expect(AuthChange.from(event: .signedOut, userID: nil) == .signedOut)

        let service = FakeAuthService()
        let ensure = CallCounter()
        let store = S.makeStore(service, ensureCount: ensure)
        store.apply(.initialSession(S.userA))
        store.apply(.updated)
        #expect(store.phase == .signedIn(userID: S.userA))
        store.apply(.signedOut)
        #expect(store.phase == .signedOut)
        // 入り直すと ensure_user_defaults をもう一度呼ぶ
        store.apply(.signedIn(S.userA))
        #expect(store.phase == .signedIn(userID: S.userA))
        await S.waitUntil { ensure.value == 2 }
        #expect(ensure.value == 2)
    }

    @Test("人が変わればその人のサインイン済みになる。サインアウトを経ずに変わったときは、前の人の片付け → サインインの順")
    func switchUser() async {
        typealias W = SignOutSupport
        let switched = ["reload(snapshot: none, signedIn: false)", "stopRest", "signOutGoogle",
                        "reload(snapshot: none, signedIn: true)"]
        let defaults = S.defaults()
        let log = SideEffectLog()
        ContinuityShare.save(W.snapshot, defaults: defaults)
        let store = W.makeStore(FakeAuthService(), effects: W.effects(defaults, log: log))
        store.apply(.initialSession(S.userA))
        #expect(log.events.isEmpty)
        store.apply(.signedIn(S.userB))
        #expect(store.phase == .signedIn(userID: S.userB))
        #expect(log.events == switched)
        // 同じ人の .signedIn では片付けない
        store.apply(.signedIn(S.userB))
        #expect(log.events == switched)

        // 別の人の古いメールのリンクを開いた (サインイン済みのまま、端末のセッションが置き換わる)
        let linkDefaults = S.defaults()
        let linkLog = SideEffectLog()
        ContinuityShare.save(W.snapshot, defaults: linkDefaults)
        let service = FakeAuthService()
        service.sessionResult = .success(S.userB)
        let linked = W.makeStore(service, effects: W.effects(linkDefaults, log: linkLog))
        linked.apply(.initialSession(S.userA))
        await linked.handle(url: S.callbackURL)
        #expect(linked.phase == .signedIn(userID: S.userB))
        #expect(linkLog.events == switched)
    }

    @Test("ensure_user_defaults が失敗しても画面はサインイン済みのまま")
    func ensureFailureKeepsSignedIn() async {
        struct Boom: Error {}
        let ensure = CallCounter()
        let store = S.makeStore(FakeAuthService(), ensureCount: ensure, ensureError: Boom())
        store.apply(.initialSession(S.userA))
        await S.waitUntil { ensure.value == 1 }
        #expect(ensure.value == 1)
        #expect(store.phase == .signedIn(userID: S.userA))
    }

    @Test("サインアウトが失敗しても未サインインへ")
    func signOutAlwaysSignsOut() async {
        let service = FakeAuthService()
        service.signOutError = URLError(.notConnectedToInternet)
        let store = S.makeStore(service)
        store.apply(.initialSession(S.userA))
        await store.signOut()
        #expect(store.phase == .signedOut)
        #expect(service.calls == ["signOut"])
    }
}

// MARK: - メールのコードでサインイン (2026-10-22 パスワードレス)

@MainActor
@Suite("AuthStore — メールのコードでサインイン (送る → コード → サインイン済み。はじめての人も同じ)")
struct AuthStoreEmailCodeTests {
    typealias S = AuthTestSupport

    @Test("送る → コードの入力 → コードが通ればサインイン済み。メールアドレスの前後の空白、コードの空白とハイフンは取り除いて送る。片付けと初期データは 1 回ずつ")
    func sendThenVerify() async {
        let service = FakeAuthService()
        service.verifyResult = .success(S.userB)
        service.currentEmail = "new@example.com"
        let clock = S.Clock()
        let ensure = CallCounter()
        let hooks = SideEffectLog()
        let store = S.makeStore(service, clock: clock, ensureCount: ensure, hooks: hooks)
        store.apply(.initialSession(nil))
        hooks.events = []

        #expect(await store.sendCode(email: " new@example.com ") == nil)
        #expect(service.calls == ["send:new@example.com"])
        #expect(store.phase == .awaitingCode(email: "new@example.com"))
        #expect(store.resendRemainingSeconds(at: clock.now) == 60)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(ensure.value == 0, "コードを確かめるまでは初期データを作らない")
        #expect(hooks.events.isEmpty)

        #expect(await store.verifyCode(" 123-456 ") == nil)
        #expect(service.calls == ["send:new@example.com", "verify:new@example.com:123456"])
        #expect(store.phase == .signedIn(userID: S.userB))
        #expect(store.resendRemainingSeconds(at: clock.now) == 0)
        #expect(store.lastEmail == "")
        #expect(store.signedInEmail == "new@example.com")
        await S.waitUntil { ensure.value == 1 }
        #expect(ensure.value == 1)
        #expect(hooks.events == ["onSignedIn"])
    }

    @Test("誤り・期限切れのコード (otp_expired) は「コードが違うか…」、送りすぎは「しばらく待って…」、通信は通信の文言。どれもコードの入力のまま")
    func wrongCode() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))
        await S.sendCode(store)

        service.verifyResult = .failure(AuthFailure.from(S.apiError(.otpExpired, status: 403), during: .verifyCode))
        #expect(await store.verifyCode("000000") == "コードが違うか、期限が切れています。新しいコードを送ってください")
        #expect(store.phase == .awaitingCode(email: "a@example.com"))
        // supabase-swift のエラーのままでも同じ (AuthStore の側でも変える)
        service.verifyResult = .failure(S.apiError(.otpExpired, status: 403))
        #expect(await store.verifyCode("000000") == AuthFailure.codeInvalid.message)

        service.verifyResult = .failure(AuthFailure.from(S.apiError(.overRequestRateLimit, status: 429), during: .verifyCode))
        #expect(await store.verifyCode("000000") == "しばらく待ってから、もう一度お試しください")
        service.verifyResult = .failure(URLError(.notConnectedToInternet))
        #expect(await store.verifyCode("000000") == AuthFailure.network.message)
        #expect(store.phase == .awaitingCode(email: "a@example.com"))

        service.verifyResult = .success(S.userA)
        #expect(await store.verifyCode("123456") == nil)
        #expect(store.phase == .signedIn(userID: S.userA))
    }

    @Test("送り直しは 60 秒待ち。同じメールアドレスにもう一度送り、待ちが始まり直す。断られたら文言で、待ちは始まらない")
    func resendCountdown() async {
        let service = FakeAuthService()
        let clock = S.Clock()
        let store = S.makeStore(service, clock: clock)
        store.apply(.initialSession(nil))
        await S.sendCode(store)
        #expect(store.resendRemainingSeconds(at: clock.now) == 60)
        #expect(store.resendRemainingSeconds(at: clock.now.addingTimeInterval(30.2)) == 30)

        // 待ちの間は送らない
        clock.now = S.start.addingTimeInterval(59)
        #expect(await store.resendCode() == nil)
        #expect(service.calls == ["send:a@example.com"])

        clock.now = S.start.addingTimeInterval(60)
        #expect(store.resendRemainingSeconds(at: clock.now) == 0)
        #expect(await store.resendCode() == nil)
        #expect(service.calls == ["send:a@example.com", "send:a@example.com"])
        #expect(store.resendRemainingSeconds(at: clock.now) == 60)
        #expect(store.phase == .awaitingCode(email: "a@example.com"))

        // 送りすぎ・通信の失敗は文言。待ちは始まらず、コードの入力のまま
        clock.now = S.start.addingTimeInterval(200)
        service.sendError = S.apiError(.overEmailSendRateLimit, status: 429)
        #expect(await store.resendCode() == AuthFailure.rateLimited.message)
        #expect(store.resendRemainingSeconds(at: clock.now) == 0)
        service.sendError = URLError(.notConnectedToInternet)
        #expect(await store.resendCode() == AuthFailure.network.message)
        #expect(store.resendRemainingSeconds(at: clock.now) == 0)
        #expect(store.phase == .awaitingCode(email: "a@example.com"))

        service.sendError = nil
        #expect(await store.resendCode() == nil)
        #expect(store.resendRemainingSeconds(at: clock.now) == 60)
    }

    @Test("コードの確かめの中で .signedIn が先に届いても、確かめの側が戻ってからサインイン済みにする (片付けと初期データは 1 回ずつ)")
    func signedInEventDuringVerify() async {
        let service = FakeAuthService()
        let ensure = CallCounter()
        let hooks = SideEffectLog()
        let store = S.makeStore(service, ensureCount: ensure, hooks: hooks)
        service.observedStore = store
        store.start()
        service.continuation.yield(.initialSession(nil))
        await S.waitUntil { store.phase == .signedOut }
        hooks.events = []
        await S.sendCode(store)

        // supabase-swift と同じく、verifyOTP の中で .signedIn が先に届く (AuthStore が反映してから返る)
        service.emitBeforeSessionReturns = .signedIn(S.userA)
        service.verifyResult = .success(S.userA)
        let appliedBefore = store.appliedChanges
        #expect(await store.verifyCode("123456") == nil)
        #expect(store.appliedChanges == appliedBefore + 1)
        #expect(service.phaseAfterEmit == .awaitingCode(email: "a@example.com"), "届いた .signedIn では画面を変えない")
        #expect(store.phase == .signedIn(userID: S.userA))
        await S.waitUntil { ensure.value == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(ensure.value == 1)
        #expect(hooks.events == ["onSignedIn"])

        // 遅れて届いた同じ人の .signedIn でも呼び直さない
        store.apply(.signedIn(S.userA))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(hooks.events == ["onSignedIn"])
        #expect(ensure.value == 1)
    }

    @Test("新規登録を閉じている (signup_disabled・otp_disabled) と「今はサインアップを受け付けていません」。メールのサインインを閉じているときは別の文言。どれもサインインの画面のまま")
    func signupDisabled() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))

        service.sendError = AuthFailure.from(S.apiError(.signupDisabled, status: 422), during: .sendCode)
        #expect(await store.sendCode(email: "new@example.com") == "今はサインアップを受け付けていません")
        #expect(store.phase == .signedOut)
        #expect(store.resendRemainingSeconds(at: S.start) == 0)

        // supabase-swift のエラーのままでも同じ
        service.sendError = S.apiError(.signupDisabled, status: 422)
        #expect(await store.sendCode(email: "new@example.com") == "今はサインアップを受け付けていません")
        service.sendError = S.apiError(.otpDisabled, status: 422)
        #expect(await store.sendCode(email: "new@example.com") == "今はサインアップを受け付けていません")

        service.sendError = S.apiError(.emailProviderDisabled, status: 422)
        #expect(await store.sendCode(email: "new@example.com") == "今はメールのコードでサインインできません")
        #expect(store.phase == .signedOut)
        #expect(service.calls.count == 4)
    }

    @Test("標準のメール送信で送れないアドレス (email_address_not_authorized) は「このメールアドレスには、今はコードを送れません」。サインインの画面のまま")
    func emailAddressNotAuthorized() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))

        service.sendError = S.apiError(.emailAddressNotAuthorized, status: 400)
        #expect(await store.sendCode(email: "someone@example.com") == "このメールアドレスには、今はコードを送れません")
        #expect(store.phase == .signedOut)
        #expect(store.lastEmail == "someone@example.com", "欄のメールアドレスは残す")
        #expect(AuthFailure.from(S.apiError(.emailAddressNotAuthorized), during: .sendCode) == .emailAddressNotAuthorized)
    }

    @Test("送る前の確かめで断られたアドレス (email_address_invalid・ドメインが無いなど) は「メールアドレスが正しくありません。…」。サインインの画面のまま (2026-10-22 本番で「うまくいきませんでした」が出た)")
    func emailAddressInvalid() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))

        service.sendError = S.apiError(AuthFailure.emailAddressInvalidCode, status: 400)
        #expect(await store.sendCode(email: "aaa@aaaa.jj") == "メールアドレスが正しくありません。確かめて、もう一度入力してください")
        #expect(store.phase == .signedOut)
        #expect(store.lastEmail == "aaa@aaaa.jj", "欄のメールアドレスは残す")
    }

    @Test("送るとき: 通信できない・送りすぎは文言でサインインの画面のまま。メールアドレスの形が違えば送らない")
    func sendFailures() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))

        service.sendError = URLError(.notConnectedToInternet)
        #expect(await store.sendCode(email: "a@example.com") == AuthFailure.network.message)
        service.sendError = URLError(.timedOut)
        #expect(await store.sendCode(email: "a@example.com") == AuthFailure.network.message)
        service.sendError = S.apiError(.overEmailSendRateLimit, status: 429)
        #expect(await store.sendCode(email: "a@example.com") == AuthFailure.rateLimited.message)
        #expect(store.phase == .signedOut)
        #expect(service.calls.count == 3)

        service.sendError = nil
        for email in ["", "  ", "no-at-mark", "a@", "@example.com", "a b@example.com"] {
            #expect(await store.sendCode(email: email) == "メールアドレスを入れてください", "\(email)")
        }
        #expect(service.calls.count == 3)
        #expect(store.phase == .signedOut)
    }

    @Test("「変更」: コードの入力からサインインの画面へ (サーバーは呼ばない・待ちは消える)。別のメールアドレスで送り直せる")
    func backToSignIn() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))
        await S.sendCode(store)
        store.backToSignIn()
        #expect(store.phase == .signedOut)
        #expect(store.resendRemainingSeconds(at: S.start) == 0)
        #expect(service.calls == ["send:a@example.com"])

        await S.sendCode(store, to: "b@example.com")
        #expect(service.calls == ["send:a@example.com", "send:b@example.com"])
        // 未サインイン・サインイン済みでは何もしない
        let signedIn = S.makeStore(service)
        signedIn.apply(.initialSession(S.userA))
        signedIn.backToSignIn()
        #expect(signedIn.phase == .signedIn(userID: S.userA))
    }

    @Test("コードの入力の画面は、遅れて届いた .signedOut で動かさない (片付けもしない)")
    func ignoresSignedOut() async {
        let hooks = SideEffectLog()
        let store = S.makeStore(FakeAuthService(), hooks: hooks)
        store.apply(.initialSession(nil))
        await S.sendCode(store)
        hooks.events = []
        store.apply(.signedOut)
        #expect(store.phase == .awaitingCode(email: "a@example.com"))
        #expect(hooks.events.isEmpty)
    }

    @Test("6 桁の数字でなければ送らない (空・5 桁・7 桁・英字・全角の数字)。コードの入力のほかでは確かめ・送り直しは何もしない")
    func incompleteCodeNotSent() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))
        await S.sendCode(store)
        for code in ["", "12345", "1234567", "12a456", "１２３４５６", "123 45"] {
            #expect(await store.verifyCode(code) == "メールに届いた 6 桁のコードを入れてください", "\(code)")
        }
        #expect(service.calls.filter { $0.hasPrefix("verify") }.isEmpty)
        #expect(store.phase == .awaitingCode(email: "a@example.com"))

        let other = FakeAuthService()
        let signedOut = S.makeStore(other)
        signedOut.apply(.initialSession(nil))
        #expect(await signedOut.verifyCode("123456") == nil)
        #expect(await signedOut.resendCode() == nil)
        #expect(other.calls.isEmpty)
        #expect(signedOut.phase == .signedOut)
    }

    @Test("コードの入力中に古いメールのリンク (PKCE の code) を開いたら、サインイン済みへ (リンクの中で .signedIn が先に届いても 1 回ずつ)")
    func oldLinkDuringCode() async {
        let service = FakeAuthService()
        service.sessionResult = .success(S.userA)
        let hooks = SideEffectLog()
        let store = S.makeStore(service, hooks: hooks)
        service.observedStore = store
        store.start()
        service.continuation.yield(.initialSession(nil))
        await S.waitUntil { store.phase == .signedOut }
        hooks.events = []

        await S.sendCode(store)
        service.emitBeforeSessionReturns = .signedIn(S.userA)
        await store.handle(url: S.callbackURL)
        #expect(store.phase == .signedIn(userID: S.userA))
        #expect(store.linkFailureMessage == nil)
        #expect(store.resendRemainingSeconds(at: S.start) == 0)
        #expect(hooks.events == ["onSignedIn"])
        #expect(service.calls == ["send:a@example.com", "session"])
    }
}

// MARK: - リンクの失敗の文言 (P19)

@MainActor
@Suite("AuthStore — リンクの失敗の文言 (別の端末で開いた／使い切り・期限切れ・無効)")
struct AuthStoreLinkFailureTests {
    typealias S = AuthTestSupport

    static let otherDevice = "このメールは、「コードを送る」を押したこの iPhone で開いてください"
    static let invalid = "リンクが無効です。いちばん新しいメールのリンクを開くか、もう一度送ってください"

    func message(for error: Error) async -> String? {
        let service = FakeAuthService()
        service.sessionResult = .failure(error)
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))
        await store.handle(url: S.callbackURL)
        #expect(store.phase == .signedOut)
        return store.linkFailureMessage
    }

    @Test("verifier が無い (GoTrue が validation_failed) → この iPhone で開いて")
    func missingVerifier() async {
        #expect(await message(for: S.apiError(.validationFailed)) == Self.otherDevice)
    }

    @Test("使い切り・期限切れ・verifier の食い違い・URL の error・code が無い → リンクが無効")
    func invalidLinks() async {
        #expect(await message(for: S.apiError(.flowStateNotFound, status: 404)) == Self.invalid)
        #expect(await message(for: S.apiError(.flowStateExpired, status: 422)) == Self.invalid)
        #expect(await message(for: S.apiError(.badCodeVerifier)) == Self.invalid)
        #expect(await message(for: AuthError.pkceGrantCodeExchange(message: "Email link is invalid or has expired",
                                                                     error: "access_denied", code: "otp_expired")) == Self.invalid)
        #expect(await message(for: AuthError.pkceGrantCodeExchange(message: "No code detected.")) == Self.invalid)
        #expect(await message(for: AuthError.sessionMissing) == Self.invalid)
    }

    @Test("通信の失敗はリンクの無効にしない")
    func networkIsNotInvalid() async {
        #expect(await message(for: URLError(.notConnectedToInternet)) == AuthFailure.network.message)
    }

    @Test("Supabase の層で変えた後の値も同じ文言 (AuthFailure はそのまま通る)")
    func mappedFailurePassesThrough() async {
        let mapped = AuthFailure.from(S.apiError(.validationFailed), during: .link)
        #expect(mapped == .linkOpenedOnAnotherDevice)
        #expect(await message(for: mapped) == Self.otherDevice)
        // リンクのほかでは validation_failed は「verifier が無い」ではない
        #expect(AuthFailure.from(S.apiError(.validationFailed), during: .sendCode) != .linkOpenedOnAnotherDevice)
    }
}

// MARK: - Google

@MainActor
@Suite("Google — nonce (SHA-256 の小文字の 16 進) と設定の有無")
struct GoogleSignInTests {
    typealias S = AuthTestSupport

    @Test("Google に渡す値は、元の値の UTF-8 の SHA-256 の小文字の 16 進")
    func hashedNonce() {
        // FIPS 180-2 の例
        #expect(GoogleNonce.hashed("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let raw = GoogleNonce.makeRaw()
        let hashed = GoogleNonce.hashed(raw)
        #expect(hashed.count == 64)
        #expect(hashed == hashed.lowercased())
        #expect(hashed.allSatisfy { $0.isHexDigit })
        #expect(hashed != raw)
    }

    @Test("元の値は 32 バイトの乱数の 16 進 (毎回変わる)")
    func rawNonce() {
        let first = GoogleNonce.makeRaw()
        let second = GoogleNonce.makeRaw()
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(first != second)
    }

    @Test("Supabase には元の値を渡す")
    func passesRawNonceToSupabase() async {
        let service = FakeAuthService()
        service.googleResult = .success(S.userA)
        let token = GoogleIDToken(idToken: "id-token", accessToken: "access-token", rawNonce: "raw-nonce")
        let store = S.makeStore(service, google: { token })
        store.apply(.initialSession(nil))
        #expect(await store.signInWithGoogle() == nil)
        #expect(service.googleArguments?.idToken == "id-token")
        #expect(service.googleArguments?.accessToken == "access-token")
        #expect(service.googleArguments?.rawNonce == "raw-nonce")
        #expect(store.phase == .signedIn(userID: S.userA))
    }

    @Test("設定がまだなら「Google の設定がまだです」。やめたときは何も出さない")
    func notConfiguredAndCancelled() async {
        let service = FakeAuthService()
        let store = S.makeStore(service, google: { throw AuthFailure.googleNotConfigured })
        store.apply(.initialSession(nil))
        #expect(await store.signInWithGoogle() == "Google の設定がまだです")
        let cancelled = S.makeStore(service, google: { throw AuthFailure.cancelled })
        cancelled.apply(.initialSession(nil))
        #expect(await cancelled.signInWithGoogle() == nil)
        #expect(cancelled.phase == .signedOut)
        #expect(!service.calls.contains("google"))
    }

    @Test("クライアント ID が unset・空・展開されていない値なら、設定がまだ")
    func configured() {
        #expect(!GoogleSignInConfig.isConfigured(clientID: "unset", reversedClientID: "com.googleusercontent.apps.unset"))
        #expect(!GoogleSignInConfig.isConfigured(clientID: "", reversedClientID: ""))
        #expect(!GoogleSignInConfig.isConfigured(clientID: nil, reversedClientID: nil))
        #expect(!GoogleSignInConfig.isConfigured(clientID: "$(GOOGLE_IOS_CLIENT_ID)", reversedClientID: "com.googleusercontent.apps.x"))
        #expect(!GoogleSignInConfig.isConfigured(clientID: "1-x.apps.googleusercontent.com", reversedClientID: "com.googleusercontent.apps.unset"))
        #expect(GoogleSignInConfig.isConfigured(clientID: "1-x.apps.googleusercontent.com", reversedClientID: "com.googleusercontent.apps.1-x"))

        let info: [String: Any] = [
            "GIDClientID": "1-x.apps.googleusercontent.com",
            "CFBundleURLTypes": [
                ["CFBundleURLSchemes": ["lifetracker"]],
                ["CFBundleURLSchemes": ["com.googleusercontent.apps.1-x"]],
            ],
        ]
        #expect(GoogleSignInConfig.isConfigured(info: info))
        #expect(!GoogleSignInConfig.isConfigured(info: ["GIDClientID": "1-x.apps.googleusercontent.com"]))
    }
}

// MARK: - 起動の組み立て

@MainActor
@Suite("LaunchPlan — テストの環境では SupabaseClient を作らない・起動引数")
struct LaunchPlanTests {
    @Test("テストの環境 (XCTestConfigurationFilePath) ならメモリ上のデータとサインイン済みの MockAuthService")
    func testEnvironment() {
        let plan = LaunchPlan.make(arguments: [], environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
                                   isDebug: true)
        #expect(plan == LaunchPlan(auth: .mockSignedIn, memoryDay: true, memoryWorkout: true))
    }

    @Test("このテストを動かしているプロセス (TEST_HOST のアプリ) でも、クライアントを作らない側 (メモリ上の認証とデータ) になっている")
    func currentProcessIsTestEnvironment() {
        #expect(ProcessInfo.processInfo.environment[LaunchPlan.testEnvironmentKey] != nil)
        #expect(LaunchPlan.current == LaunchPlan(auth: .mockSignedIn, memoryDay: true, memoryWorkout: true))
    }

    @Test("メモリ上の認証とデータの組 (テストの環境・-mock-auth・-mock-auth-signed-out) は、組み立てても SupabaseClient を作らず、端末の側の片付けもしない")
    func makeSetupWithoutClient() async {
        struct ClientNotAllowed: Error {}
        let plans = [LaunchPlan.current,
                     LaunchPlan(auth: .mockSignedIn, memoryDay: true, memoryWorkout: true),
                     LaunchPlan(auth: .mockSignedOut, memoryDay: true, memoryWorkout: true)]
        for plan in plans {
            // 渡した片付けが呼ばれたら落ちる (メモリ上の認証では何もしない片付けに替える)
            let tripwire = SignInSideEffects(defaults: nil,
                                             reloadWidgets: { Issue.record("ウィジェットを作り直した: \(plan)") },
                                             stopRestAlerts: { Issue.record("休憩の通知を止めた: \(plan)") },
                                             signOutGoogle: { Issue.record("Google の資格情報を消した: \(plan)") })
            let result = LifeTrackerApp.makeSetup(plan: plan, makeClient: {
                Issue.record("SupabaseClient を作ろうとした: \(plan)")
                throw ClientNotAllowed()
            }, sideEffects: tripwire)
            guard case .success(let setup) = result else {
                Issue.record("組み立てが失敗した: \(plan)")
                continue
            }
            let auth = setup.auth
            await AuthTestSupport.waitUntil { auth.phase != .launching }
            let expected: AuthStore.Phase = plan.auth == .mockSignedIn ? .signedIn(userID: MockAuthService.userID) : .signedOut
            #expect(auth.phase == expected)
            // サインイン・サインアウトを通しても片付けを呼ばない
            if plan.auth == .mockSignedOut {
                #expect(await auth.sendCode(email: MockAuthService.email) == nil)
                #expect(await auth.verifyCode(MockAuthService.code) == nil)
                #expect(auth.phase == .signedIn(userID: MockAuthService.userID))
            }
            await auth.signOut()
            #expect(auth.phase == .signedOut)
        }
    }

    @Test("起動引数: -mock-auth・-mock-auth-signed-out・-mock-day・-mock-workout")
    func arguments() {
        let all = LaunchPlan.make(arguments: ["-mock-day", "-mock-workout", "-mock-auth"], environment: [:], isDebug: true)
        #expect(all == LaunchPlan(auth: .mockSignedIn, memoryDay: true, memoryWorkout: true))

        let signedOut = LaunchPlan.make(arguments: ["-mock-day", "-mock-workout", "-mock-auth-signed-out"], environment: [:],
                                        isDebug: true)
        #expect(signedOut == LaunchPlan(auth: .mockSignedOut, memoryDay: true, memoryWorkout: true))

        // -mock-auth を付けなければ本物の認証＋メモリ上のデータ (クライアントは認証のためだけに作る)
        let realAuth = LaunchPlan.make(arguments: ["-mock-day", "-mock-workout"], environment: [:], isDebug: true)
        #expect(realAuth == LaunchPlan(auth: .supabase, memoryDay: true, memoryWorkout: true))

        let plain = LaunchPlan.make(arguments: [], environment: [:], isDebug: true)
        #expect(plain == LaunchPlan(auth: .supabase, memoryDay: false, memoryWorkout: false))
    }

    @Test("Release は起動引数とテストの環境を見ない")
    func release() {
        let plan = LaunchPlan.make(arguments: ["-mock-day", "-mock-workout", "-mock-auth"],
                                   environment: ["XCTestConfigurationFilePath": "/tmp/x"], isDebug: false)
        #expect(plan == LaunchPlan(auth: .supabase, memoryDay: false, memoryWorkout: false))
    }
}

// MARK: - 小さな規則

@MainActor
@Suite("認証の小さな規則 (メールアドレス・コード・失敗の分け方・戻り先の URL・メモリ上の認証)")
struct AuthRulesTests {
    @Test("最後に入れたメールアドレス: コードの画面から戻ったとき・送れなかったときに残る。サインイン済みになったら消す (メモリの中だけ)")
    func lastEmailKeptUntilSignedIn() async {
        let service = FakeAuthService()
        let store = AuthStore(service: service, ensureUserDefaults: {})
        store.apply(.initialSession(nil))
        #expect(store.lastEmail == "")

        // コードの入力から「変更」
        #expect(await store.sendCode(email: " a@example.com ") == nil)
        store.backToSignIn()
        #expect(store.phase == .signedOut)
        #expect(store.lastEmail == "a@example.com")

        // 形の違うメールアドレスは覚えない (送っていない)
        _ = await store.sendCode(email: "no-at-mark")
        #expect(store.lastEmail == "a@example.com")

        // 断られても覚える (サインインの画面の欄のまま)
        service.sendError = AuthFailure.signupDisabled
        _ = await store.sendCode(email: "b@example.com")
        #expect(store.lastEmail == "b@example.com")

        // サインイン済みになったら消す (サインアウトの後のサインインの画面は空)
        service.sendError = nil
        service.verifyResult = .success(AuthTestSupport.userA)
        _ = await store.sendCode(email: "c@example.com")
        #expect(store.lastEmail == "c@example.com")
        _ = await store.verifyCode("123456")
        #expect(store.lastEmail == "")
        await store.signOut()
        #expect(store.lastEmail == "")
    }

    @Test("サインイン中のメールアドレス (プロフィールのタブ): サインイン済みに入ると認証の層から読み、人が変われば入れ替え、.updated で読み直し、未サインインで消す")
    func signedInEmailFollowsSession() async {
        typealias S = AuthTestSupport
        let service = FakeAuthService()
        service.currentEmail = "a@example.com"
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))
        #expect(store.signedInEmail == nil, "未サインインでは持たない")

        service.verifyResult = .success(S.userA)
        await S.sendCode(store)
        #expect(store.signedInEmail == nil, "コードの入力ではまだ持たない")
        #expect(await store.verifyCode("123456") == nil)
        #expect(store.signedInEmail == "a@example.com")

        // ユーザーの更新 (メールアドレスが変わった) → 読み直す。画面の状態は変えない
        service.currentEmail = "a2@example.com"
        store.apply(.updated)
        #expect(store.signedInEmail == "a2@example.com")
        #expect(store.phase == .signedIn(userID: S.userA))

        // サインアウトを経ずに別の人へ
        service.currentEmail = "b@example.com"
        store.apply(.signedIn(S.userB))
        #expect(store.signedInEmail == "b@example.com")

        // サインアウトで消す。遅れて届いた .updated では戻さない
        await store.signOut()
        #expect(store.signedInEmail == nil)
        store.apply(.updated)
        #expect(store.signedInEmail == nil)

        // 起動したとき端末にセッションがある (期限切れでも) → そのセッションのメールアドレス
        let launched = S.makeStore(service)
        launched.apply(.initialSession(S.userB))
        #expect(launched.signedInEmail == "b@example.com")
    }

    @Test("サインイン中のメールアドレス: Google でサインインした人もセッションの user の email。取れない・空白だけなら nil (行を出さない)。前後の空白は取る")
    func signedInEmailForGoogleAndMissing() async {
        typealias S = AuthTestSupport
        let service = FakeAuthService()
        service.googleResult = .success(S.userA)
        service.currentEmail = "google-user@example.com"
        let token = GoogleIDToken(idToken: "id-token", accessToken: "access-token", rawNonce: "raw-nonce")
        let store = S.makeStore(service, google: { token })
        store.apply(.initialSession(nil))
        #expect(await store.signInWithGoogle() == nil)
        #expect(store.signedInEmail == "google-user@example.com")

        service.currentEmail = nil
        store.apply(.updated)
        #expect(store.signedInEmail == nil)
        service.currentEmail = " \n"
        store.apply(.updated)
        #expect(store.signedInEmail == nil)
        service.currentEmail = " a@example.com\n"
        store.apply(.updated)
        #expect(store.signedInEmail == "a@example.com")
        #expect(store.phase == .signedIn(userID: S.userA))

        #expect(AuthStore.displayEmail(nil) == nil)
        #expect(AuthStore.displayEmail("") == nil)
        #expect(AuthStore.displayEmail("\u{3000}") == nil, "全角の空白だけ")
        #expect(AuthStore.displayEmail("b@example.com") == "b@example.com")
    }

    @Test("メモリ上の認証のメールアドレス: コードでサインインした人はそのアドレス、Google と起動時のサインイン済みは test@example.com、サインアウトで nil")
    func mockAuthServiceEmail() async throws {
        let service = MockAuthService(signedIn: false)
        #expect(service.currentEmail == nil)
        try await service.sendEmailCode(email: "new@example.com")
        _ = try await service.verifyEmailCode(email: "new@example.com", code: MockAuthService.code)
        #expect(service.currentEmail == "new@example.com")
        try await service.signOut()
        #expect(service.currentEmail == nil)
        _ = try await service.signInWithGoogle(idToken: "x", accessToken: "y", rawNonce: "z")
        #expect(service.currentEmail == MockAuthService.email)

        guard case .success(let setup) = LifeTrackerApp.makeSetup(plan: LaunchPlan(auth: .mockSignedIn, memoryDay: true, memoryWorkout: true),
                                                                  makeClient: { throw AuthFailure.unknown("no client") },
                                                                  sideEffects: .disabled) else {
            Issue.record("組み立てが失敗した")
            return
        }
        let auth = setup.auth
        await AuthTestSupport.waitUntil { auth.phase != .launching }
        #expect(auth.signedInEmail == MockAuthService.email)
        await auth.signOut()
        #expect(auth.signedInEmail == nil)
    }

    @Test("メモリ上の認証: どのメールアドレスにもコードを送れ、123456 でサインイン済み。ほかのコードは codeInvalid")
    func mockAuthService() async throws {
        #expect(MockAuthService.code == "123456")
        #expect(MockAuthService.email == "test@example.com")
        let service = MockAuthService(signedIn: false)
        await #expect(throws: AuthFailure.codeInvalid) {
            _ = try await service.verifyEmailCode(email: "new@example.com", code: "000000")
        }
        #expect(try await service.verifyEmailCode(email: "new@example.com", code: "123456") == MockAuthService.userID)

        // UI テストと同じ道: 送る → 誤りのコード → 正しいコード → サインイン済み → サインアウト
        let store = AuthStore(service: MockAuthService(signedIn: false), ensureUserDefaults: {})
        store.start()
        await AuthTestSupport.waitUntil { store.phase != .launching }
        #expect(store.phase == .signedOut)
        for email in [MockAuthService.email, "someone@example.com"] {
            #expect(await store.sendCode(email: email) == nil)
            #expect(store.phase == .awaitingCode(email: email))
            #expect(await store.verifyCode("000000") == AuthFailure.codeInvalid.message)
            #expect(await store.verifyCode(MockAuthService.code) == nil)
            #expect(store.phase == .signedIn(userID: MockAuthService.userID))
            #expect(store.signedInEmail == email)
            await store.signOut()
            #expect(store.phase == .signedOut)
        }
    }

    @Test("画面の言い方はサインイン・サインアップ・サインアウトに揃える (2026-10-22 本人の決定。見出し・失敗の文言)")
    func signInWording() {
        #expect(SignInView.headline == "サインイン・サインアップ")
        #expect(EmailCodeView.headline == "入力したメールアドレスに届いた認証コードを入力してください")
        #expect(AuthFailure.signupDisabled.message == "今はサインアップを受け付けていません")
        let messages = [AuthFailure.signupDisabled, .emailSignInDisabled, .emailAddressNotAuthorized, .emailAddressInvalid, .linkOpenedOnAnotherDevice,
                        .linkInvalid, .codeInvalid, .sessionMissing, .rateLimited, .network, .googleNotConfigured, .unknown("x")]
            .compactMap(\.message) + [SignInView.headline, EmailCodeView.headline, AuthStore.emailConfirmedNotice, EmailCodeInput.guidance]
        for message in messages {
            for word in ["ログイン", "ログアウト", "新規登録", "登録"] {
                #expect(!message.contains(word), "\(message)")
            }
        }
    }

    @Test("Google のボタン: 公式の G の画像が GoogleSignIn-iOS の resource bundle から読める (18pt)。文言は「Google」だけにしない")
    func googleLogoFromPackage() throws {
        let logo = try #require(GoogleLogo.image)
        #expect(logo.size == CGSize(width: 18, height: 18))
        #expect(GoogleLogo.buttonTitle == "Google で続ける")
        #expect(GoogleLogo.buttonTitle != "Google")
    }

    @Test("起動時の片付け: もう使わない再設定の印 auth.passwordResetRequestedAt.v1 を消す。ほかのキーには触れない。無くても落ちない")
    func obsoleteKeysRemoved() {
        let defaults = AuthTestSupport.defaults()
        defaults.set(Date(), forKey: "auth.passwordResetRequestedAt.v1")
        defaults.set(true, forKey: "other.key")
        ObsoleteAuthKeys.remove(from: defaults)
        #expect(defaults.object(forKey: "auth.passwordResetRequestedAt.v1") == nil)
        #expect(defaults.bool(forKey: "other.key"))
        ObsoleteAuthKeys.remove(from: defaults)
        #expect(ObsoleteAuthKeys.keys == ["auth.passwordResetRequestedAt.v1"])
    }

    @Test("lifetracker://auth-callback だけ AuthStore に渡す")
    func callbackURL() {
        #expect(AuthCallback.matches(URL(string: "lifetracker://auth-callback?code=abc")!))
        #expect(AuthCallback.matches(URL(string: "lifetracker://auth-callback#error=access_denied")!))
        #expect(!AuthCallback.matches(URL(string: "lifetracker://other")!))
        #expect(!AuthCallback.matches(URL(string: "com.googleusercontent.apps.1-x:/oauth2redirect")!))
        #expect(AuthCallback.url.absoluteString == "lifetracker://auth-callback")
    }

    @Test("コードの種類は .email (新しい人の確認のコードと、登録済みの人の Magic Link のコードの両方で通る)")
    func emailCodeType() {
        #expect(SupabaseAuthService.emailCodeType == .email)
    }

    @Test("コードの入力: 空白 (全角・改行も)・ハイフン (似た字も) を取り除く。ほかの字は残す。6 桁の ASCII の数字だけが揃い")
    func emailCodeInput() {
        #expect(EmailCodeInput.normalized("123456") == "123456")
        #expect(EmailCodeInput.normalized(" 123 456 ") == "123456")
        #expect(EmailCodeInput.normalized("123-456") == "123456")
        #expect(EmailCodeInput.normalized("123\u{3000}456\n") == "123456")
        #expect(EmailCodeInput.normalized("12\u{2010}34\u{FF0D}56") == "123456")
        #expect(EmailCodeInput.normalized("12a456") == "12a456")
        #expect(EmailCodeInput.isComplete("123456"))
        #expect(EmailCodeInput.isComplete("000000"))
        #expect(!EmailCodeInput.isComplete(""))
        #expect(!EmailCodeInput.isComplete("12345"))
        #expect(!EmailCodeInput.isComplete("1234567"))
        #expect(!EmailCodeInput.isComplete("12a456"))
        #expect(!EmailCodeInput.isComplete("１２３４５６"))
        #expect(!EmailCodeInput.isComplete("123 456"), "整える前の値は揃いとみなさない")
        #expect(EmailCodeInput.guidance == "メールに届いた 6 桁のコードを入れてください")
    }

    @Test("メールアドレスの検査: a@b の形だけ (空白を含まない)")
    func emailInput() {
        #expect(EmailInput.normalized("  a@example.com\n") == "a@example.com")
        #expect(EmailInput.looksValid("a@example.com"))
        #expect(!EmailInput.looksValid(""))
        #expect(!EmailInput.looksValid("a@"))
        #expect(!EmailInput.looksValid("@example.com"))
        #expect(!EmailInput.looksValid("a@b@example.com"))
        #expect(!EmailInput.looksValid("a b@example.com"))
    }

    @Test("失敗の分け方: 送る (signup_disabled・otp_disabled・email_provider_disabled・email_address_not_authorized・email_address_invalid・送りすぎ) とコード (otp_expired・送りすぎ)。通信 → network、ほか → unknown")
    func failureMapping() {
        typealias S = AuthTestSupport
        // コードを送る
        #expect(AuthFailure.from(S.apiError(.signupDisabled, status: 422), during: .sendCode) == .signupDisabled)
        #expect(AuthFailure.from(S.apiError(.otpDisabled, status: 422), during: .sendCode) == .signupDisabled)
        #expect(AuthFailure.from(S.apiError(.emailProviderDisabled, status: 422), during: .sendCode) == .emailSignInDisabled)
        #expect(AuthFailure.from(S.apiError(.emailAddressNotAuthorized), during: .sendCode) == .emailAddressNotAuthorized)
        #expect(AuthFailure.from(S.apiError(AuthFailure.emailAddressInvalidCode, status: 400), during: .sendCode) == .emailAddressInvalid)
        #expect(AuthFailure.from(S.apiError(.overEmailSendRateLimit, status: 429), during: .sendCode) == .rateLimited)
        #expect(AuthFailure.from(URLError(.notConnectedToInternet), during: .sendCode) == .network)
        #expect(AuthFailure.signupDisabled.message == "今はサインアップを受け付けていません")
        #expect(AuthFailure.emailAddressNotAuthorized.message == "このメールアドレスには、今はコードを送れません")
        #expect(AuthFailure.emailAddressInvalid.message == "メールアドレスが正しくありません。確かめて、もう一度入力してください")
        #expect(AuthFailure.emailSignInDisabled.message == "今はメールのコードでサインインできません")

        // コードを確かめる
        #expect(AuthFailure.from(S.apiError(.otpExpired, status: 403), during: .verifyCode) == .codeInvalid)
        #expect(AuthFailure.codeInvalid.message == "コードが違うか、期限が切れています。新しいコードを送ってください")
        #expect(AuthFailure.from(S.apiError(.overRequestRateLimit, status: 429), during: .verifyCode) == .rateLimited)
        #expect(AuthFailure.from(S.apiError(.overEmailSendRateLimit, status: 429), during: .verifyCode) == .rateLimited)
        #expect(AuthFailure.from(URLError(.notConnectedToInternet), during: .verifyCode) == .network)
        #expect(AuthFailure.from(S.apiError(.validationFailed), during: .verifyCode) == .unknown("validation_failed: server message"))
        // Supabase の層・メモリ上の認証で変えた後の値はそのまま通る
        #expect(AuthFailure.from(AuthFailure.codeInvalid, during: .verifyCode) == .codeInvalid)
        // 古いリンクの otp_expired (URL の error_code) はこれまでどおりリンクの無効
        #expect(AuthFailure.from(S.apiError(.otpExpired, status: 403), during: .link) == .linkInvalid)
    }
}
