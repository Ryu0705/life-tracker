import SwiftUI
import Charts

/// 睡眠の推移 (1 画面目の右上「推移」から push)。[週|月] の切り替え、数字 1 行、範囲バー (就寝〜起床。予定の帯なし)、
/// 睡眠時間の棒＋7 日平均の線。通常の睡眠だけ (仮眠は入れない)。期間は未来へ進めない
struct SleepTrendView: View {
    @ObservedObject var store: SleepStore
    let today: Date

    enum Period: String, CaseIterable, Identifiable {
        case week, month
        var id: String { rawValue }
        var label: String { self == .week ? "週" : "月" }
    }

    @State private var period: Period = .week
    /// 表示中の期間の最初の朝。nil = 今の週・月
    @State private var anchor: Date?

    private var calendar: Calendar { store.calendar }

    /// 期間の最初と最後の朝 (両端を含む)
    private func bounds(_ start: Date) -> (first: Date, last: Date) {
        switch period {
        case .week:
            return (start, calendar.date(byAdding: .day, value: 6, to: start)!)
        case .month:
            let next = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start, calendar.date(byAdding: .day, value: -1, to: next)!)
        }
    }

    private func periodStart(containing day: Date) -> Date {
        switch period {
        case .week: return WorkoutSummary.weekStart(containing: day, calendar: calendar)
        case .month: return store.monthRange(containing: day).lowerBound
        }
    }

    private var currentStart: Date { periodStart(containing: today) }
    private var shownStart: Date { anchor ?? currentStart }
    private var shown: (first: Date, last: Date) { bounds(shownStart) }
    private var isCurrent: Bool { shownStart == currentStart }

    /// 期間の朝 (就寝が前日の夜) ＋ 7 日平均の分 (6 朝前) を覆う範囲
    private var loadRange: Range<Date> {
        let from = calendar.date(byAdding: .day, value: -8, to: shown.first)!
        return from..<calendar.date(byAdding: .day, value: 1, to: shown.last)!
    }

    private var mornings: [Date] {
        let count = (calendar.dateComponents([.day], from: shown.first, to: shown.last).day ?? 0) + 1
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: shown.first)! }
    }

    var body: some View {
        let nights = SleepRules.nights(store.records, calendar: calendar)
        let inPeriod = nights.filter {
            let m = SleepRules.morning(ofKey: $0.key, calendar: calendar)
            return m >= shown.first && m <= shown.last
        }
        List {
            Section {
                Picker("期間", selection: $period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                navigation
                Text(numbersLine(nights))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.secondary)
            }
            Section("就寝〜起床") {
                rangeChart(inPeriod)
            }
            Section("睡眠時間") {
                durationChart(nights)
            }
        }
        .navigationTitle("推移")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: period) { anchor = nil }
        .task(id: loadRange) { await store.ensureLoaded(loadRange) }
    }

    private var navigation: some View {
        HStack {
            Button { anchor = previousStart } label: { Self.chevron("chevron.left") }
                .accessibilityLabel(period == .week ? "前の週" : "前の月")
            Spacer()
            VStack(spacing: 2) {
                if isCurrent { Text(period == .week ? "今週" : "今月").font(.caption).foregroundStyle(Color.secondary) }
                Text("\(WorkoutSummary.dayLabel(shown.first, calendar: calendar))〜\(WorkoutSummary.dayLabel(shown.last, calendar: calendar))")
                    .font(.subheadline.monospacedDigit())
            }
            Spacer()
            Button {
                let next = nextStart
                anchor = next == currentStart ? nil : next
            } label: { Self.chevron("chevron.right") }
                .disabled(isCurrent)
                .accessibilityLabel(period == .week ? "次の週" : "次の月")
        }
        .buttonStyle(.borderless)
    }

    private var previousStart: Date {
        period == .week ? calendar.date(byAdding: .day, value: -7, to: shownStart)! : calendar.date(byAdding: .month, value: -1, to: shownStart)!
    }

    private var nextStart: Date {
        period == .week ? calendar.date(byAdding: .day, value: 7, to: shownStart)! : calendar.date(byAdding: .month, value: 1, to: shownStart)!
    }

    /// 「平均 6時間52分 · 就寝 0:12 · 起床 7:04 · 記録 5/7」
    private func numbersLine(_ nights: [SleepNight]) -> String {
        let stats = SleepRules.stats(nights: nights, firstMorning: shown.first, lastMorning: shown.last, today: today, calendar: calendar)
        var parts: [String] = []
        if let average = stats.averageDuration { parts.append("平均 \(SleepRules.durationText(average))") }
        if let bed = stats.averageBedtimeMinutes { parts.append("就寝 \(ScheduleRepeat.timeText(bed))") }
        if let wake = stats.averageWakeMinutes { parts.append("起床 \(ScheduleRepeat.timeText(wake))") }
        parts.append("記録 \(stats.recordedCount)/\(stats.elapsedCount)")
        return parts.joined(separator: " · ")
    }

    // MARK: - 範囲バー

    private struct Segment: Identifiable {
        let id: UUID
        /// 行の位置 (一番上の朝 = count − 1、一番下 = 0)
        let row: Double
        /// 鍵の日の 18:00 からの時間
        let start: Double
        let end: Double
    }

    private func label(_ morning: Date) -> String {
        let c = calendar.dateComponents([.month, .day], from: morning)
        return period == .week ? WorkoutSummary.dayLabel(morning, calendar: calendar) : "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// 行は数値の軸で置く (行 i の帯 = i ± 0.5、罫線は帯の境、ラベルは帯の中央)。
    /// 文字列の軸 (y: .value("朝", "10/3(土)")) では、既定の軸の罫線・ラベルと BarMark の帯の位置が合わず、
    /// バーが行の中央より約 9pt 下 (下の罫線のあたり) に描かれた (2026-10-04 シミュレータで確認)
    @ViewBuilder
    private func rangeChart(_ nights: [SleepNight]) -> some View {
        let days = mornings
        let count = days.count
        let segments = nights.flatMap { night -> [Segment] in
            let origin = night.key.addingTimeInterval(TimeInterval(SleepRules.averageOriginMinutes * 60))
            let morning = SleepRules.morning(ofKey: night.key, calendar: calendar)
            guard let index = days.firstIndex(of: morning) else { return [] }
            let row = Double(count - 1 - index)
            return night.records.map {
                Segment(id: $0.id, row: row, start: $0.startAt.timeIntervalSince(origin) / 3600,
                        end: $0.endAt.timeIntervalSince(origin) / 3600)
            }
        }
        // 既定は 20時〜12時。外れる記録があれば広げる
        let lower = min(2, (segments.map(\.start).min() ?? 2).rounded(.down))
        let upper = max(18, (segments.map(\.end).max() ?? 18).rounded(.up))
        let labels = days.map(label)
        if segments.isEmpty {
            Text("この期間の記録はありません")
                .foregroundStyle(Color.secondary)
        }
        let rows = Double(max(count, 1))
        let height = CGFloat(rows) * (period == .week ? 28 : 14) + 30
        Chart(segments) { segment in
            Self.bar(segment, radius: period == .week ? 8 : 4)
        }
        .chartXScale(domain: lower...upper)
        .chartYScale(domain: -0.5...(rows - 0.5))
        .chartXAxis { hourAxis(lower: lower, upper: upper) }
        .chartYAxis { rowAxis(labels) }
        .frame(height: height)
    }

    /// 角は帯の高さの半分 (カプセル形)
    private static func bar(_ segment: Segment, radius: CGFloat) -> some ChartContent {
        let top: Double = segment.row + 0.3
        let bottom: Double = segment.row - 0.3
        let mark = RectangleMark(xStart: PlottableValue.value("就寝", segment.start), xEnd: PlottableValue.value("起床", segment.end),
                           yStart: PlottableValue.value("朝", bottom), yEnd: PlottableValue.value("朝", top))
        return mark
            .foregroundStyle(Color.indigo)
            .cornerRadius(radius)
    }

    private func hourAxis(lower: Double, upper: Double) -> some AxisContent {
        AxisMarks(values: Array(stride(from: (lower / 4).rounded(.up) * 4, through: upper, by: 4))) { value in
            AxisGridLine()
            AxisValueLabel {
                if let hours = value.as(Double.self) {
                    Text("\((Int(hours) + 18) % 24)時")
                }
            }
        }
    }

    /// 罫線 = 行の境 (−0.5, 0.5, …)、ラベル = 行の中央 (0, 1, …。一番上が最初の朝)
    @AxisContentBuilder
    private func rowAxis(_ labels: [String]) -> some AxisContent {
        let count = labels.count
        let borders: [Double] = (0...count).map { Double($0) - 0.5 }
        let centers: [Double] = (0..<count).map { Double($0) }
        AxisMarks(values: borders) { _ in
            AxisGridLine()
        }
        AxisMarks(position: .leading, values: centers) { value in
            AxisValueLabel {
                Text(Self.rowLabel(value.as(Double.self), labels: labels))
            }
        }
    }

    private static func rowLabel(_ row: Double?, labels: [String]) -> String {
        guard let row else { return "" }
        let index = labels.count - 1 - Int(row.rounded())
        return labels.indices.contains(index) ? labels[index] : ""
    }

    // MARK: - 睡眠時間の棒＋7 日平均

    private struct DurationPoint: Identifiable {
        let morning: Date
        let hours: Double
        var id: Date { morning }
    }

    @ViewBuilder
    private func durationChart(_ nights: [SleepNight]) -> some View {
        let bars = nights.compactMap { night -> DurationPoint? in
            let morning = SleepRules.morning(ofKey: night.key, calendar: calendar)
            guard morning >= shown.first && morning <= shown.last else { return nil }
            return DurationPoint(morning: morning, hours: night.total / 3600)
        }
        let averages = mornings.filter { $0 <= today }.compactMap { morning -> DurationPoint? in
            SleepRules.movingAverage(nights: nights, morning: morning, calendar: calendar).map { DurationPoint(morning: morning, hours: $0 / 3600) }
        }
        let end = calendar.date(byAdding: .day, value: 1, to: shown.last)!
        Chart {
            ForEach(bars) { point in
                BarMark(x: .value("朝", point.morning, unit: .day), y: .value("時間", point.hours))
                    .foregroundStyle(Color.indigo.opacity(0.7))
            }
            ForEach(averages) { point in
                LineMark(x: .value("朝", point.morning, unit: .day), y: .value("7日平均", point.hours), series: .value("系列", "7日平均"))
                    .foregroundStyle(Color.orange)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: shown.first...end)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hours = value.as(Double.self) { Text("\(Int(hours))時間") }
                }
            }
        }
        .frame(height: 180)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .environment(\.timeZone, calendar.timeZone)
        HStack(spacing: 12) {
            Label("睡眠時間", systemImage: "square.fill").foregroundStyle(Color.indigo.opacity(0.7))
            Label("7日平均", systemImage: "line.diagonal").foregroundStyle(Color.orange)
        }
        .font(.caption)
    }

    static func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
