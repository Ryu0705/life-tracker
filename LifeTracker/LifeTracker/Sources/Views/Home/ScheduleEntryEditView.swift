import SwiftUI

/// 1 回分の予定の追加・編集 (段階 1)。繰り返しは編集画面の 1 項目 (曜日のチップ＋祝日も出す。何も選ばなければ繰り返さない)。
/// 保存・削除の分岐は SchedulePlanner (pure)。保存は store を直接呼ぶ (シートに async クロージャで値を渡すと値が壊れた前例があるため)。
/// 段階 2: 下に「実績」欄 (回の日 ≤ 今日のときだけ)。過去日は予定の欄を読むだけ (canEditPlan = false。C-5: 既定値なしの必須引数)。
/// 0012: 「時刻を決める」のオン・オフ (オフ = やること)、「目標の回数」、時刻なしの繰り返しの「終わらなければ翌日にも出す」、
/// 時刻なしの単発の「日付」。回数の欄 (count) の − ＋・スキップは押したときにすぐ書く (一覧の丸と同じ。AI 既定)
struct ScheduleEntryEditView: View {
    @ObservedObject var store: ScheduleStore
    let target: ScheduleEditTarget
    /// 一覧で見ている日 (保存後に読み直す日。前日から続く行を開いたときは target.date と違う)
    let visibleDay: Date
    /// false = 予定の欄は読むだけ (名前・種類・時刻・繰り返し・削除をすべて出さない)。実績欄だけ入力できる。
    /// ただし繰り越し中の繰り返しの回 (target.isCarried) は読むだけでも削除を出す (その回だけ。2026-10-15 本人決定 1)
    let canEditPlan: Bool
    /// 実績欄で扱う回。nil = 実績欄を出さない (明日以降・睡眠の行)
    let checkIn: CheckInSlot?
    /// 回数の欄で扱う回 (時刻なしの回・時刻つきで目標 2 以上の回)。nil = 出さない
    let count: CountSlot?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var categoryId: UUID?
    @State private var startMinutes: Int
    @State private var endMinutes: Int
    @State private var weekdays: Set<ScheduleWeekday>
    @State private var showsOnHoliday: Bool
    /// 時刻を決める (オフ = 時刻なしのやること)
    @State private var isTimed: Bool
    @State private var targetCount: Int
    @State private var carriesOver: Bool
    /// 時刻なしの単発の日 (開いた時点は元の日)
    @State private var singleDay: Date
    @State private var isChangingDate = false
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
    /// 開いた時点の実績の時刻の欄 (0 時からの分)。時刻の無い「やった」(時刻なしの間の記録) は予定の時刻が入る。
    /// 変更ありの判定はこれと比べる (開いただけで「変更あり」にしない。R9)
    private let initialActualStartMinutes: Int
    private let initialActualEndMinutes: Int

    /// 実績欄の状態 (記録なし／やった／スキップ)
    enum ActualChoice: Hashable {
        case none, done, skipped
    }

    init(store: ScheduleStore, target: ScheduleEditTarget, visibleDay: Date, canEditPlan: Bool, checkIn: CheckInSlot?,
         count: CountSlot? = nil) {
        self.store = store
        self.target = target
        self.visibleDay = visibleDay
        self.canEditPlan = canEditPlan
        self.checkIn = checkIn
        self.count = count
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
        initialActualStartMinutes = CheckInPlanner.minutesOfDay(start, calendar: calendar)
        initialActualEndMinutes = CheckInPlanner.minutesOfDay(end, calendar: calendar)
        _actualStartMinutes = State(initialValue: initialActualStartMinutes)
        _actualEndMinutes = State(initialValue: initialActualEndMinutes)
        // 新規の既定: 開いた時刻から一番近いキリのいい時刻 (次の :00 か :30) から 1 時間 (本人指定)・繰り返さない (Google と同じ)・
        // 種類は未選択 (選ぶまで保存できない)
        let input = target.original
        let defaultStart = ScheduleRepeat.defaultStartMinutes(now: Date(), calendar: store.calendar)
        _name = State(initialValue: input?.content.name ?? "")
        _categoryId = State(initialValue: input?.content.categoryId)
        // 時刻なしの予定を時刻ありに切り替えたときの既定は、新規と同じ (次のキリのいい時刻から 1 時間)
        let planStart = input?.content.startMinutes ?? defaultStart
        _startMinutes = State(initialValue: planStart)
        _endMinutes = State(initialValue: ScheduleRepeat.endMinutes(startMinutes: planStart, duration: input?.content.durationMinutes ?? 60))
        _weekdays = State(initialValue: input?.repeatRule.weekdays ?? [])
        _showsOnHoliday = State(initialValue: input?.repeatRule.showsOnHoliday ?? false)
        // 新規の既定は時刻あり (今と同じ)・目標 1・繰り越さない
        _isTimed = State(initialValue: input?.content.timing.isTimed ?? true)
        _targetCount = State(initialValue: input?.content.targetCount ?? 1)
        _carriesOver = State(initialValue: input?.repeatRule.carriesOver ?? false)
        _singleDay = State(initialValue: calendar.startOfDay(for: target.occurrenceDate ?? target.date))
    }

    private var calendar: Calendar { store.calendar }
    private var dayLabel: String { WorkoutSummary.dayLabel(target.date, calendar: calendar) }

    private var duration: Int? {
        ScheduleRepeat.duration(startMinutes: startMinutes, endMinutes: endMinutes)
    }

    private var repeatRule: ScheduleRepeatRule {
        // 繰り越しは時刻なしの繰り返しだけ (時刻つきは常にオフで持つ = 元の入力と比べて「変更あり」にしない)
        ScheduleRepeatRule(weekdays: weekdays, showsOnHoliday: showsOnHoliday, carriesOver: !isTimed && carriesOver)
    }

    /// ジム・睡眠の種類は目標の回数を出さない (1 固定。AI 既定)
    private var usesTargetCount: Bool {
        guard let categoryId else { return true }
        return store.category(categoryId)?.subInputKind == nil
    }

    private var timing: ScheduleTiming? {
        guard isTimed else { return .untimed }
        guard let duration else { return nil }
        return .timed(startMinutes: startMinutes, durationMinutes: duration)
    }

    /// 時刻なしの単発の日の変更 (元の日と同じなら nil)
    private var changedSingleDay: Date? {
        guard !isTimed, !repeatRule.isRepeating else { return nil }
        let original = calendar.startOfDay(for: target.occurrenceDate ?? target.date)
        return singleDay == original ? nil : singleDay
    }

    private var input: ScheduleEntryInput? {
        guard let categoryId, let timing else { return nil }
        return ScheduleEntryInput(
            content: ScheduleContent(name: name, categoryId: categoryId, timing: timing, targetCount: usesTargetCount ? targetCount : 1),
            repeatRule: repeatRule,
            singleDate: changedSingleDay
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
        if count != nil {
            // 回数のある回は時刻だけ (回の行が無い・スキップなら何もしない)。今の回の行の時刻 (無ければ予定の時刻) と比べる
            guard let live = countState?.record, live.status == .done else { return .unchanged }
            let base = countBaselineMinutes(live)
            if actualStartMinutes == base.start && actualEndMinutes == base.end { return .unchanged }
            guard let range = actualRange else { return .invalid }
            return .apply(.set(key: checkIn.key, status: .done, name: task.name, categoryId: task.categoryId,
                               start: range.start, end: range.end))
        }
        switch actualChoice {
        case .none:
            return initialActual == nil ? .unchanged : .apply(.clear(key: checkIn.key))
        case .skipped:
            if initialActual?.status == .skipped { return .unchanged }
            return .apply(.set(key: checkIn.key, status: .skipped, name: task.name, categoryId: task.categoryId,
                               start: nil, end: nil))
        case .done:
            if initialActual?.status == .done, actualStartMinutes == initialActualStartMinutes,
               actualEndMinutes == initialActualEndMinutes {
                return .unchanged
            }
            guard let range = actualRange else { return .invalid }
            return .apply(.set(key: checkIn.key, status: .done, name: task.name, categoryId: task.categoryId,
                               start: range.start, end: range.end))
        }
    }

    /// 回数のある時刻つきの回の、時刻の欄の基準 (回の行の時刻。時刻の無い行は予定の時刻)
    private func countBaselineMinutes(_ record: ActualTask?) -> (start: Int, end: Int) {
        let start = record?.startAt ?? checkIn?.row.task.startAt ?? Date()
        let end = record?.endAt ?? checkIn?.row.task.endAt ?? Date()
        return (CheckInPlanner.minutesOfDay(start, calendar: calendar), CheckInPlanner.minutesOfDay(end, calendar: calendar))
    }

    /// 実績欄の見出し。前日の回 (前日から続く行) なら日付を出す
    private var actualHeader: String {
        guard let checkIn, checkIn.occurrenceDay != calendar.startOfDay(for: target.date) || !canEditPlan && checkIn.row.isSpillover
        else { return "実績" }
        return "実績（\(WorkoutSummary.dayLabel(checkIn.occurrenceDay, calendar: calendar)) の回）"
    }

    private var actualSummary: String {
        guard let range = actualRange else { return "開始と終了を別の時刻にしてください" }
        return CheckInPlanner.actualRangeSummary(range, occurrenceDay: checkIn?.occurrenceDay, calendar: calendar)
    }

    @ViewBuilder
    private func actualSection(_ slot: CheckInSlot) -> some View {
        if count != nil {
            // 目標 2 以上の時刻つきの回: 状態 (記録なし・スキップ) は回数の欄。実績の時刻は回の行がある (1 回以上) ときだけ直せる
            if countState?.record?.status == .done {
                Section {
                    DatePicker("開始", selection: timeBinding($actualStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding($actualEndMinutes), displayedComponents: .hourAndMinute)
                } header: {
                    Text(actualHeader + "の時刻")
                } footer: {
                    Text(actualSummary)
                        .foregroundStyle(actualRange == nil ? Color.red : Color.secondary)
                }
            }
        } else if case .workout(let first, let last, let count)? = slot.workout {
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
            // 状態の選択肢は置かない: 時刻を入れたら「やった」、スキップはボタン、消す・取り消すで記録なしに戻す
            // (本人 2026-10-13。「記録なし」を選ぶ操作と、時刻入力との二重の指定をなくす)
            switch actualChoice {
            case .none:
                Section {
                    Button("実績の時刻を入れる", systemImage: "clock") { actualChoice = .done }
                    Button("スキップにする", systemImage: "forward") { actualChoice = .skipped }
                } header: {
                    Text(actualHeader)
                }
            case .done:
                Section {
                    DatePicker("開始", selection: timeBinding($actualStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding($actualEndMinutes), displayedComponents: .hourAndMinute)
                } header: {
                    Text(actualHeader + "の時刻")
                } footer: {
                    Text(actualSummary)
                        .foregroundStyle(actualRange == nil ? Color.red : Color.secondary)
                }
                Section {
                    Button("実績の時刻を消す", role: .destructive) { actualChoice = .none }
                }
            case .skipped:
                Section {
                    LabeledContent("状態", value: "スキップ")
                    Button("スキップを取り消す") { actualChoice = .none }
                } header: {
                    Text(actualHeader)
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
                LabeledContent("時刻", value: original.content.timing.isTimed ? original.content.timeRangeText : "決めない")
                if original.content.targetCount >= 2 || !original.content.timing.isTimed {
                    LabeledContent("目標の回数", value: "\(original.content.targetCount) 回")
                }
                LabeledContent("繰り返し", value: original.repeatRule.isRepeating
                               ? ScheduleRepeat.summary(days: original.repeatRule.weekdays, holiday: original.repeatRule.showsOnHoliday)
                               : "繰り返さない")
                if let count, count.occurrenceDay < calendar.startOfDay(for: visibleDay) {
                    LabeledContent("回の日", value: "\(WorkoutSummary.dayLabel(count.occurrenceDay, calendar: calendar)) から繰り越し中")
                }
            }
        }
    }

    // MARK: - 回数の欄 (押したときにすぐ書く)

    /// 回数の欄の今の状態 (store の読み込み＋応答前の上書き)。count・スキップ・実績の行
    private var countState: (count: Int, isSkipped: Bool, record: ActualTask?)? {
        guard let count else { return nil }
        if let todo = store.todoDay(visibleDay)?.todos.first(where: { $0.key == count.key }) {
            // スキップの記録がある回は、見ている日が skipped_on より前でも取り消しだけ (R6)
            return (todo.count, todo.isSkipRecorded, todo.record)
        }
        if let checkIn, let day = store.day(visibleDay) {
            switch store.checkInState(for: checkIn.row, in: day) {
            case .progress(let n, _, let record): return (n, false, record)
            case .skipped(let record): return (0, true, record)
            default: return (0, false, nil)
            }
        }
        return nil
    }

    @ViewBuilder
    private func countSection(_ slot: CountSlot, _ state: (count: Int, isSkipped: Bool, record: ActualTask?)) -> some View {
        Section {
            if state.isSkipped {
                LabeledContent("状態", value: state.record?.skippedOn.map { "スキップ（\(TodoRow.shortDate($0, calendar: calendar))）" } ?? "スキップ")
                Button("スキップを取り消す") { record(.unskipCounted(key: slot.key)) }
            } else {
                // − は見ている日以前の最新のタップを消す。＋ は目標を超えても数える
                // 見ている日以前のタップが 0 件なら − は押せない (onDecrement nil)
                Stepper(
                    label: { Text("回数 \(state.count)/\(slot.target)").monospacedDigit() },
                    onIncrement: {
                        record(.tap(key: slot.key, name: slot.name, categoryId: slot.categoryId,
                                    at: CheckInPlanner.tapTime(viewDay: visibleDay, now: Date(), calendar: calendar),
                                    plannedStart: slot.plannedStart, plannedEnd: slot.plannedEnd))
                    },
                    // 時刻つきの回は全部のタップの中で最新を消す (数え方と揃える。日をまたぐ回。R12)。時刻なしは見ている日以前の最新
                    onDecrement: state.count > 0
                        ? { record(.untap(key: slot.key, asOf: slot.isTimed ? Date() : visibleDay)) } : nil
                )
                .disabled(isWorking)
                Button("スキップにする", systemImage: "forward") {
                    record(.skipCounted(key: slot.key, name: slot.name, categoryId: slot.categoryId, on: visibleDay))
                }
                .disabled(isWorking)
            }
        } header: {
            Text(countHeader(slot))
        } footer: {
            if state.count >= slot.target && !state.isSkipped {
                Text("目標に届きました。")
            }
        }
    }

    /// 終わった (目標に届いた・スキップした) 時刻なしの単発か (見ている日の時点)
    private var isClosedSingle: Bool {
        guard case .single = target.kind, target.original?.content.timing.isTimed == false, let state = countState else { return false }
        return state.isSkipped || state.count >= (count?.target ?? 1)
    }

    /// 元の日が今日より前の、終わった時刻なしの単発。時刻ありへは切り替えられない (SQL の単発の検査で拒否される。
    /// 保存して初めてエラーになる形にしないため、トグルを押せなくする。2026-10-14 リード指示)
    private var cannotSwitchToTimed: Bool {
        isClosedSingle && calendar.startOfDay(for: target.occurrenceDate ?? target.date) < calendar.startOfDay(for: Date())
    }

    private func countHeader(_ slot: CountSlot) -> String {
        guard slot.occurrenceDay != calendar.startOfDay(for: visibleDay) else { return "回数" }
        return "回数（\(WorkoutSummary.dayLabel(slot.occurrenceDay, calendar: calendar)) の回）"
    }

    private func record(_ operation: CheckInOperation) {
        Task {
            isWorking = true
            let error = await store.checkIn(operation, reloading: visibleDay)
            isWorking = false
            message = error.map { "記録できませんでした: \($0.localizedDescription)" }
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
                if let count, let state = countState {
                    countSection(count, state)
                }
                if let checkIn {
                    actualSection(checkIn)
                }
                if (canEditPlan || target.isCarried) && !target.isNew {
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
            .onChange(of: countState?.record?.id) {
                // 回数の欄で回の行ができた・消えたら、時刻の欄を今の行 (無ければ予定) に合わせる (前の実績の時刻を残さない。R9)
                guard count != nil else { return }
                let base = countBaselineMinutes(countState?.record)
                actualStartMinutes = base.start
                actualEndMinutes = base.end
            }
            .onChange(of: isTimed) { _, timed in
                // 時刻なしでは睡眠の種類を選べない
                if !timed, let categoryId, store.category(categoryId)?.subInputKind == .sleep { self.categoryId = nil }
            }
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
                // 時刻なしのときは睡眠を外す (睡眠は時刻つきの予定だけ)
                ForEach(store.categories.filter { isTimed || $0.subInputKind != .sleep }) { category in
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
            Toggle("時刻を決める", isOn: $isTimed)
                .disabled(cannotSwitchToTimed && !isTimed)
            if isTimed {
                DatePicker("開始", selection: timeBinding($startMinutes), displayedComponents: .hourAndMinute)
                DatePicker("終了", selection: timeBinding($endMinutes), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("時刻")
        } footer: {
            if isTimed {
                Text(timeSummary)
                    .foregroundStyle(duration == nil ? Color.red : Color.secondary)
            } else if cannotSwitchToTimed {
                Text("終わった単発は時刻を決められません。")
            } else {
                Text("時刻を決めない「やること」になります。一覧の下の「やること」に出ます。")
            }
        }
        if usesTargetCount {
            Section {
                Stepper(value: $targetCount, in: 1...99) {
                    Text("目標の回数 \(targetCount) 回").monospacedDigit()
                }
            } footer: {
                Text(targetCount >= 2 ? "丸を押すたびに 1 回ずつ数えます。" : "1 回やったら完了です。")
            }
        }
        if !isTimed && !repeatRule.isRepeating {
            singleDateSection
        }
        Section {
            WeekdayChips(selection: $weekdays)
            Toggle("祝日も出す", isOn: $showsOnHoliday)
            if !isTimed && repeatRule.isRepeating {
                Toggle("終わらなければ翌日にも出す", isOn: $carriesOver)
            }
        } header: {
            Text("繰り返し")
        } footer: {
            Text(repeatFooter)
        }
    }

    /// 時刻なしの単発の日。繰り越し中は「10/10 から繰り越し中」と「日付を変える」(今日以降)。閉じた単発の日付は変えられない (AI 既定)
    @ViewBuilder
    private var singleDateSection: some View {
        let today = calendar.startOfDay(for: Date())
        let original = calendar.startOfDay(for: target.occurrenceDate ?? target.date)
        let isClosed = isClosedSingle
        Section {
            if isClosed && !target.isNew {
                // 終わった単発は元の日だけ (繰り越さないので「から繰り越し中」・脚注は出さない)
                LabeledContent("日付", value: WorkoutSummary.dayLabel(original, calendar: calendar))
            } else if original < today && !isChangingDate {
                LabeledContent("日付", value: "\(WorkoutSummary.dayLabel(original, calendar: calendar)) から繰り越し中")
                Button("日付を変える") {
                    singleDay = today
                    isChangingDate = true
                }
            } else {
                DatePicker("日付", selection: $singleDay, in: today..., displayedComponents: .date)
            }
        } footer: {
            if !(isClosed && !target.isNew) {
                Text("終わるまで翌日以降にも出ます。")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if canEditPlan || checkIn != nil {
            editingToolbar
        } else {
            // 読むだけ＋回数欄 (繰り越し中の繰り返しの回など): 回数欄はすぐ書くので保存するものが無い
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") { dismiss() }
            }
        }
    }

    @ToolbarContentBuilder
    private var editingToolbar: some ToolbarContent {
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
        // 繰り越し中の回は「これ以降」を出さずその回だけ消すので、単発と同じ問いにする (AI 既定)
        target.isOccurrence && !target.isCarried ? "繰り返しの予定を削除" : "この予定を削除しますか？"
    }

    private var usualText: String {
        guard let usual = target.usual else { return "この日だけ変更済み" }
        if !usual.timing.isTimed { return "この日だけ変更済み（いつもは \(usual.name)・\(usual.targetCount) 回）" }
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
        if !isTimed {
            lines.append(rule.carriesOver ? "終わらなければ翌日以降にも出ます（7 日まで）" : "その日に終わらなければ翌日には出ません")
        }
        if target.isOccurrence, rule != target.original?.repeatRule || isTimed != target.original?.content.timing.isTimed {
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
