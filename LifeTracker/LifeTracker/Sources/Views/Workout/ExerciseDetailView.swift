import SwiftUI

/// 1 種目の推移グラフ・履歴・メモ。記録はトレーニングタブのセット行で行う
struct ExerciseDetailView: View {
    @ObservedObject var store: WorkoutSessionStore
    let exercise: Exercise

    var body: some View {
        List {
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
                                Text(entry.sets.map { WorkoutLogic.summary(of: $0, kind: exercise.metricKind) }.joined(separator: " / "))
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
