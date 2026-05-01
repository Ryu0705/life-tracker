import SwiftUI

struct ScheduleListView: View {
    let scheduled: [DayScheduledTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("予定")
                .font(.headline)
            if scheduled.isEmpty {
                Text("本日の予定はありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(scheduled) { item in
                    ScheduleRow(item: item)
                }
            }
        }
    }
}

private struct ScheduleRow: View {
    let item: DayScheduledTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timeText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task.name)
                    .font(.body)
                if let badge = membershipBadge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .opacity(item.membership == .primary ? 1.0 : 0.6)
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: item.visibleRange.start)
        let end = formatter.string(from: item.visibleRange.end)
        return "\(start)–\(end)"
    }

    private var membershipBadge: String? {
        switch item.membership {
        case .primary: return nil
        case .spillover: return "前日から継続"
        case .overflow: return "翌日へ継続"
        }
    }
}
