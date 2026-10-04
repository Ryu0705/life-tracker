import ActivityKit
import Foundation

/// 休憩タイマーの Live Activity (ロック画面・Dynamic Island に残り時間を出す)。アプリと Widget Extension の両方で使う。
/// 残り時間は endsAt から表示側で数えるので、±15・スキップのときだけ更新すればよい
nonisolated struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endsAt: Date
    }

    /// 休憩の元になったセット (例: 「ベンチプレス セット2」)
    var title: String
}
