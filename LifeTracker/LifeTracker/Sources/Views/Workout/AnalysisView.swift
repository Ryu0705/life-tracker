import SwiftUI

/// トレーニングタブの右上 [📊] から push する分析 (3 つ目のタブにはしない)。
/// ナビバー中央の「強さ｜継続｜中身」で 3 ページに分ける (docs/analysis-tabs-discussion/40-integration.md)。
/// 各ページの期間はここに持つ: ページを切り替えても保ち、分析を出たら全部直近に戻る (この View ごと消えるため)
struct AnalysisView: View {
    @ObservedObject var store: WorkoutSessionStore
    @ObservedObject var historyStore: WorkoutHistoryStore
    @ObservedObject var continuity: ContinuityStore
    @ObservedObject var profileStore: ProfileStore
    let calendar: Calendar

    /// 既定は毎回「強さ」(AI 既定 Q1)
    @State private var page: AnalysisPage = .strength
    @State private var strengthPeriod: StrengthPeriod = .recent
    @State private var heatmapRange: HeatmapRange = .halfYear
    @State private var monthPeriod: StrengthPeriod = .recent
    /// 中身ページの週頭。nil = 今週
    @State private var weekStart: Date?

    enum AnalysisPage: String, CaseIterable, Identifiable {
        case strength, continuity, content

        var id: String { rawValue }

        var title: String {
            switch self {
            case .strength: return "強さ"
            case .continuity: return "継続"
            case .content: return "中身"
            }
        }
    }

    /// 先読みのやり直しの合図: invalidate (日跨ぎ・引っ張って更新) と週の切り替わり
    private struct PrefetchKey: Hashable {
        let generation: Int
        let week: Date
    }

    private var today: Date { WorkoutSummary.dayKey(Date(), calendar: calendar) }

    var body: some View {
        // 修飾子は中身が透過しない VStack に付ける (Group に付けると switch の各ページに配られ、
        // ページを替えるたびに先読みの .task が取り消し・再実行される)。各ページは必ず List を返す
        VStack(spacing: 0) {
            switch page {
            case .strength:
                StrengthPage(store: store, historyStore: historyStore, profileStore: profileStore,
                             period: $strengthPeriod, today: today, calendar: calendar)
            case .continuity:
                ContinuityPage(store: store, historyStore: historyStore, continuity: continuity,
                               range: $heatmapRange, monthPeriod: $monthPeriod, today: today, calendar: calendar)
            case .content:
                TrainingContentPage(store: store, historyStore: historyStore, weekStart: $weekStart, today: today, calendar: calendar)
            }
        }
        .navigationTitle("分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("ページ", selection: $page) {
                    ForEach(AnalysisPage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        // 強さ・継続の色の基準の 26 週 (各ページの .task は 26 週より前へ動かしたときの分だけ)
        .task(id: PrefetchKey(generation: historyStore.generation, week: Continuity.weekStart(containing: today, calendar: calendar))) {
            await historyStore.ensureLoaded(weekStarts: TrainingHeatmap.windowWeekStarts(today: today, calendar: calendar))
        }
        .task { await historyStore.loadRecordedExerciseIds() }
    }
}
