import SwiftUI
import Charts

/// トレーニングタブの右上 [📊] から push する分析 (3 つ目のタブにはしない)。
/// 週の総ボリューム・前週比・曜日×部位の棒グラフ・部位別の本番セット数と、種目ごとの推移一覧。
/// 「今週 N 日」「連続 N 週」「目標達成」は出さない (INV-6)
struct WeekAnalysisView: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    let calendar: Calendar

    /// 表示中の週頭。nil = 今週 (日付をまたいでも今週を指し続ける)
    @State private var weekStart: Date?

    private var today: Date { WorkoutSummary.dayKey(Date(), calendar: calendar) }
    private var shownWeek: Date { weekStart ?? WorkoutSummary.weekStart(containing: today, calendar: calendar) }
    private var previousWeek: Date { calendar.date(byAdding: .day, value: -7, to: shownWeek)! }

    private var isCurrentWeek: Bool { shownWeek == WorkoutSummary.weekStart(containing: today, calendar: calendar) }

    var body: some View {
        let current = totals(shownWeek)
        // 今週は前週の同じ曜日までと比べる (週の前半にいつも大きくマイナスにならないように。D-4)。過去の週は丸 1 週どうし
        let previousThrough = isCurrentWeek ? calendar.date(byAdding: .day, value: -7, to: today) : nil
        let previous = historyStore.isLoaded(weekStart: previousWeek) ? totals(previousWeek, through: previousThrough) : nil
        List {
            Section { weekNavigation }
            Section("総ボリューム") {
                volumeHeader(current: current, previous: previous, isPartial: previousThrough != nil)
                chart(current)
            }
            Section {
                if current.workingSetsByMuscle.isEmpty {
                    Text("この週の記録はありません")
                        .foregroundStyle(.secondary)
                } else {
                    Text(current.workingSetsByMuscle.map { "\($0.muscle.displayName) \($0.count)" }.joined(separator: " · "))
                        .font(.callout.monospacedDigit())
                }
            } header: {
                HStack {
                    Text("本番セット数（部位別）")
                    Spacer()
                    Text("計 \(current.totalWorkingSets)")
                        .monospacedDigit()
                }
            }
            if !progressExercises.isEmpty {
                Section("種目ごとの推移") {
                    ForEach(progressExercises) { exercise in
                        NavigationLink(value: exercise.id) {
                            ProgressExerciseRow(exercise: exercise)
                        }
                    }
                }
            }
        }
        .navigationTitle("分析")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: shownWeek) { await historyStore.ensureLoaded(weekStarts: [shownWeek, previousWeek]) }
        .task { await historyStore.loadRecordedExerciseIds() }
    }

    private var weekNavigation: some View {
        let end = calendar.date(byAdding: .day, value: 6, to: shownWeek)!
        return HStack {
            Button { weekStart = previousWeek } label: { Self.chevron("chevron.left") }
                .accessibilityLabel("前の週")
            Spacer()
            VStack(spacing: 2) {
                if isCurrentWeek { Text("今週").font(.caption).foregroundStyle(.secondary) }
                Text("\(WorkoutSummary.dayLabel(shownWeek, calendar: calendar))〜\(WorkoutSummary.dayLabel(end, calendar: calendar))")
                    .font(.subheadline.monospacedDigit())
            }
            Spacer()
            Button { weekStart = calendar.date(byAdding: .day, value: 7, to: shownWeek) } label: { Self.chevron("chevron.right") }
                .disabled(isCurrentWeek)
                .accessibilityLabel("次の週")
        }
        .buttonStyle(.borderless)
    }

    private static func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
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

    /// 曜日×kg を部位で積み上げ。kg のない日 (自重・時間のみ) は 0 (本番セット数には出る)
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

    /// 推移一覧: 記録がある種目を種目マスタの並び順で (今日初めて記録した種目も含める)
    private var progressExercises: [Exercise] {
        let recorded = historyStore.recordedExerciseIds.union(store.sets.map(\.exerciseId))
        return store.exercises.filter { recorded.contains($0.id) }
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

/// NavigationLink の label 用。static な表示のみ (structural-conventions A-1)
private struct ProgressExerciseRow: View {
    let exercise: Exercise

    var body: some View {
        HStack {
            Text(exercise.name)
            Spacer()
            Text(exercise.muscleGroup.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
