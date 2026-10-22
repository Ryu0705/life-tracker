import GoogleSignIn
import SwiftUI

/// 「Google で続ける」のボタン (2026-10-22 本人「自前で揃える」。ほかのボタンと同じ高さ 52・角丸の枠線のボタン)。
/// Google のブランドの決まり (https://developers.google.com/identity/branding-guidelines 。2026-10-22 に読んだ) に合わせる:
/// - ロゴは GoogleSignIn-iOS 10.0.0 に入っている公式の 4 色の G (`google.png`・18pt) をそのまま使う。色も大きさも変えない。自分で描かない
/// - 明るい画面: 塗り #FFFFFF・枠 #747775 (1px・内側)・文字 #1F1F1F。暗い画面: 塗り #131314・枠 #8E918F・文字 #E3E3E3
/// - iOS の余白: ロゴの前 16・ロゴと文字の間 12・文字の後 16 (幅いっぱいなので、ロゴと文字の組を真ん中に置き、これを最低の余白にする)
/// - 文言は決まりの「Continue with Google」を日本語にしたもの (訳は使ってよいと書いてある)。「Google」だけにはしない
/// - 形は「長方形か丸い端」で、角丸と高さの数字は決まりに無い (拡大はロゴを伸ばさなければよい) ので、ほかのボタンに揃えた
/// - 譲った所: 決まりのフォントは Google Sans Medium だが、パッケージに入っておらず外から入れないので、システムのフォント (中くらいの太さ)
/// 押したときの動きは呼ぶ側 (AuthStore.signInWithGoogle)
struct AuthGoogleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let logo = GoogleLogo.image {
                    Image(uiImage: logo)
                        .accessibilityHidden(true)
                }
                Text(GoogleLogo.buttonTitle)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: AuthMetrics.controlHeight)
        }
        .buttonStyle(AuthGoogleButtonStyle())
        .accessibilityLabel(GoogleLogo.buttonTitle)
        .accessibilityIdentifier("auth.google")
    }
}

/// Google のボタンの色 (決まりの値。明るい画面・暗い画面)
struct AuthGoogleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: AuthMetrics.cornerRadius)
        configuration.label
            .foregroundStyle(Color(hex: isDark ? 0xE3E3E3 : 0x1F1F1F))
            .background {
                shape.fill(Color(hex: isDark ? 0x131314 : 0xFFFFFF))
            }
            .overlay {
                shape.strokeBorder(Color(hex: isDark ? 0x8E918F : 0x747775), lineWidth: 1)
            }
            .overlay {
                // 押している間は薄い膜を重ねる (ロゴの色は変えない)
                shape.fill(Color(hex: isDark ? 0xE3E3E3 : 0x1F1F1F).opacity(configuration.isPressed ? 0.12 : 0))
            }
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(shape)
    }
}

/// GoogleSignIn-iOS のパッケージに入っている公式の G の画像 (GIDSignInButton と同じ探し方: アプリの中の resource bundle、無ければ GIDSignIn の bundle)
enum GoogleLogo {
    static let buttonTitle = "Google で続ける"
    /// SwiftPM で入れたときの resource bundle の名前 (GoogleSignIn-iOS 10.0.0 の NSBundle+GID3PAdditions.m の `GoogleSignInBundleName`)
    static let resourceBundleName = "GoogleSignIn_GoogleSignIn"

    static let image: UIImage? = {
        let path = Bundle.main.path(forResource: resourceBundleName, ofType: "bundle")
            ?? Bundle(for: GIDSignIn.self).path(forResource: resourceBundleName, ofType: "bundle")
        guard let path, let bundle = Bundle(path: path) else { return nil }
        return UIImage(named: "google", in: bundle, compatibleWith: nil)
    }()
}

private extension Color {
    /// 0xRRGGBB の色 (Google の決まりの値をそのまま書くため)
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
