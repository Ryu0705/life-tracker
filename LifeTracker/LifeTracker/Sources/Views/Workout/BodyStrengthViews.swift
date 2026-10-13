import SwiftUI

/// 分析の強さページ (docs/analysis-tabs-discussion/40-integration.md §2「強さページ」): 強さ・心肺と、末尾に種目ごとの推移 (全期間)。
/// 期間の状態は分析画面 (AnalysisView) が持つ
struct StrengthPage: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    @ObservedObject var profileStore: ProfileStore
    @Binding var period: StrengthPeriod
    let today: Date
    let calendar: Calendar

    var body: some View {
        List {
            BodyStrengthSections(store: store, historyStore: historyStore, profileStore: profileStore,
                                 period: $period, today: today, calendar: calendar)
            ExerciseProgressSection(store: store, historyStore: historyStore)
        }
    }
}

/// 種目ごとの推移の一覧。期間ナビの対象外 (全期間) なので見出しの右に「全期間」と出す
struct ExerciseProgressSection: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore

    var body: some View {
        if !progressExercises.isEmpty {
            Section {
                ForEach(progressExercises) { exercise in
                    NavigationLink(value: exercise.id) {
                        ProgressExerciseRow(exercise: exercise)
                    }
                }
            } header: {
                HStack {
                    Text("種目ごとの推移")
                    Spacer()
                    Text("全期間")
                }
            }
        }
    }

    /// 推移一覧: 記録がある種目を種目マスタの並び順で (今日初めて記録した種目も含める)
    private var progressExercises: [Exercise] {
        let recorded = historyStore.recordedExerciseIds.union(store.sets.map(\.exerciseId))
        return store.exercises.filter { recorded.contains($0.id) }
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

/// 強さ (人体図・部位の一覧) と心肺 (docs/body-strength-and-heatmap-period.md「画面」1〜3)。
/// 入力は 26 週の先読み＋今日の分 (mergeToday)。期間の週が全部読めるまで級を出さない (A-6)
struct BodyStrengthSections: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    @ObservedObject var profileStore: ProfileStore
    @Binding var period: StrengthPeriod
    let today: Date
    let calendar: Calendar
    var standards: StrengthStandards = .bundled

    @State private var selected: MuscleStrength?
    @State private var sheet: SheetKind?

    private enum SheetKind: String, Identifiable {
        case profile, weight
        var id: String { rawValue }
    }

    var body: some View {
        let interval = period.interval(today: today, calendar: calendar)
        let isLoaded = period.weekStarts(today: today, calendar: calendar).allSatisfy { historyStore.isLoaded(weekStart: $0) }
        let sets = WorkoutSummary.mergeToday(historySets: historyStore.loadedSets, todaySets: store.sets, today: today, calendar: calendar)
        let summary = summary(sets: sets, interval: interval, isLoaded: isLoaded)
        // 見出しなし (ナビバーの「ランク」がページを示す)
        Section {
            PeriodNavigator(label: period.label(today: today, calendar: calendar), currentCaption: "直近\(StrengthPeriod.days)日",
                            isCurrent: period.isRecent, unit: "期間",
                            onOlder: { period = period.older }, onNewer: { period = period.newer })
            // シートは 1 行にだけ付ける (Section に付けると各行に配られて表示が競合する)
            .sheet(item: $selected) { MuscleDetailSheet(muscle: $0, calendar: calendar) }
            .sheet(item: $sheet) { kind in
                switch kind {
                case .profile: ProfileSheet(profileStore: profileStore, today: today, calendar: calendar)
                case .weight: BodyWeightSheet(profileStore: profileStore, today: today, calendar: calendar)
                }
            }
            .task { if !profileStore.isLoaded { await profileStore.load() } }
            // 先読みの 26 週より前に戻ったときはその場で読む
            .task(id: period) { await historyStore.ensureLoaded(weekStarts: period.weekStarts(today: today, calendar: calendar)) }
            profileRow
            if !isLoaded && profileStore.setup == .ready {
                Text("読み込み中…").foregroundStyle(.secondary)
            }
            // 性別はプロフィール (未設定は男性の図)
            BodyDiagramView(states: Dictionary(uniqueKeysWithValues: summary.map { ($0.muscle, $0.state) }),
                            female: profileStore.profile?.sex == .female) { muscle in
                selected = summary.first { $0.muscle == muscle }
            }
            .frame(maxHeight: 300)
            .padding(.vertical, 4)
            .disabled(summary.isEmpty)
            legend
            ForEach(summary) { muscle in
                Button { selected = muscle } label: { MuscleRow(muscle: muscle) }
            }
        }

        Section {
            cardioRow(StrengthLevels.cardioTotals(sets: sets, exercisesById: store.exercisesById, interval: interval), isLoaded: isLoaded)
        } header: {
            // 期間ナビが画面外にスクロールしても、どの期間の合計か読めるように
            HStack {
                Text("心肺")
                Spacer()
                Text(period.label(today: today, calendar: calendar)).monospacedDigit()
            }
        }
    }

    private func summary(sets: [WorkoutSet], interval: (start: Date, end: Date), isLoaded: Bool) -> [MuscleStrength] {
        guard isLoaded, profileStore.setup == .ready, let sex = profileStore.profile?.sex else { return [] }
        return StrengthLevels.summarize(sets: sets, exercisesById: store.exercisesById, standards: standards, sex: sex,
                                        bodyWeights: profileStore.weights, interval: interval, calendar: calendar)
    }

    @ViewBuilder
    private var profileRow: some View {
        if let error = profileStore.error {
            HStack {
                Text("プロフィールを読めませんでした: \(error.localizedDescription)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Spacer()
                Button("再読み込み") { Task { profileStore.error = nil; await profileStore.load() } }
                    .buttonStyle(.borderless)
            }
        } else if !profileStore.isLoaded {
            Text("読み込み中…").foregroundStyle(.secondary)
        } else {
            switch profileStore.setup {
            case .needsProfile:
                Button { sheet = .profile } label: {
                    Label("プロフィールを設定（性別・生年月日・体重）", systemImage: "person.crop.circle.badge.plus")
                }
            case .needsWeight:
                Button { sheet = .profile } label: { Label("体重を入力", systemImage: "scalemass") }
            case .ready:
                HStack {
                    Button { sheet = .weight } label: { weightLabel }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button { sheet = .profile } label: {
                        Image(systemName: "person.crop.circle").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("プロフィールを変更")
                }
            }
        }
    }

    private var weightLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "scalemass")
            if let latest = profileStore.latestWeight {
                Text("\(WorkoutLogic.formatWeight(latest.weightKg))kg").font(.body.monospacedDigit())
                Text(WorkoutSummary.dayLabel(latest.recordedOn, calendar: calendar))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("· 今日の体重を入力").font(.caption).foregroundStyle(Color.accentColor)
        }
        .foregroundStyle(Color.primary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 6 ランクを 3 列 × 2 行 (色だけでは名前が分からないので全部に名前を付ける) ＋ 記録なしの輪郭
    private var legend: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 6) {
            ForEach(StrengthLevels.Rank.allCases, id: \.self) { rank in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(BodyDiagramView.color(rank: rank)).frame(width: 14, height: 10)
                    Text(rank.name)
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.6), lineWidth: 0.5).frame(width: 14, height: 10)
                Text("記録なし")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func cardioRow(_ totals: CardioTotals, isLoaded: Bool) -> some View {
        if !isLoaded {
            Text("読み込み中…").foregroundStyle(.secondary)
        } else if totals.count == 0 {
            Text("この期間の有酸素の記録はありません").foregroundStyle(.secondary)
        } else {
            HStack {
                Text(Self.hoursText(totals.durationSec)).font(.title3.bold().monospacedDigit())
                if totals.distanceM > 0 {
                    Text(WorkoutLogic.formatDistance(totals.distanceM)).font(.title3.monospacedDigit())
                }
                Spacer()
                Text("\(totals.count)回").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    /// "2時間15分" / "45分"
    static func hoursText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
    }

    /// 0〜5 の値の表示 (切り捨てで 1 桁。名前の切り捨てと揃える)
    static func valueText(_ value: Double) -> String {
        String(format: "%.1f", (value * 10).rounded(.down) / 10)
    }
}

/// 一覧の 1 行 (Button の label。static な表示のみ)
private struct MuscleRow: View {
    let muscle: MuscleStrength

    var body: some View {
        HStack {
            Circle().fill(BodyDiagramView.color(muscle.state))
                .overlay(Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
                .frame(width: 10, height: 10)
            Text(muscle.muscle.displayName).foregroundStyle(Color.primary)
            Spacer()
            Text(Self.stateText(muscle))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.secondary)
        }
        .contentShape(Rectangle())
    }

    static func stateText(_ muscle: MuscleStrength) -> String {
        switch muscle.state {
        case .level(let v): return StrengthLevels.rankName(v)
        case .noStandard(let n): return "基準なし \(n)種目"
        case .noRecord: return muscle.exercises.isEmpty ? "記録なし" : "対象外のみ"
        }
    }
}

/// 部位をタップ: 期間内にやった種目と各種目の級・使った記録
struct MuscleDetailSheet: View {
    let muscle: MuscleStrength
    let calendar: Calendar

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle().fill(BodyDiagramView.color(muscle.state))
                            .overlay(Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
                            .frame(width: 12, height: 12)
                        Text(MuscleRow.stateText(muscle)).font(.headline.monospacedDigit())
                        if case .level(let v) = muscle.state {
                            // 元の級 (Strength Level の名前と値) も小さく残す
                            Text("\(StrengthLevels.levelName(v)) \(BodyStrengthSections.valueText(v))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("部位のランクは、種目ごとの最高の級の平均です。")
                }
                if muscle.exercises.isEmpty {
                    Text("この期間の記録はありません").foregroundStyle(.secondary)
                } else {
                    Section("種目") {
                        ForEach(muscle.exercises) { row($0) }
                    }
                }
            }
            .navigationTitle(muscle.muscle.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ entry: ExerciseStrength) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.exercise.name)
                Spacer()
                switch entry.status {
                case .level(let v, _, _):
                    Text(StrengthLevels.rankName(v)).monospacedDigit()
                case .noStandard:
                    Text("基準なし").foregroundStyle(.secondary)
                case .excluded:
                    Text("対象外").foregroundStyle(.secondary)
                }
            }
            if case .level(_, let best, let bodyWeight) = entry.status {
                Text("使った記録: \(WorkoutLogic.summary(of: best, kind: entry.exercise.metricKind))"
                     + (best.completedAt.map { " · \(WorkoutSummary.dayLabel($0, calendar: calendar))" } ?? "")
                     + "（体重 \(WorkoutLogic.formatWeight(bodyWeight))kg）")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let label = entry.label {
                Text(label).font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
