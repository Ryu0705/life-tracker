import Foundation

/// もう使わない端末のキーの片付け。起動のたびに `UserDefaults.standard` から消す (無ければ何もしない)
enum ObsoleteAuthKeys {
    /// 再設定の印 (2026-10-22 リンクからコードに替えて使わなくなった)
    static let keys = ["auth.passwordResetRequestedAt.v1"]

    static func remove(from defaults: UserDefaults) {
        keys.forEach { defaults.removeObject(forKey: $0) }
    }
}
