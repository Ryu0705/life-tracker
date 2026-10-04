import SwiftUI
import UIKit

/// 睡眠の時刻の 1 行: 「就寝 ……… 23:40」。時刻を押すと下に 5 分刻みのホイールが開く (±ボタンは置かない。2026-10-03 本人決定 B)
struct SleepTimeField: View {
    let title: String
    @Binding var minutes: Int
    @Binding var isExpanded: Bool
    /// 時刻の左に薄く出す補足 (就寝が起床の前日になるときの日付など)
    var detail: String?
    let calendar: Calendar

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                Text(ScheduleRepeat.timeText(minutes))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(isExpanded ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(title) \(ScheduleRepeat.timeText(minutes))")
            .accessibilityHint("押すと時刻を選べます")
        }
        if isExpanded {
            MinuteWheel(minutes: $minutes, calendar: calendar)
                .frame(maxWidth: .infinity)
                .frame(height: 180)
        }
    }
}

/// 時刻のホイール (5 分刻み)。SwiftUI の DatePicker は分の刻みを指定できないので UIDatePicker (minuteInterval = 5) を包む
struct MinuteWheel: UIViewRepresentable {
    @Binding var minutes: Int
    let calendar: Calendar

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        picker.minuteInterval = SleepRules.minuteStep
        picker.calendar = calendar
        picker.timeZone = calendar.timeZone
        picker.locale = Locale(identifier: "ja_JP")
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        picker.date = date(for: minutes)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.parent = self
        let target = date(for: minutes)
        if picker.date != target { picker.setDate(target, animated: false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// 0 時からの分 → 固定の日のその時刻 (ホイールは時刻だけを使う)
    private func date(for minutes: Int) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 0)).addingTimeInterval(TimeInterval(minutes * 60))
    }

    final class Coordinator: NSObject {
        var parent: MinuteWheel

        init(parent: MinuteWheel) {
            self.parent = parent
        }

        @MainActor @objc func changed(_ picker: UIDatePicker) {
            parent.minutes = SleepRules.minutesOfDay(picker.date, calendar: parent.calendar)
        }
    }
}
