import SwiftUI

/// 強さの人体図: 写実の筋肉画像 (前面・背面を横並び) に部位マスクをランクの色で乗算して重ねる (2026-10-13 本人 F-3)。
/// 素材は js-rich-body-highlighter (MIT。docs/body-diagram/)。画像 = Assets の Body{Male,Female}{Front,Back}、マスク = BodyDiagramPaths (生成物)。
/// 記録なし・基準なしは塗らない。タップはマスクの形で判定。小さい部位は図の下の一覧からも同じシートを開ける
struct BodyDiagramView: View {
    let states: [Exercise.MuscleGroup: MuscleState]
    var female = false
    let onSelect: (Exercise.MuscleGroup) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 素材の部位 → アプリの部位。背面の僧帽筋は背中上部と 1 つの形 (upper_back) なので僧帽筋に寄せる
    static func muscle(group: String) -> Exercise.MuscleGroup? {
        switch group {
        case "chest": return .chest
        case "shoulders": return .shoulders
        case "biceps": return .biceps
        case "triceps": return .triceps
        case "forearms": return .forearms
        case "abs", "obliques": return .core
        case "upper_back": return .traps
        case "lats", "lower_back": return .back
        case "glutes": return .glutes
        case "quads": return .quads
        case "hamstrings": return .hamstrings
        case "calves": return .calves
        default: return nil
        }
    }

    private struct Shape: Identifiable {
        let id: String
        let muscle: Exercise.MuscleGroup
        let path: Path
    }

    /// 起動後 1 回だけ文字列から Path を作る (36 枚)
    private static let shapes: [String: Shape] = {
        var result: [String: Shape] = [:]
        for mask in BodyDiagramPaths.masks {
            guard let muscle = muscle(group: mask.group) else { continue }
            result[mask.id] = Shape(id: mask.id, muscle: muscle, path: path(mask.d))
        }
        return result
    }()

    private func shapes(front: Bool) -> [Shape] {
        BodyDiagramPaths.masks.filter { $0.front == front && $0.female == female }.compactMap { Self.shapes[$0.id] }
    }

    /// 部位 1 つの形 (viewBox の座標)。種目の画像に重ねる部位の図 (MuscleBadge) が使う
    static func paths(for muscle: Exercise.MuscleGroup, front: Bool, female: Bool = false) -> [Path] {
        BodyDiagramPaths.masks.filter { $0.front == front && $0.female == female }
            .compactMap { shapes[$0.id] }
            .filter { $0.muscle == muscle }
            .map(\.path)
    }

    var body: some View {
        HStack(spacing: 12) {
            figure(front: true, title: "前")
            figure(front: false, title: "後")
        }
    }

    private func figure(front: Bool, title: String) -> some View {
        let parts = shapes(front: front)
        let box = BodyDiagramPaths.viewBox
        return VStack(spacing: 4) {
            GeometryReader { geo in
                let scale = geo.size.width / box.width
                let transform = CGAffineTransform(scaleX: scale, y: scale)
                let image = Image("Body\(female ? "Female" : "Male")\(front ? "Front" : "Back")").resizable()
                let painted = parts.filter { Self.color(states[$0.muscle] ?? .noRecord) != .clear }
                ZStack(alignment: .topLeading) {
                    // 塗らない部位は薄く引く (Silver は灰に近く、同じ濃さだと塗ったのか分からない)
                    image.opacity(0.45)
                    ForEach(painted) { part in
                        let shape = part.path.applying(transform)
                        image.mask(shape)
                        shape.fill(Self.color(states[part.muscle] ?? .noRecord))
                            // 明るい画像は乗算で筋の溝に色を残す。暗い画像は乗算だと沈むので色を重ねる
                            .blendMode(colorScheme == .dark ? .color : .multiply)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .compositingGroup()
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let point = location.applying(transform.inverted())
                    if let hit = parts.first(where: { $0.path.contains(point) }) { onSelect(hit.muscle) }
                }
            }
            .aspectRatio(box.width / box.height, contentMode: .fit)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        // 部位ごとの操作は図の下の一覧が担う (VoiceOver もそちら)
        .accessibilityHidden(true)
    }

    /// 生成物の d (絶対座標の M/L/C/Q/Z だけ) → Path
    static func path(_ d: String) -> Path {
        var path = Path()
        let tokens = d.split(separator: " ")
        var i = 0
        func point() -> CGPoint {
            defer { i += 2 }
            return CGPoint(x: Double(tokens[i])!, y: Double(tokens[i + 1])!)
        }
        while i < tokens.count {
            let command = tokens[i]
            i += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C":
                let c1 = point(), c2 = point()
                path.addCurve(to: point(), control1: c1, control2: c2)
            case "Q":
                let c = point()
                path.addQuadCurve(to: point(), control: c)
            case "Z": path.closeSubpath()
            default: assertionFailure("未対応のコマンド \(command)")
            }
        }
        return path
    }

    /// 記録なし・基準なしは塗らない (輪郭だけ。Silver の灰と取り違えない・F-7)、級はランクの色
    static func color(_ state: MuscleState) -> Color {
        switch state {
        case .noRecord, .noStandard: return Color.clear
        case .level(let value): return color(rank: StrengthLevels.rank(value).rank)
        }
    }

    /// Apex 風の 6 色 (銅・銀・金・プラチナの青緑・ダイヤの青・マスターの紫)
    static func color(rank: StrengthLevels.Rank) -> Color {
        switch rank {
        case .bronze: return Color(red: 0.69, green: 0.44, blue: 0.25)
        case .silver: return Color(red: 0.62, green: 0.70, blue: 0.82)
        case .gold: return Color(red: 0.88, green: 0.71, blue: 0.23)
        case .platinum: return Color(red: 0.25, green: 0.72, blue: 0.69)
        case .diamond: return Color(red: 0.24, green: 0.48, blue: 0.95)
        case .master: return Color(red: 0.61, green: 0.30, blue: 0.88)
        }
    }
}
