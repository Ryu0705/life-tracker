import Testing
import SwiftUI
import UIKit
@testable import LifeTracker

/// 種目の画像と部位の図 (2026-10-15・docs/exercise-images-design.md)
struct ExerciseImageTests {
    @Test func 対応表のすべての画像がアプリに入っている() {
        #expect(!ExerciseImageNames.byName.isEmpty)
        for (name, asset) in ExerciseImageNames.byName {
            #expect(UIImage(named: asset) != nil, "\(name) → \(asset)")
        }
        #expect(Set(ExerciseImageNames.byName.values).count == ExerciseImageNames.byName.count)
    }

    @Test func 部位の図は形のある12部位で正方形に切り出す() {
        let box = CGRect(x: 0, y: 0, width: BodyDiagramPaths.viewBox.width, height: BodyDiagramPaths.viewBox.height)
        for muscle in Exercise.MuscleGroup.allCases {
            let crop = MuscleBadge.cropRect(for: muscle)
            guard let front = MuscleBadge.isFront(muscle) else {
                #expect(crop == nil, "\(muscle)")
                continue
            }
            guard let crop else {
                Issue.record("\(muscle) の切り出しが無い")
                continue
            }
            let bounds = BodyDiagramView.paths(for: muscle, front: front).reduce(CGRect.null) { $0.union($1.boundingRect) }
            #expect(abs(crop.width - crop.height) < 0.001, "\(muscle)")
            #expect(box.contains(crop), "\(muscle) \(crop)")
            #expect(crop.contains(bounds), "\(muscle) \(crop) \(bounds)")
        }
        #expect(MuscleBadge.crops.count == 12)
        #expect(MuscleBadge.crops[.cardio] == nil && MuscleBadge.crops[.fullBody] == nil)
    }
}
