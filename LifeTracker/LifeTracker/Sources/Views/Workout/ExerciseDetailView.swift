import SwiftUI

/// 1 種目の推移グラフ・履歴・メモ。記録はトレーニングタブのセット行で行う
struct ExerciseDetailView: View {
    @ObservedObject var store: WorkoutSessionStore
    let exercise: Exercise

    var body: some View {
        List {
            // 種目の画像は記録の有無に関係なく一番上に出す (2026-10-15 本人決定)
            Section {
                ExerciseImageView(exercise: exercise, size: 320)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if store.history[exercise.id] == nil {
                ProgressView()
            } else if store.daily(for: exercise.id).isEmpty {
                Text("まだ記録がありません")
                    .foregroundStyle(.secondary)
            } else {
                Section("推移") {
                    ProgressChartView(exercise: exercise, daily: store.daily(for: exercise.id))
                }
                let pastDays = store.pastDays(for: exercise.id)
                if !pastDays.isEmpty {
                    Section("履歴") {
                        ForEach(pastDays.prefix(30)) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.day.formatted(.dateTime.year().month().day().weekday().locale(Locale(identifier: "ja_JP"))))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // 同じ日に 2 回やった種目は「60×10 / 65×8 ｜ 50×12 / 50×10」
                                Text(WorkoutSummary.blocksText(entry.sets, kind: exercise.metricKind,
                                                               entriesById: store.historyEntries, markWarmup: false))
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }
            }
            if let note = exercise.note, !note.isEmpty {
                Section("メモ") { Text(note) }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadHistory(exerciseId: exercise.id) }
    }
}
