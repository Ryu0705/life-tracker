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
    /// 記録・削除の失敗 (カード id → 文言)。カードの下に出す
    @State private var messages: [UUID: String] = [:]
    @State private var recordedCount = 0
    @State private var restEndsAt: Date?
    /// 休憩の元になったセット (Live Activity と通知の文言)
    @State private var restTitle = ""
    /// 休憩を動かしたセット。そのセットの ✓ を取り消したら休憩も止める
    @State private var restSetId: UUID?
    @State private var restFinishedCount = 0
    /// 入力シートで編集中の行 (未保存の行 / 記録済みの行)
    @State private var editing: EditorTarget?
    /// 次に押す行 (セット完了で 1 つ下へ進む)
    @State private var selectedDraftId: UUID?
    /// 自己ベスト更新などの一時表示
    @State private var toast: String?
    /// 「プログラム」メニューから開く、今日の種目での保存 / 上書きの編集画面
    @State private var programDraft: ProgramDraft?
    /// 各カードの ⋮ →「種目を並べ替え」
    @State private var isReordering = false

    /// 休憩の既定秒数 (Gymwork の推奨 3:00 に合わせる)
    static let restSeconds: TimeInterval = 180

    enum EditorTarget: Identifiable, Hashable {
        case draft(cardId: UUID, draftId: UUID)
        case completed(cardId: UUID, setId: UUID)

        var id: UUID {
            switch self {
            case .draft(_, let draftId): return draftId
            case .completed(_, let setId): return setId
            }
        }
    }

    enum PickerRequest: Identifiable {
        case add
        case replace(TodayCard, Exercise)
        var id: String {
            switch self {
            case .add: return "add"
            case .replace(let card, _): return card.id.uuidString
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
                .sheet(isPresented: $isReordering) {
                    ReorderSheet(store: store)
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
                PastDayView(sets: historyStore.sets(on: selectedDay), entries: historyStore.entries(on: selectedDay),
                            exercisesById: store.exercisesById,
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
                WeekStripView(selectedDay: displayedDay, today: today, allowsFuture: false, recordedDays: recordedDays, calendar: calendar,
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
            ForEach(store.cards) { card in
                if let exercise = store.exercisesById[card.exerciseId] {
                    exerciseCard(card, exercise)
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

    private func exerciseCard(_ card: TodayCard, _ exercise: Exercise) -> some View {
        TodayExerciseCard(
            store: store, card: card, exercise: exercise, editing: editing, selectedDraftId: selectedDraftId,
            message: messages[card.id],
            onEdit: { editing = $0 },
            onUndo: { set in Task { await undo(card, set: set) } },
            onDelete: { set in
                Task {
                    if let error = await store.deleteSet(set) {
                        messages[card.id] = "削除できませんでした: \(error.localizedDescription)"
                    } else if editing == .completed(cardId: card.id, setId: set.id) {
                        editing = nil
                    }
                }
            },
            onComplete: { draftId in Task { await complete(card, exercise, draftId: draftId) } },
            onOpenExercise: { path.append(exercise.id) },
            onReplace: { picker = .replace(card, exercise) },
            onReorder: { isReordering = true }
        )
    }

    @ViewBuilder
    private func pickerSheet(_ request: PickerRequest) -> some View {
        // 今日にある種目も選べる (2 枚目になる)。入れ替えは自分自身だけ候補から外す (E11)
        let counts = Self.counts(store.todayExerciseIds)
        switch request {
        case .add:
            ExercisePickerView(exercises: store.exercises, todayCounts: counts,
                               mode: .add(ProgramLoad(programs: programStore.programs, context: programContext) { ids in
                picker = nil
                loadPlanned(ids)
            })) { picked in
                picker = nil
                loadPlanned(picked.map(\.id))
            }
        case .replace(let card, let current):
            ExercisePickerView(exercises: store.exercises.filter { $0.id != current.id }, todayCounts: counts,
                               mode: .replace(current: current)) { picked in
                picker = nil
                guard let replacement = picked.first else { return }
                Task { await store.replacePlannedCard(card, with: replacement.id) }
            }
        }
    }

    /// 左上「プログラム」(ProgramViews.swift の TodayProgramMenu)
    private var programMenu: some View {
        TodayProgramMenu(programStore: programStore, todayIds: store.todayExerciseIds,
                         onNew: { programDraft = .new() }, onList: { path.append(ProgramsRoute()) },
                         onSaveToday: { programDraft = .new(exerciseIds: $0) },
                         onOverwrite: { programDraft = .overwrite($0, with: $1) })
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
        ProgramContext(exercisesById: store.exercisesById, todayCounts: Self.counts(store.todayExerciseIds),
                       latestSets: WorkoutSummary.latestDaySets(historyStore.loadedSets, today: today, calendar: calendar),
                       entriesById: historyStore.entriesById)
    }

    /// 種目 id → 今日のカードの枚数 (「追加済み（n）」とプログラムの件数判定)
    static func counts(_ exerciseIds: [UUID]) -> [UUID: Int] {
        exerciseIds.reduce(into: [:]) { $0[$1, default: 0] += 1 }
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
    private func editorSheet(_ target: EditorTarget) -> some View {
        switch target {
        case .draft(let cardId, let draftId):
            draftEditorSheet(cardId: cardId, draftId: draftId)
        case .completed(let cardId, let setId):
            // 取り消し・削除で行が無くなったら何も出さない (それぞれの操作でシートも閉じる)
            if let card = store.card(id: cardId), let exercise = store.exercisesById[card.exerciseId],
               let set = store.sets.first(where: { $0.id == setId }) {
                let completed = store.sets(for: card)
                let rows = store.drafts[cardId] ?? []
                let number = Self.setNumbers(warmups: completed.map(\.isWarmup) + rows.map(\.input.isWarmup))
                let position = completed.firstIndex { $0.id == setId } ?? 0
                CompletedSetEditor(
                    title: "\(exercise.name)  セット\(number.indices.contains(position) ? number[position] : "")",
                    columns: SetColumn.columns(for: exercise),
                    initial: WorkoutLogic.input(from: set, keepWarmup: true),
                    isWriting: store.isWriting,
                    message: messages[cardId],
                    restEndsAt: restEndsAt,
                    onSave: { input in Task { await save(card, exercise, set: set, input: input) } }
                )
                .id(setId)
            }
        }
    }

    @ViewBuilder
    private func draftEditorSheet(cardId: UUID, draftId: UUID) -> some View {
        if let card = store.card(id: cardId), let exercise = store.exercisesById[card.exerciseId] {
            let rows = store.drafts[cardId] ?? []
            let number = Self.setNumbers(warmups: store.sets(for: card).map(\.isWarmup) + rows.map(\.input.isWarmup))
            let position = store.sets(for: card).count + (rows.firstIndex { $0.id == draftId } ?? 0)
            SetEditorSheet(
                title: "\(exercise.name)  セット\(number.indices.contains(position) ? number[position] : "")",
                columns: SetColumn.columns(for: exercise),
                input: Binding(
                    get: { rows.first { $0.id == draftId }?.input ?? WorkoutSetInput() },
                    set: { store.updateDraft(cardId: cardId, draftId: draftId, input: $0) }
                ),
                isWriting: store.isWriting,
                message: messages[cardId],
                restEndsAt: restEndsAt,
                onApplyToRemaining: { store.applyToRemaining(cardId: cardId, from: draftId) },
                onComplete: { Task { await complete(card, exercise, draftId: draftId) } }
            )
        }
    }

    /// 記録済みの行の編集を保存する。completed_at・set_index と休憩タイマーはそのまま
    private func save(_ card: TodayCard, _ exercise: Exercise, set: WorkoutSet, input: WorkoutSetInput) async {
        Self.dismissKeyboard()
        switch await store.updateSet(set, exercise: exercise, input: input) {
        case .success:
            messages[card.id] = nil
            editing = nil
        case .failure(let error as WorkoutSetInput.ValidationError):
            messages[card.id] = Self.validationMessage(for: error)
        case .failure(WorkoutSessionStore.StoreError.busy):
            break
        case .failure(let error):
            messages[card.id] = "保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// 緑の ✓ の取り消し: 未保存の行の先頭に戻して選択する。そのセットが動かしていた休憩は止める
    private func undo(_ card: TodayCard, set: WorkoutSet) async {
        switch await store.undoSet(set) {
        case .success(let draftId):
            messages[card.id] = nil
            if restSetId == set.id {
                restEndsAt = nil
                restSetId = nil
            }
            if editing == .completed(cardId: card.id, setId: set.id) { editing = nil }
            selectedDraftId = draftId
        case .failure(WorkoutSessionStore.StoreError.busy):
            break
        case .failure(let error):
            messages[card.id] = "取り消せませんでした: \(error.localizedDescription)"
        }
    }

    private func complete(_ card: TodayCard, _ exercise: Exercise, draftId: UUID) async {
        Self.dismissKeyboard()
        let rows = store.drafts[card.id] ?? []
        // 同じカードの次の行。カードの最後なら、下に続くカードの最初の未保存の行へ進む
        let next = rows.firstIndex { $0.id == draftId }.flatMap { rows.indices.contains($0 + 1) ? rows[$0 + 1].id : nil }
            ?? store.cards.drop { $0.id != card.id }.dropFirst().lazy.compactMap { store.drafts[$0.id]?.first?.id }.first
        let bestBefore = [store.bestOneRMBeforeToday(exerciseId: exercise.id),
                          WorkoutProgress.bestOneRM(store.sets(for: exercise.id))].compactMap { $0 }.max()
        switch await store.completeDraft(card: card, exercise: exercise, draftId: draftId) {
        case .success(let set):
            messages[card.id] = nil
            recordedCount += 1
            editing = nil
            selectedDraftId = next
            // 番号はカードごとに 1 から (題名は種目名だけ。2 枚目でも「（2回目）」は付けない = Q4)
            let setCount = store.card(id: card.id).map { store.sets(for: $0).filter { !$0.isWarmup }.count } ?? 0
            restTitle = set.isWarmup ? "\(exercise.name) ウォームアップ" : "\(exercise.name) セット\(setCount)"
            restEndsAt = Date().addingTimeInterval(Self.restSeconds)
            restSetId = set.id
            if let bestBefore, let newBest = WorkoutProgress.bestOneRM([set]), newBest > bestBefore + 0.001 {
                toast = "\(exercise.name) 推定1RM 自己ベスト \(ProgressMetric.estimatedOneRM.format(newBest))"
            }
        case .failure(let error as WorkoutSetInput.ValidationError):
            messages[card.id] = Self.validationMessage(for: error)
        case .failure(WorkoutSessionStore.StoreError.busy):
            break
        case .failure(let error):
            messages[card.id] = "記録できませんでした: \(error.localizedDescription)"
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { (store.error ?? historyStore.error ?? programStore.error) != nil },
                set: { if !$0 { store.error = nil; historyStore.error = nil; programStore.error = nil } })
    }
}
