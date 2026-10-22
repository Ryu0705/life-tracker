import SwiftUI

/// サインアウトの操作。AppRootView が AuthStore の `signOut()` を environment で配る (計画 §2-6)。
/// 使うのはプロフィールのタブの「アカウント」の節だけ (2026-10-22 トレーニングの分析のプロフィールから移した)
struct SignOutAction {
    let perform: () async -> Void

    func callAsFunction() async {
        await perform()
    }
}

private struct SignOutActionKey: EnvironmentKey {
    static let defaultValue: SignOutAction? = nil
}

extension EnvironmentValues {
    /// nil = サインアウトの節を出さない (サインイン済みの画面の外)
    var signOutAction: SignOutAction? {
        get { self[SignOutActionKey.self] }
        set { self[SignOutActionKey.self] = newValue }
    }
}

/// プロフィールのタブの一番下の「アカウント」の節: サインイン中のメールアドレス (読むだけ) とサインアウト。
/// サインアウトは押すと確認 → サインアウト。結果に依らずサインインの画面に戻る (AuthStore.signOut。この画面ごと閉じる)
struct SignOutSection: View {
    let action: SignOutAction
    /// サインイン中のメールアドレス (AuthStore.signedInEmail)。nil なら行を出さない
    let email: String?

    @State private var isConfirming = false
    @State private var isWorking = false

    var body: some View {
        Section {
            if let email {
                LabeledContent("メールアドレス", value: email)
                    .accessibilityIdentifier("profile.email")
            }
            Button(role: .destructive) {
                isConfirming = true
            } label: {
                SignOutButtonLabel(isWorking: isWorking)
            }
            .disabled(isWorking)
            .accessibilityIdentifier("profile.signOut")
            .confirmationDialog("サインアウトしますか？", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("サインアウト", role: .destructive) {
                    isWorking = true
                    Task { await action() }
                }
                .accessibilityIdentifier("profile.signOut.confirm")
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("記録はサーバーに残ります。もう一度サインインすると見られます。")
            }
        } header: {
            Text("アカウント")
        } footer: {
            Text("ホーム画面のウィジェットの表示も消えます。")
        }
    }
}

/// サインアウトのボタンの中身 (送っている間は右に ProgressView。プロフィールの一覧の行なので、認証の画面の部品は使わない)
private struct SignOutButtonLabel: View {
    let isWorking: Bool

    var body: some View {
        HStack {
            Text("サインアウト")
            if isWorking {
                Spacer()
                ProgressView()
            }
        }
    }
}
