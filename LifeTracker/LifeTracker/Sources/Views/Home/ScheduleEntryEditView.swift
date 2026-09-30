import SwiftUI

/// 1 回分の予定の追加・編集 (段階 1)。繰り返しは編集画面の 1 項目 (曜日のチップ＋祝日も出す。何も選ばなければ繰り返さない)。
/// 保存・削除の分岐は SchedulePlanner (pure)。保存は store を直接呼ぶ (シートに async クロージャで値を渡すと値が壊れた前例があるため)
struct ScheduleEntryEditView: View {
    @ObservedObject var store: ScheduleStore
    let target: ScheduleEditTarget
    /// 一覧で見ている日 (保存後に読み直す日。前日から続く行を開いたときは target.date と違う)
    let visibleDay: Date

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var categoryId: UUID?
    @State private var startMinutes: Int
    @State private var endMinutes: Int
    @State private var weekdays: Set<ScheduleWeekday>
    @State private var showsOnHoliday: Bool
    @State private var message: String?
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingDelete = false
    /// 保存の確認 (「この予定／これ以降」・繰り返しをやめる)
    @State private var pendingSave: SchedulePlanner.Decision?
    @State private var isNamingCategory = false
    @State private var newCategoryName = ""

    init(store: ScheduleStore, target: ScheduleEditTarget, visibleDay: Date) {
        self.store = store
        self.target = target
        self.visibleDay = visibleDay
        // 新規の既定: 開いた時刻から一番近いキリのいい時刻 (次の :00 か :30) から 1 時間 (本人指定)・繰り返さない (Google と同じ)・
        // 種類は未選択 (選ぶまで保存できない)
        let input = target.original
        let defaultStart = ScheduleRepeat.defaultStartMinutes(now: Date(), calendar: store.calendar)
        _name = State(initialValue: input?.content.name ?? "")
        _categoryId = State(initialValue: input?.content.categoryId)
        _startMinutes = State(initialValue: input?.content.startMinutes ?? defaultStart)
        _endMinutes = State(initialValue: input.map {
            ScheduleRepeat.endMinutes(startMinutes: $0.content.startMinutes, duration: $0.content.durationMinutes)
        } ?? ScheduleRepeat.endMinutes(startMinutes: defaultStart, duration: 60))
        _weekdays = State(initialValue: input?.repeatRule.weekdays ?? [])
        _showsOnHoliday = State(initialValue: input?.repeatRule.showsOnHoliday ?? false)
    }

    private var calendar: Calendar { store.calendar }
    private var dayLabel: String { WorkoutSummary.dayLabel(target.date, calendar: calendar) }

    private var duration: Int? {
        ScheduleRepeat.duration(startMinutes: startMinutes, endMinutes: endMinutes)
    }

    private var repeatRule: ScheduleRepeatRule {
        ScheduleRepeatRule(weekdays: weekdays, showsOnHoliday: showsOnHoliday)
    }

    private var input: ScheduleEntryInput? {
        guard let categoryId, let duration else { return nil }
        return ScheduleEntryInput(
            content: ScheduleContent(name: name, categoryId: categoryId, startMinutes: startMinutes, durationMinutes: duration),
            repeatRule: repeatRule
        )
    }

    /// 閉じる前に確認するか。新規は名前か種類を入れたら「変更あり」
    private var hasChanges: Bool {
        guard let original = target.original else { return !name.isEmpty || categoryId != nil }
        return input != original
    }

    private var canSave: Bool {
        guard input != nil else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isSaving
            && (target.isNew || hasChanges)
    }

    var body: some View {
        NavigationStack {
            Form {
                if target.isOverridden {
                    Section {
                        Text(usualText)
                            .font(.callout)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Section("名前") {
                    TextField("例: 朝の勉強", text: $name)
                }
                Section {
                    Picker("種類", selection: $categoryId) {
                        if categoryId == nil { Text("選ぶ").tag(UUID?.none) }
                        ForEach(store.categories) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                    Button("新しい種類を作る", systemImage: "plus") {
                        newCategoryName = ""
                        isNamingCategory = true
                    }
                } footer: {
                    Text("予実をまとめて見る単位です（例: 「勉強」に PMBOK と資格の勉強をまとめる）。")
                }
                Section {
                    DatePicker("開始", selection: timeBinding($startMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding($endMinutes), displayedComponents: .hourAndMinute)
                } header: {
                    Text("時刻")
                } footer: {
                    Text(timeSummary)
                        .foregroundStyle(duration == nil ? Color.red : Color.secondary)
                }
                Section {
                    WeekdayChips(selection: $weekdays)
                    Toggle("祝日も出す", isOn: $showsOnHoliday)
                } header: {
                    Text("繰り返し")
                } footer: {
                    Text(repeatFooter)
                }
                if !target.isNew {
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(target.isNew ? "\(dayLabel) に追加" : "\(dayLabel) の予定")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        if hasChanges {
                            isConfirmingDiscard = true
                        } else {
                            dismiss()
                        }
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
            // 保存の確認。文言に日付は入れない (本人決定 5。どの日かは題名で分かる)
            .confirmationDialog(saveDialogTitle, isPresented: pendingSaveBinding, titleVisibility: .visible,
                                presenting: pendingSave) { decision in
                switch decision {
                case .chooseScope(let this, let following):
                    Button("この予定") { run(this) }
                    Button("これ以降のすべての予定") { run(following) }
                case .confirmStopRepeating(let operation):
                    Button("繰り返しをやめる", role: .destructive) { run(operation) }
                case .apply, .noChange:
                    EmptyView()
                }
                Button("キャンセル", role: .cancel) {}
            } message: { decision in
                if case .confirmStopRepeating = decision {
                    Text("この日の予定は残ります")
                }
            }
            .confirmationDialog(deleteDialogTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                switch SchedulePlanner.delete(target: target) {
                case .chooseScope(let this, let following):
                    Button("この予定", role: .destructive) { run(this) }
                    Button("これ以降のすべての予定", role: .destructive) { run(following) }
                case .apply(let operation):
                    Button("削除", role: .destructive) { run(operation) }
                case .confirmStopRepeating, .noChange:
                    EmptyView()
                }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("新しい種類", isPresented: $isNamingCategory) {
                TextField("例: 勉強", text: $newCategoryName)
                Button("作成") { createCategory() }
                Button("キャンセル", role: .cancel) {}
            }
            .onChange(of: input) { message = nil }
            .task { if !store.isCatalogLoaded { await store.loadCatalog() } }
        }
    }

    private var pendingSaveBinding: Binding<Bool> {
        Binding(get: { pendingSave != nil }, set: { if !$0 { pendingSave = nil } })
    }

    private var saveDialogTitle: String {
        if case .confirmStopRepeating = pendingSave { return "繰り返しをやめますか？" }
        return "繰り返しの予定を変更"
    }

    private var deleteDialogTitle: String {
        target.isOccurrence ? "繰り返しの予定を削除" : "この予定を削除しますか？"
    }

    private var usualText: String {
        guard let usual = target.usual else { return "この日だけ変更済み" }
        return "この日だけ変更済み（いつもは \(usual.timeRangeText)）"
    }

    private var timeSummary: String {
        guard let duration else { return "開始と終了を別の時刻にしてください" }
        let nextDay = endMinutes <= startMinutes ? "（翌日）" : ""
        let hours = duration / 60, minutes = duration % 60
        let length = [hours > 0 ? "\(hours)時間" : nil, minutes > 0 ? "\(minutes)分" : nil].compactMap { $0 }.joined()
        return "\(ScheduleRepeat.timeText(startMinutes))〜\(ScheduleRepeat.timeText(endMinutes))\(nextDay) · \(length)"
    }

    /// 繰り返し欄の footer: 出る日／これ以降が変わる／この日には出ない (次に出る日)
    private var repeatFooter: String {
        let rule = repeatRule
        guard rule.isRepeating else {
            return target.isOccurrence ? "繰り返しをやめます。この日の予定は残ります。" : "繰り返さない（この日だけ）"
        }
        var lines = ["出る日: " + ScheduleRepeat.summary(days: rule.weekdays, holiday: rule.showsOnHoliday)]
        if target.isOccurrence, rule != target.original?.repeatRule {
            lines.append("これ以降のすべての予定が変わります")
        }
        let isHoliday = store.holidayChecker
        if !ScheduleRepeat.appears(on: target.date, days: rule.weekdays, holiday: rule.showsOnHoliday,
                                   isHoliday: isHoliday, calendar: calendar) {
            if let next = ScheduleRepeat.nextDate(after: target.date, days: rule.weekdays, holiday: rule.showsOnHoliday,
                                                  isHoliday: isHoliday, calendar: calendar) {
                lines.append("\(dayLabel) には出ません。次は \(WorkoutSummary.dayLabel(next, calendar: calendar))")
            } else {
                lines.append("\(dayLabel) には出ません")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 0 時からの分 ↔ 今日のその時刻 (DatePicker は時刻だけを使う)
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        let calendar = self.calendar
        let base = calendar.startOfDay(for: Date())
        return Binding(
            get: { base.addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func save() {
        guard let input else { return }
        if let error = ScheduleStore.validate(input) {
            message = error.localizedDescription
            return
        }
        let decision = SchedulePlanner.save(target: target, input: input)
        switch decision {
        case .apply(let operation): run(operation)
        case .chooseScope, .confirmStopRepeating: pendingSave = decision
        case .noChange: dismiss()
        }
    }

    private func run(_ operation: ScheduleOperation) {
        Task {
            if let error = await store.perform(operation, reloading: visibleDay) {
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

/// 月〜日の丸いチップ。タップで切り替え
private struct WeekdayChips: View {
    @Binding var selection: Set<ScheduleWeekday>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ScheduleWeekday.allCases) { day in
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(day.label)
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(Circle().fill(isOn ? Color.accentColor : Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(day.label)曜日")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
