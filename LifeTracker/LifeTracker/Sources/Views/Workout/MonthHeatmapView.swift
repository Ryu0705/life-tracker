import SwiftUI

/// ヒートマップの表示期間 (本人 2026-10-07「最小 1 か月・2 段切替」)
enum HeatmapRange: String, CaseIterable, Identifiable {
    case month, halfYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: return "1か月"
        case .halfYear: return "半年"
        }
    }
}

/// 1 か月のヒートマップ: カレンダー型 (行 = 週・列 = 月〜日)。期間は強さと同じ段 (StrengthPeriod: 直近30日 → 先月 → 先々月 …)。
/// 期間を含む週を並べ、期間の外の日は空白。セルに日の数字。色と閾値は半年の草と同じ (TrainingHeatmap.level / color。閾値は今日からの 26 週で固定)
struct MonthHeatmapView: View {
    let volumes: [Date: Double]
    let thresholds: [Double]
    /// 色の基準の 26 週と表示中の週が読めているか。false の間は塗らない
    let isLoaded: Bool
    let today: Date
    var period: StrengthPeriod = .recent
    let calendar: Calendar

    /// 古い週が先頭。各週は月曜から 7 日 (期間の最初の日を含む週〜最後の日を含む週)
    static func weeks(today: Date, period: StrengthPeriod = .recent, calendar: Calendar) -> [[Date]] {
        period.weekStarts(today: today, calendar: calendar).map { start in
            (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        }
    }

    var body: some View {
        let weeks = Self.weeks(today: today, period: period, calendar: calendar)
        let todayKey = calendar.startOfDay(for: today)
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(["月", "火", "水", "木", "金", "土", "日"], id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 4) {
                    ForEach(week, id: \.self) { day in
                        cell(day, inPeriod: period.contains(day, today: today, calendar: calendar), isToday: day == todayKey)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(period.label(today: today, calendar: calendar))のトレーニング "
                            + (isLoaded ? "\(weeks.joined().filter { period.contains($0, today: today, calendar: calendar) && $0 <= todayKey && (volumes[$0] ?? 0) > 0 }.count)日" : "読み込み中"))
    }

    /// 期間の外 (今日より後を含む) は空白
    @ViewBuilder
    private func cell(_ day: Date, inPeriod: Bool, isToday: Bool) -> some View {
        let isFuture = day > calendar.startOfDay(for: today)
        if !inPeriod || isFuture {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            let level = TrainingHeatmap.level(volumes[day], thresholds: thresholds)
            RoundedRectangle(cornerRadius: 4)
                .fill(isLoaded ? TrainingHeatmap.color(level: level) : Color.clear)
                .overlay {
                    if !isLoaded { TrainingHeatmap.unloadedCell(cornerRadius: 4) }
                }
                .overlay {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isLoaded && level >= 3 ? Color.white : Color.primary)
                }
                .overlay {
                    if isToday { RoundedRectangle(cornerRadius: 4).stroke(Color.primary, lineWidth: 1) }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }
}

/// 分析の継続ページ (docs/analysis-tabs-discussion/40-integration.md §2「継続ページ」)。期間の状態は分析画面 (AnalysisView) が持つ
struct ContinuityPage: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    @ObservedObject var continuity: ContinuityStore
    @Binding var range: HeatmapRange
    @Binding var monthPeriod: StrengthPeriod
    let today: Date
    let calendar: Calendar

    var body: some View {
        List {
            AnalysisContinuitySection(store: store, historyStore: historyStore, continuity: continuity,
                                      range: $range, monthPeriod: $monthPeriod, today: today, calendar: calendar)
        }
    }
}

/// 継続: 連続日数・今週の回数と、ヒートマップ (見出しの横で 1 か月｜半年を切り替える。docs/continuity-design.md)
struct AnalysisContinuitySection: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    @ObservedObject var continuity: ContinuityStore
    @Binding var range: HeatmapRange
    /// 1 か月表示の期間 (半年はナビなし)
    @Binding var monthPeriod: StrengthPeriod
    let today: Date
    let calendar: Calendar

    var body: some View {
        Section {
            if let status = continuity.status(today: today, recordedToday: !store.sets.isEmpty) {
                HStack(spacing: 10) {
                    StreakLabel(days: status.streakDays)
                    WeekRing(status: status, lineWidth: 3)
                        .frame(width: 18, height: 18)
                    Text(ContinuityRow.weekText(status))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section {
            let volumes = heatmapVolumes
            let thresholds = TrainingHeatmap.windowThresholds(volumes: volumes, today: today, calendar: calendar)
            // 色の基準の 26 週がそろうまで塗らない (40-integration.md §3-3)。1 か月で窓より前に戻ったときはその週も
            let windowLoaded = TrainingHeatmap.windowWeekStarts(today: today, calendar: calendar).allSatisfy { historyStore.isLoaded(weekStart: $0) }
            switch range {
            case .month:
                let isLoaded = windowLoaded && monthPeriod.weekStarts(today: today, calendar: calendar).allSatisfy { historyStore.isLoaded(weekStart: $0) }
                PeriodNavigator(label: monthPeriod.label(today: today, calendar: calendar),
                                currentCaption: "直近\(StrengthPeriod.days)日", isCurrent: monthPeriod.isRecent, unit: "期間",
                                onOlder: { monthPeriod = monthPeriod.older }, onNewer: { monthPeriod = monthPeriod.newer })
                    // 先読みの 26 週より前に戻ったときはその場で読む
                    .task(id: monthPeriod) {
                        await historyStore.ensureLoaded(weekStarts: monthPeriod.weekStarts(today: today, calendar: calendar))
                    }
                if !isLoaded { loadingRow }
                MonthHeatmapView(volumes: volumes, thresholds: thresholds, isLoaded: isLoaded, today: today, period: monthPeriod, calendar: calendar)
            case .halfYear:
                if !windowLoaded { loadingRow }
                TrainingHeatmap(volumes: volumes, thresholds: thresholds, isLoaded: windowLoaded, today: today, calendar: calendar)
            }
        } header: {
            HStack {
                // ナビバーの「継続」と同じ語を並べない
                Text("トレーニングした日")
                Spacer()
                Picker("期間", selection: $range) {
                    ForEach(HeatmapRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: range) { monthPeriod = .recent }
            }
        }
    }

    private var loadingRow: some View {
        Text("読み込み中…").foregroundStyle(.secondary)
    }

    /// 日 → ボリューム。kg の出ない種目だけの日も「やった日」として最も薄い色で出す
    private var heatmapVolumes: [Date: Double] {
        let sets = WorkoutSummary.mergeToday(historySets: historyStore.loadedSets, todaySets: store.sets, today: today, calendar: calendar)
        return Dictionary(grouping: sets.filter { $0.completedAt != nil }) { WorkoutSummary.dayKey($0.completedAt!, calendar: calendar) }
            .mapValues { max(WorkoutProgress.value(of: .volume, in: $0) ?? 0, .leastNonzeroMagnitude) }
    }
}
