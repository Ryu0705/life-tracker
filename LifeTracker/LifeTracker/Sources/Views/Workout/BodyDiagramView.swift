import SwiftUI

/// 強さの人体図: 前面・背面を横並び。0〜1 の正規化座標に部位ごとの基本図形を置く (Path の手描きはしない。レビュー A-13 代案 1)。
/// 塗り = 級の色、輪郭 = .secondary。小さい部位は図の下の一覧からも同じシートを開ける
struct BodyDiagramView: View {
    let states: [Exercise.MuscleGroup: MuscleState]
    let onSelect: (Exercise.MuscleGroup) -> Void

    private enum Kind { case ellipse, capsule, rounded }

    /// x, y, 幅, 高さ (図 1 枚の幅 = 1、高さ = 1。縦横比 1:2 の枠に置く)
    private struct Part {
        let muscle: Exercise.MuscleGroup?
        let kind: Kind
        let rect: CGRect
    }

    private static func pair(_ muscle: Exercise.MuscleGroup?, _ kind: Kind, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> [Part] {
        [Part(muscle: muscle, kind: kind, rect: CGRect(x: x, y: y, width: w, height: h)),
         Part(muscle: muscle, kind: kind, rect: CGRect(x: 1 - x - w, y: y, width: w, height: h))]
    }

    /// 頭・首・手・骨盤 (部位なし・薄い灰)
    private static let frame: [Part] = [
        Part(muscle: nil, kind: .ellipse, rect: CGRect(x: 0.41, y: 0.0, width: 0.18, height: 0.09)),
        Part(muscle: nil, kind: .rounded, rect: CGRect(x: 0.46, y: 0.085, width: 0.08, height: 0.04)),
        Part(muscle: nil, kind: .rounded, rect: CGRect(x: 0.36, y: 0.445, width: 0.28, height: 0.05)),
    ] + pair(nil, .ellipse, x: 0.11, y: 0.51, w: 0.08, h: 0.05)

    private static let front: [Part] = frame
        + pair(.shoulders, .ellipse, x: 0.19, y: 0.125, w: 0.16, h: 0.08)
        + pair(.chest, .rounded, x: 0.335, y: 0.135, w: 0.16, h: 0.1)
        + pair(.biceps, .capsule, x: 0.17, y: 0.2, w: 0.1, h: 0.15)
        + pair(.forearms, .capsule, x: 0.12, y: 0.355, w: 0.09, h: 0.15)
        + [Part(muscle: .core, kind: .rounded, rect: CGRect(x: 0.375, y: 0.245, width: 0.25, height: 0.195))]
        + pair(.quads, .capsule, x: 0.335, y: 0.5, w: 0.15, h: 0.23)
        + pair(.calves, .capsule, x: 0.35, y: 0.75, w: 0.115, h: 0.21)

    private static let back: [Part] = frame
        + [Part(muscle: .traps, kind: .rounded, rect: CGRect(x: 0.36, y: 0.11, width: 0.28, height: 0.07))]
        + pair(.shoulders, .ellipse, x: 0.19, y: 0.125, w: 0.16, h: 0.08)
        + pair(.back, .rounded, x: 0.335, y: 0.185, w: 0.16, h: 0.25)
        + pair(.triceps, .capsule, x: 0.17, y: 0.2, w: 0.1, h: 0.15)
        + pair(.forearms, .capsule, x: 0.12, y: 0.355, w: 0.09, h: 0.15)
        + pair(.glutes, .ellipse, x: 0.34, y: 0.425, w: 0.155, h: 0.1)
        + pair(.hamstrings, .capsule, x: 0.335, y: 0.53, w: 0.15, h: 0.2)
        + pair(.calves, .capsule, x: 0.35, y: 0.75, w: 0.115, h: 0.21)

    var body: some View {
        HStack(spacing: 16) {
            figure(Self.front, title: "前")
            figure(Self.back, title: "後")
        }
    }

    private func figure(_ parts: [Part], title: String) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    ForEach(parts.indices, id: \.self) { index in
                        shape(parts[index], in: size)
                    }
                }
            }
            .aspectRatio(0.5, contentMode: .fit)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func shape(_ part: Part, in size: CGSize) -> some View {
        let rect = CGRect(x: part.rect.minX * size.width, y: part.rect.minY * size.height,
                          width: part.rect.width * size.width, height: part.rect.height * size.height)
        let fill = part.muscle.map { Self.color(states[$0] ?? .noRecord) } ?? Color.secondary.opacity(0.08)
        let base = Group {
            switch part.kind {
            case .ellipse: Ellipse().fill(fill).overlay(Ellipse().stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
            case .capsule: Capsule().fill(fill).overlay(Capsule().stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
            case .rounded:
                RoundedRectangle(cornerRadius: rect.width * 0.25).fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: rect.width * 0.25).stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        if let muscle = part.muscle {
            base
                .contentShape(Rectangle())
                .onTapGesture { onSelect(muscle) }
                .accessibilityElement()
                .accessibilityLabel(muscle.displayName)
                .accessibilityAddTraits(.isButton)
        } else {
            base.accessibilityHidden(true)
        }
    }

    /// 灰 = 記録なし・基準なし、級は 6 段 (Beginner 未満 = 最も薄い)
    static func color(_ state: MuscleState) -> Color {
        switch state {
        case .noRecord: return Color.secondary.opacity(0.15)
        case .noStandard: return Color.secondary.opacity(0.3)
        case .level(let value): return color(level: value)
        }
    }

    static func color(level value: Double) -> Color {
        let step = value < 1 ? 0 : min(5, Int(value))
        return Color.blue.opacity([0.15, 0.3, 0.45, 0.62, 0.8, 1][step])
    }
}
