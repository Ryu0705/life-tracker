import SwiftUI

/// 予定外の実績 (C6「やったことを記録」) を開く単位
struct ActualEntryTarget: Identifiable, Hashable {
    let id = UUID()
    /// 見ている日 (新規の開始の日)
    let day: Date
    /// nil = 新規
    let actual: ActualTask?
}

/// 予定になかったことの記録・編集 (段階 2 決定 C6)。入力は名前・種類・開始・終了。過去日も記録・削除できる (実績なので)。
/// 保存は store を直接呼ぶ (ScheduleEntryEditView と同じ理由)
struct ActualEntryEditView: View {
    @ObservedObject var store: ScheduleStore
    let target: ActualEntryTarget
    /// 保存後に読み直す日
    let visibleDay: Date

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var categoryId: UUID?
    @State private var startMinutes: Int
    @State private var endMinutes: Int
    @State private var message: String?
    @State private var isWorking = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingDelete = false
    @State private var isNamingCategory = false
    @State private var newCategoryName = ""
    private let initialMinutes: (start: Int, end: Int)

    init(store: ScheduleStore, target: ActualEntryTarget, visibleDay: Date) {
        self.store = store
        self.target = target
        self.visibleDay = visibleDay
        let calendar = store.calendar
        let minutes: (start: Int, end: Int)
        if let actual = target.actual, let start = actual.startAt, let end = actual.endAt {
            minutes = (CheckInPlanner.minutesOfDay(start, calendar: calendar), CheckInPlanner.minutesOfDay(end, calendar: calendar))
        } else {
            minutes = CheckInPlanner.defaultUnplannedMinutes(day: target.day, now: Date(), calendar: calendar)
        }
        initialMinutes = minutes
        _name = State(initialValue: target.actual?.name ?? "")
        _categoryId = State(initialValue: target.actual?.categoryId)
        _startMinutes = State(initialValue: minutes.start)
        _endMinutes = State(initialValue: minutes.end)
    }

    private var calendar: Calendar { store.calendar }

    /// 種類の選択肢。睡眠は睡眠タブで記録するので出さない (DB の actual_save も拒否する)
    private var selectableCategories: [Category] {
        store.categories.filter { $0.subInputKind != .sleep }
    }
    private var dayLabel: String { WorkoutSummary.dayLabel(target.day, calendar: calendar) }

    /// 新規は見ている日のその時刻から。既存は元の開始の近く (0 時をまたぐ記録の日をずらさない)
    private var range: (start: Date, end: Date)? {
        if let original = target.actual?.startAt {
            let start = CheckInPlanner.nearest(minutes: startMinutes, around: original, calendar: calendar)
            return CheckInPlanner.end(minutes: endMinutes, after: start, calendar: calendar).map { (start, $0) }
        }
        return CheckInPlanner.unplannedRange(day: target.day, startMinutes: startMinutes, endMinutes: endMinutes, calendar: calendar)
    }

    private var hasChanges: Bool {
        guard let actual = target.actual else { return !name.isEmpty || categoryId != nil }
        return name != actual.name || categoryId != actual.categoryId
            || startMinutes != initialMinutes.start || endMinutes != initialMinutes.end
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && categoryId != nil && range != nil
            && hasChanges && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("例: 読書", text: $name)
                }
                Section {
                    Picker("種類", selection: $categoryId) {
                        if categoryId == nil { Text("選ぶ").tag(UUID?.none) }
                        ForEach(selectableCategories) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                    Button("新しい種類を作る", systemImage: "plus") {
                        newCategoryName = ""
                        isNamingCategory = true
                    }
                }
                Section {
                    DatePicker("開始", selection: timeBinding($startMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding($endMinutes), displayedComponents: .hourAndMinute)
                } header: {
                    Text("時刻")
                } footer: {
                    Text(summary)
                        .foregroundStyle(range == nil ? Color.red : Color.secondary)
                }
                if target.actual != nil {
                    Section {
                        Button("削除", role: .destructive) { isConfirmingDelete = true }
                            .frame(maxWidth: .infinity)
                    }
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle(target.actual == nil ? "\(dayLabel) にやったこと" : "\(dayLabel) の実績")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
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
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("この記録を削除しますか？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let id = target.actual?.id { run(.deleteActual(id: id)) }
                }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("新しい種類", isPresented: $isNamingCategory) {
                TextField("例: 勉強", text: $newCategoryName)
                Button("作成") { createCategory() }
                Button("キャンセル", role: .cancel) {}
            }
            .task { if !store.isCatalogLoaded { await store.loadCatalog() } }
        }
    }

    private var summary: String {
        guard let range else { return "開始と終了を別の時刻にしてください" }
        let nextDay = calendar.isDate(range.end, inSameDayAs: range.start) ? "" : "（翌日）"
        return "\(ScheduleRepeat.timeText(startMinutes))〜\(ScheduleRepeat.timeText(endMinutes))\(nextDay) · "
            + CheckInPlanner.durationText(range.start, range.end)
    }

    /// 0 時からの分 ↔ 今日のその時刻 (DatePicker は時刻だけを使う)
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        let calendar = self.calendar
        let base = calendar.startOfDay(for: Date())
        return Binding(
            get: { base.addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { date in minutes.wrappedValue = CheckInPlanner.minutesOfDay(date, calendar: calendar) }
        )
    }

    private func save() {
        guard let categoryId, let range else { return }
        run(.saveActual(id: target.actual?.id, name: name, categoryId: categoryId, start: range.start, end: range.end))
    }

    private func run(_ operation: CheckInOperation) {
        Task {
            isWorking = true
            let error = await store.checkIn(operation, reloading: visibleDay)
            isWorking = false
            if let error {
                message = "できませんでした: \(error.localizedDescription)"
            } else {
                dismiss()
            }
        }
    }

    private func createCategory() {
        let name = newCategoryName
        Task {
            switch await store.createCategory(name: name) {
            case .success(let category): categoryId = category.id
            case .failure(let error): message = "種類を作れませんでした: \(error.localizedDescription)"
            }
        }
    }
}
