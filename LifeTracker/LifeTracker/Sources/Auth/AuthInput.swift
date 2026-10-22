import Foundation

/// メールアドレスの入力の整え方と、送る前の最低限の検査
enum EmailInput {
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `a@b` の形か (細かい検査はサーバーに任せる)
    static func looksValid(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !email.contains(" ")
    }
}

/// メールに届くコードの入力の整え方 (2026-10-22 リンクからコードに替え、同じ日にサインインもコードだけにした)。数字だけ・6 桁。
/// 空白 (全角も) とハイフン (ダッシュ・マイナスの似た字も) は取り除く。ほかの字は残す (残れば 6 桁の数字にならず、送れない)
enum EmailCodeInput {
    /// コードの桁 (Supabase のダッシュボードの「Email OTP Length」の既定と同じ 6)
    static let length = 6
    /// 6 桁に足りないときの文言 (2026-10-22 までコードの画面の見出しの下にも出していた)。期限 (ダッシュボードの Email OTP Expiration) はサーバーが決め、アプリは数字を持たない
    static let guidance = "メールに届いた 6 桁のコードを入れてください"

    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}", "\u{FF0D}"]

    static func normalized(_ raw: String) -> String {
        String(raw.filter { !$0.isWhitespace && !hyphens.contains($0) })
    }

    /// 整えた後の値が 6 桁の数字 (ASCII の 0〜9) か
    static func isComplete(_ code: String) -> Bool {
        code.count == length && code.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}
