import Testing
import Foundation
@testable import LifeTracker

private func exercise(_ name: String) -> Exercise {
    Exercise(id: UUID(), name: name, muscleGroup: .chest, equipment: nil, metricKind: .weightReps, note: nil, isArchived: false, sortOrder: nil)
}

@Suite("ProgramStore — プログラムの登録・呼び出し")
@MainActor
struct ProgramStoreTests {
    let bench = exercise("ベンチプレス")
    let incline = exercise("インクライン")
    let pushdown = exercise("プッシュダウン")

    @Test("新規登録: 種目は選んだ順で並び、登録順に一覧へ出る。target は持たない")
    func create() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, incline, pushdown])
        let store = ProgramStore(dataSource: source)
        #expect(await store.save(id: nil, name: " 胸の日 ", exerciseIds: [incline.id, bench.id]) == nil)
        #expect(await store.save(id: nil, name: "腕", exerciseIds: [pushdown.id]) == nil)
        #expect(store.programs.map(\.name) == ["胸の日", "腕"])
        #expect(store.programs[0].exerciseIds == [incline.id, bench.id])
        #expect(source.routineExercises.allSatisfy { $0.targetSets == nil && $0.targetReps == nil && $0.targetWeight == nil })
    }

    @Test("編集: 名前と種目の並びを丸ごと置き換える。重複した種目は 1 つにまとめる")
    func edit() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, incline, pushdown])
        let store = ProgramStore(dataSource: source)
        _ = await store.save(id: nil, name: "胸の日", exerciseIds: [bench.id, incline.id])
        let id = try #require(store.programs.first?.id)
        #expect(await store.save(id: id, name: "胸と三頭", exerciseIds: [pushdown.id, bench.id, pushdown.id]) == nil)
        #expect(store.programs.count == 1)
        #expect(store.programs[0].name == "胸と三頭")
        #expect(store.programs[0].exerciseIds == [pushdown.id, bench.id])
    }

    @Test("名前が空・種目が 0 なら保存しない")
    func validation() async {
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = ProgramStore(dataSource: source)
        #expect(await store.save(id: nil, name: "  ", exerciseIds: [bench.id]) as? ProgramStore.SaveError == .emptyName)
        #expect(await store.save(id: nil, name: "胸", exerciseIds: []) as? ProgramStore.SaveError == .noExercises)
        #expect(source.routines.isEmpty)
    }

    @Test("種目の書き込みが途中で失敗しても、同じ保存のやり直しで揃う")
    func retryAfterPartialFailure() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, incline])
        let store = ProgramStore(dataSource: source)
        _ = await store.save(id: nil, name: "胸の日", exerciseIds: [bench.id])
        let id = try #require(store.programs.first?.id)
        source.failNextRoutineExerciseInsert = true
        #expect(await store.save(id: id, name: "胸の日", exerciseIds: [bench.id, incline.id]) != nil)
        #expect(store.programs[0].exerciseIds.isEmpty) // 途中で止まった状態が一覧に反映される
        #expect(await store.save(id: id, name: "胸の日", exerciseIds: [bench.id, incline.id]) == nil)
        #expect(store.programs[0].exerciseIds == [bench.id, incline.id])
    }

    @Test("同じ内容の判定は種目の並びまで一致したときだけ。今日が空なら該当なし")
    func sameOrder() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, incline, pushdown])
        let store = ProgramStore(dataSource: source)
        _ = await store.save(id: nil, name: "胸の日", exerciseIds: [bench.id, incline.id])
        #expect(store.program(withSameOrderAs: [bench.id, incline.id])?.name == "胸の日")
        #expect(store.program(withSameOrderAs: [incline.id, bench.id]) == nil)
        #expect(store.program(withSameOrderAs: [bench.id]) == nil)
        #expect(store.program(withSameOrderAs: [bench.id, incline.id, pushdown.id]) == nil)
        #expect(store.program(withSameOrderAs: []) == nil)
    }

    @Test("今日の種目で上書き: 名前と id はそのまま、種目の並びが今日のものに置き換わる。ほかのプログラムは変わらない")
    func overwriteWithToday() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, incline, pushdown])
        let store = ProgramStore(dataSource: source)
        _ = await store.save(id: nil, name: "胸の日", exerciseIds: [bench.id, incline.id])
        _ = await store.save(id: nil, name: "腕", exerciseIds: [pushdown.id])
        let chest = try #require(store.programs.first)
        let today = [incline.id, bench.id, pushdown.id]
        let draft = ProgramDraft.overwrite(chest, with: today)
        #expect(draft.programId == chest.id && draft.name == "胸の日" && draft.exerciseIds == today)
        #expect(await store.save(id: draft.programId, name: draft.name, exerciseIds: draft.exerciseIds) == nil)
        #expect(store.programs.map(\.name) == ["胸の日", "腕"])
        #expect(store.programs[0].id == chest.id)
        #expect(store.programs[0].exerciseIds == today)
        #expect(store.programs[1].exerciseIds == [pushdown.id])
        #expect(store.program(withSameOrderAs: today)?.id == chest.id)
    }

    @Test("削除は論理削除で、一覧から消える (再読み込みでも出ない)")
    func archive() async throws {
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = ProgramStore(dataSource: source)
        _ = await store.save(id: nil, name: "胸の日", exerciseIds: [bench.id])
        #expect(await store.archive(try #require(store.programs.first)) == nil)
        #expect(store.programs.isEmpty)
        #expect(source.routines.first?.isArchived == true)
        await store.load()
        #expect(store.programs.isEmpty)
    }

    @Test("プログラムの読み込みは今日の store の下書きに触れず、既存の追加経路で行が前回値で埋まる")
    func loadIntoToday() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, incline])
        let programs = ProgramStore(dataSource: source)
        _ = await programs.save(id: nil, name: "胸の日", exerciseIds: [bench.id, incline.id])
        let today = WorkoutSessionStore(dataSource: source, calendar: .current)
        await today.load()
        await today.addPlannedExercise(bench.id)
        today.updateDraft(exerciseId: bench.id, draftId: try #require(today.drafts[bench.id]?.first?.id),
                          input: WorkoutSetInput(weight: 50, reps: 5))
        await programs.load()
        for exerciseId in try #require(programs.programs.first).exerciseIds where !today.todayExerciseIds.contains(exerciseId) {
            await today.addPlannedExercise(exerciseId)
        }
        #expect(today.todayExerciseIds == [bench.id, incline.id])
        #expect(today.drafts[bench.id]?.first?.input.weight == 50)
    }
}
