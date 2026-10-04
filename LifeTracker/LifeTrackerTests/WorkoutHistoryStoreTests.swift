import Testing
import Foundation
@testable import LifeTracker

private let jst: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return cal
}()

private func jstDate(_ local: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: "\(local)+09:00")!
}

private func exercise(_ name: String, _ muscle: Exercise.MuscleGroup = .chest) -> Exercise {
    Exercise(id: UUID(), name: name, muscleGroup: muscle, equipment: nil, metricKind: .weightReps, note: nil, isArchived: false, sortOrder: nil)
}

/// 既定は 1 つのセッション (日ごとの絞り込みはセットの completed_at で行うため)。entry は (セッション, 種目) ごと
private let sharedSession = UUID()

private func set(_ exercise: Exercise, _ index: Int = 1, weight: Double = 60, reps: Int = 10, at: Date?,
                 session: UUID = sharedSession, entry: UUID? = nil) -> WorkoutSet {
    WorkoutSet(id: UUID(), sessionId: session, exerciseId: exercise.id, entryId: entry ?? backfillEntryId(session, exercise.id),
               setIndex: index, weight: weight, reps: reps,
               durationSec: nil, distanceM: nil, rpe: nil, isWarmup: false, completedAt: at)
}

@Suite("MockWorkoutDataSource — 期間取得")
@MainActor
struct MockWorkoutRangeTests {
    @Test("半開区間 [from, to) で、completed_at が無いセットは含まない")
    func halfOpen() async throws {
        let bench = exercise("ベンチプレス")
        let inside = set(bench, 1, at: jstDate("2026-09-28T00:00:00"))
        let source = MockWorkoutDataSource(exercises: [bench], sets: [
            inside, set(bench, 2, at: jstDate("2026-10-05T00:00:00")), set(bench, 3, at: nil),
        ])
        let fetched = try await source.fetchSets(completedFrom: jstDate("2026-09-28T00:00:00"), to: jstDate("2026-10-05T00:00:00"))
        #expect(fetched.map(\.id) == [inside.id])
    }
}

@Suite("WorkoutHistoryStore — 読み取り専用の週キャッシュ")
@MainActor
struct WorkoutHistoryStoreTests {
    let bench = exercise("ベンチプレス")
    let monday = jstDate("2026-09-28T00:00:00")

    @Test("同じ週を 2 回 ensureLoaded してもフェッチは 1 回。複数週はまとめて 1 回")
    func cachesWeeks() async {
        let source = MockWorkoutDataSource(exercises: [bench], sets: [set(bench, at: jstDate("2026-09-29T07:00:00"))])
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.ensureLoaded(weekStarts: [monday])
        await store.ensureLoaded(weekStarts: [jstDate("2026-09-30T12:00:00")])
        #expect(source.fetchRangeCallCount == 1)
        #expect(store.isLoaded(weekStart: monday))

        await store.ensureLoaded(weekStarts: WorkoutSummary.recentWeekStarts(today: monday, count: 5, calendar: jst))
        #expect(source.fetchRangeCallCount == 2)
        #expect(store.weeks.count == 5)
    }

    @Test("sets(on:) は JST の暦日で絞る (UTC 前日 15:30 = JST 0:30 は当日)")
    func setsOnDay() async {
        let early = set(bench, 1, at: jstDate("2026-09-30T00:30:00"))
        let source = MockWorkoutDataSource(exercises: [bench], sets: [
            early, set(bench, 2, at: jstDate("2026-09-29T23:30:00")), set(bench, 3, at: jstDate("2026-10-01T07:00:00")),
        ])
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.ensureLoaded(weekStarts: [monday])
        #expect(store.sets(on: jstDate("2026-09-30T12:00:00")).map(\.id) == [early.id])
        #expect(store.recordedDays == Set(["2026-09-29", "2026-09-30", "2026-10-01"].map { jstDate("\($0)T00:00:00") }))
        #expect(store.sets(inWeekStarting: monday).count == 3)
    }

    @Test("invalidate 後は再フェッチする")
    func invalidate() async {
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.ensureLoaded(weekStarts: [monday])
        store.invalidate()
        #expect(!store.isLoaded(weekStart: monday))
        await store.ensureLoaded(weekStarts: [monday])
        #expect(source.fetchRangeCallCount == 2)
    }

    @Test("推移一覧用の記録済み種目を読む")
    func recordedExerciseIds() async {
        let source = MockWorkoutDataSource(exercises: [bench], sets: [set(bench, at: monday)])
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.loadRecordedExerciseIds()
        #expect(store.recordedExerciseIds == [bench.id])
    }
}

@Suite("WorkoutSessionStore — 種目の入れ替え")
@MainActor
struct WorkoutSessionStoreReplaceTests {
    let bench = exercise("ベンチプレス")
    let incline = exercise("インクライン")
    let squat = exercise("スクワット", .quads)

    private func makeStore() -> (MockWorkoutDataSource, WorkoutSessionStore) {
        let source = MockWorkoutDataSource(exercises: [bench, incline, squat], sets: [
            set(incline, 1, weight: 20, reps: 12, at: jstDate("2026-09-27T07:00:00")),
            set(incline, 2, weight: 22, reps: 10, at: jstDate("2026-09-27T07:03:00")),
        ])
        return (source, WorkoutSessionStore(dataSource: source, calendar: jst, now: { jstDate("2026-09-30T07:00:00") }))
    }

    @Test("位置が保たれ、行は差し替え先の前回値で作り直される")
    func replaceKeepsPosition() async {
        let (_, store) = makeStore()
        await store.load()
        let benchCard = await store.addPlannedExercise(bench.id)
        await store.addPlannedExercise(squat.id)
        await store.replacePlannedCard(benchCard, with: incline.id)
        #expect(store.todayExerciseIds == [incline.id, squat.id])
        #expect(store.drafts[benchCard.id] == nil)
        #expect(store.drafts[store.cards[0].id]?.map(\.input.weight) == [20, 22])
    }

    @Test("記録済みのカードは入れ替えない")
    func recordedCardRejected() async {
        let (_, store) = makeStore()
        await store.load()
        let benchCard = await store.addPlannedExercise(bench.id)
        _ = await store.addSet(card: benchCard, exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        await store.replacePlannedCard(benchCard, with: incline.id)
        #expect(store.todayExerciseIds == [bench.id])
    }

    @Test("すでに今日にある種目への入れ替えは 2 枚目になる (E11)。自分と同じ種目への入れ替えは何もしない")
    func replaceIntoExistingBecomesSecondCard() async {
        let (_, store) = makeStore()
        await store.load()
        let benchCard = await store.addPlannedExercise(bench.id)
        let squatCard = await store.addPlannedExercise(squat.id)
        await store.replacePlannedCard(benchCard, with: squat.id)
        #expect(store.todayExerciseIds == [squat.id, squat.id])
        #expect(store.drafts[benchCard.id] == nil)
        #expect(store.drafts[store.cards[0].id] != nil)
        await store.replacePlannedCard(squatCard, with: squat.id)
        #expect(store.cards[1].id == squatCard.id)
    }
}
