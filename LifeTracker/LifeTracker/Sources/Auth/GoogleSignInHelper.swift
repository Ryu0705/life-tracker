import CryptoKit
import Foundation
import GoogleSignIn
import Security
import UIKit

/// Google の ID トークン一式 (Supabase の signInWithIdToken に渡す)
struct GoogleIDToken: Equatable {
    let idToken: String
    let accessToken: String
    /// Google に渡した nonce (SHA-256) の元の値。Supabase にはこちらを渡す
    let rawNonce: String
}

/// nonce (計画 §2-3)。Supabase (GoTrue) は、渡された値の SHA-256 の小文字の 16 進と ID トークンの `nonce` を比べる。
/// だから Google には SHA-256 の値を、Supabase には元の値を渡す (「Skip nonce check」は OFF のまま)
enum GoogleNonce {
    /// 32 バイトの乱数 (SecRandomCopyBytes) の 16 進の文字列
    static func makeRaw() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 失敗はまず無いが、そのときも暗号用の乱数で埋める
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return hex(bytes)
    }

    /// 元の値の UTF-8 の SHA-256 を小文字の 16 進にしたもの (Google の `nonce:` に渡す)
    static func hashed(_ raw: String) -> String {
        hex(Array(SHA256.hash(data: Data(raw.utf8))))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Google のクライアント ID が入っているか (xcconfig の `GOOGLE_IOS_CLIENT_ID`・`GOOGLE_REVERSED_CLIENT_ID`)。
/// `unset` (`.example` の印) か空なら入っていない。入っていないまま GIDSignIn を呼ぶと、URL スキームが無いと止まる
enum GoogleSignInConfig {
    static let reversedClientIDPrefix = "com.googleusercontent.apps."

    static func isConfigured(clientID: String?, reversedClientID: String?) -> Bool {
        func isSet(_ value: String?) -> Bool {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  !value.contains("$(") else { return false }
            return value != "unset" && !value.hasSuffix(".unset")
        }
        return isSet(clientID) && isSet(reversedClientID)
    }

    /// Info.plist の `GIDClientID` と、CFBundleURLTypes のうち逆順のクライアント ID のスキーム
    static func isConfigured(info: [String: Any]) -> Bool {
        let clientID = info["GIDClientID"] as? String
        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let reversed = urlTypes
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .first { $0.hasPrefix(reversedClientIDPrefix) }
        return isConfigured(clientID: clientID, reversedClientID: reversed)
    }
}

/// GoogleSignIn-iOS 10.0.0 で ID トークンを受ける (SwiftUI の部品は使わない)
enum GoogleSignInHelper {
    static func signIn() async throws -> GoogleIDToken {
        guard GoogleSignInConfig.isConfigured(info: Bundle.main.infoDictionary ?? [:]) else {
            throw AuthFailure.googleNotConfigured
        }
        guard let presenting = presentingViewController() else {
            throw AuthFailure.unknown("Google の画面を出す元の画面が見つからない")
        }
        let rawNonce = GoogleNonce.makeRaw()
        let result: GIDSignInResult
        do {
            // 9.0.0 で足された nonce を渡せる形 (GIDSignIn.h の signInWithPresentingViewController:hint:additionalScopes:nonce:completion:)
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting, hint: nil,
                                                               additionalScopes: nil,
                                                               nonce: GoogleNonce.hashed(rawNonce))
        } catch let error as GIDSignInError where error.code == .canceled {
            throw AuthFailure.cancelled
        }
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthFailure.unknown("Google の ID トークンが無い")
        }
        return GoogleIDToken(idToken: idToken, accessToken: result.user.accessToken.tokenString, rawNonce: rawNonce)
    }

    /// `onOpenURL` で `lifetracker://auth-callback` 以外の URL (逆順のクライアント ID のスキーム) を渡す
    static func handle(_ url: URL) {
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    /// サインアウトの後片付け。GoogleSignIn がサインインの成功時に Keychain に保存した auth state (Google の access・refresh token) を消す。
    /// 端末の中の処理だけで通信しない (`disconnect` は使わない)。Google で入っていない人で呼んでも何もしない
    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    /// いま前に出ている画面の一番上の view controller
    private static func presentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
