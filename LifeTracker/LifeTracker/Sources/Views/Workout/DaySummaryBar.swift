import SwiftUI

/// 表示中の日の合計 (kg・本番セット・種目・時刻範囲)。今日 / 過去日の 2 モード。
/// 記録が無くてもバーは出したまま (最初の ✓ で数字に変わるだけで、レイアウトが跳ねない)
struct DaySummaryBar: View {
    let day: Date
    let isToday: Bool
    let totals: DayTotals
    let calendar: Calendar
    let onBackToToday: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(WorkoutSummary.dayLabel(day, calendar: calendar) + (isToday ? " 今日" : ""))
                    .font(.subheadline.bold())
                Spacer()
                if !isToday {
                    // タップ領域は 44pt。はみ出す分は負の余白で打ち消し、今日 / 過去日でバーの高さを変えない
                    Button(action: onBackToToday) {
                        Text("今日へ")
                            .font(.subheadline)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.vertical, -13)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if totals.totalSets == 0 {
                    Text(isToday ? "まだ記録なし" : "記録なし")
                        .foregroundStyle(.secondary)
                } else {
                    // 自重・時間種目だけの日はボリュームが無いので kg を省略する
                    if let volume = totals.volume {
                        Text("\(WorkoutLogic.formatVolume(volume))kg")
                    }
                    Text("\(totals.workingSets)セット")
                    Text("\(totals.exerciseCount)種目")
                }
                Spacer()
                if let range = WorkoutSummary.timeRangeText(totals, calendar: calendar) {
                    Text(range)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.headline.monospacedDigit())
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
