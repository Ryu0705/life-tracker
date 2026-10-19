import SwiftUI

/// 種目のイメージ画像 (2026-10-15 本人決定。docs/exercise-images-design.md)。
/// 画像は本人が ChatGPT で生成したもの (アセット Exercise<sort_order>・対応表は生成物 ExerciseImageNames)。
/// 画像の無い種目は薄い灰色の地に人の形の記号。showsMuscle なら右下に部位の図 (MuscleBadge) を重ねる
struct ExerciseImageView: View {
    let exercise: Exercise
    let size: CGFloat
    var showsMuscle = false

    var body: some View {
        ZStack {
            if let name = ExerciseImageNames.byName[exercise.name] {
                Image(name).resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(size * 0.18, 16), style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if showsMuscle, MuscleBadge.crops[exercise.muscleGroup] != nil {
                // 参考画像 (IMG_2199) と同じく、絵の右下から少しはみ出す
                MuscleBadge(muscle: exercise.muscleGroup)
                    .frame(width: size * 0.44, height: size * 0.44)
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        // 名前は隣の文字が読む
        .accessibilityHidden(true)
    }
}

/// 部位の図: 強さの人体図の素材 (js-rich-body-highlighter・MIT) から、その部位の周りを正方形に切り出して赤く塗る。
/// 種目の画像とは別に持ち、その場で描いて重ねる (2026-10-15 本人「別画像として保持すべき」)。有酸素・全身は形が無いので出さない
struct MuscleBadge: View {
    let muscle: Exercise.MuscleGroup

    @Environment(\.colorScheme) private var colorScheme

    /// 前面で描くか背面で描くか (2026-10-15 AI 既定)。nil = 塗る形が無い
    static func isFront(_ muscle: Exercise.MuscleGroup) -> Bool? {
        switch muscle {
        case .chest, .shoulders, .biceps, .forearms, .core, .quads: return true
        case .back, .traps, .triceps, .glutes, .hamstrings, .calves: return false
        case .cardio, .fullBody: return nil
        }
    }

    /// 切り出す正方形 (viewBox の座標)。部位の形の外接矩形の長い辺の 1.6 倍を一辺にし、はみ出す分は viewBox の中へずらす
    static func cropRect(for muscle: Exercise.MuscleGroup) -> CGRect? {
        guard let front = isFront(muscle) else { return nil }
        let bounds = BodyDiagramView.paths(for: muscle, front: front).reduce(CGRect.null) { $0.union($1.boundingRect) }
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        let box = BodyDiagramPaths.viewBox
        let side = min(max(bounds.width, bounds.height) * 1.6, box.width, box.height)
        let x = min(max(bounds.midX - side / 2, 0), box.width - side)
        let y = min(max(bounds.midY - side / 2, 0), box.height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 起動後 1 回だけ作る
    static let crops: [Exercise.MuscleGroup: CGRect] = Dictionary(uniqueKeysWithValues:
        Exercise.MuscleGroup.allCases.compactMap { muscle in cropRect(for: muscle).map { (muscle, $0) } })

    /// 種目の画像の赤に寄せる
    static let red = Color(red: 0.91, green: 0.30, blue: 0.24)

    var body: some View {
        if let front = Self.isFront(muscle), let crop = Self.crops[muscle] {
            GeometryReader { geo in
                let scale = geo.size.width / crop.width
                let box = BodyDiagramPaths.viewBox
                let parts = BodyDiagramView.paths(for: muscle, front: front)
                    .map { $0.applying(CGAffineTransform(scaleX: scale, y: scale)) }
                let image = Image("BodyMale\(front ? "Front" : "Back")").resizable()
                // 体全体を viewBox の大きさで描いてから、切り出す正方形が左上に来るようにずらす
                ZStack(alignment: .topLeading) {
                    image.opacity(0.45)
                    ForEach(parts.indices, id: \.self) { index in
                        image.mask(parts[index])
                        parts[index].fill(Self.red)
                            // 強さの人体図と同じ: 明るい画像は乗算、暗い画像は色を重ねる
                            .blendMode(colorScheme == .dark ? .color : .multiply)
                    }
                }
                .frame(width: box.width * scale, height: box.height * scale, alignment: .topLeading)
                .compositingGroup()
                .offset(x: -crop.minX * scale, y: -crop.minY * scale)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
        }
    }
}
