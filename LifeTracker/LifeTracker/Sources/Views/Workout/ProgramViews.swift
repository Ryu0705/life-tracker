import SwiftUI

/// プログラムの呼び出しに要る周辺情報 (確認シートの種目名・追加済み判定・前回の記録)
struct ProgramContext {
    let exercisesById: [UUID: Exercise]
    /// 種目 id → 今日の画面のカードの枚数 (確認シートの件数判定: k 行目は今日 k 枚以上あれば追加済み)
    let todayCounts: [UUID: Int]
    /// 種目ごとの直近の日のセット (WorkoutSummary.latestDaySets)
    let latestSets: [UUID: [WorkoutSet]]
    /// 前回のかたまりの区切り (「｜」) の順番
    let entriesById: [UUID: WorkoutEntry]
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
/// 読み込んだ種目の行は、既存の前回値の埋め方 (その種目の直近の日) で埋まる。
/// 同じ種目の行は件数で判定する (例: 今日 A が 1 枚・プログラムが A・B・A → 1 行目の A だけ追加済み = E8)
struct ProgramLoadSheet: View {
    let program: WorkoutProgram
    let context: ProgramContext
    let onLoad: ([UUID]) -> Void

    /// チェックを外した行 (プログラム内の位置)
    @State private var excluded: Set<Int> = []

    /// 使える種目の行 (位置, 種目, 追加済みか)
    private var rows: [(offset: Int, exercise: Exercise, isAdded: Bool)] {
        let added = Self.addedFlags(exerciseIds: program.exerciseIds, todayCounts: context.todayCounts)
        return program.exerciseIds.enumerated().compactMap { offset, exerciseId in
            context.exercisesById[exerciseId].map { (offset, $0, added[offset]) }
        }
    }

    /// 件数判定: その種目の k 行目は、今日その種目のカードが k 枚以上あれば追加済み
    static func addedFlags(exerciseIds: [UUID], todayCounts: [UUID: Int]) -> [Bool] {
        var seen: [UUID: Int] = [:]
        return exerciseIds.map { exerciseId in
            seen[exerciseId, default: 0] += 1
            return (todayCounts[exerciseId] ?? 0) >= seen[exerciseId]!
        }
    }

    private var selectedIds: [UUID] {
        rows.filter { !$0.isAdded && !excluded.contains($0.offset) }.map(\.exercise.id)
    }

    var body: some View {
        List {
            ForEach(rows, id: \.offset) { row in
                self.row(row.exercise, offset: row.offset, isAdded: row.isAdded)
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

    private func row(_ exercise: Exercise, offset: Int, isAdded: Bool) -> some View {
        let isOn = !isAdded && !excluded.contains(offset)
        let summary = WorkoutSummary.blocksText(context.latestSets[exercise.id] ?? [], kind: exercise.metricKind,
                                                entriesById: context.entriesById, markWarmup: true)
        return Button {
            if excluded.contains(offset) { excluded.remove(offset) } else { excluded.insert(offset) }
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

/// 「プログラムから選択」: 一覧から選ぶと確認シート (ProgramLoadSheet) へ進む。作成・編集はここでは行わない
struct ProgramChooserView: View {
    let programs: [WorkoutProgram]
    let exercisesById: [UUID: Exercise]

    var body: some View {
        List(programs) { program in
            NavigationLink(value: program) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name)
                    Text(program.exerciseIds.compactMap { exercisesById[$0]?.name }.joined(separator: "・"))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
        }
        .navigationTitle("プログラムから選択")
        .navigationBarTitleDisplayMode(.inline)
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
                    Text("プログラムはまだありません。右上の ＋ か、トレーニング画面の「プログラム」メニューから作れます。")
                } else if programStore.isLoaded {
                    Text("タップで編集、スワイプで削除。読み込みは、トレーニング画面の「プログラムから選択」と種目追加のチップから。")
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
    /// 行ごとの id を持つ (同じ種目を 2 行入れても ForEach の id が重ならない)
    @State private var rows: [ProgramRow]
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
        _rows = State(initialValue: draft.exerciseIds.map { ProgramRow(id: UUID(), exerciseId: $0) })
    }

    struct ProgramRow: Identifiable, Hashable {
        let id: UUID
        let exerciseId: UUID
    }

    private var exerciseIds: [UUID] { rows.map(\.exerciseId) }

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
                    ForEach(rows) { row in
                        HStack {
                            Text(exercisesById[row.exerciseId]?.name ?? "（使われていない種目）")
                            Spacer()
                            Text(exercisesById[row.exerciseId]?.muscleGroup.displayName ?? "")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { rows.remove(atOffsets: $0) }
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
            .onChange(of: rows) { message = nil }
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
                // 入っている種目も選べる (同じ種目を 2 行。例: 最初と最後にベンチ)。入っている数は「追加済み（n）」で示す
                ExercisePickerView(exercises: exercises, todayCounts: WorkoutView.counts(exerciseIds), mode: .add(nil)) { picked in
                    isPicking = false
                    rows += picked.map { ProgramRow(id: UUID(), exerciseId: $0.id) }
                }
            }
        }
    }
}

/// 記録画面の左上「プログラム」: 作成・一覧 (管理) と、今日の種目の保存・上書き。
/// 同じ並びのプログラムがあれば保存は押せず、上書き先も同じ並びのものは押せない。今日が空なら両方押せない (D-1)。
/// 今日の種目は画面順・同じ種目は枚数ぶん (記録画面で並べ替えてから上書きすると、実施した順がプログラムに残る)
struct TodayProgramMenu: View {
    @ObservedObject var programStore: ProgramStore
    let todayIds: [UUID]
    let onNew: () -> Void
    let onList: () -> Void
    let onSaveToday: ([UUID]) -> Void
    let onOverwrite: (WorkoutProgram, [UUID]) -> Void

    var body: some View {
        let same = programStore.program(withSameOrderAs: todayIds)
        Menu {
            Button("新しいプログラムを作成", systemImage: "plus", action: onNew)
            Button("プログラム一覧", systemImage: "list.bullet", action: onList)
            Section("今日の種目（\(Set(todayIds).count)種目）") {
                Button {
                    onSaveToday(todayIds)
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
                                onOverwrite(program, todayIds)
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
}
