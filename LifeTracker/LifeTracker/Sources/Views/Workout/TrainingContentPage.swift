import SwiftUI
import Charts

/// 分析の中身ページ (docs/analysis-tabs-discussion/40-integration.md §2「中身ページ」):
/// 週の総ボリューム・前週比・曜日×部位の棒グラフ。表示中の週は分析画面 (AnalysisView) が持つ
struct TrainingContentPage: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    /// 表示中の週頭。nil = 今週 (日付をまたいでも今週を指し続ける)
    @Binding var weekStart: Date?
    let today: Date
    let calendar: Calendar

    private var shownWeek: Date { weekStart ?? WorkoutSummary.weekStart(containing: today, calendar: calendar) }
    private var previousWeek: Date { calendar.date(byAdding: .day, value: -7, to: shownWeek)! }

    private var isCurrentWeek: Bool { shownWeek == WorkoutSummary.weekStart(containing: today, calendar: calendar) }

    var body: some View {
        let current = totals(shownWeek)
        // 今週は前週の同じ曜日までと比べる (週の前半にいつも大きくマイナスにならないように。D-4)。過去の週は丸 1 週どうし
        let previousThrough = isCurrentWeek ? calendar.date(byAdding: .day, value: -7, to: today) : nil
        let previous = historyStore.isLoaded(weekStart: previousWeek) ? totals(previousWeek, through: previousThrough) : nil
        let end = calendar.date(byAdding: .day, value: 6, to: shownWeek)!
        List {
            Section {
                PeriodNavigator(label: "\(WorkoutSummary.dayLabel(shownWeek, calendar: calendar))〜\(WorkoutSummary.dayLabel(end, calendar: calendar))",
                                currentCaption: "今週", isCurrent: isCurrentWeek, unit: "週",
                                onOlder: { weekStart = previousWeek },
                                onNewer: { weekStart = calendar.date(byAdding: .day, value: 7, to: shownWeek) })
            }
            Section("総ボリューム") {
                volumeHeader(current: current, previous: previous, isPartial: previousThrough != nil)
                if current.workingSetsByMuscle.isEmpty {
                    Text("この週の記録はありません")
                        .foregroundStyle(.secondary)
                } else {
                    chart(current)
                }
            }
        }
        .task(id: shownWeek) { await historyStore.ensureLoaded(weekStarts: [shownWeek, previousWeek]) }
    }

    private func volumeHeader(current: WeekTotals, previous: WeekTotals?, isPartial: Bool) -> some View {
        let label = isPartial ? "前週同期間" : "前週"
        return HStack(alignment: .firstTextBaseline) {
            Text(current.volume.map { "\(WorkoutLogic.formatVolume($0))kg" } ?? "—")
                .font(.title2.bold().monospacedDigit())
            Spacer()
            Group {
                if let previousVolume = previous?.volume,
                   let change = WorkoutSummary.volumeChange(current: current.volume ?? 0, previous: previousVolume) {
                    Text("\(label)比 \(change >= 0 ? "+" : "")\(change)%（\(label) \(WorkoutLogic.formatVolume(previousVolume))kg）")
                } else if previous != nil {
                    Text(isPartial ? "前週の同期間は記録なし" : "前週の記録なし")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// 曜日×kg を部位で積み上げ。kg のない日 (自重・時間のみ) は 0
    private func chart(_ totals: WeekTotals) -> some View {
        let symbols = WorkoutSummary.weekDays(containing: shownWeek, calendar: calendar).map { WorkoutSummary.weekdaySymbol($0, calendar: calendar) }
        let muscles = Exercise.MuscleGroup.allCases.filter { m in totals.byDayMuscle.contains { $0.muscle == m } }
        return Chart(totals.byDayMuscle, id: \.self) { entry in
            BarMark(
                x: .value("曜日", WorkoutSummary.weekdaySymbol(entry.day, calendar: calendar)),
                y: .value("kg", entry.volume)
            )
            .foregroundStyle(by: .value("部位", entry.muscle.displayName))
        }
        .chartXScale(domain: symbols)
        .chartForegroundStyleScale(domain: muscles.map(\.displayName), range: muscles.map { Self.color($0) })
        .frame(height: 180)
    }

    private func totals(_ week: Date, through: Date? = nil) -> WeekTotals {
        let sets = WorkoutSummary.mergeToday(historySets: historyStore.sets(inWeekStarting: week), todaySets: store.sets,
                                             today: today, calendar: calendar)
        return WorkoutSummary.weekTotals(sets: sets, exercisesById: store.exercisesById, week: week, through: through, calendar: calendar)
    }

    /// 部位 → 色は固定 (週をまたいでも同じ部位は同じ色)
    static func color(_ muscle: Exercise.MuscleGroup) -> Color {
        switch muscle {
        case .chest: return .red
        case .back: return .blue
        case .traps: return .indigo
        case .shoulders: return .orange
        case .biceps: return .cyan
        case .triceps: return .purple
        case .forearms: return .brown
        case .quads: return .green
        case .hamstrings: return .mint
        case .glutes: return .teal
        case .calves: return .pink
        case .core: return .yellow
        case .cardio, .fullBody: return .gray
        }
    }
}
