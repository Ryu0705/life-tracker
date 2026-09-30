import ActivityKit
import SwiftUI
import WidgetKit

/// 休憩の残り時間 (ロック画面のバナーと Dynamic Island)。終わりの知らせはアプリが予約するローカル通知で出す
struct RestTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("休憩")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(context.attributes.title)
                        .font(.callout)
                        .lineLimit(1)
                }
                Spacer()
                // timerInterval の Text は幅いっぱいに広がるので、幅を決めて題名に場所を残す
                countdown(context.state.endsAt)
                    .font(.largeTitle.monospacedDigit().bold())
                    .frame(width: 110, alignment: .trailing)
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("休憩", systemImage: "timer")
                        .font(.callout)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context.state.endsAt)
                        .font(.title2.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                countdown(context.state.endsAt)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }

    /// 0 で止まるカウントダウン (表示側で数えるので、アプリが止まっていても進む)
    private func countdown(_ endsAt: Date) -> some View {
        Text(timerInterval: Date.now...max(endsAt, Date.now), countsDown: true)
            .multilineTextAlignment(.trailing)
    }
}
