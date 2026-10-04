import SwiftUI
import HolidayJp

/// 「予定」タブのルート (段階 1・2)。上部に週帯＋日付バー (トレーニングと同じ並び)。過去・未来の日へ移れる。
/// 今日・未来は行をタップで編集・左スワイプで削除。過去日の予定は読むだけ。
/// 段階 2: 過去日・今日の回は左の丸で「やった」、右スワイプで「スキップ」、行を開いて実績欄で時刻を直す。
/// 右上 ＋ は今日 = 「予定を追加」「やったことを記録」、明日以降 = 予定の追加、過去日 = やったことを記録。
/// 睡眠の行は sleep_record の実績を表示するだけ (丸・実績欄なし。記録は睡眠タブ。「睡眠（確定仕様）」)
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
        .onChange(of: displayedDay) { store.listMessage = nil }
        // 保存は store を直接渡して呼ぶ (シートに async クロージャで値を渡すと値が壊れた前例があるため)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .plan(let target, let checkIn, let canEditPlan):
                ScheduleEntryEditView(store: store, target: target, visibleDay: displayedDay, canEditPlan: canEditPlan, checkIn: checkIn)
            case .actual(let target):
                ActualEntryEditView(store: store, target: target, visibleDay: displayedDay)
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
                                      checkIn: nil, canEditPlan: true) }
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
                    if items.isEmpty {
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
        }
        .refreshable { await store.reload(displayedDay) }
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
        // 今日・未来は予定の編集 (＋実績欄)。過去の回は予定を読むだけ＋実績欄
        let opened: ScheduleSheet? = target.map { .plan($0, checkIn: slot, canEditPlan: true) }
            ?? slot.map { .plan(SchedulePlanner.readOnlyTarget(for: item, catalog: store.catalog, calendar: calendar),
                                checkIn: $0, canEditPlan: false) }
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
            if let style {
                CheckInCircle(style: style) {
                    if let operation = CheckInPlanner.toggle(row: item, state: state, calendar: calendar) { checkIn(operation) }
                }
            }
            if let opened {
                Button { sheet = opened } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // スキップ (丸を出す回だけ。セットのあるジムは出さない)
            if let style, style != .hidden, let operation = CheckInPlanner.skip(row: item, state: state, calendar: calendar) {
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
    }

    /// 予定外の実績の行: 丸は塗り・押せない。タップで編集、左スワイプで削除 (過去日も可)
    private func unplannedRow(_ actual: ActualTask) -> some View {
        HStack(spacing: 8) {
            CheckInCircle(style: .fixedDone) {}
            Button { sheet = .actual(ActualEntryTarget(day: displayedDay, actual: actual)) } label: {
                UnplannedActualRow(actual: actual, categoryName: store.categoryName(actual.categoryId), calendar: calendar)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { checkIn(.deleteActual(id: actual.id)) } label: { Label("削除", systemImage: "trash") }
                .tint(.red)
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

/// 予定タブのシート (予定の編集＋実績欄 / 予定外の実績)
enum ScheduleSheet: Identifiable {
    case plan(ScheduleEditTarget, checkIn: CheckInSlot?, canEditPlan: Bool)
    case actual(ActualEntryTarget)

    var id: UUID {
        switch self {
        case .plan(let target, _, _): return target.id
        case .actual(let target): return target.id
        }
    }
}
