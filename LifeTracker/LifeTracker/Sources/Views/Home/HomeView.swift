import SwiftUI
import HolidayJp

/// 「予定」タブのルート (段階 1)。上部に週帯＋日付バー (トレーニングと同じ並び)。過去・未来の日へ移れる。
/// 今日・未来は行をタップで編集・スワイプで削除・右上 ＋ で見ている日に追加。過去日は読むだけ。
/// 仕様: docs/day-cycle-walkthrough.md「段階 1 確定仕様」
struct HomeView: View {
    @EnvironmentObject private var clockTick: ClockTick
    @StateObject private var store: ScheduleStore
    /// 週帯で選んだ日。nil = 今日 (日付をまたいでも今日を指し続ける。トレーニングと同じ持ち方)
    @State private var selectedDay: Date?
    @State private var editing: ScheduleEditTarget?
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
                    Button("予定を追加", systemImage: "plus") {
                        editing = ScheduleEditTarget(date: displayedDay, kind: .new, original: nil, usual: nil)
                    }
                    .disabled(!canEdit)
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
        .onChange(of: displayedDay) { store.listMessage = nil }
        // 保存は store を直接渡して呼ぶ (シートに async クロージャで値を渡すと値が壊れた前例があるため)
        .sheet(item: $editing) { target in
            ScheduleEntryEditView(store: store, target: target, visibleDay: displayedDay)
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
                    if day.scheduled.isEmpty {
                        Text(canEdit ? "予定はありません。右上の ＋ で追加します。" : "この日の予定はありません")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(day.scheduled) { item in
                        row(item)
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
    private func row(_ item: DayScheduledTask) -> some View {
        let target = store.editTarget(for: item, viewDay: displayedDay, today: today)
        let content = ScheduleRow(
            item: item,
            categoryName: store.categoryName(item.task.categoryId),
            isEditable: target != nil,
            isPastTime: isToday && item.task.endAt <= clockTick.now,
            calendar: calendar
        )
        if let target {
            Button { editing = target } label: { content }
                .buttonStyle(.plain)
                .swipeActions(allowsFullSwipe: false) {
                    // 前日から続く行ではスワイプを出さない (どの回を消すかが曖昧になるため)
                    if !item.isSpillover {
                        // role: .destructive は確認の前に行が消える動きになるため、色だけ赤にする
                        Button { delete(target) } label: { Label("削除", systemImage: "trash") }
                            .tint(.red)
                    }
                }
        } else {
            content
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
