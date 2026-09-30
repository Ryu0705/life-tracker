import SwiftUI

/// 週帯 (月〜日)。トレーニング実施日の閲覧専用: 点は「記録がある日」の事実だけ (連続日数・ヒートマップは ContinuityRow と分析画面が受け持つ)。
/// 「予定」タブも同じ部品を使う (allowsFuture = true で未来の日・次の週へ移れる)。選んでいる日は連動しない
struct WeekStripView: View {
    let selectedDay: Date
    let today: Date
    /// true = 未来の日も押せる・今週でも › が押せる (予定タブ)。false = 今日まで (トレーニング)
    let allowsFuture: Bool
    let recordedDays: Set<Date>
    let calendar: Calendar
    let onSelect: (Date) -> Void
    let onShiftWeek: (Int) -> Void

    var body: some View {
        let days = WorkoutSummary.weekDays(containing: selectedDay, calendar: calendar)
        let isCurrentWeek = days.contains { calendar.isDate($0, inSameDayAs: today) }
        HStack(spacing: 0) {
            Button { onShiftWeek(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 44)
            }
            .accessibilityLabel("前の週")
            ForEach(days, id: \.self) { day in
                dayCell(day)
            }
            Button { onShiftWeek(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 44)
            }
            .disabled(isCurrentWeek && !allowsFuture)
            .accessibilityLabel("次の週")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isSelectable = allowsFuture || WorkoutSummary.isSelectable(day: day, today: today, calendar: calendar)
        let isRecorded = recordedDays.contains(WorkoutSummary.dayKey(day, calendar: calendar))
        return Button { onSelect(day) } label: {
            VStack(spacing: 2) {
                Text(WorkoutSummary.weekdaySymbol(day, calendar: calendar))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.monospacedDigit().weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
                    .overlay(Circle().strokeBorder(isSelected && !isToday ? Color.accentColor : Color.clear, lineWidth: 1.5))
                Circle()
                    .fill(isRecorded ? Color.secondary : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .opacity(isSelectable ? 1 : 0.3)
        .accessibilityLabel(WorkoutSummary.dayLabel(day, calendar: calendar) + (isRecorded ? " 記録あり" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
