import Foundation
import WidgetKit

/// サインイン・サインアウトに伴う端末の側の片付け (計画 §2-6)。AuthStore のフック (`onSignedIn`・`onSignedOut`) の中身で、
/// LifeTrackerApp の組み立てで渡す (AuthStore にウィジェット・通知の知識を持たせない)。テストは UserDefaults と操作を差し込む
struct SignInSideEffects {
    /// App Group の UserDefaults (ウィジェットと共有)
    var defaults: UserDefaults?
    var reloadWidgets: () -> Void
    /// 休憩の終わりの通知の予約を消し、Live Activity を閉じる
    var stopRestAlerts: () -> Void
    /// 端末の Keychain に残る Google の資格情報 (GoogleSignIn が保存した auth state) を消す。通信しない
    var signOutGoogle: () -> Void

    /// 本物 (App Group・WidgetCenter・RestAlerts・GoogleSignIn)
    static var live: SignInSideEffects {
        SignInSideEffects(defaults: ContinuityShare.sharedDefaults,
                          reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
                          stopRestAlerts: { RestAlerts.cancelAll() },
                          signOutGoogle: { GoogleSignInHelper.signOut() })
    }

    /// 何もしない (メモリ上の認証。実機で `-mock-*` を付けて起動しても、本人のウィジェット・休憩の通知・Google の資格情報に触れない)
    static var disabled: SignInSideEffects {
        SignInSideEffects(defaults: nil, reloadWidgets: {}, stopRestAlerts: {}, signOutGoogle: {})
    }

    /// サインアウト (サーバーの `.signedOut` を含む) の後片付け。順: スナップショットを消す → サインインの印を false →
    /// ウィジェットを作り直す → 休憩の通知の予約と Live Activity を止める → Google の資格情報を消す
    func signedOut() {
        ContinuityShare.clearSnapshot(defaults: defaults)
        ContinuityShare.setSignedIn(false, defaults: defaults)
        reloadWidgets()
        stopRestAlerts()
        signOutGoogle()
    }

    /// サインイン済みになった。印を true にし、サインアウトしていた (false) ときだけウィジェットを作り直す
    func signedIn() {
        let wasSignedIn = ContinuityShare.isSignedIn(defaults: defaults)
        ContinuityShare.setSignedIn(true, defaults: defaults)
        if !wasSignedIn { reloadWidgets() }
    }
}
