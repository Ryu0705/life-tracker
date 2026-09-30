import SwiftUI

extension DayScheduledTask {
    /// 前日から続く行 (別の日の回)
    var isSpillover: Bool {
        if case .spillover = membership { return true }
        return false
    }

    /// その日だけ変えた回 (系列の実体 O(D))
    var isOverridden: Bool { !isVirtual && task.templateId != nil }
}

/// 予定の 1 行。見分け: 右端 › = 編集できる / 薄い = 別の日の回 (前日から続く) / 時刻が薄い色 = 今日のもう過ぎた回 /
/// 2 行目「この日だけ変更」= その日だけ変えた回 (UI レビュー §5)
struct ScheduleRow: View {
    let item: DayScheduledTask
    let categoryName: String?
    let isEditable: Bool
    let isPastTime: Bool
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timeText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isPastTime ? Color.secondary : Color.primary)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task.name)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 0)
            if isEditable {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(item.isSpillover ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isEditable ? "編集" : "")
    }

    /// 本来の範囲 (日をまたぐ予定も「23:00–7:00」)。書式はトレーニング・編集画面と同じ %d:%02d
    private var timeText: String {
        "\(Self.clock(item.task.startAt, calendar: calendar))–\(Self.clock(item.task.endAt, calendar: calendar))"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let categoryName { parts.append(categoryName) }
        if item.isOverridden { parts.append("この日だけ変更") }
        switch item.membership {
        case .primary: break
        case .spillover: parts.append("前日から継続")
        case .overflow: parts.append("翌日へ継続")
        }
        return parts.joined(separator: " · ")
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return ScheduleRepeat.timeText((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}
