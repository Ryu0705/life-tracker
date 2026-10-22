import SwiftUI
import Charts

/// 分析の中身ページ (docs/analysis-tabs-discussion/40-integration.md §2「中身ページ」):
/// 週の総ボリューム・前週比・曜日×部位の棒グラフと部位ごとの kg。表示中の週は分析画面 (AnalysisView) が持つ。
/// 棒をタップするとその日を選び、部位ごとの kg がその日の分になる (docs/body-strength-and-heatmap-period.md「ボリュームページの追加要望」)
struct TrainingContentPage: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    /// 表示中の週頭。nil = 今週 (日付をまたいでも今週を指し続ける)
    @Binding var weekStart: Date?
    let today: Date
    let calendar: Calendar
    /// 棒をタップして選んだ日。nil = 週の合計
    @State private var selectedDay: Date?

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
            Section(selectedDay.map { "\(WorkoutSummary.dayLabel($0, calendar: calendar)) のボリューム" } ?? "総ボリューム") {
                if let selectedDay {
                    dayVolumeHeader(selectedDay)
                } else {
                    volumeHeader(current: current, previous: previous, isPartial: previousThrough != nil)
                }
                if current.workingSetsByMuscle.isEmpty {
                    Text("この週の記録はありません")
                        .foregroundStyle(.secondary)
                } else {
                    chart(current)
                }
            }
            if !current.workingSetsByMuscle.isEmpty {
                muscleSection(current)
            }
        }
        .task(id: shownWeek) { await historyStore.ensureLoaded(weekStarts: [shownWeek, previousWeek]) }
        .onChange(of: shownWeek) { selectedDay = nil }
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

    /// 選んだ日のボリュームと、前週の同じ曜日との比較
    private func dayVolumeHeader(_ day: Date) -> some View {
        let lastWeekDay = calendar.date(byAdding: .day, value: -7, to: day)!
        let volume = dayVolume(day)
        let previousVolume = historyStore.isLoaded(weekStart: previousWeek) ? dayVolume(lastWeekDay) : nil
        let weekday = WorkoutSummary.weekdaySymbol(day, calendar: calendar)
        return HStack(alignment: .firstTextBaseline) {
            Text(volume.map { "\(WorkoutLogic.formatVolume($0))kg" } ?? "—")
                .font(.title2.bold().monospacedDigit())
            Spacer()
            Group {
                if let previousVolume,
                   let change = WorkoutSummary.volumeChange(current: volume ?? 0, previous: previousVolume) {
                    Text("前週の\(weekday)比 \(change >= 0 ? "+" : "")\(change)%（\(WorkoutLogic.formatVolume(previousVolume))kg）")
                } else if historyStore.isLoaded(weekStart: previousWeek) {
                    Text("前週の\(weekday)は記録なし")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// その日の総ボリューム (週の総ボリュームと同じ数え方で、その日 (セットの day) のセットだけ)
    private func dayVolume(_ day: Date) -> Double? {
        let week = WorkoutSummary.weekStart(containing: day, calendar: calendar)
        let key = WorkoutSummary.dayKey(day, calendar: calendar)
        let sets = WorkoutSummary.mergeLive(history: historyStore.sets(inWeekStarting: week), live: liveSets)
            .filter { WorkoutSummary.dayKey($0.day, calendar: calendar) == key }
        return WorkoutProgress.value(of: .volume, in: sets)
    }

    /// 曜日×kg を部位で積み上げ。kg のない日 (自重・時間のみ) は 0
    private func chart(_ totals: WeekTotals) -> some View {
        let symbols = WorkoutSummary.weekDays(containing: shownWeek, calendar: calendar).map { WorkoutSummary.weekdaySymbol($0, calendar: calendar) }
        let muscles = Exercise.MuscleGroup.allCases.filter { m in totals.byDayMuscle.contains { $0.muscle == m } }
        let selectedSymbol = selectedDay.map { WorkoutSummary.weekdaySymbol($0, calendar: calendar) }
        return Chart {
            ForEach(totals.byDayMuscle, id: \.self) { entry in
                BarMark(
                    x: .value("曜日", WorkoutSummary.weekdaySymbol(entry.day, calendar: calendar)),
                    y: .value("kg", entry.volume)
                )
                .foregroundStyle(by: .value("部位", entry.muscle.displayName))
                .opacity(selectedDay == nil || selectedDay == entry.day ? 1 : 0.3)
            }
            // 選んだ日以外の列を灰色で覆う (選んだ日の列に色を敷くと、棒が上に伸びたように見えた・10/13 本人)
            if let selectedSymbol {
                ForEach(symbols.filter { $0 != selectedSymbol }, id: \.self) { symbol in
                    RectangleMark(x: .value("曜日", symbol), width: .ratio(1))
                        .foregroundStyle(Color.gray.opacity(0.18))
                }
            }
        }
        .chartXScale(domain: symbols)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    let symbol = value.as(String.self) ?? ""
                    Text(symbol)
                        .fontWeight(symbol == selectedSymbol ? .bold : .regular)
                        .foregroundStyle(symbol == selectedSymbol ? Color.accentColor : .secondary)
                }
            }
        }
        .chartForegroundStyleScale(domain: muscles.map(\.displayName), range: muscles.map { Self.color($0) })
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard let plot = proxy.plotFrame else { return }
                        let x = tap.location.x - geometry[plot].origin.x
                        guard let symbol: String = proxy.value(atX: x),
                              let day = WorkoutSummary.weekDays(containing: shownWeek, calendar: calendar)
                                .first(where: { WorkoutSummary.weekdaySymbol($0, calendar: calendar) == symbol }) else { return }
                        // 同じ日をもう一度タップしたら週の合計に戻す
                        selectedDay = selectedDay == day ? nil : day
                    })
            }
        }
        .frame(height: 180)
    }

    /// 部位ごとの kg (多い順)。日を選んでいればその日、いなければ週の合計
    private func muscleSection(_ totals: WeekTotals) -> some View {
        let entries = totals.byDayMuscle.filter { selectedDay == nil || $0.day == selectedDay }
        let rows = Dictionary(grouping: entries, by: \.muscle)
            .map { (muscle: $0.key, volume: $0.value.reduce(0) { $0 + $1.volume }) }
            .sorted { ($1.volume, $0.muscle.displayName) < ($0.volume, $1.muscle.displayName) }
        return Section {
            if rows.isEmpty {
                Text("この日の記録はありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.muscle) { row in
                HStack {
                    Circle().fill(Self.color(row.muscle)).frame(width: 10, height: 10)
                    Text(row.muscle.displayName)
                    Spacer()
                    // kg のない部位 (自重・時間のみ) は — にする
                    Text(row.volume > 0 ? "\(WorkoutLogic.formatVolume(row.volume))kg" : "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(selectedDay.map { "\(WorkoutSummary.dayLabel($0, calendar: calendar)) の部位別" } ?? "部位別（週の合計）")
        }
    }

    private func totals(_ week: Date, through: Date? = nil) -> WeekTotals {
        let sets = WorkoutSummary.mergeLive(history: historyStore.sets(inWeekStarting: week), live: liveSets)
        return WorkoutSummary.weekTotals(sets: sets, exercisesById: store.exercisesById, week: week, through: through, calendar: calendar)
    }

    /// 開いている日 → その日の記録の store のセット (週の外の日も入るが、weekTotals・dayVolume が日で絞る)
    private var liveSets: [Date: [WorkoutSet]] {
        WorkoutSummary.liveSets(openDays: store.openDays, setsOn: store.sets(on:))
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
