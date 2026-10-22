import SwiftUI

/// メールに届いた 6 桁のコードを入れる画面 (2026-10-22 リンクから替え、同じ日に見た目を作り直し、サインインもこのコードだけにした)。
/// 一番上はサインインの画面と同じアプリ名の文字。見出し (何を入れるか。2026-10-22 本人の言葉。下の灰色の案内の 1 行と重なるので見出しだけにした) の下に、
/// 送り先のメールアドレスと「変更」(サインインの画面に戻る。欄には送ったメールアドレスが残る)。
/// 6 つの枠 (`AuthCodeField`)・「認証」(6 桁の数字で押せる。通ればサインイン済み)・「コードを送り直す」(60 秒の待ちの間は残りの秒)
struct EmailCodeView: View {
    static let headline = "入力したメールアドレスに届いた認証コードを入力してください"

    @ObservedObject var store: AuthStore
    let email: String

    @State private var code = ""
    @State private var verifyError: String?
    @State private var resendError: String?
    @State private var resendNotice: String?
    @State private var isVerifying = false
    @State private var isResending = false

    private var isWorking: Bool {
        isVerifying || isResending
    }

    private var canVerify: Bool {
        !isWorking && EmailCodeInput.isComplete(EmailCodeInput.normalized(code))
    }

    var body: some View {
        AuthScreen {
            AuthHeadline(text: Self.headline)
            AuthSentEmailRow(email: email) {
                store.backToSignIn()
            }
            .disabled(isWorking)
            .padding(.bottom, 8)
            AuthCodeField(code: $code)
            AuthErrorText(message: verifyError)
            AuthPrimaryButton(title: "認証", isWorking: isVerifying) {
                verify()
            }
            .disabled(!canVerify)
            .accessibilityIdentifier("auth.verifyCode")

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = store.resendRemainingSeconds(at: context.date)
                AuthTextLink(title: remaining > 0 ? "あと \(remaining) 秒で送り直せます" : "コードを送り直す") {
                    resend()
                }
                .disabled(remaining > 0 || isWorking)
                .monospacedDigit()
                .accessibilityIdentifier("auth.resendCode")
            }
            // 確かめの失敗と同時には出さない (どちらかを押すと、もう片方の文言を消す。auth.error は 1 つだけ)
            if let resendError {
                AuthErrorText(message: resendError)
            } else if let resendNotice {
                AuthNotice(message: resendNotice)
            }
        }
    }

    private func verify() {
        guard canVerify else { return }
        isVerifying = true
        verifyError = nil
        resendError = nil
        resendNotice = nil
        Task {
            // 通れば AuthStore の状態が変わり、この画面ごと替わる
            verifyError = await store.verifyCode(code)
            isVerifying = false
        }
    }

    private func resend() {
        isResending = true
        verifyError = nil
        resendError = nil
        resendNotice = nil
        Task {
            if let message = await store.resendCode() {
                resendError = message
            } else {
                resendNotice = "新しいコードを送りました"
                code = ""
            }
            isResending = false
        }
    }
}
