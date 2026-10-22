import SwiftUI

/// サインインの画面 (2026-10-22 作り直し。Slack の形。同じ日にパスワードレスにして 1 段にした)。計画 §2-2
/// - 一番上はアプリ名の文字・見出し「サインイン・サインアップ」・メールアドレスの欄 → 主のボタン「コードを送る」(送れたらコードの画面へ)
/// - 登録の入口は無い (登録とサインインが同じ流れ)。それは見出しで分かるようにし、説明の文は足さない (2026-10-22 本人の決定。言い方はサインイン・サインアップ・サインアウトに揃える)
/// - 「または」の下に Google のボタン
struct SignInView: View {
    @ObservedObject var store: AuthStore

    /// 見出し (2026-10-22 本人の決定。言い方は「サインイン・サインアップ・サインアウト」に揃える)
    static let headline = "サインイン・サインアップ"

    @State private var email: String
    @State private var errorMessage: String?
    @State private var googleErrorMessage: String?
    @State private var isSending = false
    @State private var isSigningInWithGoogle = false

    /// 欄のメールアドレスは、最後に入れたもの (コードの画面から戻ったとき。AuthStore のメモリの中だけ)
    init(store: AuthStore) {
        self.store = store
        _email = State(initialValue: store.lastEmail)
    }

    private var normalizedEmail: String {
        EmailInput.normalized(email)
    }

    private var isWorking: Bool {
        isSending || isSigningInWithGoogle
    }

    private var canSend: Bool {
        !isWorking && !normalizedEmail.isEmpty
    }

    var body: some View {
        AuthScreen {
            AuthHeadline(text: Self.headline)
            // 古い確認のリンク (implicit 形式) を開いた後の知らせ
            if let notice = store.signInNotice {
                AuthNotice(message: notice)
                    .accessibilityIdentifier("auth.notice")
            }
            AuthEmailField(email: $email)
                .submitLabel(.send)
                .onSubmit { sendCode() }
            AuthErrorText(message: errorMessage)
            AuthPrimaryButton(title: "コードを送る", isWorking: isSending) {
                sendCode()
            }
            .disabled(!canSend)
            .accessibilityIdentifier("auth.sendCode")

            AuthOrDivider()
            AuthGoogleButton {
                signInWithGoogle()
            }
            .disabled(isWorking)
            AuthErrorText(message: googleErrorMessage)
        }
    }

    private func sendCode() {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        googleErrorMessage = nil
        Task {
            // 送れたら AuthStore の状態が変わり、コードの画面に替わる
            errorMessage = await store.sendCode(email: normalizedEmail)
            isSending = false
        }
    }

    private func signInWithGoogle() {
        isSigningInWithGoogle = true
        errorMessage = nil
        googleErrorMessage = nil
        Task {
            googleErrorMessage = await store.signInWithGoogle()
            isSigningInWithGoogle = false
        }
    }
}
