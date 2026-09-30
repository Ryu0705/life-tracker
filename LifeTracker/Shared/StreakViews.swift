import SwiftUI

/// 今週の回数のリング (アプリとウィジェットで共有)。達成したら緑
nonisolated struct WeekRing: View {
    let status: ContinuityStatus
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: status.progress)
                .stroke(status.isWeekAchieved ? Color.green : Color.orange,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// 「🔥 45日」。連続なしは灰色の炎と 0
nonisolated struct StreakLabel: View {
    let days: Int
    var font: Font = .headline

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .foregroundStyle(days > 0 ? Color.orange : Color.secondary)
            Text("\(days)日")
                .monospacedDigit()
        }
        .font(font)
    }
}

/// 今週 7 日の点 (月〜日)。トレーニングした日は塗りつぶし、今日は輪
nonisolated struct WeekDots: View {
    let status: ContinuityStatus
    var size: CGFloat = 16

    var body: some View {
        let todayIndex = 7 - status.daysLeftInWeek
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                VStack(spacing: 2) {
                    Text(["月", "火", "水", "木", "金", "土", "日"][index])
                        .font(.system(size: size * 0.6))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(status.weekDone[index] ? Color.orange : Color.secondary.opacity(0.2))
                        .overlay(Circle().strokeBorder(index == todayIndex ? Color.primary : Color.clear, lineWidth: 1.5))
                        .frame(width: size, height: size)
                }
            }
        }
    }
}
