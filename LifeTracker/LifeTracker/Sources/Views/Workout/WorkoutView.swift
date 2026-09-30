import SwiftUI

/// トレーニングタブのルート。Gymwork 型: 今日の種目をカードで縦に並べ、各カードは「セット | 前回 | 値 | ✓」の行。
/// 行は前回の値で埋まっていて、✓ を押した行だけ記録される。開始・終了の操作は持たない (2026-09-30 本人フィードバック)
struct WorkoutView: View {
    @StateObject private var store: WorkoutSessionStore
    /// 過去日・週帯・分析・プログラムの前回表示用 (読み取り専用)。日付選択の状態は今日の store に持ち込まない
    @StateObject private var historyStore: WorkoutHistoryStore
    /// 自分で組んだプログラム。今日の store とは別に持ち、今日の下書きに触れない
    @StateObject private var programStore: ProgramStore
    /// 継続 (週 N 回基準の連続日数・今週のリング)。ウィジェットへの受け渡しもここから
    @StateObject private var continuity: ContinuityStore
    @State private var isEditingGoal = false
    @State private var path = NavigationPath()
    @State private var picker: PickerRequest?
    /// 週帯で選んだ過去日。nil = 今日 (日付をまたいでも今日を指し続ける)
    @State private var selectedDay: Date?
    /// 今日が空の日の「プログラムから選択」(一覧 → 確認シート)
    @State private var isChoosingProgram = false
    /// 記録・削除の失敗 (種目 id → 文言)。カードの下に出す
    @State private var messages: [UUID: String] = [:]
    @State private var recordedCount = 0
    @State private var restEndsAt: Date?
    /// 休憩の元になったセット (Live Activity と通知の文言)
    @State private var restTitle = ""
    @State private var restFinishedCount = 0
    /// 入力シートで編集中の行
    @State private var editing: DraftTarget?
    /// 次に押す行 (セット完了で 1 つ下へ進む)
    @State private var selectedDraftId: UUID?
    /// 自己ベスト更新などの一時表示
    @State private var toast: String?
    /// 「プログラム」メニューから開く、今日の種目での保存 / 上書きの編集画面
    @State private var programDraft: ProgramDraft?

    /// 休憩の既定秒数 (Gymwork の推奨 3:00 に合わせる)
    static let restSeconds: TimeInterval = 180

    struct DraftTarget: Identifiable, Hashable {
        let exerciseId: UUID
        let draftId: UUID
        var id: UUID { draftId }
    }

    enum PickerRequest: Identifiable {
        case add
        case replace(Exercise)
        var id: String {
            switch self {
            case .add: return "add"
            case .replace(let exercise): return exercise.id.uuidString
            }
        }
    }

    struct AnalysisRoute: Hashable {}
    struct ProgramsRoute: Hashable {}

    private let calendar: Calendar

    init(dataSource: WorkoutDataSource, calendar: Calendar = HomeView.defaultCalendar) {
        self.calendar = calendar
        _store = StateObject(wrappedValue: WorkoutSessionStore(dataSource: dataSource, calendar: calendar))
        _historyStore = StateObject(wrappedValue: WorkoutHistoryStore(dataSource: dataSource, calendar: calendar))
        _programStore = StateObject(wrappedValue: ProgramStore(dataSource: dataSource))
        _continuity = StateObject(wrappedValue: ContinuityStore(dataSource: dataSource, calendar: calendar))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("トレーニング")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        programMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("分析", value: AnalysisRoute())
                    }
                }
                .navigationDestination(for: UUID.self) { exerciseId in
                    if let exercise = store.exercisesById[exerciseId] {
                        ExerciseDetailView(store: store, exercise: exercise)
                    }
                }
                .navigationDestination(for: AnalysisRoute.self) { _ in
                    WeekAnalysisView(store: store, historyStore: historyStore, continuity: continuity, calendar: calendar)
                }
                .navigationDestination(for: ProgramsRoute.self) { _ in
                    ProgramListView(programStore: programStore, exercises: store.exercises)
                }
                .sheet(item: $picker) { request in
                    pickerSheet(request)
                }
                .sheet(isPresented: $isChoosingProgram) {
                    NavigationStack {
                        ProgramChooserView(programs: programStore.programs, exercisesById: store.exercisesById)
                            .navigationDestination(for: WorkoutProgram.self) { program in
                                ProgramLoadSheet(program: program, context: programContext) { ids in
                                    isChoosingProgram = false
                                    loadPlanned(ids)
                                }
                            }
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("閉じる") { isChoosingProgram = false }
                                }
                            }
                    }
                }
                .sheet(isPresented: $isEditingGoal) {
                    WeeklyGoalSheet(continuity: continuity, today: today)
                    .presentationDetents([.medium])
                }
                .sheet(item: $programDraft) { draft in
                    ProgramEditView(programStore: programStore, exercises: store.exercises, draft: draft)
                }
                .sheet(item: $editing) { target in
                    editorSheet(target)
                        .presentationDetents([.height(Self.editorHeight)])
                        .presentationBackgroundInteraction(.enabled(upThrough: .height(Self.editorHeight)))
                        .presentationDragIndicator(.visible)
                }
                .alert("エラー", isPresented: errorBinding) {
                    Button("OK") { store.error = nil; historyStore.error = nil; programStore.error = nil }
                } message: {
                    Text((store.error ?? historyStore.error ?? programStore.error)?.localizedDescription ?? "")
                }
        }
        .task {
            async let staleActivities: Void = RestAlerts.endActivities()
            async let programs: Void = programStore.load()
            async let continuityLoad: Void = continuity.load()
            await store.load()
            await loadHistory()
            await programs
            await continuityLoad
            continuity.share(today: today, recordedToday: !store.sets.isEmpty)
            await staleActivities
        }
        .task(id: displayedWeekStart) { await historyStore.ensureLoaded(weekStarts: [displayedWeekStart]) }
        .onChange(of: store.session?.id) {
            // 日跨ぎ (23:50 → 0:10) で昨日の分をキャッシュから取りこぼさないよう取り直す
            historyStore.invalidate()
            Task {
                await loadHistory()
                await continuity.load()
                continuity.share(today: today, recordedToday: !store.sets.isEmpty)
            }
        }
        // 今日の最初の記録・最後の削除と目標の変更で、ウィジェットの連続日数を更新する
        .onChange(of: store.sets.isEmpty) { continuity.share(today: today, recordedToday: !store.sets.isEmpty) }
        .onChange(of: continuity.goals) { continuity.share(today: today, recordedToday: !store.sets.isEmpty) }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
        .sensoryFeedback(.success, trigger: recordedCount)
        .sensoryFeedback(.impact(weight: .heavy), trigger: restFinishedCount)
        .onChange(of: restEndsAt) { old, new in
            // 最後まで進んで nil になったときは、届く通知を消さない (スキップ・±15・✓ のときだけ差し替える)
            if new == nil, let old, old <= Date() {
                Task { await RestAlerts.finish() }
            } else {
                Task { await RestAlerts.sync(endsAt: new, title: restTitle) }
            }
        }
        .task(id: restEndsAt) {
            guard let end = restEndsAt else { return }
            let remaining = end.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled, restEndsAt == end else { return }
            restFinishedCount += 1
            restEndsAt = nil
        }
    }

    /// 今日 / 過去日の切替。週帯＋合計バー (上) と休憩バー (下) は切替の外に置き、過去日を見ている間も休憩バーと下書きを残す
    private var content: some View {
        ZStack {
            if store.isLoading && store.exercises.isEmpty {
                ProgressView("読み込み中…")
            } else if let selectedDay {
                PastDayView(sets: historyStore.sets(on: selectedDay), exercisesById: store.exercisesById,
                            isLoaded: historyStore.isLoaded(weekStart: displayedWeekStart),
                            onOpenExercise: { path.append($0) })
            } else {
                todayList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 自己ベストのトーストは記録一覧の上端 (＝合計バーのすぐ下) に出す。ツールバーの「プログラム」「分析」を隠さない。タップで消せる
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "trophy.fill")
                    .font(.callout.bold())
                    .foregroundStyle(Color.primary, Color.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.thinMaterial))
                    .padding(.top, 8)
                    .padding(.horizontal)
                    .onTapGesture { self.toast = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: toast)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if continuity.isLoaded {
                    ContinuityRow(status: continuity.status(today: today, recordedToday: !store.sets.isEmpty)) {
                        isEditingGoal = true
                    }
                }
                WeekStripView(selectedDay: displayedDay, today: today, recordedDays: recordedDays, calendar: calendar,
                              onSelect: select, onShiftWeek: { select(WorkoutSummary.shiftWeek(selected: displayedDay, by: $0, today: today, calendar: calendar)) })
                DaySummaryBar(day: displayedDay, isToday: selectedDay == nil, totals: WorkoutSummary.dayTotals(displayedSets),
                              calendar: calendar, onBackToToday: { selectedDay = nil })
                Divider()
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            if let restEndsAt {
                RestTimerBar(endsAt: restEndsAt) { self.restEndsAt = $0 }
            }
        }
    }

    private var todayList: some View {
        List {
            ForEach(store.todayExerciseIds, id: \.self) { exerciseId in
                if let exercise = store.exercisesById[exerciseId] {
                    exerciseCard(exercise)
                }
            }

            // 今日が空の日だけ出す (種目が入ったら種目追加シートのチップから読み込む)。作成・編集は左上の「プログラム」から。
            // 0 件でも押せないボタンとして出し、作り方を footer で示す
            if store.todayExerciseIds.isEmpty && programStore.isLoaded {
                Section {
                    Button {
                        isChoosingProgram = true
                    } label: {
                        // List 内の disabled は文字が黒くなるだけでアイコンは青のまま残るため、押せないときは全体を灰色にする
                        Label("プログラムから選択", systemImage: "list.bullet.rectangle")
                            .foregroundStyle(programStore.programs.isEmpty ? Color.secondary : Color.accentColor)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(programStore.programs.isEmpty)
                } footer: {
                    if programStore.programs.isEmpty {
                        Text("プログラムは左上の「プログラム」から作れます。")
                    }
                }
            }

            Section {
                Button {
                    picker = .add
                } label: {
                    Label("種目を追加", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
            } footer: {
                if store.todayExerciseIds.isEmpty {
                    Text("種目を追加すると、前回の重量・回数が入った行が並びます。✓ を押した行が記録されます。")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await store.load()
            historyStore.invalidate()
            await loadHistory()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { Self.dismissKeyboard() }
            }
        }
    }

    private func exerciseCard(_ exercise: Exercise) -> some View {
        let completed = store.sets(for: exercise.id)
        let drafts = store.drafts[exercise.id] ?? []
        let columns = SetColumn.columns(for: exercise)
        let numbers = Self.setNumbers(warmups: completed.map(\.isWarmup) + drafts.map(\.input.isWarmup))

        return Section {
            SetHeaderRow(columns: columns)
            ForEach(Array(completed.enumerated()), id: \.element.id) { position, set in
                CompletedSetRow(
                    label: numbers[position],
                    previous: previousSummary(exercise, position: position),
                    set: set,
                    columns: columns
                )
                .swipeActions(allowsFullSwipe: false) {
                    Button("削除", role: .destructive) {
                        Task {
                            if let error = await store.deleteSet(set) {
                                messages[exercise.id] = "削除できませんでした: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
            ForEach(Array(drafts.enumerated()), id: \.element.id) { offset, draft in
                let position = completed.count + offset
                DraftSetRow(
                    label: numbers[position],
                    previous: previousSummary(exercise, position: position),
                    input: draft.input,
                    columns: columns,
                    isSelected: selectedDraftId == draft.id || editing?.draftId == draft.id,
                    isWriting: store.isWriting,
                    onEdit: { editing = DraftTarget(exerciseId: exercise.id, draftId: draft.id) },
                    onComplete: { Task { await complete(exercise, draftId: draft.id) } }
                )
                .swipeActions(allowsFullSwipe: false) {
                    Button("削除", role: .destructive) {
                        store.removeDraft(exerciseId: exercise.id, draftId: draft.id)
                    }
                }
            }
            Button {
                store.addDraft(exerciseId: exercise.id)
            } label: {
                Label("セットを追加", systemImage: "plus")
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
        } header: {
            HStack {
                Button {
                    path.append(exercise.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(exercise.name)
                                .font(.headline)
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.caption)
                        }
                        if let headline = WorkoutSummary.cardHeadline(kind: exercise.metricKind, todaySets: completed,
                                                                      previousSets: store.previousDay(for: exercise.id)?.sets ?? []) {
                            Text(headline)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
                Spacer()
                // 記録済みのカードではできることが無いので ⋮ 自体を出さない
                if completed.isEmpty {
                    Menu {
                        Button("種目を入れ替え", systemImage: "arrow.left.arrow.right") { picker = .replace(exercise) }
                        Button("今日から外す", systemImage: "minus.circle", role: .destructive) { store.removePlannedExercise(exercise.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(exercise.name)のメニュー")
                }
            }
            .textCase(nil)
        } footer: {
            if let message = messages[exercise.id] {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func pickerSheet(_ request: PickerRequest) -> some View {
        let candidates = store.exercises.filter { !store.todayExerciseIds.contains($0.id) }
        switch request {
        case .add:
            ExercisePickerView(exercises: candidates, mode: .add(ProgramLoad(programs: programStore.programs, context: programContext) { ids in
                picker = nil
                loadPlanned(ids)
            })) { picked in
                picker = nil
                loadPlanned(picked.map(\.id))
            }
        case .replace(let current):
            ExercisePickerView(exercises: candidates, mode: .replace(current: current)) { picked in
                picker = nil
                guard let replacement = picked.first else { return }
                Task { await store.replacePlannedExercise(current.id, with: replacement.id) }
            }
        }
    }

    /// 左上「プログラム」: 作成・一覧 (管理) と、今日の種目の保存・上書き。
    /// 同じ並びのプログラムがあれば保存は押せず、上書き先も同じ並びのものは押せない。今日が空なら両方押せない (D-1)
    private var programMenu: some View {
        let todayIds = store.todayExerciseIds
        let same = programStore.program(withSameOrderAs: todayIds)
        return Menu {
            Button("新しいプログラムを作成", systemImage: "plus") { programDraft = .new() }
            Button("プログラム一覧", systemImage: "list.bullet") { path.append(ProgramsRoute()) }
            Section("今日の種目（\(todayIds.count)種目）") {
                Button {
                    programDraft = .new(exerciseIds: todayIds)
                } label: {
                    Label("今日の種目を新しいプログラムに保存", systemImage: "square.and.arrow.down")
                    if let same { Text("「\(same.name)」と同じ内容です") }
                }
                .disabled(todayIds.isEmpty || same != nil)
                // メニューの入れ子には .disabled が効かないため、押せないときは押せないボタンとして出す
                if todayIds.isEmpty || programStore.programs.isEmpty {
                    Button("今日の種目で上書き", systemImage: "arrow.triangle.2.circlepath") {}
                        .disabled(true)
                } else {
                    Menu {
                        ForEach(programStore.programs) { program in
                            Button {
                                programDraft = .overwrite(program, with: todayIds)
                            } label: {
                                Text(program.name)
                                if program.exerciseIds == todayIds { Text("今日と同じ内容です") }
                            }
                            .disabled(program.exerciseIds == todayIds)
                        }
                    } label: {
                        Label("今日の種目で上書き", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        } label: {
            Text("プログラム")
        }
    }

    private func loadPlanned(_ exerciseIds: [UUID]) {
        Task {
            for exerciseId in exerciseIds { await store.addPlannedExercise(exerciseId) }
        }
    }

    // MARK: 日付・履歴 (過去日は historyStore から。今日の分は常に今日の store)

    private var today: Date { WorkoutSummary.dayKey(Date(), calendar: calendar) }
    private var displayedDay: Date { selectedDay ?? today }
    private var displayedWeekStart: Date { WorkoutSummary.weekStart(containing: displayedDay, calendar: calendar) }
    private var displayedSets: [WorkoutSet] { selectedDay.map { historyStore.sets(on: $0) } ?? store.sets }

    private var recordedDays: Set<Date> {
        historyStore.recordedDays.subtracting([today]).union(store.sets.isEmpty ? [] : [today])
    }

    private var programContext: ProgramContext {
        ProgramContext(exercisesById: store.exercisesById, alreadyAdded: Set(store.todayExerciseIds),
                       latestSets: WorkoutSummary.latestDaySets(historyStore.loadedSets, today: today, calendar: calendar))
    }

    private func select(_ day: Date) {
        guard WorkoutSummary.isSelectable(day: day, today: today, calendar: calendar) else { return }
        selectedDay = calendar.isDate(day, inSameDayAs: today) ? nil : WorkoutSummary.dayKey(day, calendar: calendar)
    }

    /// 表示中の週と、プログラムの確認シートの前回表示用に 28 日前まで (= 5 週)
    private func loadHistory() async {
        await historyStore.ensureLoaded(weekStarts: WorkoutSummary.recentWeekStarts(today: today, count: 5, calendar: calendar) + [displayedWeekStart])
    }

    private static let editorHeight: CGFloat = 400

    @ViewBuilder
    private func editorSheet(_ target: DraftTarget) -> some View {
        if let exercise = store.exercisesById[target.exerciseId] {
            let rows = store.drafts[target.exerciseId] ?? []
            let number = Self.setNumbers(warmups: store.sets(for: target.exerciseId).map(\.isWarmup) + rows.map(\.input.isWarmup))
            let position = store.sets(for: target.exerciseId).count + (rows.firstIndex { $0.id == target.draftId } ?? 0)
            SetEditorSheet(
                title: "\(exercise.name)  セット\(number.indices.contains(position) ? number[position] : "")",
                columns: SetColumn.columns(for: exercise),
                input: Binding(
                    get: { rows.first { $0.id == target.draftId }?.input ?? WorkoutSetInput() },
                    set: { store.updateDraft(exerciseId: target.exerciseId, draftId: target.draftId, input: $0) }
                ),
                isWriting: store.isWriting,
                message: messages[target.exerciseId],
                restEndsAt: restEndsAt,
                onApplyToRemaining: { store.applyToRemaining(exerciseId: target.exerciseId, from: target.draftId) },
                onComplete: { Task { await complete(exercise, draftId: target.draftId) } }
            )
        }
    }

    private func complete(_ exercise: Exercise, draftId: UUID) async {
        Self.dismissKeyboard()
        let rows = store.drafts[exercise.id] ?? []
        // 同じカードの次の行。カードの最後なら、下に続く種目の最初の未保存の行へ進む
        let next = rows.firstIndex { $0.id == draftId }.flatMap { rows.indices.contains($0 + 1) ? rows[$0 + 1].id : nil }
            ?? store.todayExerciseIds.drop { $0 != exercise.id }.dropFirst().lazy.compactMap { store.drafts[$0]?.first?.id }.first
        let bestBefore = [store.bestOneRMBeforeToday(exerciseId: exercise.id),
                          WorkoutProgress.bestOneRM(store.sets(for: exercise.id))].compactMap { $0 }.max()
        switch await store.completeDraft(exercise: exercise, draftId: draftId) {
        case .success(let set):
            messages[exercise.id] = nil
            recordedCount += 1
            editing = nil
            selectedDraftId = next
            let setCount = store.sets(for: exercise.id).filter { !$0.isWarmup }.count
            restTitle = set.isWarmup ? "\(exercise.name) ウォームアップ" : "\(exercise.name) セット\(setCount)"
            restEndsAt = Date().addingTimeInterval(Self.restSeconds)
            if let bestBefore, let newBest = WorkoutProgress.bestOneRM([set]), newBest > bestBefore + 0.001 {
                toast = "\(exercise.name) 推定1RM 自己ベスト \(ProgressMetric.estimatedOneRM.format(newBest))"
            }
        case .failure(let error as WorkoutSetInput.ValidationError):
            messages[exercise.id] = Self.validationMessage(for: error)
        case .failure(WorkoutSessionStore.StoreError.busy):
            break
        case .failure(let error):
            messages[exercise.id] = "記録できませんでした: \(error.localizedDescription)"
        }
    }

    private func previousSummary(_ exercise: Exercise, position: Int) -> String? {
        store.previousSet(for: exercise.id, position: position).map {
            ($0.isWarmup ? "W " : "") + WorkoutLogic.summary(of: $0, kind: exercise.metricKind)
        }
    }

    /// セット番号: ウォームアップは「W」、本番セットは 1 から数える
    static func setNumbers(warmups: [Bool]) -> [String] {
        var count = 0
        return warmups.map { isWarmup in
            if isWarmup { return "W" }
            count += 1
            return "\(count)"
        }
    }

    static func validationMessage(for error: WorkoutSetInput.ValidationError) -> String {
        switch error {
        case .missingWeight: return "重量を入れてください"
        case .missingReps: return "回数を入れてください"
        case .missingDuration: return "時間を入れてください"
        case .negativeValue: return "マイナスの値は記録できません"
        }
    }

    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { (store.error ?? historyStore.error ?? programStore.error) != nil },
                set: { if !$0 { store.error = nil; historyStore.error = nil; programStore.error = nil } })
    }
}
