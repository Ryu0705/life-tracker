import ActivityKit
import Foundation
import UserNotifications

/// 休憩の知らせ (D-3): ロック画面の Live Activity (残り時間) と、終わりのローカル通知。
/// 休憩の終わりが変わるたび (✓・±15・スキップ) に sync、休憩が最後まで進んだら finish を呼ぶ。
/// 通知が許可されなければ Live Activity だけになる
enum RestAlerts {
    static let notificationId = "rest-timer-end"
    /// 無音 (0.5 秒)。音は鳴らさず振動だけにする (2026-09-30 本人「バイブレーションだけ欲しい」)。
    /// 通知に「振動だけ」の指定は無いため、無音の音を付けて振動を出す。振動が出るかは実機で確認する
    static let soundName = UNNotificationSoundName("rest_end.caf")

    @MainActor
    static func sync(endsAt: Date?, title: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        guard let endsAt, endsAt > Date() else {
            await endActivities()
            return
        }
        await scheduleNotification(center: center, endsAt: endsAt, title: title)
        await startOrUpdateActivity(endsAt: endsAt, title: title)
    }

    /// 休憩が最後まで進んだ: 予約した通知は届く (または届いた) ので消さず、Live Activity だけ閉じる
    static func finish() async {
        await endActivities()
    }

    /// 前回の起動から残った Live Activity を片付ける (アプリの起動時は休憩していない)
    static func endActivities() async {
        for activity in Activity<RestActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func scheduleNotification(center: UNUserNotificationCenter, endsAt: Date, title: String) async {
        // 初回だけ許可を聞く。拒否されていれば予約しない (アプリ内の表示と振動だけになる)
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "休憩終了"
        content.body = "\(title) の次のセットへ"
        content.sound = UNNotificationSound(named: soundName)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, endsAt.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger))
    }

    private static func startOrUpdateActivity(endsAt: Date, title: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: RestActivityAttributes.ContentState(endsAt: endsAt), staleDate: endsAt)
        let current = Activity<RestActivityAttributes>.activities
        // 題名 (種目・セット) が変わる ✓ では作り直す。±15 は同じ Activity の更新
        if let activity = current.first, activity.attributes.title == title {
            await activity.update(content)
            return
        }
        for activity in current { await activity.end(nil, dismissalPolicy: .immediate) }
        _ = try? Activity.request(attributes: RestActivityAttributes(title: title), content: content)
    }
}

