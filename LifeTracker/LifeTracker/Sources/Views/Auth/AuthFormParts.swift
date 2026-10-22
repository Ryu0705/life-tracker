import SwiftUI

// 認証の画面の見た目の部品 (2026-10-22 作り直し。Slack のサインインの形に合わせた。設計 §7「サインインの画面の作り直し」)。
// 認証の画面 (サインイン・コードの入力。同じ日にパスワードレスにして 2 つになった) はこの部品だけで組む。一覧 (List・Form の行) は使わない。
// 色はシステムの色 (明るい画面・暗い画面で自動で変わる) とアプリの青 (accent) だけ

/// 寸法 (入力欄と主のボタンは同じ高さ・同じ角丸)
enum AuthMetrics {
    static let controlHeight: CGFloat = 52
    static let cornerRadius: CGFloat = 12
    static let horizontalPadding: CGFloat = 24
    /// iPad・横向きで広がりすぎないように
    static let maxContentWidth: CGFloat = 480
}

/// 認証の画面の外枠。一番上のアプリ名の文字 (2026-10-22 本人「アプリ名の文字」) と、その下に縦に並べた中身。
/// かたまり (アプリ名からいちばん下の要素まで) を、見えている高さの縦の真ん中に置く (2026-10-22 本人「上寄りすぎ。中央寄せ」)。
/// 見えている高さはキーボードの分だけ縮む (GeometryReader がキーボードの安全域を除いた高さになる) ので、キーボードが出ると
/// 残りの高さの真ん中に寄り、欄と主のボタンが隠れない。収まらなければスクロールする。
/// 収まるときも弾むまま (下に引くとキーボードが閉じる。コードの画面の数字のキーボードには閉じるキーが無い)
struct AuthScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    AuthAppName()
                        .padding(.bottom, 8)
                    content
                }
                .padding(.horizontal, AuthMetrics.horizontalPadding)
                .padding(.vertical, 24)
                .frame(maxWidth: AuthMetrics.maxContentWidth)
                // 高さが足りれば真ん中、足りなければ上から並べてスクロール
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemBackground))
    }
}

/// アプリの顔: アプリ名の文字 (太字・title2・中央)。認証の画面のかたまりの一番上
struct AuthAppName: View {
    static let text = "LifeTracker"

    var body: some View {
        Text(Self.text)
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("auth.appName")
    }
}

/// 中央の大きな見出し (説明文は付けない。2026-10-22 コードの画面の灰色の案内の 1 行もやめ、見出しだけにした)
struct AuthHeadline: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title2.bold())
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 枠線だけの入力欄の外側 (角丸・高さ 52)。入力中はアプリの青の太い枠
struct AuthFieldFrame: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: AuthMetrics.controlHeight)
            .overlay {
                RoundedRectangle(cornerRadius: AuthMetrics.cornerRadius)
                    .strokeBorder(isFocused ? Color.accentColor : Color(.systemGray2), lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AuthMetrics.cornerRadius))
    }
}

/// メールアドレスの欄 (`.emailAddress`。自動の大文字・修正を切る)。
/// パスワードが無くなったので、パスワードの自動入力のための `.username` はやめた (2026-10-22)
struct AuthEmailField: View {
    @Binding var email: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("メールアドレス", text: $email)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
            .accessibilityIdentifier("auth.email")
            .modifier(AuthFieldFrame(isFocused: focused))
    }
}

/// アプリの青で塗りつぶした全幅の主のボタン (高さ 52・角丸・白の太字)。押せないときは薄く。送っている間は ProgressView
struct AuthPrimaryButton: View {
    let title: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .opacity(isWorking ? 0 : 1)
                if isWorking {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AuthMetrics.controlHeight)
        }
        .buttonStyle(AuthPrimaryButtonStyle())
    }
}

struct AuthPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: AuthMetrics.cornerRadius)
                    .fill(Color.accentColor)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: AuthMetrics.cornerRadius))
    }
}

/// 「または」の区切りの線
struct AuthOrDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            line
            Text("または")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            line
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
    }
}

/// 青い文字のリンク (補助の操作。コードの送り直し)。押せないとき (送り直しの待ち) は灰色
struct AuthTextLink: View {
    let title: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 欄の下の赤い小さな文言 (失敗。各画面が自分の @State で持つ。規約 A-2)
struct AuthErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("auth.error")
        }
    }
}

/// うまくいった知らせ (緑の小さな文言。例「新しいコードを送りました」)
struct AuthNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 送り先のメールアドレス (灰色・長ければ真ん中を省く) と「変更」(サインインの画面に戻る)。コードの画面の見出しの下
struct AuthSentEmailRow: View {
    let email: String
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(email)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("auth.sentEmail")
            Button("変更", action: onChange)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel("メールアドレスを変更")
                .accessibilityIdentifier("auth.changeEmail")
        }
        .frame(maxWidth: .infinity)
    }
}

/// 6 つの枠に 1 桁ずつ見えるコードの欄。中は 1 本の透明な TextField (貼り付けと iOS のコードの自動入力 `.oneTimeCode` が効く)。
/// 入れた値は空白とハイフンを取り除き、6 文字までにする (`EmailCodeInput`)。出たときに入力を始める
struct AuthCodeField: View {
    @Binding var code: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<EmailCodeInput.length, id: \.self) { index in
                    box(at: index)
                }
            }
            .accessibilityHidden(true)

            TextField("", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focused)
                .frame(maxWidth: .infinity, minHeight: AuthMetrics.controlHeight)
                .accessibilityLabel("6 桁のコード")
                .accessibilityIdentifier("auth.code")
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: code) { _, newValue in
            let cleaned = String(EmailCodeInput.normalized(newValue).prefix(EmailCodeInput.length))
            if cleaned != newValue { code = cleaned }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
    }

    private func box(at index: Int) -> some View {
        let characters = Array(code)
        let character = index < characters.count ? String(characters[index]) : ""
        // 次に入る枠 (6 桁が揃ったら最後の枠) を青く
        let isCurrent = focused && index == min(characters.count, EmailCodeInput.length - 1)
        return Text(character)
            .font(.title2.weight(.semibold).monospacedDigit())
            .frame(maxWidth: .infinity, minHeight: AuthMetrics.controlHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isCurrent ? Color.accentColor : Color(.systemGray2), lineWidth: isCurrent ? 2 : 1)
            }
    }
}
