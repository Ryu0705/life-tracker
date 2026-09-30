import SwiftUI

/// プログラムの呼び出しに要る周辺情報 (確認シートの種目名・追加済み判定・前回の記録)
struct ProgramContext {
    let exercisesById: [UUID: Exercise]
    /// 今日すでに画面にある種目 (確認シートで選べない)
    let alreadyAdded: Set<UUID>
    /// 種目ごとの直近の日のセット (WorkoutSummary.latestDaySets)
    let latestSets: [UUID: [WorkoutSet]]
}

/// 種目追加シートからプログラムを呼び出すための一式
struct ProgramLoad {
    let programs: [WorkoutProgram]
    let context: ProgramContext
    let onLoad: ([UUID]) -> Void
}

/// プログラムのチップ行 (横スクロール・登録順)
struct ProgramChips: View {
    let programs: [WorkoutProgram]
    let onSelect: (WorkoutProgram) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(programs) { program in
                    Button { onSelect(program) } label: {
                        // › で「押すと確認画面が開く」ことを示し、その場で絞り込む部位のチップと見分ける
                        HStack(spacing: 4) {
                            Text(program.name)
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.secondary)
                        }
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

/// プログラムの確認: 種目と前回の記録を並べ、外したい種目のチェックを外して読み込む。
/// 読み込んだ種目の行は、既存の前回値の埋め方 (その種目の直近の日) で埋まる
struct ProgramLoadSheet: View {
    let program: WorkoutProgram
    let context: ProgramContext
    let onLoad: ([UUID]) -> Void

    @State private var excluded: Set<UUID> = []

    private var exerciseIds: [UUID] {
        program.exerciseIds.filter { context.exercisesById[$0] != nil }
    }

    private var selectedIds: [UUID] {
        exerciseIds.filter { !context.alreadyAdded.contains($0) && !excluded.contains($0) }
    }

    var body: some View {
        List {
            ForEach(exerciseIds, id: \.self) { exerciseId in
                if let exercise = context.exercisesById[exerciseId] {
                    row(exercise)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onLoad(selectedIds)
            } label: {
                Text("読み込む（\(selectedIds.count)種目）")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIds.isEmpty)
            .padding()
            .background(.bar)
        }
        .navigationTitle(program.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ exercise: Exercise) -> some View {
        let isAdded = context.alreadyAdded.contains(exercise.id)
        let isOn = !isAdded && !excluded.contains(exercise.id)
        let summary = (context.latestSets[exercise.id] ?? [])
            .map { ($0.isWarmup ? "W " : "") + WorkoutLogic.summary(of: $0, kind: exercise.metricKind) }
            .joined(separator: " / ")
        return Button {
            if excluded.contains(exercise.id) { excluded.remove(exercise.id) } else { excluded.insert(exercise.id) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .foregroundStyle(isAdded ? Color.secondary : Color.primary)
                    Text(isAdded ? "追加済み" : (summary.isEmpty ? exercise.muscleGroup.displayName : "前回 \(summary)"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }
}

/// 開く編集画面の中身。新規・編集・今日の種目での保存 / 上書きで共通
struct ProgramDraft: Identifiable {
    let id = UUID()
    let programId: UUID?
    let name: String
    let exerciseIds: [UUID]
    let title: String

    static func new(exerciseIds: [UUID] = []) -> ProgramDraft {
        ProgramDraft(programId: nil, name: "", exerciseIds: exerciseIds, title: "プログラムを作成")
    }

    static func edit(_ program: WorkoutProgram) -> ProgramDraft {
        ProgramDraft(programId: program.id, name: program.name, exerciseIds: program.exerciseIds, title: "プログラムを編集")
    }

    /// 今日の種目で上書き: 名前はそのまま、種目の並びを今日のものにした編集画面。保存で確定する
    static func overwrite(_ program: WorkoutProgram, with exerciseIds: [UUID]) -> ProgramDraft {
        ProgramDraft(programId: program.id, name: program.name, exerciseIds: exerciseIds, title: "今日の種目で上書き")
    }
}

/// プログラムの一覧 (トレーニングの「プログラム」メニューから push)。管理用: 行タップで編集、スワイプで削除。
/// 読み込みはチップ (今日の画面・種目追加) から
struct ProgramListView: View {
    @ObservedObject var programStore: ProgramStore
    let exercises: [Exercise]

    @State private var editing: ProgramDraft?
    @State private var message: String?

    private var exercisesById: [UUID: Exercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    var body: some View {
        List {
            Section {
                ForEach(programStore.programs) { program in
                    Button {
                        editing = .edit(program)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(program.name)
                                    .foregroundStyle(Color.primary)
                                Text(program.exerciseIds.compactMap { exercisesById[$0]?.name }.joined(separator: "・"))
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("削除", role: .destructive) {
                            Task {
                                if let error = await programStore.archive(program) {
                                    message = "削除できませんでした: \(error.localizedDescription)"
                                } else {
                                    message = nil
                                }
                            }
                        }
                    }
                }
            } footer: {
                if let message {
                    Text(message).foregroundStyle(.red)
                } else if programStore.isLoaded && programStore.programs.isEmpty {
                    Text("プログラムはまだありません。右上の ＋ か、トレーニング画面の「プログラム」メニューの「今日の種目を新しいプログラムに保存」から作れます。")
                } else if programStore.isLoaded {
                    Text("タップで編集、スワイプで削除。読み込みは、トレーニング画面と種目追加のチップから。")
                }
            }
        }
        .navigationTitle("プログラム")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = .new()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("プログラムを作成")
            }
        }
        .sheet(item: $editing) { draft in
            ProgramEditView(programStore: programStore, exercises: exercises, draft: draft)
        }
        .task {
            if !programStore.isLoaded { await programStore.load() }
        }
    }
}

/// プログラムの作成・編集 (名前と種目の並び。目標値は持たない＝行は前回の値で埋まる)
struct ProgramEditView: View {
    @ObservedObject var programStore: ProgramStore
    let exercises: [Exercise]
    let draft: ProgramDraft

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var exerciseIds: [UUID]
    @State private var isPicking = false
    @State private var isConfirmingDiscard = false
    /// 通信の失敗だけを出す (入力の不足は保存ボタンを押せなくして示す)。入力が変わったら消す
    @State private var message: String?
    @FocusState private var nameFocused: Bool

    init(programStore: ProgramStore, exercises: [Exercise], draft: ProgramDraft) {
        self.programStore = programStore
        self.exercises = exercises
        self.draft = draft
        _name = State(initialValue: draft.name)
        _exerciseIds = State(initialValue: draft.exerciseIds)
    }

    private var exercisesById: [UUID: Exercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    /// 開いたときから名前か種目の並びが変わっているか (変わっていれば、閉じる前に確認する)
    private var hasChanges: Bool {
        name != draft.name || exerciseIds != draft.exerciseIds
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exerciseIds.isEmpty && !programStore.isSaving
    }

    var body: some View {
        NavigationStack {
            List {
                Section("名前") {
                    TextField("例: 胸の日", text: $name)
                        .focused($nameFocused)
                }
                Section {
                    ForEach(exerciseIds, id: \.self) { exerciseId in
                        HStack {
                            Text(exercisesById[exerciseId]?.name ?? "（使われていない種目）")
                            Spacer()
                            Text(exercisesById[exerciseId]?.muscleGroup.displayName ?? "")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .onMove { exerciseIds.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { exerciseIds.remove(atOffsets: $0) }
                    Button {
                        isPicking = true
                    } label: {
                        Label("種目を追加", systemImage: "plus")
                    }
                } header: {
                    Text("種目（\(exerciseIds.count)）")
                } footer: {
                    if let message {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("≡ で並べ替え、⊖ で外せます。読み込んだときの重量・回数は、その種目の前回の記録から入ります。")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .onChange(of: name) { message = nil }
            .onChange(of: exerciseIds) { message = nil }
            .onAppear {
                if draft.name.isEmpty { nameFocused = true }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        if hasChanges { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog("変更を破棄しますか？", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                        Button("変更を破棄", role: .destructive) { dismiss() }
                        Button("編集を続ける", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if let error = await programStore.save(id: draft.programId, name: name, exerciseIds: exerciseIds) {
                                message = "保存できませんでした: \(error.localizedDescription)"
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $isPicking) {
                ExercisePickerView(exercises: exercises.filter { !exerciseIds.contains($0.id) }, mode: .add(nil)) { picked in
                    isPicking = false
                    exerciseIds += picked.map(\.id)
                }
            }
        }
    }
}
