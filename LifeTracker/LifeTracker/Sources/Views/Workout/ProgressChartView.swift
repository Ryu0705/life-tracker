import SwiftUI
import Charts

/// 種目の推移グラフ。指標は種目の metric_kind に応じて切り替えられる (ウェイト種目は 3 指標)
struct ProgressChartView: View {
    let exercise: Exercise
    let daily: [DailySets]

    @State private var metric: ProgressMetric?

    var body: some View {
        let available = ProgressMetric.available(for: exercise.metricKind)
        let selected = metric ?? available[0]
        let points = WorkoutProgress.points(daily, metric: selected)

        VStack(alignment: .leading, spacing: 12) {
            if available.count > 1 {
                Picker("指標", selection: Binding(get: { selected }, set: { metric = $0 })) {
                    ForEach(available) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if let best = points.max(by: { $0.value < $1.value }) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ベスト")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selected.format(best.value))
                        .font(.title3.monospacedDigit().bold())
                    Text(best.day.formatted(.dateTime.month().day().locale(Locale(identifier: "ja_JP"))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if points.count >= 2 {
                Chart(points, id: \.day) { point in
                    LineMark(x: .value("日付", point.day, unit: .day), y: .value(selected.displayName, point.value))
                    PointMark(x: .value("日付", point.day, unit: .day), y: .value(selected.displayName, point.value))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 180)
                .environment(\.locale, Locale(identifier: "ja_JP"))
            } else {
                Text("2日分以上の記録でグラフが出ます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
