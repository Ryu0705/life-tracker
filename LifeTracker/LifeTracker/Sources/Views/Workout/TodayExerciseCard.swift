import SwiftUI

/// 今日の記録画面のカード 1 枚 (List の Section)。WorkoutView から挙動を変えずに切り出したもの。
/// 同じ種目のカードが 2 枚あっても見出しは種目名だけ (2026-10-04 本人「表示上は2回目などは不要」)。
/// セット番号・見出しの「今日 …」・前回はこのカードの分 (前回は同じ順番のかたまり = Q2「a」)
struct TodayExerciseCard: View {
    @ObservedObject var store: WorkoutSessionStore
    let card: TodayCard
    let exercise: Exercise
    let editing: WorkoutView.EditorTarget?
    let selectedDraftId: UUID?
    let message: String?
    let onEdit: (WorkoutView.EditorTarget) -> Void
    let onUndo: (WorkoutSet) -> Void
    let onDelete: (WorkoutSet) -> Void
    let onComplete: (UUID) -> Void
    let onOpenExercise: () -> Void
    let onReplace: () -> Void
    let onReorder: () -> Void

    var body: some View {
        let completed = store.sets(for: card)
        let drafts = store.drafts[card.id] ?? []
        let columns = SetColumn.columns(for: exercise)
        let numbers = WorkoutView.setNumbers(warmups: completed.map(\.isWarmup) + drafts.map(\.input.isWarmup))

        Section {
            SetHeaderRow(columns: columns)
            ForEach(Array(completed.enumerated()), id: \.element.id) { position, set in
                CompletedSetRow(
                    label: numbers[position],
                    previous: previousSummary(position: position),
                    set: set,
                    columns: columns,
                    isSelected: editing == .completed(cardId: card.id, setId: set.id),
                    isWriting: store.isWriting,
                    onEdit: { onEdit(.completed(cardId: card.id, setId: set.id)) },
                    onUndo: { onUndo(set) }
                )
                .swipeActions(allowsFullSwipe: false) {
                    Button("削除", role: .destructive) { onDelete(set) }
                }
            }
            ForEach(Array(drafts.enumerated()), id: \.element.id) { offset, draft in
                let position = completed.count + offset
                DraftSetRow(
                    label: numbers[position],
                    previous: previousSummary(position: position),
                    input: draft.input,
                    columns: columns,
                    isSelected: selectedDraftId == draft.id || editing == .draft(cardId: card.id, draftId: draft.id),
                    isWriting: store.isWriting,
                    onEdit: { onEdit(.draft(cardId: card.id, draftId: draft.id)) },
                    onComplete: { onComplete(draft.id) }
                )
                .swipeActions(allowsFullSwipe: false) {
                    Button("削除", role: .destructive) {
                        store.removeDraft(cardId: card.id, draftId: draft.id)
                    }
                }
            }
            Button {
                store.addDraft(cardId: card.id)
            } label: {
                Label("セットを追加", systemImage: "plus")
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
        } header: {
            HStack {
                Button(action: onOpenExercise) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(exercise.name)
                                .font(.headline)
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.caption)
                        }
                        if let headline = WorkoutSummary.cardHeadline(kind: exercise.metricKind, todaySets: completed,
                                                                      previousSets: store.previousSets(for: card)) {
                            Text(headline)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
                Spacer()
                menu(isRecorded: !completed.isEmpty)
            }
            .textCase(nil)
        } footer: {
            if let message {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    /// ⋮ はすべてのカードに出す。記録済みのカードは「種目を並べ替え」だけ (実施した順を直す。Q3「A」)
    private func menu(isRecorded: Bool) -> some View {
        Menu {
            if !isRecorded {
                Button("種目を入れ替え", systemImage: "arrow.left.arrow.right", action: onReplace)
            }
            Button("種目を並べ替え", systemImage: "arrow.up.arrow.down", action: onReorder)
            if !isRecorded {
                Button("今日から外す", systemImage: "minus.circle", role: .destructive) {
                    Task { await store.removePlannedCard(card) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(exercise.name)のメニュー")
    }

    private func previousSummary(position: Int) -> String? {
        store.previousSet(for: card, position: position).map {
            ($0.isWarmup ? "W " : "") + WorkoutLogic.summary(of: $0, kind: exercise.metricKind)
        }
    }
}

extension WorkoutView {
    /// セット番号: ウォームアップは「W」、本番セットは 1 から数える
    static func setNumbers(warmups: [Bool]) -> [String] {
        var count = 0
        return warmups.map { isWarmup in
            if isWarmup { return "W" }
            count += 1
            return "\(count)"
        }
    }

    static func validationMessage(for error: WorkoutSetInput.ValidationError) -> String {
        switch error {
        case .missingWeight: return "重量を入れてください"
        case .missingReps: return "回数を入れてください"
        case .missingDuration: return "時間を入れてください"
        case .negativeValue: return "マイナスの値は記録できません"
        }
    }

    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// 記録済みの行の入力シート。保存するまで store には書かない (値はシートの中だけで持つ)
struct CompletedSetEditor: View {
    let title: String
    let columns: [SetColumn]
    let isWriting: Bool
    let message: String?
    let restEndsAt: Date?
    let onSave: (WorkoutSetInput) -> Void

    @State private var input: WorkoutSetInput

    init(title: String, columns: [SetColumn], initial: WorkoutSetInput, isWriting: Bool, message: String?,
         restEndsAt: Date?, onSave: @escaping (WorkoutSetInput) -> Void) {
        self.title = title
        self.columns = columns
        self.isWriting = isWriting
        self.message = message
        self.restEndsAt = restEndsAt
        self.onSave = onSave
        _input = State(initialValue: initial)
    }

    var body: some View {
        SetEditorSheet(
            title: title,
            columns: columns,
            input: $input,
            isWriting: isWriting,
            message: message,
            restEndsAt: restEndsAt,
            onApplyToRemaining: nil,
            onComplete: { onSave(input) },
            completeTitle: "保存"
        )
    }
}
