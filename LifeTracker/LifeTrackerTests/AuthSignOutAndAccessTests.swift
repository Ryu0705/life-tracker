import Foundation
import Supabase
import Testing
@testable import LifeTracker

// サインインと複数人化の後半 (docs/auth-multiuser-implementation-plan.md §2-5・§2-6・§2-7):
// サインアウトの片付けとウィジェットの印・42501／PGRST3xx の文言 (P9)・タップの投げ分け・upsert の衝突先・implicit 形式の戻り

/// テスト用の端末のセッション。更新は release() まで止められる (走っている間に新しく始めないことを見る)
@MainActor
final class FakeSessionAccess: SessionAccess {
    var hasStoredSession: Bool
    private(set) var refreshCount = 0
    /// true なら refreshSession は release() まで返らない
    var holdsRefresh = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(hasStoredSession: Bool) {
        self.hasStoredSession = hasStoredSession
    }

    func refreshSession() async throws {
        refreshCount += 1
        if holdsRefresh {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        holdsRefresh = false
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// サインインの片付けの記録 (操作の順と、そのときの UserDefaults の中身)
@MainActor
final class SideEffectLog {
    var events: [String] = []
}

@MainActor
enum SignOutSupport {
    static let snapshot = ContinuityShare.Snapshot(trainingDays: [Date(timeIntervalSince1970: 1_800_000_000)],
                                                   goals: [WeeklyGoal(weeklyTarget: 3, effectiveFrom: Date(timeIntervalSince1970: 1_799_900_000))])

    /// 差し込んだ UserDefaults の上の片付け。reload・stop の時点の中身を記録する
    static func effects(_ defaults: UserDefaults, log: SideEffectLog) -> SignInSideEffects {
        SignInSideEffects(
            defaults: defaults,
            reloadWidgets: {
                let snapshot = ContinuityShare.load(defaults: defaults) == nil ? "none" : "kept"
                log.events.append("reload(snapshot: \(snapshot), signedIn: \(ContinuityShare.isSignedIn(defaults: defaults)))")
            },
            stopRestAlerts: { log.events.append("stopRest") },
            signOutGoogle: { log.events.append("signOutGoogle") })
    }

    static func makeStore(_ service: FakeAuthService, effects: SignInSideEffects) -> AuthStore {
        AuthStore(service: service, now: { AuthTestSupport.start },
                  googleSignIn: { throw AuthFailure.googleNotConfigured },
                  ensureUserDefaults: {},
                  onSignedIn: { effects.signedIn() },
                  onSignedOut: { effects.signedOut() })
    }
}

// MARK: - サインアウトとウィジェット

@MainActor
@Suite("サインアウトの片付け — ウィジェットのスナップショットを消し、サインインの印を false に (計画 §2-6)")
struct SignOutCleanupTests {
    typealias S = AuthTestSupport
    typealias W = SignOutSupport

    @Test("サインアウトで continuity.v1 が消え、印が false になり、ウィジェットを作り直してから休憩の知らせを止め、最後に Google の資格情報を消す")
    func signOutClearsWidgetKeys() async {
        let defaults = S.defaults()
        let log = SideEffectLog()
        ContinuityShare.save(W.snapshot, defaults: defaults)
        ContinuityShare.setSignedIn(true, defaults: defaults)
        let service = FakeAuthService()
        let store = W.makeStore(service, effects: W.effects(defaults, log: log))
        store.apply(.initialSession(S.userA))
        #expect(log.events.isEmpty, "印が true のままなら作り直さない")

        await store.signOut()
        #expect(store.phase == .signedOut)
        #expect(defaults.object(forKey: ContinuityShare.snapshotKey) == nil)
        #expect(ContinuityShare.load(defaults: defaults) == nil)
        #expect(defaults.object(forKey: ContinuityShare.signedInKey) as? Bool == false)
        #expect(!ContinuityShare.isSignedIn(defaults: defaults))
        #expect(log.events == ["reload(snapshot: none, signedIn: false)", "stopRest", "signOutGoogle"])
    }

    @Test("サインアウトが失敗しても片付ける")
    func signOutFailureStillCleans() async {
        let defaults = S.defaults()
        let log = SideEffectLog()
        ContinuityShare.save(W.snapshot, defaults: defaults)
        let service = FakeAuthService()
        service.signOutError = URLError(.notConnectedToInternet)
        let store = W.makeStore(service, effects: W.effects(defaults, log: log))
        store.apply(.initialSession(S.userA))
        await store.signOut()
        #expect(ContinuityShare.load(defaults: defaults) == nil)
        #expect(!ContinuityShare.isSignedIn(defaults: defaults))
        #expect(log.events == ["reload(snapshot: none, signedIn: false)", "stopRest", "signOutGoogle"])
    }

    @Test("サーバーの .signedOut でサインイン済みから、また起動して端末にセッションが無いときも片付ける。コードの入力・未サインインからは片付けない")
    func serverSignedOut() async {
        let defaults = S.defaults()
        let log = SideEffectLog()
        let effects = W.effects(defaults, log: log)

        let signedIn = W.makeStore(FakeAuthService(), effects: effects)
        signedIn.apply(.initialSession(S.userA))
        ContinuityShare.save(W.snapshot, defaults: defaults)
        signedIn.apply(.signedOut)
        #expect(signedIn.phase == .signedOut)
        #expect(ContinuityShare.load(defaults: defaults) == nil)
        #expect(log.events == ["reload(snapshot: none, signedIn: false)", "stopRest", "signOutGoogle"])
        // その後のサインアウト (.signedOut が先に届いていた) では、もう一度は片付けない
        await signedIn.signOut()
        #expect(log.events.count == 3)

        // 起動して端末にセッションが無い (初期セッション無し・起動中の .signedOut) ときも片付ける
        // (片付けを経ずにセッションが無くなった端末で、ウィジェットに前の人の記録を残さない)
        log.events = []
        let fresh = W.makeStore(FakeAuthService(), effects: effects)
        fresh.apply(.initialSession(nil))
        #expect(log.events.contains("stopRest"))
        log.events = []
        let launching = W.makeStore(FakeAuthService(), effects: effects)
        launching.apply(.signedOut)
        #expect(log.events.contains("stopRest"))

        // コードの入力・未サインイン (セッションが無い画面) から先の .signedOut では片付けない
        let waiting = W.makeStore(FakeAuthService(), effects: effects)
        waiting.apply(.initialSession(nil))
        log.events = []
        await S.sendCode(waiting)
        waiting.apply(.signedOut)
        #expect(waiting.phase == .awaitingCode(email: "a@example.com"))
        waiting.backToSignIn()
        waiting.apply(.signedOut)
        #expect(waiting.phase == .signedOut)
        #expect(log.events.isEmpty)
    }

    @Test("サインイン済みになったら印を true に。false から変わったときだけウィジェットを作り直す")
    func signInSetsFlag() async {
        let defaults = S.defaults()
        let log = SideEffectLog()
        let service = FakeAuthService()
        service.verifyResult = .success(S.userA)
        let store = W.makeStore(service, effects: W.effects(defaults, log: log))
        store.apply(.initialSession(S.userA))
        await store.signOut()
        log.events = []

        await S.sendCode(store)
        #expect(log.events.isEmpty, "コードを送っただけでは印を変えない")
        #expect(await store.verifyCode("123456") == nil)
        #expect(store.phase == .signedIn(userID: S.userA))
        #expect(defaults.object(forKey: ContinuityShare.signedInKey) as? Bool == true)
        #expect(log.events == ["reload(snapshot: none, signedIn: true)"])
        // 同じ人の .signedIn がもう一度届いても作り直さない
        store.apply(.signedIn(S.userA))
        #expect(log.events.count == 1)
    }

    @Test("印のキーが無い (サインインの入る前のビルドから移った直後) ときはサインイン済みとみなす。サインインしても作り直さない")
    func missingKeyMeansSignedIn() {
        let defaults = S.defaults()
        #expect(defaults.object(forKey: ContinuityShare.signedInKey) == nil)
        #expect(ContinuityShare.isSignedIn(defaults: defaults))
        // App Group が開けない (nil) ときも同じ
        #expect(ContinuityShare.isSignedIn(defaults: nil))

        let log = SideEffectLog()
        W.effects(defaults, log: log).signedIn()
        #expect(defaults.object(forKey: ContinuityShare.signedInKey) as? Bool == true)
        #expect(log.events.isEmpty)

        ContinuityShare.setSignedIn(false, defaults: defaults)
        #expect(!ContinuityShare.isSignedIn(defaults: defaults))
    }

    @Test("スナップショットの形は変えない (今の保存がそのまま読める)")
    func snapshotShapeUnchanged() throws {
        let defaults = S.defaults()
        ContinuityShare.save(W.snapshot, defaults: defaults)
        #expect(ContinuityShare.load(defaults: defaults) == W.snapshot)
        let data = try #require(defaults.data(forKey: "continuity.v1"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["trainingDays", "goals"])
    }
}

// MARK: - 42501・PGRST3xx の文言 (P9)

@MainActor
@Suite("データの境界 — 42501・PGRST3xx は、セッションがあれば「もう一度」(更新を 1 回)、無ければ「サインインし直して」(P9)")
struct DataAccessGuardTests {
    static let denied = PostgrestError(code: "42501", message: "permission denied for table sleep_record")

    @Test("端末にセッションがあれば「確認できませんでした。もう一度お試しください」。セッションの更新を 1 回試す")
    func withSession() async {
        let session = FakeSessionAccess(hasStoredSession: true)
        let access = DataAccessGuard(session: session)
        let error = access.translate(Self.denied)
        #expect(error as? DataAccessError == .couldNotVerify)
        #expect(error.localizedDescription == "確認できませんでした。もう一度お試しください")
        await AuthTestSupport.waitUntil { session.refreshCount == 1 }
        #expect(session.refreshCount == 1)
    }

    @Test("端末にセッションが無ければ「サインインし直してください」。更新は試さない")
    func withoutSession() async {
        let session = FakeSessionAccess(hasStoredSession: false)
        let access = DataAccessGuard(session: session)
        let error = access.translate(Self.denied)
        #expect(error as? DataAccessError == .signInRequired)
        #expect(error.localizedDescription == "サインインし直してください")
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(session.refreshCount == 0)
    }

    @Test("更新が走っている間は新しく始めない (同時に何度も 42501 が来ても 1 回)。終われば次の 42501 でまた試す")
    func refreshOnlyOnceWhileRunning() async {
        let session = FakeSessionAccess(hasStoredSession: true)
        session.holdsRefresh = true
        let access = DataAccessGuard(session: session)
        for _ in 0..<3 { _ = access.translate(Self.denied) }
        _ = access.translate(PostgrestError(code: "PGRST303", message: "JWT expired"))
        await AuthTestSupport.waitUntil { session.refreshCount == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(session.refreshCount == 1)

        session.release()
        try? await Task.sleep(nanoseconds: 20_000_000)
        _ = access.translate(Self.denied)
        await AuthTestSupport.waitUntil { session.refreshCount == 2 }
        #expect(session.refreshCount == 2)
    }

    @Test("PGRST3xx (JWT の問題) も同じ。ほかの PostgREST のコード・通信の失敗はそのまま")
    func classification() {
        for code in ["42501", "PGRST300", "PGRST301", "PGRST302", "PGRST303"] {
            #expect(DataAccessError.isAccessDenied(PostgrestError(code: code, message: "x")), "\(code)")
        }
        for code in ["23514", "23503", "23P01", "P0001", "PGRST116", "PGRST202", "42P01"] {
            #expect(!DataAccessError.isAccessDenied(PostgrestError(code: code, message: "x")), "\(code)")
        }
        #expect(!DataAccessError.isAccessDenied(PostgrestError(message: "no code")))
        #expect(!DataAccessError.isAccessDenied(URLError(.notConnectedToInternet)))

        let access = DataAccessGuard(session: FakeSessionAccess(hasStoredSession: false))
        #expect(access.translate(PostgrestError(code: "PGRST301", message: "JWSError")) as? DataAccessError == .signInRequired)
        let check = PostgrestError(code: "23514", message: "violates check")
        #expect((access.translate(check) as? PostgrestError)?.code == "23514")
        #expect(access.translate(URLError(.timedOut)) is URLError)
        // 変えた後の値をもう一度通しても変わらない (境界が二重になっても同じ)
        #expect(access.translate(DataAccessError.couldNotVerify) as? DataAccessError == .couldNotVerify)
    }

    @Test("run は失敗を translate を通して投げ直す。成功はそのまま返す")
    func run() async throws {
        let access = DataAccessGuard(session: FakeSessionAccess(hasStoredSession: false))
        let value = try await access.run { 42 }
        #expect(value == 42)
        await #expect(throws: DataAccessError.signInRequired) {
            try await access.run { () async throws -> Int in throw Self.denied }
        }
    }

    @Test("RPC の失敗の分け方: 42501 は先に DataAccessError になり、規則の分け方 (RuleErrorMapping) に渡さない")
    func classifyAccessDeniedBeforeRules() {
        let access = DataAccessGuard(session: FakeSessionAccess(hasStoredSession: false))
        let error = SupabaseDayDataSource.classify(Self.denied, access: access) { _ in
            Issue.record("42501 を規則の分け方に渡した")
            return ScheduleRuleError.pastDay
        }
        #expect(error as? DataAccessError == .signInRequired)
    }

    @Test("RPC の失敗の分け方: 23514 の target_chk は RuleErrorMapping の規則のエラー。対応の無いものと通信の失敗はそのまま")
    func classifyRuleErrors() {
        let access = DataAccessGuard(session: FakeSessionAccess(hasStoredSession: false))
        let check = PostgrestError(code: "23514",
                                   message: "new row for relation \"task_template_version\" violates check constraint \"task_template_version_target_chk\"")
        let mapped = SupabaseDayDataSource.classify(check, access: access) { RuleErrorMapping.schedule($0) }
        #expect(mapped as? ScheduleRuleError == .invalidTarget)

        let unmapped = SupabaseDayDataSource.classify(PostgrestError(code: "23505", message: "duplicate key"), access: access) {
            RuleErrorMapping.schedule($0)
        }
        #expect((unmapped as? PostgrestError)?.code == "23505")

        let network = SupabaseDayDataSource.classify(URLError(.timedOut), access: access) { _ in
            Issue.record("通信の失敗を規則の分け方に渡した")
            return nil
        }
        #expect(network is URLError)
    }

    @Test("睡眠の失敗の文言も境界で変えた文言になる (SleepRules.message)")
    func sleepMessage() {
        let withSession = DataAccessGuard(session: FakeSessionAccess(hasStoredSession: true))
        let withoutSession = DataAccessGuard(session: FakeSessionAccess(hasStoredSession: false))
        #expect(SleepRules.message(for: withSession.translate(Self.denied)) == "確認できませんでした。もう一度お試しください")
        #expect(SleepRules.message(for: withoutSession.translate(Self.denied)) == "サインインし直してください")
    }
}

// MARK: - タップの投げ分け・upsert の衝突先

@MainActor
@Suite("data source — タップの投げ分けと upsert の衝突先 (0014 の人ごとの一意)")
struct MultiuserDataSourceTests {
    @Test("タップが読めないとき: 42501・PGRST3xx (境界で DataAccessError) は投げ、ほか (0012 の無い DB・通信) は空")
    func tapsFallback() throws {
        let access = DataAccessGuard(session: FakeSessionAccess(hasStoredSession: false))
        #expect(throws: DataAccessError.signInRequired) {
            try SupabaseDayDataSource.tapsAfterFailure(access.translate(PostgrestError(code: "42501", message: "denied")))
        }
        #expect(throws: DataAccessError.signInRequired) {
            try SupabaseDayDataSource.tapsAfterFailure(access.translate(PostgrestError(code: "PGRST301", message: "JWSError")))
        }
        #expect(throws: DataAccessError.couldNotVerify) {
            try SupabaseDayDataSource.tapsAfterFailure(DataAccessError.couldNotVerify)
        }
        let missingTable = PostgrestError(code: "42P01", message: "relation \"actual_task_tap\" does not exist")
        #expect(try SupabaseDayDataSource.tapsAfterFailure(access.translate(missingTable)).isEmpty)
        #expect(try SupabaseDayDataSource.tapsAfterFailure(PostgrestError(code: "PGRST205", message: "not in schema cache")).isEmpty)
        #expect(try SupabaseDayDataSource.tapsAfterFailure(URLError(.notConnectedToInternet)).isEmpty)
    }

    @Test("upsert の衝突先: プロフィール user_id・週の目標 user_id,effective_from・体重 user_id,recorded_on。種目は exercise_for_user")
    func conflictTargets() {
        #expect(SupabaseWorkoutDataSource.Conflict.profile == "user_id")
        #expect(SupabaseWorkoutDataSource.Conflict.weeklyGoal == "user_id,effective_from")
        #expect(SupabaseWorkoutDataSource.Conflict.bodyWeight == "user_id,recorded_on")
        #expect(SupabaseWorkoutDataSource.exerciseSource == "exercise_for_user")
    }

    @Test("送る中身に id・user_id を入れない (プロフィールの id 列は 0014 で消えた。user_id は DB の既定値 auth.uid())")
    func payloadColumns() throws {
        let birth = Date(timeIntervalSince1970: 946_652_400) // 2000-01-01 JST
        #expect(try Self.keys(ProfileRow(sex: .female, birthDate: birth)) == ["sex", "birth_date"])
        #expect(try Self.keys(WeeklyGoalRow(weeklyTarget: 3, effectiveFrom: birth)) == ["weekly_target", "effective_from"])
        #expect(try Self.keys(BodyWeightRecord(recordedOn: birth, weightKg: 60)) == ["recorded_on", "weight_kg"])
    }

    static func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder.supabase.encode(value)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }
}

// MARK: - implicit 形式の戻り (再送した確認メールのリンク)

@MainActor
@Suite("確認のリンクの implicit 形式 — セッションは作らず、サインインの画面に「確認しました」")
struct ImplicitConfirmationTests {
    typealias S = AuthTestSupport

    static let implicitURL = URL(string:
        "lifetracker://auth-callback#access_token=eyJ.x.y&expires_at=1800003600&expires_in=3600&refresh_token=r1&token_type=bearer&type=signup")!

    @Test("fragment に空でない access_token があれば implicit 形式。code・error・クエリの access_token は違う")
    func detection() {
        #expect(AuthCallback.isImplicitGrant(Self.implicitURL))
        #expect(AuthCallback.isImplicitGrant(URL(string: "lifetracker://auth-callback#type=signup&access_token=abc")!))
        #expect(!AuthCallback.isImplicitGrant(URL(string: "lifetracker://auth-callback?code=abc")!))
        #expect(!AuthCallback.isImplicitGrant(URL(string: "lifetracker://auth-callback")!))
        #expect(!AuthCallback.isImplicitGrant(URL(string:
            "lifetracker://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid")!))
        #expect(!AuthCallback.isImplicitGrant(URL(string: "lifetracker://auth-callback#access_token=&type=signup")!))
        #expect(!AuthCallback.isImplicitGrant(URL(string: "lifetracker://auth-callback?access_token=abc")!))
        #expect(!AuthCallback.isImplicitGrant(URL(string: "lifetracker://auth-callback#xaccess_token=abc")!))
    }

    @Test("コードの入力中に開くと、セッションを作らずにサインインの画面へ移り「メールアドレスを確認しました」を出す (入れかけの確認のコードはもう使えない)")
    func fromAwaitingCode() async {
        let service = FakeAuthService()
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))
        await S.sendCode(store)

        await store.handle(url: Self.implicitURL)
        #expect(store.phase == .signedOut)
        #expect(store.resendRemainingSeconds(at: S.start) == 0)
        #expect(store.signInNotice == "メールアドレスを確認しました。サインインしてください")
        #expect(store.linkFailureMessage == nil)
        #expect(store.lastEmail == "a@example.com", "サインインの画面の欄にメールアドレスが残る")
        #expect(!service.calls.contains("session"), "session(from:) を呼ばない")

        // コードを送り直したら知らせを消す。サインインしても出ない
        await S.sendCode(store)
        #expect(store.signInNotice == nil)
        service.verifyResult = .success(S.userA)
        #expect(await store.verifyCode("123456") == nil)
        #expect(store.signInNotice == nil)
    }

    @Test("未サインインでも同じ。サインイン済みの間は何もしない")
    func otherPhases() async {
        let service = FakeAuthService()
        let signedOut = S.makeStore(service)
        signedOut.apply(.initialSession(nil))
        await signedOut.handle(url: Self.implicitURL)
        #expect(signedOut.phase == .signedOut)
        #expect(signedOut.signInNotice == AuthStore.emailConfirmedNotice)

        let signedIn = S.makeStore(service)
        signedIn.apply(.initialSession(S.userA))
        await signedIn.handle(url: Self.implicitURL)
        #expect(signedIn.phase == .signedIn(userID: S.userA))
        #expect(signedIn.signInNotice == nil)
        #expect(!service.calls.contains("session"))
    }

    @Test("起動中に開いたら知らせだけ置く。初期セッションが無ければサインインの画面で出る・あればサインイン済みで消える")
    func duringLaunch() async {
        let none = S.makeStore(FakeAuthService())
        await none.handle(url: Self.implicitURL)
        #expect(none.phase == .launching)
        none.apply(.initialSession(nil))
        #expect(none.phase == .signedOut)
        #expect(none.signInNotice == AuthStore.emailConfirmedNotice)

        let some = S.makeStore(FakeAuthService())
        await some.handle(url: Self.implicitURL)
        some.apply(.initialSession(S.userA))
        #expect(some.phase == .signedIn(userID: S.userA))
        #expect(some.signInNotice == nil)
    }

    @Test("PKCE の形 (?code=。テンプレートを替える前の古いリンク) はこれまでどおり session(from:) に渡し、サインイン済みへ")
    func pkceStillExchanges() async {
        let service = FakeAuthService()
        service.sessionResult = .success(S.userA)
        let store = S.makeStore(service)
        store.apply(.initialSession(nil))
        await store.handle(url: S.callbackURL)
        #expect(service.calls == ["session"])
        #expect(store.phase == .signedIn(userID: S.userA))
    }
}
