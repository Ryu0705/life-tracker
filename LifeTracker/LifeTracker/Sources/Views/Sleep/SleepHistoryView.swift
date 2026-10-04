import SwiftUI

/// すべての記録 (月ごと)。‹ › で月を移る (未来の月へは進めない)。右上 ＋ で任意の記録 (仮眠を含む) を足す。
/// 行を押すと記録シート、左スワイプで［削除］→ 画面中央のアラートで確認 (全スワイプなし)
struct SleepHistoryView: View {
    @ObservedObject var store: SleepStore
    let today: Date

    /// 表示中の月の 1 日。nil = 今月
    @State private var month: Date?
    @State private var sheet: SleepSheetTarget?
    @State private var pendingDelete: SleepRecord?
    @State private var message: String?

    private var calendar: Calendar { store.calendar }
    private var currentMonth: Date { store.monthRange(containing: today).lowerBound }
    private var shownMonth: Date { month ?? currentMonth }
    private var range: Range<Date> { store.monthRange(containing: shownMonth) }

    var body: some View {
        // 月の範囲に起床がある記録を、新しい順に
        let records = store.records
            .filter { range.contains($0.endAt) }
            .sorted { $0.startAt > $1.startAt }
        List {
            Section { monthNavigation }
            Section {
                if records.isEmpty {
                    Text("この月の記録はありません")
                        .foregroundStyle(Color.secondary)
                }
                ForEach(records) { record in
                    Button { sheet = .edit(record) } label: {
                        SleepRecordRow(title: title(record), kind: record.kind,
                                       range: CheckInPlanner.rangeText(record.startAt, record.endAt, calendar: calendar),
                                       duration: SleepRules.durationText(record.duration), isOpenable: true)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("削除") { pendingDelete = record }
                            .tint(.red)
                    }
                }
            } footer: {
                if let message {
                    Text(message).foregroundStyle(Color.red)
                }
            }
        }
        .navigationTitle("すべての記録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("追加", systemImage: "plus") {
                    // 起床の日 = 今日の前夜の予定どおり (シートで起床の日を変えると、その日の前夜の予定に合わせ直す)
                    let key = SleepRules.key(ofMorning: today, calendar: calendar)
                    let range = SleepRules.addDefault(
                        wakeDay: today, plan: store.plan(nightKey: key),
                        previous: SleepRules.previousNight(store.records, before: key, calendar: calendar), now: Date(), calendar: calendar)
                    sheet = .new(start: range.start, end: range.end, choosesWakeDay: true)
                }
            }
        }
        .task(id: shownMonth) { await store.ensureLoaded(range) }
        .refreshable { await store.reloadAll() }
        .sheet(item: $sheet) { target in
            SleepRecordSheet(store: store, target: target)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(SleepDeleteAlert.title, isPresented: pendingDeleteBinding, presenting: pendingDelete) { record in
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) { delete(record) }
        }
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    /// 通常の睡眠は「10/2(金) の朝」、仮眠は「10/1(木)」
    private func title(_ record: SleepRecord) -> String {
        let day = WorkoutSummary.dayLabel(SleepRules.displayDay(of: record, calendar: calendar), calendar: calendar)
        return record.kind == .sleep ? "\(day) の朝" : day
    }

    private var monthNavigation: some View {
        let c = calendar.dateComponents([.year, .month], from: shownMonth)
        let isCurrent = shownMonth == currentMonth
        return HStack {
            Button { month = calendar.date(byAdding: .month, value: -1, to: shownMonth) } label: { SleepTrendView.chevron("chevron.left") }
                .accessibilityLabel("前の月")
            Spacer()
            Text("\(String(c.year ?? 0))年\(c.month ?? 0)月")
                .font(.subheadline.monospacedDigit())
            Spacer()
            Button {
                let next = calendar.date(byAdding: .month, value: 1, to: shownMonth)!
                month = next == currentMonth ? nil : next
            } label: { SleepTrendView.chevron("chevron.right") }
                .disabled(isCurrent)
                .accessibilityLabel("次の月")
        }
        .buttonStyle(.borderless)
    }

    private func delete(_ record: SleepRecord) {
        Task {
            if let error = await store.delete(id: record.id) {
                message = "消せませんでした: \(SleepRules.message(for: error))"
            } else {
                message = nil
            }
        }
    }
}
