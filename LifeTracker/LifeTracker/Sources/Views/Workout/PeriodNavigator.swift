import SwiftUI

/// 期間ナビ「‹ 日付範囲 ›」。同じ見せ方で対象期間だけが違う表示はタブにせず、これで前後に動かす
/// (本人 2026-10-10。docs/body-strength-and-heatmap-period.md「期間の動かし方」)。› は現在の期間で止まる
struct PeriodNavigator: View {
    let label: String
    /// 現在の期間のときだけ出す小見出し (例: 直近30日)
    let currentCaption: String
    let isCurrent: Bool
    let unit: String
    let onOlder: () -> Void
    let onNewer: () -> Void

    var body: some View {
        HStack {
            Button(action: onOlder) { chevron("chevron.left") }
                .accessibilityLabel("前の\(unit)")
            Spacer()
            VStack(spacing: 2) {
                if isCurrent { Text(currentCaption).font(.caption).foregroundStyle(.secondary) }
                Text(label).font(.subheadline.monospacedDigit())
            }
            Spacer()
            Button(action: onNewer) { chevron("chevron.right") }
                .disabled(isCurrent)
                .accessibilityLabel("次の\(unit)")
        }
        .buttonStyle(.borderless)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
