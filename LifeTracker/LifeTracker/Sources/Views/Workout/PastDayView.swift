import SwiftUI

/// 過去日の読み取り専用表示。✓・スワイプ・＋セット・⋮ などの編集要素を一切持たない専用 View
/// (今日の記録画面と兼用しないので、何もゲートしない isReadOnly 引数は置かない)。
/// Round 4 で過去日の編集を足すときは、ここに isReadOnly を必須引数 (デフォルト引数なし) として導入し、
/// 追加する全編集要素をゲートする (structural-conventions C-5)
struct PastDayView: View {
    let sets: [WorkoutSet]
    /// その日の entry。カード = entry ごとに 1 枚、sort_order (実施した順) で並べる。セットの無い entry は出さない
    let entries: [WorkoutEntry]
    let exercisesById: [UUID: Exercise]
    let isLoaded: Bool
    let onOpenExercise: (UUID) -> Void

    var body: some View {
        List {
            if !isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if sets.isEmpty {
                Text("この日の記録はありません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(WorkoutLogic.groupByEntry(sets: sets, entries: entries).filter { !$0.sets.isEmpty }, id: \.entry.id) { group in
                    if let exercise = exercisesById[group.entry.exerciseId] {
                        PastExerciseCard(exercise: exercise, sets: group.sets) { onOpenExercise(exercise.id) }
                    }
                }
            }
        }
    }
}

/// 過去日の 1 種目。行は summary 表記のみ
private struct PastExerciseCard: View {
    let exercise: Exercise
    let sets: [WorkoutSet]
    let onOpen: () -> Void

    var body: some View {
        let numbers = WorkoutView.setNumbers(warmups: sets.map(\.isWarmup))
        Section {
            ForEach(Array(sets.enumerated()), id: \.element.id) { position, set in
                HStack(spacing: 16) {
                    Text(numbers[position])
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: SetRowLayout.labelWidth, alignment: .leading)
                    Text(WorkoutLogic.summary(of: set, kind: exercise.metricKind))
                        .font(.body.monospacedDigit())
                    Spacer()
                }
            }
        } header: {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(exercise.name)
                            .font(.headline)
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption)
                    }
                    if let summary = WorkoutSummary.setsSummary(kind: exercise.metricKind, sets: sets) {
                        Text(summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .textCase(nil)
        }
    }
}
