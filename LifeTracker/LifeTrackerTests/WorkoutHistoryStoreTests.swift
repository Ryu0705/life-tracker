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

/// 日を指定しなければ at の JST の日 (時刻なしは 9/28)
private func set(_ exercise: Exercise, _ index: Int = 1, weight: Double = 60, reps: Int = 10, at: Date?,
                 session: UUID = sharedSession, entry: UUID? = nil, day: Date? = nil) -> WorkoutSet {
    WorkoutSet(id: UUID(), sessionId: session, exerciseId: exercise.id, entryId: entry ?? backfillEntryId(session, exercise.id),
               setIndex: index, weight: weight, reps: reps,
               durationSec: nil, distanceM: nil, rpe: nil, isWarmup: false, completedAt: at,
               day: day ?? trainingDayJST(at ?? jstDate("2026-09-28T00:00:00")))
}

@Suite("MockWorkoutDataSource — 期間取得")
@MainActor
struct MockWorkoutRangeTests {
    @Test("セットの day の半開区間 [from, to) で、completed_at が無いセットは含まない。並びは day・completed_at 順")
    func halfOpen() async throws {
        let bench = exercise("ベンチプレス")
        let inside = set(bench, 1, at: jstDate("2026-09-28T00:00:00"))
        // 日曜 (10/4) に 0:30 (月曜の時刻) に記録したセットは日曜の週に入る。月曜 0:00 の日のセットは入らない
        let sundayLate = set(bench, 4, at: jstDate("2026-10-05T00:30:00"), day: jstDate("2026-10-04T00:00:00"))
        let source = MockWorkoutDataSource(exercises: [bench], sets: [
            sundayLate, inside, set(bench, 2, at: jstDate("2026-10-05T00:00:00")), set(bench, 3, at: nil),
            set(bench, 5, at: jstDate("2026-09-27T23:59:00")),
        ])
        let fetched = try await source.fetchSets(daysFrom: jstDate("2026-09-28T00:00:00"), to: jstDate("2026-10-05T00:00:00"))
        #expect(fetched.map(\.id) == [inside.id, sundayLate.id])
    }
}

private final class Flag {
    var value = false
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

    @Test("月曜 0:30 に日曜へ記録したセットは日曜の週・日曜の sets(on:)・日曜の点 (付録 B-5)")
    func lateSundaySetBelongsToSunday() async {
        let sunday = jstDate("2026-10-04T00:00:00")
        let nextMonday = jstDate("2026-10-05T00:00:00")
        let late = set(bench, 1, at: jstDate("2026-10-05T00:30:00"), session: UUID(), day: sunday)
        let mondaySet = set(bench, 1, at: jstDate("2026-10-05T19:00:00"), session: UUID())
        let source = MockWorkoutDataSource(exercises: [bench], sets: [late, mondaySet])
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.ensureLoaded(weekStarts: [monday, nextMonday])
        #expect(store.sets(inWeekStarting: monday).map(\.id) == [late.id])
        #expect(store.sets(inWeekStarting: nextMonday).map(\.id) == [mondaySet.id])
        #expect(store.sets(on: sunday).map(\.id) == [late.id])
        #expect(store.sets(on: nextMonday).map(\.id) == [mondaySet.id])
        #expect(store.recordedDays == [sunday, nextMonday])
        #expect(store.entries(on: sunday).map(\.id) == [late.entryId])
    }

    @Test("日曜の週だけを読んでも、月曜 0:30 に日曜へ記録したセットは日曜の週に入る (取りこぼさない)")
    func lateSundaySetLoadedWithSundayWeek() async {
        let sunday = jstDate("2026-10-04T00:00:00")
        let late = set(bench, 1, at: jstDate("2026-10-05T00:30:00"), session: UUID(), day: sunday)
        let source = MockWorkoutDataSource(exercises: [bench], sets: [late])
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.ensureLoaded(weekStarts: [monday])
        #expect(store.sets(on: sunday).map(\.id) == [late.id])
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

    /// 止めた fetchSets に届くまで進める
    private func waitUntilPending(_ source: MockWorkoutDataSource, _ count: Int = 1) async {
        while source.pendingFetchSets < count { await Task.yield() }
    }

    @Test("取得中の週を別の呼び出しが頼むと、その取得を待ってから返る。フェッチは 1 回")
    func waitsForInFlight() async {
        let source = MockWorkoutDataSource(exercises: [bench], sets: [set(bench, at: jstDate("2026-09-29T07:00:00"))])
        source.holdsFetchSets = true
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        let first = Task { await store.ensureLoaded(weekStarts: [monday]) }
        await waitUntilPending(source)
        let returned = Flag()
        let second = Task {
            await store.ensureLoaded(weekStarts: [monday])
            returned.value = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!returned.value, "取得中の週を待たずに返っている")
        source.releaseFetchSets()
        await second.value
        #expect(store.isLoaded(weekStart: monday))
        #expect(source.fetchRangeCallCount == 1)
        await first.value
    }

    @Test("先に頼んだ側が取り消されても取得は続いて weeks に入り、後から頼んだ側は読めた状態で返る")
    func cancelledCallerDoesNotDropFetch() async {
        let source = MockWorkoutDataSource(exercises: [bench], sets: [set(bench, at: jstDate("2026-09-29T07:00:00"))])
        source.holdsFetchSets = true
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        let first = Task { await store.ensureLoaded(weekStarts: [monday]) }
        await waitUntilPending(source)
        first.cancel()
        let second = Task { await store.ensureLoaded(weekStarts: [monday]) }
        for _ in 0..<5 { await Task.yield() }
        source.releaseFetchSets()
        await second.value
        #expect(store.isLoaded(weekStart: monday))
        #expect(store.sets(inWeekStarting: monday).count == 1)
        #expect(store.error == nil && !store.isLoading)
        #expect(source.fetchRangeCallCount == 1)
    }

    @Test("取得中に invalidate すると結果は捨て、世代が 1 増える。もう一度頼むと取り直す")
    func invalidateWhileInFlight() async {
        let source = MockWorkoutDataSource(exercises: [bench], sets: [set(bench, at: jstDate("2026-09-29T07:00:00"))])
        source.holdsFetchSets = true
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        let first = Task { await store.ensureLoaded(weekStarts: [monday]) }
        await waitUntilPending(source)
        let generation = store.generation
        store.invalidate()
        #expect(store.generation == generation + 1)
        source.holdsFetchSets = false
        source.releaseFetchSets()
        await first.value
        #expect(!store.isLoaded(weekStart: monday))
        await store.ensureLoaded(weekStarts: [monday])
        #expect(store.isLoaded(weekStart: monday))
        #expect(source.fetchRangeCallCount == 2)
    }

    @Test("invalidate の後に始まった取得の印は、古い取得の完了で消さない")
    func staleFetchKeepsNewInFlight() async {
        let source = MockWorkoutDataSource(exercises: [bench], sets: [set(bench, at: jstDate("2026-09-29T07:00:00"))])
        source.holdsFetchSets = true
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        let old = Task { await store.ensureLoaded(weekStarts: [monday]) }
        await waitUntilPending(source)
        store.invalidate()
        let fresh = Task { await store.ensureLoaded(weekStarts: [monday]) }
        await waitUntilPending(source, 2)
        source.releaseFetchSets()
        await old.value
        await fresh.value
        #expect(store.isLoaded(weekStart: monday) && !store.isLoading)
        // 3 つ目は読めた週なので取りに行かない
        await store.ensureLoaded(weekStarts: [monday])
        #expect(source.fetchRangeCallCount == 2)
    }

    @Test("取得が失敗すると取得中の印が外れ、次の呼び出しで取り直す")
    func failureClearsInFlight() async {
        let source = MockWorkoutDataSource(exercises: [bench], sets: [set(bench, at: jstDate("2026-09-29T07:00:00"))])
        source.failNextFetchSets = true
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.ensureLoaded(weekStarts: [monday])
        #expect(!store.isLoaded(weekStart: monday) && store.error != nil && !store.isLoading)
        await store.ensureLoaded(weekStarts: [monday])
        #expect(store.isLoaded(weekStart: monday))
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
