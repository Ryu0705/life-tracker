import SwiftUI

/// 種目選択 (Gymwork 型)。部位のチップで絞り込み、複数選んで一度に追加する。選んだ順に番号が付き、その順で並ぶ。
/// 入れ替えモード (カードの ⋮) では 1 つ選んだ時点で確定する
struct ExercisePickerView: View {
    enum Mode {
        /// 追加。プログラムがあれば上部にチップを出し、確認シートで読み込める (プログラム編集からは nil)
        case add(ProgramLoad?)
        /// 未記録カードの種目の入れ替え。同じ部位を初期選択
        case replace(current: Exercise)
    }

    let exercises: [Exercise]
    /// 種目 id → すでに入っている枚数 (今日のカード / 編集中のプログラムの行)。0 より多ければ「追加済み（n）」と出す。
    /// 入っている種目も選べる (同じ種目の 2 枚目・2 行目)。1 回のシートで同じ種目は 1 つまで (2 つ目は開き直す)
    let todayCounts: [UUID: Int]
    let mode: Mode
    let onAdd: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var group: Exercise.MuscleGroup?
    @State private var selected: [UUID] = []
    @State private var programPath: [WorkoutProgram] = []

    init(exercises: [Exercise], todayCounts: [UUID: Int], mode: Mode, onAdd: @escaping ([Exercise]) -> Void) {
        self.exercises = exercises
        self.todayCounts = todayCounts
        self.mode = mode
        self.onAdd = onAdd
        if case .replace(let current) = mode {
            _group = State(initialValue: exercises.contains { $0.muscleGroup == current.muscleGroup } ? current.muscleGroup : nil)
        }
    }

    var body: some View {
        NavigationStack(path: $programPath) {
            List {
                ForEach(filtered) { exercise in
                    Button {
                        if case .replace = mode {
                            onAdd([exercise])
                        } else if let index = selected.firstIndex(of: exercise.id) {
                            selected.remove(at: index)
                        } else {
                            selected.append(exercise.id)
                        }
                    } label: {
                        HStack {
                            Text(exercise.name)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if let index = selected.firstIndex(of: exercise.id) {
                                Text("\(index + 1)")
                                    .font(.callout.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Color.accentColor))
                            } else {
                                Text(todayCounts[exercise.id].map { "追加済み（\($0)）" } ?? exercise.muscleGroup.displayName)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(selected.contains(exercise.id) ? Color.accentColor.opacity(0.12) : nil)
                }
            }
            .overlay {
                if filtered.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if case .add(let load?) = mode, !load.programs.isEmpty {
                        HStack(spacing: 0) {
                            Text("プログラム")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading)
                            ProgramChips(programs: load.programs) { programPath.append($0) }
                        }
                    }
                    groupChips
                }
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    Button {
                        let byId = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
                        onAdd(selected.compactMap { byId[$0] })
                    } label: {
                        Text("\(selected.count)種目を追加")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                    .background(.bar)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "種目名")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .navigationDestination(for: WorkoutProgram.self) { program in
                if case .add(let load?) = mode {
                    // 手で選んでいた種目は捨てず、プログラムの種目の後ろに足す (重なりは追加側のガードで二重に入らない)
                    ProgramLoadSheet(program: program, context: load.context) { ids in
                        load.onLoad(ids + selected.filter { !ids.contains($0) })
                    }
                }
            }
        }
    }

    private var title: String {
        switch mode {
        case .add: return "種目を追加"
        case .replace(let current): return "入れ替え: \(current.name)"
        }
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("すべて", isOn: group == nil) { group = nil }
                ForEach(availableGroups, id: \.self) { g in
                    chip(g.displayName, isOn: group == g) { group = g }
                }
            }
            .padding(.horizontal)
        }
        .background(.bar)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(Capsule().fill(isOn ? Color.primary : Color(.tertiarySystemFill)))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var availableGroups: [Exercise.MuscleGroup] {
        let present = Set(exercises.map(\.muscleGroup))
        return Exercise.MuscleGroup.allCases.filter { present.contains($0) }
    }

    private var filtered: [Exercise] {
        exercises.filter { exercise in
            (group == nil || exercise.muscleGroup == group)
                && (query.isEmpty || exercise.name.localizedCaseInsensitiveContains(query))
        }
    }
}
