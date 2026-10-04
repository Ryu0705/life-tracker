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

/// 予定の 1 行。見分け: 右端 › = 開ける (編集／過去日は実績の入力) / 薄い = 別の日の回 (前日から続く)・スキップした回 /
/// 時刻が薄い色 = 今日のもう過ぎた回 / 2 行目「この日だけ変更」= その日だけ変えた回 (UI レビュー §5) /
/// 3 行目 = 実績 (予定と違う時刻・睡眠の実績・スキップ)。左の丸は行の外 (HomeView) に置く (レビュー §5-1)
struct ScheduleRow: View {
    let item: DayScheduledTask
    let categoryName: String?
    let isEditable: Bool
    let isPastTime: Bool
    /// 実績の行 (「実績 7:00–7:40」「スキップ」、睡眠は sleep_record から「実績 23:40–7:10（7時間30分）」)。nil = 出さない
    let actualLine: String?
    let isSkipped: Bool
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
                if let actualLine {
                    Text(actualLine)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
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
        .opacity(item.isSpillover || isSkipped ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isEditable ? "開く" : "")
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

/// 行の左の丸 (チェックイン)。当たり判定は 44pt。押せない丸 (セットのあるジム・予定外の実績) は A-4 の 3 点セット
struct CheckInCircle: View {
    typealias Style = CheckInCircleStyle

    let style: Style
    let action: () -> Void

    var body: some View {
        let isFixed = style == .fixedDone || style == .hidden
        Button(action: action) {
            icon
                .font(.title2)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isFixed)
        .allowsHitTesting(!isFixed)
        .accessibilityLabel(label)
        .accessibilityRemoveTraits(isFixed ? .isButton : [])
        .accessibilityAddTraits(isFixed ? .isStaticText : [])
        .accessibilityHidden(style == .hidden)
    }

    @ViewBuilder
    private var icon: some View {
        switch style {
        case .empty:
            Image(systemName: "circle").foregroundStyle(Color(.tertiaryLabel))
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(Color.secondary)
        case .fixedDone:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor.opacity(0.6))
        case .hidden:
            Color.clear
        }
    }

    private var label: String {
        switch style {
        case .empty: return "記録なし"
        case .done, .fixedDone: return "やった"
        case .skipped: return "スキップ"
        case .hidden: return ""
        }
    }
}

/// 予定外の実績の 1 行 (時刻は実績、2 行目に「予定外」)
struct UnplannedActualRow: View {
    let actual: ActualTask
    let categoryName: String?
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timeText)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(actual.name)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(([categoryName, "予定外"] as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("開く")
    }

    private var timeText: String {
        guard let start = actual.startAt, let end = actual.endAt else { return "" }
        return CheckInPlanner.rangeText(start, end, calendar: calendar)
    }
}
