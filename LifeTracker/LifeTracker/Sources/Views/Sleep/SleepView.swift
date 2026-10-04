import SwiftUI

/// 「睡眠」タブのルート (1 画面目)。今週の 1 行・今朝のカード (その夜の予定の就寝〜起床で埋まり［記録する］)・直近 7 朝 (未入力の行つき)・
/// 仮眠の行・すべての記録へ。右上「推移」で push (トレーニングの「分析」と同じ位置)。
/// 仕様: docs/day-cycle-walkthrough.md「睡眠（確定仕様）」、docs/sleep-design/implementation-plan.md
struct SleepView: View {
    @EnvironmentObject private var clockTick: ClockTick
    @StateObject private var store: SleepStore
    @State private var sheet: SleepSheetTarget?
    /// 左スワイプの削除で確認中の記録
    @State private var pendingDelete: SleepRecord?
    @State private var listMessage: String?
    /// 今朝のカードで直した時刻 (nil = 既定のまま)
    @State private var cardBed: Int?
    @State private var cardWake: Int?
    @State private var cardExpanded: SleepRecordSheet.Field?

    struct HistoryRoute: Hashable {}
    struct TrendRoute: Hashable {}

    /// 1 画面目に出す朝の数 (今朝を含む)
    static let morningCount = 7

    private let calendar: Calendar

    init(dataSource: SleepDataSource, dayDataSource: DayDataSource, scheduleDataSource: ScheduleDataSource,
         calendar: Calendar = HomeView.defaultCalendar) {
        self.calendar = calendar
        _store = StateObject(wrappedValue: SleepStore(dataSource: dataSource, dayDataSource: dayDataSource,
                                                      scheduleDataSource: scheduleDataSource, calendar: calendar))
    }

    private var now: Date { clockTick.now }
    private var today: Date { calendar.startOfDay(for: now) }
    private var morningKey: Date { SleepRules.morningKey(today: today, calendar: calendar) }
    private var nights: [SleepNight] { SleepRules.nights(store.records, calendar: calendar) }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("睡眠")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("推移", value: TrendRoute())
                    }
                }
                .navigationDestination(for: HistoryRoute.self) { _ in
                    SleepHistoryView(store: store, today: today)
                }
                .navigationDestination(for: TrendRoute.self) { _ in
                    SleepTrendView(store: store, today: today)
                }
        }
        .task(id: today) {
            cardBed = nil
            cardWake = nil
            cardExpanded = nil
            await store.ensureLoaded(store.recentRange(today: today))
        }
        // 予定タブで睡眠の予定を変えた後にも合わせる (タブに戻るたび)
        .onAppear { Task { await store.loadPlan(nightKey: morningKey) } }
        .sheet(item: $sheet) { target in
            SleepRecordSheet(store: store, target: target)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        // スワイプの［削除］→ 画面中央のアラート (LINE のトーク一覧と同じ。キャンセルで行のスワイプも閉じる)
        .alert(SleepDeleteAlert.title, isPresented: pendingDeleteBinding, presenting: pendingDelete) { record in
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) { delete(record) }
        }
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    @ViewBuilder
    private var list: some View {
        List {
            if !store.isLoaded {
                if let error = store.loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("読み込みに失敗しました").font(.headline)
                        Text(error).font(.callout).foregroundStyle(Color.secondary)
                        Button("再試行") { Task { await store.ensureLoaded(store.recentRange(today: today)) } }
                    }
                } else {
                    ProgressView("読み込み中…")
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            } else {
                Section {
                    Text(weekLine)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                morningSection
                Section {
                    ForEach(pastMornings, id: \.self) { morning in
                        morningRows(morning)
                    }
                } footer: {
                    if let listMessage {
                        Text(listMessage).foregroundStyle(Color.red)
                    }
                }
                Section {
                    NavigationLink("すべての記録", value: HistoryRoute())
                }
            }
        }
        .refreshable {
            await store.reloadAll()
            await store.loadPlan(nightKey: morningKey)
        }
    }

    // MARK: - 今週の 1 行

    private var weekLine: String {
        let start = WorkoutSummary.weekStart(containing: today, calendar: calendar)
        let stats = SleepRules.stats(nights: nights, firstMorning: start, lastMorning: today, today: today, calendar: calendar)
        let count = "記録 \(stats.recordedCount)/\(stats.elapsedCount)"
        guard let average = stats.averageDuration else { return "今週 \(count)" }
        return "今週 平均 \(SleepRules.durationText(average)) · \(count)"
    }

    // MARK: - 今朝

    @ViewBuilder
    private var morningSection: some View {
        let header = "\(WorkoutSummary.dayLabel(today, calendar: calendar)) の朝"
        if nights.contains(where: { $0.key == morningKey }) {
            Section(header) { recordedRows(today) }
        } else {
            Section {
                card
                napRows(on: today)
            } header: {
                Text(header)
            }
        }
    }

    /// 今朝のカードの既定 (その夜の睡眠の予定の就寝〜起床 → 前回 → 23:00 / 7:00。起床がまだなら今)
    private var cardDefault: (start: Date, end: Date)? {
        SleepRules.cardDefault(plan: store.plan(nightKey: morningKey),
                                      previous: SleepRules.previousNight(store.records, before: morningKey, calendar: calendar),
                                      now: now, calendar: calendar)
    }

    @ViewBuilder
    private var card: some View {
        if let defaults = cardDefault {
            let bed = cardBed ?? SleepRules.minutesOfDay(defaults.start, calendar: calendar)
            let wake = cardWake ?? SleepRules.minutesOfDay(defaults.end, calendar: calendar)
            let range = SleepRules.resolve(bedMinutes: bed, wakeMinutes: wake, anchorDay: today, calendar: calendar)
            let error = range.flatMap { SleepRules.validate(start: $0.start, end: $0.end, now: now, others: store.records, excluding: nil) }
                ?? (range == nil ? .invalidTime : nil)
            SleepTimeField(title: "就寝", minutes: Binding(get: { bed }, set: { cardBed = $0 }), isExpanded: cardExpandedBinding(.bed),
                           detail: range.flatMap { calendar.isDate($0.start, inSameDayAs: today) ? nil : WorkoutSummary.dayLabel($0.start, calendar: calendar) },
                           calendar: calendar)
            SleepTimeField(title: "起床", minutes: Binding(get: { wake }, set: { cardWake = $0 }), isExpanded: cardExpandedBinding(.wake),
                           detail: nil, calendar: calendar)
            HStack {
                if let error {
                    Text(error.errorDescription ?? "")
                        .font(.callout)
                        .foregroundStyle(Color.red)
                } else if let range {
                    Text(SleepRules.durationText(range.end.timeIntervalSince(range.start)))
                        .font(.title3.bold().monospacedDigit())
                }
                Spacer()
                Button("記録する") {
                    if let range { record(range) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(error != nil || store.isSaving)
            }
        } else {
            Text("起きたら記録できます")
                .foregroundStyle(Color.secondary)
        }
    }

    private func cardExpandedBinding(_ field: SleepRecordSheet.Field) -> Binding<Bool> {
        Binding(get: { cardExpanded == field }, set: { cardExpanded = $0 ? field : nil })
    }

    // MARK: - 直近の朝

    /// 今朝より前の 6 朝。最初の記録より前の朝は出さない (読み込んだ範囲で判断)
    private var pastMornings: [Date] {
        let first = store.records.map { SleepRules.displayDay(of: $0, calendar: calendar) }.min()
        return (1..<Self.morningCount).compactMap { offset in
            let morning = calendar.date(byAdding: .day, value: -offset, to: today)!
            guard let first, morning >= first else { return nil }
            return morning
        }
    }

    /// 1 朝の行: 通常の睡眠 (記録済み or 未入力) ＋ その日の仮眠
    @ViewBuilder
    private func morningRows(_ morning: Date) -> some View {
        let key = SleepRules.key(ofMorning: morning, calendar: calendar)
        if nights.contains(where: { $0.key == key }) {
            recordedRows(morning)
        } else {
            HStack {
                Text("\(WorkoutSummary.dayLabel(morning, calendar: calendar)) の朝")
                Text("未入力")
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button("記録") {
                    let range = SleepRules.pastMorningDefault(
                        nightKey: key, previous: SleepRules.previousNight(store.records, before: key, calendar: calendar), calendar: calendar)
                    sheet = .new(start: range.start, end: range.end)
                }
                .buttonStyle(.bordered)
            }
            napRows(on: morning)
        }
    }

    /// 記録済みの朝: 1 件なら 1 行。分けた夜 (2 件以上) は合計の行の下に記録ごとの行。続けてその日の仮眠
    @ViewBuilder
    private func recordedRows(_ morning: Date) -> some View {
        let key = SleepRules.key(ofMorning: morning, calendar: calendar)
        if let night = nights.first(where: { $0.key == key }) {
            let label = "\(WorkoutSummary.dayLabel(morning, calendar: calendar)) の朝"
            if night.records.count == 1, let only = night.records.first {
                recordRow(only, title: label)
            } else {
                SleepRecordRow(title: label, range: CheckInPlanner.rangeText(night.start, night.end, calendar: calendar),
                               duration: "\(SleepRules.durationText(night.total)) · \(night.records.count) 件", isOpenable: false)
                ForEach(night.records) { recordRow($0, title: "") }
            }
        }
        napRows(on: morning)
    }

    @ViewBuilder
    private func napRows(on day: Date) -> some View {
        let naps = store.records.filter { $0.kind == .nap && SleepRules.displayDay(of: $0, calendar: calendar) == day }
        ForEach(naps) { recordRow($0, title: "") }
    }

    private func recordRow(_ record: SleepRecord, title: String) -> some View {
        Button { sheet = .edit(record) } label: {
            SleepRecordRow(title: title, kind: record.kind, range: CheckInPlanner.rangeText(record.startAt, record.endAt, calendar: calendar),
                           duration: SleepRules.durationText(record.duration), isOpenable: true)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("削除") { pendingDelete = record }
                .tint(.red)
        }
    }

    // MARK: - 書き込み

    private func record(_ range: (start: Date, end: Date)) {
        Task {
            if let error = await store.save(id: nil, start: range.start, end: range.end, kind: .sleep) {
                listMessage = "記録できませんでした: \(SleepRules.message(for: error))"
            } else {
                listMessage = nil
                cardBed = nil
                cardWake = nil
                cardExpanded = nil
            }
        }
    }

    private func delete(_ record: SleepRecord) {
        Task {
            if let error = await store.delete(id: record.id) {
                listMessage = "消せませんでした: \(SleepRules.message(for: error))"
            } else {
                listMessage = nil
            }
        }
    }
}

/// 一覧のスワイプ削除の確認 (画面中央のアラート。睡眠タブ・すべての記録で共通)
enum SleepDeleteAlert {
    static let title = "睡眠の記録を削除します。よろしいですか？"
}

/// 睡眠の記録の 1 行 (「10/1(木) の朝  23:40–7:10  7時間30分 ›」/ 仮眠は「仮眠 13:10–13:40 30分」)
struct SleepRecordRow: View {
    let title: String
    var kind: SleepKind = .sleep
    let range: String
    let duration: String
    let isOpenable: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !title.isEmpty {
                Text(title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
            }
            if kind == .nap {
                Text("仮眠")
                    .font(.caption.bold())
                    .foregroundStyle(Color.secondary)
            }
            Text(range)
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(duration)
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            if isOpenable {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.leading, title.isEmpty ? 16 : 0)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(isOpenable ? "開く" : "")
    }
}
