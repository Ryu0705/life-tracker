import SwiftUI
import HolidayJp

/// 「予定」タブのルート (段階 1・2)。上部に週帯＋日付バー (トレーニングと同じ並び)。過去・未来の日へ移れる。
/// 今日・未来は行をタップで編集・左スワイプで削除。過去日の予定は読むだけ。
/// 段階 2: 過去日・今日の回は右端の丸で「やった」、右スワイプで「スキップ」、行を開いて実績欄で時刻を直す。
/// 2026-10-14 本人指示: 丸は右端・大きく。時刻つきで目標 1 の記録なしの丸は、押すと実績の時刻のシート (ActualTimeSheet)。
/// 右上 ＋ は今日 = 「予定を追加」「やったことを記録」、明日以降 = 予定の追加、過去日 = やったことを記録。
/// 睡眠の行は sleep_record の実績を表示するだけ (丸・実績欄なし。記録は睡眠タブ。「睡眠（確定仕様）」)
/// 時刻つきの一覧の下に「やること」(時刻なしの回) の節。丸は常に +1 (目標 1 で済みなら取り消す)、右スワイプでスキップ、
/// 繰り越し中は「10/10 から」。目標 2 以上の時刻つきの回は「1/3」の丸 (docs/untimed-tasks-implementation-plan.md 2-5)
/// 行の長押しでメニュー (完了にする・完了を取り消す・スキップ・削除。目標 2 以上は 1回追加・1回取り消す。中身は丸・スワイプと同じ操作。2026-10-14 本人指示)
/// 仕様: docs/day-cycle-walkthrough.md「段階 1 確定仕様」「段階 2 確定仕様」
struct HomeView: View {
    @EnvironmentObject private var clockTick: ClockTick
    @StateObject private var store: ScheduleStore
    /// 週帯で選んだ日。nil = 今日 (日付をまたいでも今日を指し続ける。トレーニングと同じ持ち方)
    @State private var selectedDay: Date?
    @State private var sheet: ScheduleSheet?
    /// スワイプ削除で「この予定／これ以降」を選ばせている繰り返しの回
    @State private var pendingDelete: ScheduleEditTarget?

    private let calendar: Calendar

    init(dataSource: DayDataSource, scheduleSource: ScheduleDataSource, calendar: Calendar = HomeView.defaultCalendar,
         holidayChecker: ((Date) -> Bool)? = nil) {
        self.calendar = calendar
        let checker = holidayChecker ?? { HolidayJp.isHoliday($0, calendar: calendar) }
        _store = StateObject(wrappedValue: ScheduleStore(dayDataSource: dataSource, dataSource: scheduleSource,
                                                         calendar: calendar, holidayChecker: checker))
    }

    private var today: Date { calendar.startOfDay(for: clockTick.now) }
    private var displayedDay: Date { selectedDay.map { calendar.startOfDay(for: $0) } ?? today }
    private var isToday: Bool { displayedDay == today }
    private var canEdit: Bool { store.canEditSchedule(on: displayedDay, today: today) }

    var body: some View {
        NavigationStack {
            ZStack {
                list
                CheckInActionLayer()
            }
            .navigationTitle("予定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addButton
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    WeekStripView(selectedDay: displayedDay, today: today, allowsFuture: true, recordedDays: [], calendar: calendar,
                                  onSelect: select,
                                  onShiftWeek: { select(calendar.date(byAdding: .day, value: 7 * $0, to: displayedDay)!) })
                    ScheduleDateBar(day: displayedDay, isToday: isToday, isHoliday: store.holidayChecker(displayedDay),
                                    calendar: calendar, onBackToToday: { selectedDay = nil })
                    Divider()
                }
                .background(.bar)
            }
        }
        .task(id: displayedDay) { await store.ensureLoaded(displayedDay) }
        // タブに戻ったら見ている日以外のキャッシュを捨てて見ている日を読み直す (トレーニングのセット・睡眠タブの記録を出す。V-7)
        .onAppear { Task { await store.refresh(displayedDay) } }
        .onChange(of: displayedDay) {
            store.listMessage = nil
            // 日を移ったら、やることの並びを組み直す (本人決定「再描画までは、行を元の位置に残す。」)
            store.releaseTodoOrder()
        }
        // 保存は store を直接渡して呼ぶ (シートに async クロージャで値を渡すと値が壊れた前例があるため)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .plan(let target, let checkIn, let canEditPlan, let count):
                ScheduleEntryEditView(store: store, target: target, visibleDay: displayedDay, canEditPlan: canEditPlan, checkIn: checkIn,
                                      count: count)
            case .actual(let target):
                ActualEntryEditView(store: store, target: target, visibleDay: displayedDay)
            case .actualTime(let target):
                ActualTimeSheet(store: store, target: target)
            }
        }
        .confirmationDialog("繰り返しの予定を削除", isPresented: pendingDeleteBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { target in
            if case .chooseScope(let this, let following) = SchedulePlanner.delete(target: target) {
                Button("この予定", role: .destructive) { run(this) }
                Button("これ以降のすべての予定", role: .destructive) { run(following) }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    /// 右上 ＋ (3 分岐。段階 2 決定 C6)
    @ViewBuilder
    private var addButton: some View {
        let newPlan = { sheet = .plan(ScheduleEditTarget(date: displayedDay, kind: .new, original: nil, usual: nil),
                                      checkIn: nil, canEditPlan: true, count: nil) }
        let newActual = { sheet = .actual(ActualEntryTarget(day: displayedDay, actual: nil)) }
        if isToday {
            Menu {
                Button("予定を追加", systemImage: "calendar.badge.plus", action: newPlan)
                Button("やったことを記録", systemImage: "checkmark.circle", action: newActual)
            } label: {
                Label("追加", systemImage: "plus")
            }
        } else if canEdit {
            Button("予定を追加", systemImage: "plus", action: newPlan)
        } else {
            Button("やったことを記録", systemImage: "plus", action: newActual)
        }
    }

    private func select(_ day: Date) {
        let key = calendar.startOfDay(for: day)
        selectedDay = key == today ? nil : key
    }

    @ViewBuilder
    private var list: some View {
        let day = store.day(displayedDay)
        List {
            // 「現在進行中」は今日だけ (UI U-5)
            if isToday, let day {
                Section {
                    CurrentBlockCard(currentBlock: day.currentBlock(at: clockTick.now))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                if let day {
                    let items = store.listItems(day)
                    // やることだけがある日は「予定はありません」を出さない
                    if items.isEmpty && (store.todoDay(displayedDay)?.todos.isEmpty ?? true) {
                        Text(canEdit ? "予定はありません。右上の ＋ で追加します。" : "この日の予定はありません。右上の ＋ でやったことを記録できます。")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .planned(let row): self.row(row, day: day)
                        case .unplanned(let actual): unplannedRow(actual)
                        }
                    }
                } else if let error = store.dayErrors[displayedDay] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("読み込みに失敗しました").font(.headline)
                        Text(error).font(.callout).foregroundStyle(Color.secondary)
                        Button("再試行") { Task { await store.reload(displayedDay) } }
                    }
                } else {
                    ProgressView("読み込み中…")
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if store.holidayChecker(displayedDay) {
                        Text("祝日は「祝日も出す」を入れた予定だけが出ます。")
                    }
                    if let message = store.listMessage {
                        Text(message).foregroundStyle(Color.red)
                    }
                }
            }
            if store.day(displayedDay) != nil {
                todoSection
            }
        }
        .refreshable { await store.reload(displayedDay) }
    }

    /// 「やること」の節 (時刻なしが 1 件も無い日は出さない。AI 既定)
    @ViewBuilder
    private var todoSection: some View {
        let todoDay = store.todoDay(displayedDay)
        if let todoDay, !todoDay.todos.isEmpty || !todoDay.olderOpen.isEmpty {
            Section {
                ForEach(todoDay.todos) { todo in
                    todoRow(todo)
                }
            } header: {
                Text("やること")
            } footer: {
                if !todoDay.olderOpen.isEmpty {
                    // 押せない文字 (AI 既定)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(todoDay.olderOpen, id: \.templateId) { older in
                            Text("\(older.name): ほか \(older.count) 回（\(TodoBuilder.carryDays) 日より前）")
                        }
                    }
                }
            }
        } else if todoDay == nil, let error = store.todoErrors[displayedDay] {
            Section("やること") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("読み込みに失敗しました").font(.headline)
                    Text(error).font(.callout).foregroundStyle(Color.secondary)
                    Button("再試行") { Task { await store.reload(displayedDay) } }
                }
            }
        }
    }

    /// やることの 1 行: 名前・2 行目・右端の丸 (目標 1 は今の丸、2 以上は「3/8」)。過去日・今日だけ丸と回数の記録ができる
    @ViewBuilder
    private func todoRow(_ todo: DayTodo) -> some View {
        let opened = SchedulePlanner.todoTarget(for: todo, viewDay: displayedDay, today: today, catalog: store.catalog, calendar: calendar)
        let recordable = displayedDay <= today
        // スキップの記録がある回は見ている日に依らずスキップの丸 (押すと取り消し。R6)
        let style: CheckInCircleStyle = todo.isSkipRecorded ? .skipped
            : todo.target >= 2 ? .progress(count: todo.count, target: todo.target) : (todo.isDone ? .done : .empty)
        HStack(spacing: 8) {
            Button {
                sheet = .plan(opened.target, checkIn: nil, canEditPlan: opened.canEditPlan,
                              count: recordable ? CountSlot(todo: todo) : nil)
            } label: {
                TodoRow(todo: todo, categoryName: store.categoryName(todo.categoryId), viewDay: displayedDay, calendar: calendar)
            }
            .buttonStyle(.plain)
            if recordable {
                CheckInCircle(style: style) { checkIn(circleOperation(todo)) }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if recordable {
                Button {
                    checkIn(todo.isSkipRecorded ? .unskipCounted(key: todo.key)
                            : .skipCounted(key: todo.key, name: todo.name, categoryId: todo.categoryId, on: displayedDay))
                } label: {
                    todo.isSkipRecorded
                        ? Label("スキップを取り消す", systemImage: "arrow.uturn.backward")
                        : Label("スキップ", systemImage: "forward.end")
                }
                .tint(todo.isSkipRecorded ? .gray : .orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 削除は編集画面が開く行と、繰り越し中の繰り返しの回 (その回だけ。2026-10-15 本人決定 1)。過去日の行は出さない
            if opened.canDelete {
                Button { delete(opened.target) } label: { Label("削除", systemImage: "trash") }
                    .tint(.red)
            }
        }
        .contextMenu {
            rowMenu(recordable ? CheckInPlanner.menu(todo: todo, viewDay: displayedDay, tapAt: clockTick.now) : .empty,
                    freshDone: {
                        CheckInPlanner.menu(todo: todo, viewDay: displayedDay,
                                            tapAt: CheckInPlanner.tapTime(viewDay: displayedDay, now: clockTick.now, calendar: calendar)).done
                    },
                    onDone: { if case .apply(let operation) = $0 { checkIn(operation) } },
                    delete: opened.canDelete ? opened.target : nil,
                    blockedReason: opened.canDelete ? nil
                        : SchedulePlanner.deleteBlockedReason(viewDay: displayedDay, spilloverFrom: nil, today: today, calendar: calendar))
        }
    }

    /// やることの丸: 常に +1。目標 1 で済みなら取り消す (V 以前の最新のタップを消す)。スキップした回は取り消す
    private func circleOperation(_ todo: DayTodo) -> CheckInOperation {
        if todo.isSkipRecorded { return .unskipCounted(key: todo.key) }
        if todo.target < 2 && todo.isDone { return .untap(key: todo.key, asOf: displayedDay) }
        return .tap(key: todo.key, name: todo.name, categoryId: todo.categoryId,
                    at: CheckInPlanner.tapTime(viewDay: displayedDay, now: clockTick.now, calendar: calendar),
                    plannedStart: nil, plannedEnd: nil)
    }

    @ViewBuilder
    private func row(_ item: DayScheduledTask, day: Day) -> some View {
        let now = clockTick.now
        let category = store.category(item.task.categoryId)
        let target = store.editTarget(for: item, viewDay: displayedDay, today: today)
        let state = store.checkInState(for: item, in: day)
        let style = CheckInPlanner.circleStyle(row: item, state: state, category: category, today: today, calendar: calendar)
        let isSleep = category?.subInputKind == .sleep
        // 実績欄の回: 前日から続く行は前日の回 (丸と同じ回)。睡眠の行は実績欄なし (acceptsActual が false)
        let slot = CheckInPlanner.acceptsActual(for: item, category: category, now: now, calendar: calendar)
            ? CheckInSlot(row: item, category: category, state: state, calendar: calendar) : nil
        // 目標 2 以上の回は実績欄に回数の − ＋ (時刻つき。ジム・睡眠は 1 固定)
        let target2 = CheckInPlanner.targetCount(for: item, category: category)
        let count = slot != nil && target2 >= 2 ? CountSlot(row: item, target: target2, calendar: calendar) : nil
        // 今日・未来は予定の編集 (＋実績欄)。過去の回は予定を読むだけ＋実績欄
        let opened: ScheduleSheet? = target.map { .plan($0, checkIn: slot, canEditPlan: true, count: count) }
            ?? slot.map { .plan(SchedulePlanner.readOnlyTarget(for: item, catalog: store.catalog, calendar: calendar),
                                checkIn: $0, canEditPlan: false, count: count) }
        // 押せる丸・押せない丸 (セットのあるジム) を右端に出す行。睡眠 (.hidden) は何も出さない
        let circle = style.flatMap { $0 == .hidden ? nil : $0 }
        let content = ScheduleRow(
            item: item,
            categoryName: category?.name,
            isEditable: opened != nil,
            isPastTime: isToday && item.task.endAt <= now,
            actualLine: isSleep ? store.sleepLine(for: item, in: day)
                : CheckInPlanner.actualLine(row: item, state: state, category: category, now: now, calendar: calendar),
            isSkipped: state.isSkipped,
            calendar: calendar
        )
        HStack(spacing: 8) {
            if let opened {
                Button { sheet = opened } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
            if let circle {
                CheckInCircle(style: circle) {
                    let tapAt = CheckInPlanner.tapTime(viewDay: displayedDay, now: now, calendar: calendar)
                    if let tap = CheckInPlanner.circleTap(row: item, state: state, calendar: calendar, tapAt: tapAt) {
                        circleTap(tap, row: item, category: category, state: state)
                    }
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // スキップ (丸を出す回だけ。セットのあるジムは出さない)
            if let style, style != .hidden,
               let operation = CheckInPlanner.skip(row: item, state: state, calendar: calendar, skipOn: displayedDay) {
                Button { checkIn(operation) } label: {
                    state.isSkipped
                        ? Label("スキップを取り消す", systemImage: "arrow.uturn.backward")
                        : Label("スキップ", systemImage: "forward.end")
                }
                .tint(state.isSkipped ? .gray : .orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 削除は今日・未来の回だけ。前日から続く行では出さない (どの回を消すかが曖昧になるため)
            if let target, !item.isSpillover {
                // role: .destructive は確認の前に行が消える動きになるため、色だけ赤にする
                Button { delete(target) } label: { Label("削除", systemImage: "trash") }
                    .tint(.red)
            }
        }
        .contextMenu {
            let menu = { (tapAt: Date) in
                CheckInPlanner.menu(row: item, state: state, style: style, calendar: calendar, tapAt: tapAt, now: now,
                                    skipOn: displayedDay)
            }
            rowMenu(menu(now),
                    freshDone: { menu(CheckInPlanner.tapTime(viewDay: displayedDay, now: now, calendar: calendar)).done },
                    onDone: { circleTap($0, row: item, category: category, state: state) },
                    delete: item.isSpillover ? nil : target,
                    blockedReason: target != nil && !item.isSpillover ? nil
                        : SchedulePlanner.deleteBlockedReason(viewDay: displayedDay, spilloverFrom: item.isSpillover ? item.task.startAt : nil,
                                                              today: today, calendar: calendar))
        }
    }

    /// 丸 (と長押しの「完了にする」「1回追加」) を押したとき
    private func circleTap(_ tap: CheckInPlanner.CircleTap, row item: DayScheduledTask, category: Category?, state: CheckInState) {
        switch tap {
        case .askActualTime:
            // 記録なしの丸: 実績の時刻を聞く (予定の時刻が入った状態)。丸と同じ回 (前日から続く行は前日の回)
            sheet = .actualTime(ActualTimeTarget(slot: CheckInSlot(row: item, category: category, state: state, calendar: calendar),
                                                 visibleDay: displayedDay))
        case .apply(let operation):
            checkIn(operation)
        }
    }

    /// 行の長押しのメニュー (並びは本人の指示: 完了・取り消し・スキップ・削除)。言葉は AI 既定 (2026-10-14 本人「メニューの各ラベルは
    /// 私の伝えた通りになっているけど、説明しただけで、UI上もそのラベルが良いとは思っていない。適したものに変更して。」): 目標 1 は
    /// 完了にする / 完了を取り消す、目標 2 以上は 1回追加 / 1回取り消す (丸の「2/3」が 1 ずつ動く)。取り消し系の 3 つは同じ矢印
    /// (同時には出ない)。出す項目は描くときに決め、完了にするの操作は押したときに作り直す (+1 のタップの id を押すたびに新しくする。
    /// 同じ id は 1 回しか数えない。R5)。消せない予定の行は、削除を灰色にして 2 行目に理由を出す (2026-10-15 本人決定 2・3)
    @ViewBuilder
    private func rowMenu(_ menu: CheckInMenu, freshDone: @escaping () -> CheckInPlanner.CircleTap?,
                         onDone: @escaping (CheckInPlanner.CircleTap) -> Void, delete target: ScheduleEditTarget?,
                         blockedReason: String?) -> some View {
        if menu.done != nil {
            Button(menu.isCounted ? "1回追加" : "完了にする", systemImage: menu.isCounted ? "plus.circle" : "checkmark.circle") {
                if let done = freshDone() { onDone(done) }
            }
        }
        if let undone = menu.undone {
            Button(menu.isCounted ? "1回取り消す" : "完了を取り消す", systemImage: "arrow.uturn.backward") { checkIn(undone) }
        }
        if let skip = menu.skip {
            Button(menu.isSkipped ? "スキップを取り消す" : "スキップ",
                   systemImage: menu.isSkipped ? "arrow.uturn.backward" : "forward.end") { checkIn(skip) }
        }
        if let target {
            Button("削除", systemImage: "trash", role: .destructive) { delete(target) }
        } else if let blockedReason {
            // メニューの Button は 1 つめの Text を題、2 つめを下の小さな行にする
            Button {} label: {
                Text("削除")
                Text(blockedReason)
                Image(systemName: "trash")
            }
            .disabled(true)
        }
    }

    /// 予定外の実績の行: 右端の丸は塗り・押せない。タップで編集、左スワイプで削除 (過去日も可)
    private func unplannedRow(_ actual: ActualTask) -> some View {
        HStack(spacing: 8) {
            Button { sheet = .actual(ActualEntryTarget(day: displayedDay, actual: actual)) } label: {
                UnplannedActualRow(actual: actual, categoryName: store.categoryName(actual.categoryId), calendar: calendar)
            }
            .buttonStyle(.plain)
            CheckInCircle(style: .fixedDone) {}
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { checkIn(.deleteActual(id: actual.id)) } label: { Label("削除", systemImage: "trash") }
                .tint(.red)
        }
        // 長押しは削除だけ (スワイプと同じ。丸は押せない塗りの丸)
        .contextMenu {
            Button("削除", systemImage: "trash", role: .destructive) { checkIn(.deleteActual(id: actual.id)) }
        }
    }

    /// 丸・スワイプの実績の書き込み (楽観更新。失敗は footer)
    private func checkIn(_ operation: CheckInOperation) {
        let day = displayedDay
        Task {
            if let error = await store.checkIn(operation, reloading: day) {
                store.listMessage = "記録できませんでした: \(error.localizedDescription)"
            } else {
                store.listMessage = nil
            }
        }
    }

    /// スワイプ削除: 単発は確認なし (スワイプ＋ボタンの 2 回)。繰り返しの回は「この予定／これ以降」を選ぶ
    private func delete(_ target: ScheduleEditTarget) {
        switch SchedulePlanner.delete(target: target) {
        case .apply(let operation): run(operation)
        case .chooseScope: pendingDelete = target
        case .confirmStopRepeating, .noChange: break
        }
    }

    private func run(_ operation: ScheduleOperation) {
        let day = displayedDay
        Task {
            if let error = await store.perform(operation, reloading: day) {
                store.listMessage = "削除できませんでした: \(error.localizedDescription)"
            } else {
                store.listMessage = nil
            }
        }
    }

    static var defaultCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }
}

/// 週帯の下の日付バー。今日は「9/30(水) 今日」、他の日は「10/3(土)」＋右端「今日へ」。祝日は「祝日」も出す
struct ScheduleDateBar: View {
    let day: Date
    let isToday: Bool
    let isHoliday: Bool
    let calendar: Calendar
    let onBackToToday: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(WorkoutSummary.dayLabel(day, calendar: calendar) + (isToday ? " 今日" : ""))
                .font(.subheadline.bold())
            if isHoliday {
                Text("祝日")
                    .font(.caption.bold())
                    .foregroundStyle(Color.red)
            }
            Spacer()
            if !isToday {
                // タップ領域は 44pt。はみ出す分は負の余白で打ち消し、今日 / 他の日でバーの高さを変えない (DaySummaryBar と同じ)
                Button(action: onBackToToday) {
                    Text("今日へ")
                        .font(.subheadline)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.vertical, -13)
            }
        }
        .frame(minHeight: 20)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// 予定タブのシート (予定の編集＋実績欄 / 予定外の実績 / 丸から開く実績の時刻)
enum ScheduleSheet: Identifiable {
    /// count = 回数の欄で扱う回 (時刻なしの回・時刻つきで目標 2 以上の回)
    case plan(ScheduleEditTarget, checkIn: CheckInSlot?, canEditPlan: Bool, count: CountSlot?)
    case actual(ActualEntryTarget)
    case actualTime(ActualTimeTarget)

    var id: UUID {
        switch self {
        case .plan(let target, _, _, _): return target.id
        case .actual(let target): return target.id
        case .actualTime(let target): return target.id
        }
    }
}
