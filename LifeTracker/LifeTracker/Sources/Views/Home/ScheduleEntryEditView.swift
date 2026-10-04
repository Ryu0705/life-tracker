import SwiftUI

/// 1 回分の予定の追加・編集 (段階 1)。繰り返しは編集画面の 1 項目 (曜日のチップ＋祝日も出す。何も選ばなければ繰り返さない)。
/// 保存・削除の分岐は SchedulePlanner (pure)。保存は store を直接呼ぶ (シートに async クロージャで値を渡すと値が壊れた前例があるため)。
/// 段階 2: 下に「実績」欄 (回の日 ≤ 今日のときだけ)。過去日は予定の欄を読むだけ (canEditPlan = false。C-5: 既定値なしの必須引数)
struct ScheduleEntryEditView: View {
    @ObservedObject var store: ScheduleStore
    let target: ScheduleEditTarget
    /// 一覧で見ている日 (保存後に読み直す日。前日から続く行を開いたときは target.date と違う)
    let visibleDay: Date
    /// false = 予定の欄は読むだけ (名前・種類・時刻・繰り返し・削除をすべて出さない)。実績欄だけ入力できる
    let canEditPlan: Bool
    /// 実績欄で扱う回。nil = 実績欄を出さない (明日以降・睡眠の行)
    let checkIn: CheckInSlot?

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
    /// 実績欄の入力 (開いた時点の実績から)
    @State private var actualChoice: ActualChoice
    @State private var actualStartMinutes: Int
    @State private var actualEndMinutes: Int
    @State private var isWorking = false
    private let initialActual: ActualTask?

    /// 実績欄の状態 (記録なし／やった／スキップ)
    enum ActualChoice: Hashable {
        case none, done, skipped
    }

    init(store: ScheduleStore, target: ScheduleEditTarget, visibleDay: Date, canEditPlan: Bool, checkIn: CheckInSlot?) {
        self.store = store
        self.target = target
        self.visibleDay = visibleDay
        self.canEditPlan = canEditPlan
        self.checkIn = checkIn
        let calendar = store.calendar
        let state = checkIn.flatMap { slot in store.day(visibleDay).map { store.checkInState(for: slot.row, in: $0) } } ?? .none
        let record = state.record
        initialActual = record
        let choice: ActualChoice = switch record?.status {
        case .done?: .done
        case .skipped?: .skipped
        case nil: .none
        }
        _actualChoice = State(initialValue: choice)
        // 時刻は実績があればそれ、無ければ予定どおり (「予定の時刻が入った状態から直す」)
        let start = record?.startAt ?? checkIn?.row.task.startAt ?? Date()
        let end = record?.endAt ?? checkIn?.row.task.endAt ?? Date()
        _actualStartMinutes = State(initialValue: CheckInPlanner.minutesOfDay(start, calendar: calendar))
        _actualEndMinutes = State(initialValue: CheckInPlanner.minutesOfDay(end, calendar: calendar))
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

    /// 予定の欄の変更。新規は名前か種類を入れたら「変更あり」
    private var hasPlanChanges: Bool {
        guard canEditPlan else { return false }
        guard let original = target.original else { return !name.isEmpty || categoryId != nil }
        return input != original
    }

    /// 閉じる前に確認するか
    private var hasChanges: Bool {
        hasPlanChanges || actualChange != .unchanged
    }

    private var canSavePlan: Bool {
        guard input != nil else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (target.isNew || hasPlanChanges)
    }

    private var canSave: Bool {
        guard !store.isSaving, !isWorking else { return false }
        if case .invalid = actualChange { return false }
        if hasPlanChanges { return canSavePlan }
        if target.isNew { return canSavePlan }
        return actualChange != .unchanged
    }

    // MARK: - 実績欄

    private enum ActualChange: Equatable {
        case unchanged
        case invalid
        case apply(CheckInOperation)
    }

    /// やったの時刻 (開始は予定の開始の ±12 時間で最も近い時刻、終了は開始の後。レビュー §3-2)
    private var actualRange: (start: Date, end: Date)? {
        guard let checkIn else { return nil }
        return CheckInPlanner.occurrenceRange(startMinutes: actualStartMinutes, endMinutes: actualEndMinutes,
                                              plannedStart: checkIn.row.task.startAt, calendar: calendar)
    }

    private var actualChange: ActualChange {
        guard let checkIn, checkIn.workout == nil else { return .unchanged }
        let task = checkIn.row.task
        switch actualChoice {
        case .none:
            return initialActual == nil ? .unchanged : .apply(.clear(key: checkIn.key))
        case .skipped:
            if initialActual?.status == .skipped { return .unchanged }
            return .apply(.set(key: checkIn.key, status: .skipped, name: task.name, categoryId: task.categoryId,
                               start: nil, end: nil))
        case .done:
            guard let range = actualRange else { return .invalid }
            if let initial = initialActual, initial.status == .done, initial.startAt == range.start, initial.endAt == range.end {
                return .unchanged
            }
            return .apply(.set(key: checkIn.key, status: .done, name: task.name, categoryId: task.categoryId,
                               start: range.start, end: range.end))
        }
    }

    /// 実績欄の見出し。前日の回 (前日から続く行) なら日付を出す
    private var actualHeader: String {
        guard let checkIn, checkIn.occurrenceDay != calendar.startOfDay(for: target.date) || !canEditPlan && checkIn.row.isSpillover
        else { return "実績" }
        return "実績（\(WorkoutSummary.dayLabel(checkIn.occurrenceDay, calendar: calendar)) の回）"
    }

    private var actualSummary: String {
        guard let range = actualRange else { return "開始と終了を別の時刻にしてください" }
        let startDay = calendar.startOfDay(for: range.start)
        let dayNote = startDay == checkIn.map({ $0.occurrenceDay }) ? "" : "\(WorkoutSummary.dayLabel(startDay, calendar: calendar)) "
        let nextDay = calendar.isDate(range.end, inSameDayAs: range.start) ? "" : "（翌日）"
        return "\(dayNote)\(ScheduleRepeat.timeText(actualStartMinutes))〜\(ScheduleRepeat.timeText(actualEndMinutes))\(nextDay) · "
            + CheckInPlanner.durationText(range.start, range.end)
    }

    @ViewBuilder
    private func actualSection(_ slot: CheckInSlot) -> some View {
        if case .workout(let first, let last, let count)? = slot.workout {
            // セットのあるジム: トレーニング記録が正 (実績の行は書かない。決定 C4)
            Section {
                LabeledContent("状態", value: "やった（トレーニング）")
                if count >= 2 {
                    LabeledContent("時刻", value: CheckInPlanner.rangeText(first, last, calendar: calendar))
                }
                LabeledContent("セット", value: "\(count)")
            } header: {
                Text(actualHeader)
            } footer: {
                Text("トレーニングの記録から自動で「やった」になります。")
            }
        } else {
            Section {
                Picker("状態", selection: $actualChoice) {
                    Text("記録なし").tag(ActualChoice.none)
                    Text("やった").tag(ActualChoice.done)
                    Text("スキップ").tag(ActualChoice.skipped)
                }
                .pickerStyle(.segmented)
                if actualChoice == .done {
                    DatePicker("開始", selection: timeBinding($actualStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding($actualEndMinutes), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text(actualHeader)
            } footer: {
                if actualChoice == .done {
                    Text(actualSummary)
                        .foregroundStyle(actualRange == nil ? Color.red : Color.secondary)
                }
            }
        }
    }

    /// 予定の欄を読むだけ (過去日)
    @ViewBuilder
    private var readOnlyPlanSection: some View {
        if let original = target.original {
            Section("予定") {
                LabeledContent("名前", value: original.content.name)
                LabeledContent("種類", value: store.categoryName(original.content.categoryId) ?? "")
                LabeledContent("時刻", value: original.content.timeRangeText)
                LabeledContent("繰り返し", value: original.repeatRule.isRepeating
                               ? ScheduleRepeat.summary(days: original.repeatRule.weekdays, holiday: original.repeatRule.showsOnHoliday)
                               : "繰り返さない")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !canEditPlan {
                    readOnlyPlanSection
                }
                if canEditPlan && target.isOverridden {
                    Section {
                        Text(usualText)
                            .font(.callout)
                            .foregroundStyle(Color.secondary)
                    }
                }
                if canEditPlan {
                    planSections
                }
                if let checkIn {
                    actualSection(checkIn)
                }
                if canEditPlan && !target.isNew {
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
            .toolbar { toolbarContent }
            .modifier(dialogs)
            .onChange(of: input) { message = nil }
            .onChange(of: actualChoice) { message = nil }
            .task { if !store.isCatalogLoaded { await store.loadCatalog() } }
        }
    }

    /// 予定の欄 (名前・種類・時刻・繰り返し)
    @ViewBuilder
    private var planSections: some View {
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
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    private var dialogs: EntryDialogs {
        EntryDialogs(view: self)
    }

    /// 保存・削除の確認と種類の作成 (body を型検査できる大きさに保つため分けた)
    fileprivate struct EntryDialogs: ViewModifier {
        let view: ScheduleEntryEditView

        func body(content: Content) -> some View {
            view.applyDialogs(to: content)
        }
    }

    fileprivate func applyDialogs<Content: View>(to content: Content) -> some View {
        content
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

    /// 実績を先に書き、続けて予定の変更 (あれば。確認が要るものはダイアログ)
    private func save() {
        var planInput: ScheduleEntryInput?
        if hasPlanChanges || target.isNew {
            guard let input else { return }
            if let error = ScheduleStore.validate(input) {
                message = error.localizedDescription
                return
            }
            planInput = input
        }
        let change = actualChange
        Task {
            if case .apply(let operation) = change {
                isWorking = true
                let error = await store.checkIn(operation, reloading: visibleDay)
                isWorking = false
                if let error {
                    message = "実績を保存できませんでした: \(error.localizedDescription)"
                    return
                }
            }
            guard let planInput else {
                dismiss()
                return
            }
            let decision = SchedulePlanner.save(target: target, input: planInput)
            switch decision {
            case .apply(let operation): run(operation)
            case .chooseScope, .confirmStopRepeating: pendingSave = decision
            case .noChange: dismiss()
            }
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
