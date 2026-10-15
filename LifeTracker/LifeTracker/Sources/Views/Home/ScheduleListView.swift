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

/// 予定の 1 行。› は出さない (2026-10-14 本人「右端の>も廃止して。」。開ける行はタップで編集／過去日は実績の入力) /
/// 薄い = 別の日の回 (前日から続く)・スキップした回 / 時刻が薄い色 = 今日のもう過ぎた回 /
/// 2 行目「この日だけ変更」= その日だけ変えた回 (UI レビュー §5) / 3 行目 = 実績 (予定と違う時刻・睡眠の実績・スキップ)。
/// 丸は行の外 (HomeView) の右端に置く (2026-10-14 本人指示「チェックを押しづらいから右端に移動して。」)
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

/// 行の右端の丸 (チェックイン)。見た目 30pt・当たり判定 56×52pt (2026-10-14 本人「それに伴ってチェックを大きくしてほしい。」。
/// 前は左・22pt・32×44pt)。押せない丸 (セットのあるジム・予定外の実績) は A-4 の 3 点セット
struct CheckInCircle: View {
    typealias Style = CheckInCircleStyle

    let style: Style
    let action: () -> Void

    var body: some View {
        let isFixed = style == .fixedDone || style == .hidden
        Button(action: action) {
            icon
                .font(.system(size: 30))
                .frame(width: 56, height: 52)
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
        case .progress(let count, let target):
            // 枠 = 進捗の輪・中 = 「3/8」。目標に届いたら中も塗る (目標を超えても数える)
            let reached = count >= target
            ZStack {
                ProgressRing(count: count, target: target)
                Circle()
                    .fill(reached ? Color.accentColor : Color.clear)
                    .padding(ProgressRing.lineWidth + 1.5)
                Text("\(count)/\(target)")
                    .font(.system(size: count >= 10 || target >= 10 ? 9 : 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(reached ? Color.white : Color.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    // 届いたら中の塗りの縁に掛からない幅 (「12/12」)
                    .frame(width: ProgressRing.size - 2 * ProgressRing.lineWidth - (reached ? 6 : 2))
            }
            .frame(width: ProgressRing.size, height: ProgressRing.size)
        }
    }

    private var label: String {
        switch style {
        case .empty: return "記録なし"
        case .done, .fixedDone: return "やった"
        case .skipped: return "スキップ"
        case .hidden: return ""
        case .progress(let count, let target): return "\(target)回中\(count)回"
        }
    }
}

/// 目標 2 以上の丸の枠: 回数 / 目標の長さだけ 12 時の位置から時計回りに塗る輪。区切らない
/// (2026-10-14 本人「回数設定されているものは、画像のようにチェックの丸の枠に進捗表示もさせたい」「リングを区切らないで」)
struct ProgressRing: View {
    let count: Int
    let target: Int

    /// 丸の大きさ (輪の外径)
    static let size: CGFloat = 34
    static let lineWidth: CGFloat = 4

    /// 塗る長さ (1 周 = 1)。目標を超えても 1
    static func fraction(count: Int, target: Int) -> Double {
        guard target >= 1 else { return 0 }
        return Double(min(max(count, 0), target)) / Double(target)
    }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: Self.lineWidth / 2)
                .stroke(Color(.systemGray4), lineWidth: Self.lineWidth)
            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: Self.fraction(count: count, target: target))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.2), value: count)
        .accessibilityHidden(true)
    }
}

/// 「やること」(時刻なしの回) の 1 行。2 行目 = 種類・「10/10 から」(繰り越し中)・「この日だけ変更」。
/// 3 行目 = スキップ。丸は行の外 (HomeView) の右端。› は出さない (行のタップで開く)
struct TodoRow: View {
    let todo: DayTodo
    let categoryName: String?
    /// 見ている日 (これより前の回の日なら「から」を付ける)
    let viewDay: Date
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.name)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if todo.isSkipRecorded {
                    // 見ている日が skipped_on より前でも出す (記録の操作は取り消しだけ。R6)
                    Text(todo.record?.skippedOn.map { "スキップ（\(Self.shortDate($0, calendar: calendar))）" } ?? "スキップ")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(todo.isSkipRecorded ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint("開く")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let categoryName { parts.append(categoryName) }
        if todo.occurrenceDate < calendar.startOfDay(for: viewDay) {
            parts.append("\(Self.shortDate(todo.occurrenceDate, calendar: calendar)) から")
        }
        if todo.origin == .override { parts.append("この日だけ変更") }
        return parts.joined(separator: " · ")
    }

    /// 「10/10」
    static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
}

/// 予定外の実績の 1 行 (時刻は実績、2 行目に「予定外」)。押せない塗りの丸が右端。› は出さない
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
