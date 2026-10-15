import SwiftUI

/// 一覧の丸から開く「実績の時刻」のシート (2026-10-14 本人指示「時間ありのものはチェックを押すと実績時間の入力を求めるようにして。」)
struct ActualTimeTarget: Identifiable, Hashable {
    let id = UUID()
    /// その回 (前日から続く行では前日の回)
    let slot: CheckInSlot
    /// 一覧で見ている日 (保存後に読み直す日)
    let visibleDay: Date
}

/// 時刻つきで目標 1 の回の、記録なしの丸を押したときのシート。開始・終了は予定の時刻が入った状態、保存で「やった」。
/// 保存は store を直接呼ぶ (ScheduleEntryEditView と同じ理由)。キャンセル・下へのスワイプは何も書かない (AI 既定)
struct ActualTimeSheet: View {
    @ObservedObject var store: ScheduleStore
    let target: ActualTimeTarget

    @Environment(\.dismiss) private var dismiss
    @State private var startMinutes: Int
    @State private var endMinutes: Int
    @State private var message: String?
    @State private var isWorking = false

    init(store: ScheduleStore, target: ActualTimeTarget) {
        self.store = store
        self.target = target
        let task = target.slot.row.task
        _startMinutes = State(initialValue: CheckInPlanner.minutesOfDay(task.startAt, calendar: store.calendar))
        _endMinutes = State(initialValue: CheckInPlanner.minutesOfDay(task.endAt, calendar: store.calendar))
    }

    private var calendar: Calendar { store.calendar }
    private var slot: CheckInSlot { target.slot }

    /// 開始は予定の開始の ±12 時間で最も近い時刻、終了は開始の後 (実績欄と同じ)
    private var range: (start: Date, end: Date)? {
        CheckInPlanner.occurrenceRange(startMinutes: startMinutes, endMinutes: endMinutes,
                                       plannedStart: slot.row.task.startAt, calendar: calendar)
    }

    /// 前日の回 (前日から続く行) なら日付を出す (実績欄の見出しと同じ)
    private var header: String {
        guard slot.occurrenceDay != calendar.startOfDay(for: target.visibleDay) else { return "実績の時刻" }
        return "実績（\(WorkoutSummary.dayLabel(slot.occurrenceDay, calendar: calendar)) の回）の時刻"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("開始", selection: timeBinding($startMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding($endMinutes), displayedComponents: .hourAndMinute)
                } header: {
                    Text(header)
                } footer: {
                    if let range {
                        Text(CheckInPlanner.actualRangeSummary(range, occurrenceDay: slot.occurrenceDay, calendar: calendar))
                    } else {
                        Text("開始と終了を別の時刻にしてください").foregroundStyle(Color.red)
                    }
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle(slot.row.task.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(range == nil || isWorking)
                }
            }
        }
        // 睡眠の記録のシートと同じ高さ・つまみ
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        guard let range else { return }
        let task = slot.row.task
        Task {
            isWorking = true
            let error = await store.checkIn(.set(key: slot.key, status: .done, name: task.name, categoryId: task.categoryId,
                                                 start: range.start, end: range.end),
                                            reloading: target.visibleDay)
            isWorking = false
            if let error {
                message = "記録できませんでした: \(error.localizedDescription)"
            } else {
                dismiss()
            }
        }
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
}
