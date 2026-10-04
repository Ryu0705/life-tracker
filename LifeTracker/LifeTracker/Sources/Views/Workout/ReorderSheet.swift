import SwiftUI

/// 記録画面の「種目を並べ替え」(各カードの ⋮ から。Q3「A」)。プログラム編集と同じく編集モード常時の ≡ で動かす。
/// 並び = 実施した順 (2026-10-04 本人決定)。行を落とすたびに保存し、記録済みのカードの順は DB に残る。
/// 未記録のカードはメモリだけ (最初の ✓ でその位置が実施した順として入る)。同じ種目でも表記は種目名だけ (Q4)
struct ReorderSheet: View {
    @ObservedObject var store: WorkoutSessionStore

    @Environment(\.dismiss) private var dismiss
    /// 保存の失敗。次の移動で成功したら消す
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.cards) { card in
                        row(card)
                    }
                    .onMove { source, destination in
                        store.moveCard(fromOffsets: source, toOffset: destination)
                        Task {
                            message = await store.saveCardOrder().map { "並びを保存できませんでした: \($0.localizedDescription)" }
                        }
                    }
                } footer: {
                    if let message {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("≡ で並べ替えます。記録済みの種目は、この並びが実施した順として残ります。")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("種目を並べ替え")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    /// 同じ種目の行は名前が同じなので、記録済みならその値を添えて見分けられるようにする
    private func row(_ card: TodayCard) -> some View {
        let exercise = store.exercisesById[card.exerciseId]
        let recorded = store.sets(for: card)
        let values = exercise.map { e in recorded.map { WorkoutLogic.summary(of: $0, kind: e.metricKind) }.joined(separator: " / ") } ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(exercise?.name ?? "（使われていない種目）")
            Text(recorded.isEmpty ? "未記録" : "\(recorded.count)セット記録済み · \(values)")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}
