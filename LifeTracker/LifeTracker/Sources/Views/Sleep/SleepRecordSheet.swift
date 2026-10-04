import SwiftUI

/// 記録シートを開く単位 (一覧の行・未入力の朝の［記録］・すべての記録の ＋)
struct SleepSheetTarget: Identifiable, Hashable {
    let id = UUID()
    /// nil = 新規
    let record: SleepRecord?
    let start: Date
    let end: Date
    let kind: SleepKind
    /// ＋ から開いた (起床の日を選べる)
    let choosesWakeDay: Bool

    static func edit(_ record: SleepRecord) -> SleepSheetTarget {
        SleepSheetTarget(record: record, start: record.startAt, end: record.endAt, kind: record.kind, choosesWakeDay: false)
    }

    static func new(start: Date, end: Date, choosesWakeDay: Bool = false) -> SleepSheetTarget {
        SleepSheetTarget(record: nil, start: start, end: end, kind: .sleep, choosesWakeDay: choosesWakeDay)
    }
}

/// 睡眠の記録シート (下から半画面)。先頭に「通常の睡眠｜仮眠」(開くたびに通常の睡眠。既存の記録はその種別)、
/// 就寝・起床は押すとホイール。既存の記録は「記録を消す」(確認あり)。保存・削除は store を直接呼ぶ
/// (シートに async クロージャで値を渡すと値が壊れた前例があるため)
struct SleepRecordSheet: View {
    @ObservedObject var store: SleepStore
    let target: SleepSheetTarget

    @Environment(\.dismiss) private var dismiss
    /// 書き換える記録 (重なりで「その記録を開く」を押すと差し替わる)
    @State private var editing: SleepRecord?
    @State private var kind: SleepKind
    @State private var bedMinutes: Int
    @State private var wakeMinutes: Int
    /// 起床の日 (0 時)
    @State private var wakeDay: Date
    @State private var expanded: Field?
    /// 保存・削除の失敗 (DB の拒否など)
    @State private var message: String?
    @State private var isConfirmingDelete = false
    @State private var isConfirmingDiscard = false
    /// 本人が就寝・起床を触った (＋ の既定を起床の日に合わせて変えるのは触る前だけ)
    @State private var timesTouched = false
    /// 変更の有無を比べる元 (開いたとき・別の記録に差し替えたとき)
    @State private var initial: Snapshot

    enum Field: Hashable { case bed, wake }

    struct Snapshot: Equatable {
        let kind: SleepKind
        let bed: Int
        let wake: Int
        let wakeDay: Date
    }

    init(store: SleepStore, target: SleepSheetTarget) {
        self.store = store
        self.target = target
        let calendar = store.calendar
        let snapshot = Snapshot(kind: target.kind, bed: SleepRules.minutesOfDay(target.start, calendar: calendar),
                                wake: SleepRules.minutesOfDay(target.end, calendar: calendar),
                                wakeDay: calendar.startOfDay(for: target.end))
        _editing = State(initialValue: target.record)
        _kind = State(initialValue: snapshot.kind)
        _bedMinutes = State(initialValue: snapshot.bed)
        _wakeMinutes = State(initialValue: snapshot.wake)
        _wakeDay = State(initialValue: snapshot.wakeDay)
        _initial = State(initialValue: snapshot)
    }

    private var calendar: Calendar { store.calendar }

    private var range: (start: Date, end: Date)? {
        SleepRules.resolve(bedMinutes: bedMinutes, wakeMinutes: wakeMinutes, anchorDay: wakeDay, calendar: calendar)
    }

    private var current: Snapshot { Snapshot(kind: kind, bed: bedMinutes, wake: wakeMinutes, wakeDay: wakeDay) }

    private var hasChanges: Bool { editing == nil || current != initial }

    private var ruleError: SleepRuleError? {
        guard let range else { return .invalidTime }
        return SleepRules.validate(start: range.start, end: range.end, now: Date(), others: store.records, excluding: editing?.id)
    }

    private var canSave: Bool { ruleError == nil && hasChanges && !store.isSaving }

    private var title: String {
        guard let range else { return kind == .nap ? "仮眠" : "睡眠" }
        let record = SleepRecord(startAt: range.start, endAt: range.end, kind: kind)
        let day = WorkoutSummary.dayLabel(SleepRules.displayDay(of: record, calendar: calendar), calendar: calendar)
        return kind == .nap ? "\(day) の仮眠" : "\(day) の朝の睡眠"
    }

    /// 就寝が起床の前日になるときだけ日付を出す
    private var bedDetail: String? {
        guard let range, !calendar.isDate(range.start, inSameDayAs: range.end) else { return nil }
        return WorkoutSummary.dayLabel(range.start, calendar: calendar)
    }

    private var summary: (text: String, color: Color) {
        if let ruleError {
            if case .overlap = ruleError { return ("この時間には記録があります", .red) }
            return (ruleError.errorDescription ?? "", .red)
        }
        guard let range else { return ("", .secondary) }
        let duration = range.end.timeIntervalSince(range.start)
        // 通常の睡眠で 2 時間未満は注意の色 (止めない)
        return (SleepRules.durationText(duration), kind == .sleep && duration < 2 * 3600 ? .orange : .secondary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("種別", selection: $kind) {
                        ForEach(SleepKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if target.choosesWakeDay && editing == nil {
                    Section {
                        DatePicker("起床の日", selection: $wakeDay, in: ...calendar.startOfDay(for: Date()), displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "ja_JP"))
                            .environment(\.timeZone, calendar.timeZone)
                    }
                }
                Section {
                    SleepTimeField(title: "就寝", minutes: touching($bedMinutes), isExpanded: expandedBinding(.bed), detail: bedDetail,
                                   calendar: calendar)
                    SleepTimeField(title: "起床", minutes: touching($wakeMinutes), isExpanded: expandedBinding(.wake), detail: nil,
                                   calendar: calendar)
                } footer: {
                    Text(summary.text)
                        .foregroundStyle(summary.color)
                }
                if case .overlap(let otherId)? = ruleError, let other = store.record(otherId) {
                    // 手元の記録と重なる: その記録を開いて直せる
                    Section {
                        Button("その記録を開く（\(CheckInPlanner.rangeText(other.startAt, other.endAt, calendar: calendar))）") { open(other) }
                    }
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(Color.red)
                    }
                }
                if editing != nil {
                    Section {
                        Button("記録を消す", role: .destructive) { isConfirmingDelete = true }
                            .frame(maxWidth: .infinity)
                            .disabled(store.isSaving)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(editing != nil && hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        if editing != nil && hasChanges { isConfirmingDiscard = true } else { dismiss() }
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
            .confirmationDialog("睡眠の記録を消しますか？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("記録を消す", role: .destructive) { delete() }
                Button("キャンセル", role: .cancel) {}
            }
            .onChange(of: kind) { old, new in kindChanged(from: old, to: new) }
            // ＋ から開いた新規: 起床の日の前夜の睡眠の予定を読み、まだ時刻を触っていなければ既定をその日に合わせる
            .task(id: wakeDay) {
                guard target.choosesWakeDay, editing == nil else { return }
                let day = wakeDay
                await store.loadPlan(nightKey: SleepRules.key(ofMorning: day, calendar: calendar))
                guard day == wakeDay, kind == .sleep, !timesTouched, editing == nil else { return }
                applyTimes(addDefault(wakeDay: day))
            }
            .onChange(of: current) { message = nil }
        }
    }

    private func expandedBinding(_ field: Field) -> Binding<Bool> {
        Binding(get: { expanded == field }, set: { expanded = $0 ? field : nil })
    }

    /// 本人の操作で時刻が変わったら timesTouched を立てる (既定の当て直しは通さない)
    private func touching(_ binding: Binding<Int>) -> Binding<Int> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; timesTouched = true })
    }

    /// ＋ の既定 (起床の日の前夜の睡眠の予定 → 前回の通常の睡眠 → 23:00 / 7:00。起床がまだなら今)
    private func addDefault(wakeDay day: Date) -> (start: Date, end: Date) {
        let key = SleepRules.key(ofMorning: day, calendar: calendar)
        return SleepRules.addDefault(wakeDay: day, plan: store.plan(nightKey: key),
                                     previous: SleepRules.previousNight(store.records, before: key, calendar: calendar),
                                     now: Date(), calendar: calendar)
    }

    /// 就寝・起床の時計の時刻だけを当てる (起床の日は変えない)
    private func applyTimes(_ range: (start: Date, end: Date)) {
        bedMinutes = SleepRules.minutesOfDay(range.start, calendar: calendar)
        wakeMinutes = SleepRules.minutesOfDay(range.end, calendar: calendar)
    }

    /// 新規で仮眠に切り替えたら 今−30 分〜今 にする。通常の睡眠に戻したら、＋ からは起床の日の前夜の予定、それ以外は開いたときの時刻に戻す。
    /// 既存の記録は時刻を変えない
    private func kindChanged(from old: SleepKind, to new: SleepKind) {
        guard editing == nil, old != new else { return }
        timesTouched = false
        if new == .nap {
            let range = SleepRules.napDefault(now: Date(), calendar: calendar)
            applyTimes(range)
            wakeDay = calendar.startOfDay(for: range.end)
        } else if target.choosesWakeDay {
            applyTimes(addDefault(wakeDay: wakeDay))
        } else {
            applyTimes((target.start, target.end))
            wakeDay = calendar.startOfDay(for: target.end)
        }
    }

    /// 重なった記録に差し替える
    private func open(_ record: SleepRecord) {
        let snapshot = Snapshot(kind: record.kind, bed: SleepRules.minutesOfDay(record.startAt, calendar: calendar),
                                wake: SleepRules.minutesOfDay(record.endAt, calendar: calendar),
                                wakeDay: calendar.startOfDay(for: record.endAt))
        editing = record
        initial = snapshot
        kind = snapshot.kind
        bedMinutes = snapshot.bed
        wakeMinutes = snapshot.wake
        wakeDay = snapshot.wakeDay
        expanded = nil
        message = nil
    }

    private func save() {
        guard let range else { return }
        let id = editing?.id, kind = self.kind
        Task {
            let error = await store.save(id: id, start: range.start, end: range.end, kind: kind)
            if let error {
                message = SleepRules.message(for: error)
            } else {
                dismiss()
            }
        }
    }

    private func delete() {
        guard let id = editing?.id else { return }
        Task {
            if let error = await store.delete(id: id) {
                message = "消せませんでした: \(SleepRules.message(for: error))"
            } else {
                dismiss()
            }
        }
    }
}
