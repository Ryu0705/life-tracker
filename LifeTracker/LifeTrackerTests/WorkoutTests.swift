import Testing
import Foundation
@testable import LifeTracker

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

private func exercise(_ name: String, _ kind: MetricKind, id: UUID = UUID()) -> Exercise {
    Exercise(id: id, name: name, muscleGroup: .chest, equipment: nil, metricKind: kind, note: nil, isArchived: false, sortOrder: nil)
}

private func set(session: UUID, exercise: UUID, index: Int, weight: Double? = nil, reps: Int? = nil,
                 warmup: Bool = false, at: Date = Date()) -> WorkoutSet {
    WorkoutSet(id: UUID(), sessionId: session, exerciseId: exercise, setIndex: index, weight: weight, reps: reps,
               durationSec: nil, distanceM: nil, rpe: nil, isWarmup: warmup, completedAt: at)
}

@Suite("WorkoutSetInput.validate — metric_kind ごとの列の整合")
@MainActor
struct WorkoutSetInputTests {
    @Test("weight_reps は重量と回数が必須で、時間・距離は落とす")
    func weightReps() {
        let input = WorkoutSetInput(weight: 60, reps: 10, durationSec: 30, distanceM: 100)
        #expect(input.validate(for: .weightReps) == .success(.init(weight: 60, reps: 10, durationSec: nil, distanceM: nil, isWarmup: false)))
        #expect(WorkoutSetInput(weight: nil, reps: 10).validate(for: .weightReps) == .failure(.missingWeight))
        #expect(WorkoutSetInput(weight: 60, reps: 0).validate(for: .weightReps) == .failure(.missingReps))
    }

    @Test("weight_reps は 0kg を明示できる (加重なし)")
    func weightRepsZero() {
        #expect(WorkoutSetInput(weight: 0, reps: 12).validate(for: .weightReps) == .success(.init(weight: 0, reps: 12, durationSec: nil, distanceM: nil, isWarmup: false)))
    }

    @Test("reps_only は回数のみ残す")
    func repsOnly() {
        #expect(WorkoutSetInput(weight: 20, reps: 12).validate(for: .repsOnly) == .success(.init(weight: nil, reps: 12, durationSec: nil, distanceM: nil, isWarmup: false)))
        #expect(WorkoutSetInput().validate(for: .repsOnly) == .failure(.missingReps))
    }

    @Test("duration は時間のみ残し、距離欄を持たない")
    func duration() {
        #expect(WorkoutSetInput(durationSec: 60, distanceM: 50).validate(for: .duration) == .success(.init(weight: nil, reps: nil, durationSec: 60, distanceM: nil, isWarmup: false)))
        #expect(WorkoutSetInput().validate(for: .duration) == .failure(.missingDuration))
    }

    @Test("duration_distance は時間必須・距離任意")
    func durationDistance() {
        #expect(WorkoutSetInput(durationSec: 1200, distanceM: 3200).validate(for: .durationDistance) == .success(.init(weight: nil, reps: nil, durationSec: 1200, distanceM: 3200, isWarmup: false)))
        #expect(WorkoutSetInput(durationSec: 1200).validate(for: .durationDistance) == .success(.init(weight: nil, reps: nil, durationSec: 1200, distanceM: nil, isWarmup: false)))
        #expect(WorkoutSetInput(distanceM: 3200).validate(for: .durationDistance) == .failure(.missingDuration))
    }

    @Test("負の値は拒否する")
    func negative() {
        #expect(WorkoutSetInput(weight: -5, reps: 10).validate(for: .weightReps) == .failure(.negativeValue))
    }
}

@Suite("WorkoutLogic")
@MainActor
struct WorkoutLogicTests {
    let session = UUID()
    let bench = UUID()
    let squat = UUID()

    @Test("nextSetIndex は種目ごとの最大 + 1 (削除で空いた番号は再利用しない)")
    func nextSetIndex() {
        let sets = [set(session: session, exercise: bench, index: 1), set(session: session, exercise: bench, index: 3),
                    set(session: session, exercise: squat, index: 1)]
        #expect(WorkoutLogic.nextSetIndex(for: bench, in: sets) == 4)
        #expect(WorkoutLogic.nextSetIndex(for: squat, in: sets) == 2)
        #expect(WorkoutLogic.nextSetIndex(for: UUID(), in: sets) == 1)
    }

    @Test("groupByExercise は最初に記録した種目順・set_index 順")
    func group() {
        let t0 = date("2026-09-30T07:00:00+09:00")
        let sets = [
            set(session: session, exercise: squat, index: 1, at: t0.addingTimeInterval(600)),
            set(session: session, exercise: bench, index: 2, at: t0.addingTimeInterval(120)),
            set(session: session, exercise: bench, index: 1, at: t0),
        ]
        let grouped = WorkoutLogic.groupByExercise(sets)
        #expect(grouped.map(\.exerciseId) == [bench, squat])
        #expect(grouped[0].sets.map(\.setIndex) == [1, 2])
    }

    @Test("initialDrafts は前回の日のセットを行ごとに写し、今日記録済みの行数ぶんは消化済みとする")
    func initialDrafts() {
        let previous = [set(session: UUID(), exercise: bench, index: 1, weight: 40, reps: 12, warmup: true),
                        set(session: UUID(), exercise: bench, index: 2, weight: 60, reps: 10),
                        set(session: UUID(), exercise: bench, index: 3, weight: 65, reps: 8)]
        let fromPrevious = WorkoutLogic.initialDrafts(currentSets: [], previousSets: previous)
        #expect(fromPrevious.map(\.weight) == [40, 60, 65])
        #expect(fromPrevious.map(\.isWarmup) == [true, false, false])

        let current = [set(session: session, exercise: bench, index: 1, weight: 40, reps: 12, warmup: true)]
        #expect(WorkoutLogic.initialDrafts(currentSets: current, previousSets: previous).map(\.weight) == [60, 65])
        #expect(WorkoutLogic.initialDrafts(currentSets: current, previousSets: []).isEmpty)
        #expect(WorkoutLogic.initialDrafts(currentSets: [], previousSets: []) == [WorkoutSetInput()])
    }

    @Test("nextDraft は直前の行のコピー (ウォームアップは外す) → 前回の同じ位置 → 空")
    func nextDraft() {
        let last = WorkoutSetInput(weight: 40, reps: 12, isWarmup: true)
        let previous = set(session: UUID(), exercise: bench, index: 2, weight: 65, reps: 8)
        #expect(WorkoutLogic.nextDraft(lastRow: last, previousAtPosition: previous) == WorkoutSetInput(weight: 40, reps: 12))
        #expect(WorkoutLogic.nextDraft(lastRow: nil, previousAtPosition: previous) == WorkoutSetInput(weight: 65, reps: 8))
        #expect(WorkoutLogic.nextDraft(lastRow: nil, previousAtPosition: nil) == WorkoutSetInput())
    }

    @Test("重量の刻み: プレート系は 1.25kg / 5kg、ダンベル系は 2kg / 4kg")
    func weightSteps() {
        #expect(WorkoutLogic.weightSteps(for: .barbell) == (1.25, 5))
        #expect(WorkoutLogic.weightSteps(for: nil) == (1.25, 5))
        #expect(WorkoutLogic.weightSteps(for: .dumbbell) == (2, 4))
        #expect(WorkoutLogic.weightSteps(for: .kettlebell) == (2, 4))
    }

    @Test("endDate は started_at より必ず後 (CHECK ended_at > started_at)")
    func endDate() {
        let start = date("2026-09-30T07:00:00+09:00")
        #expect(WorkoutLogic.endDate(startedAt: start, now: start) > start)
        #expect(WorkoutLogic.endDate(startedAt: start, now: start.addingTimeInterval(3600)) == start.addingTimeInterval(3600))
    }

    @Test("summary の表示")
    func summary() {
        #expect(WorkoutLogic.summary(of: set(session: session, exercise: bench, index: 1, weight: 62.5, reps: 8), kind: .weightReps) == "62.5×8")
        #expect(WorkoutLogic.summary(of: set(session: session, exercise: bench, index: 1, weight: 60, reps: 10), kind: .weightReps) == "60×10")
        let run = WorkoutSet(id: UUID(), sessionId: session, exerciseId: bench, setIndex: 1, weight: nil, reps: nil,
                             durationSec: 1230, distanceM: 3200, rpe: nil, isWarmup: false, completedAt: nil)
        #expect(WorkoutLogic.summary(of: run, kind: .durationDistance) == "20:30・3.20km")
    }
}

@Suite("MockWorkoutDataSource")
@MainActor
struct MockWorkoutDataSourceTests {
    @Test("進行中セッションは同時 1 件まで")
    func singleInProgress() async throws {
        let source = MockWorkoutDataSource()
        _ = try await source.startSession(routineId: nil, startedAt: Date())
        await #expect(throws: MockWorkoutDataSource.MockError.sessionAlreadyInProgress) {
            _ = try await source.startSession(routineId: nil, startedAt: Date())
        }
    }

    @Test("セッション削除でセットも消える (ON DELETE CASCADE)")
    func deleteCascade() async throws {
        let source = MockWorkoutDataSource()
        let s = try await source.startSession(routineId: nil, startedAt: Date())
        _ = try await source.addSet(NewWorkoutSet(sessionId: s.id, exerciseId: UUID(), setIndex: 1, weight: 10, reps: 10,
                                                  durationSec: nil, distanceM: nil, isWarmup: false, completedAt: Date()))
        try await source.deleteSession(id: s.id)
        #expect(source.sets.isEmpty)
        #expect(try await source.fetchInProgressSession() == nil)
    }
}

@Suite("Workout モデルの Supabase デコード")
@MainActor
struct WorkoutDecodingTests {
    @Test("snake_case / NUMERIC / TIMESTAMPTZ / metric_kind をデコードできる")
    func decode() throws {
        let json = """
        [{"id":"8C1C4C8E-8A0B-4B0E-9D6B-0B7A1C2D3E4F","session_id":"1C1C4C8E-8A0B-4B0E-9D6B-0B7A1C2D3E4F",
          "exercise_id":"2C1C4C8E-8A0B-4B0E-9D6B-0B7A1C2D3E4F","set_index":2,"weight":62.50,"reps":8,
          "duration_sec":null,"distance_m":null,"rpe":null,"is_warmup":false,
          "completed_at":"2026-09-30T07:12:34.123456+09:00"}]
        """.data(using: .utf8)!
        let sets = try JSONDecoder.supabase.decode([WorkoutSet].self, from: json)
        #expect(sets.first?.weight == 62.5)
        #expect(sets.first?.setIndex == 2)

        let exerciseJSON = """
        [{"id":"8C1C4C8E-8A0B-4B0E-9D6B-0B7A1C2D3E4F","name":"プランク","muscle_group":"full_body",
          "equipment":"bodyweight","metric_kind":"duration","note":null,"is_archived":false,"sort_order":1300}]
        """.data(using: .utf8)!
        let exercises = try JSONDecoder.supabase.decode([Exercise].self, from: exerciseJSON)
        #expect(exercises.first?.metricKind == .duration)
        #expect(exercises.first?.muscleGroup == .fullBody)
    }
}

private let jst: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return cal
}()

/// テスト内で進められる時計
@MainActor
private final class TestClock {
    var now: Date
    init(_ iso: String) { now = date(iso) }
}

@Suite("WorkoutProgress — 前回・推移の導出")
@MainActor
struct WorkoutProgressTests {
    let session = UUID()
    let bench = UUID()

    @Test("日ごとのまとめは JST の暦日 (UTC では前日の 0:30 JST も当日扱い)")
    func dailyGroupsByJSTDay() {
        let sets = [set(session: session, exercise: bench, index: 1, weight: 60, reps: 10, at: date("2026-09-29T15:30:00Z")), // 9/30 0:30 JST
                    set(session: session, exercise: bench, index: 2, weight: 60, reps: 10, at: date("2026-09-30T07:00:00+09:00"))]
        let daily = WorkoutProgress.daily(sets, calendar: jst)
        #expect(daily.count == 1)
        #expect(daily.first?.sets.count == 2)
    }

    @Test("前回は今日より前で最も新しい日。今日の記録は前回にしない")
    func previousDayExcludesToday() {
        let sets = [set(session: UUID(), exercise: bench, index: 1, weight: 55, reps: 10, at: date("2026-09-20T07:00:00+09:00")),
                    set(session: UUID(), exercise: bench, index: 1, weight: 60, reps: 10, at: date("2026-09-28T07:00:00+09:00")),
                    set(session: session, exercise: bench, index: 1, weight: 70, reps: 3, at: date("2026-09-30T07:00:00+09:00"))]
        let previous = WorkoutProgress.previousDay(sets, today: date("2026-09-30T12:00:00+09:00"), calendar: jst)
        #expect(previous?.sets.map(\.weight) == [60])
    }

    @Test("指標: 最高重量 / 推定1RM (Epley) / ボリュームはウォームアップを除外")
    func metrics() {
        let sets = [set(session: session, exercise: bench, index: 1, weight: 100, reps: 10, warmup: true),
                    set(session: session, exercise: bench, index: 2, weight: 60, reps: 10),
                    set(session: session, exercise: bench, index: 3, weight: 65, reps: 8)]
        #expect(WorkoutProgress.value(of: .maxWeight, in: sets) == 65)
        #expect(WorkoutProgress.value(of: .estimatedOneRM, in: sets) == 65 * (1 + 8.0 / 30))
        #expect(WorkoutProgress.value(of: .volume, in: sets) == 1120.0) // 60×10 + 65×8
        #expect(WorkoutProgress.value(of: .maxReps, in: sets) == 10)
        #expect(WorkoutProgress.estimatedOneRM(weight: 100, reps: 1) == 100)
    }

    @Test("ウォームアップだけの日はグラフの点にしない")
    func warmupOnlyDayHasNoPoint() {
        let sets = [set(session: session, exercise: bench, index: 1, weight: 40, reps: 10, warmup: true, at: date("2026-09-28T07:00:00+09:00")),
                    set(session: session, exercise: bench, index: 1, weight: 60, reps: 10, at: date("2026-09-29T07:00:00+09:00"))]
        let points = WorkoutProgress.points(WorkoutProgress.daily(sets, calendar: jst), metric: .maxWeight)
        #expect(points.map(\.value) == [60])
    }

    @Test("指標の選択肢は metric_kind ごと。ウェイトは 3 つ・初期は最高重量")
    func availableMetrics() {
        #expect(ProgressMetric.available(for: .weightReps) == [.maxWeight, .estimatedOneRM, .volume])
        #expect(ProgressMetric.available(for: .durationDistance).first == .maxDistance)
    }
}

@Suite("WorkoutSessionStore — 開始・終了なしの記録")
@MainActor
struct WorkoutSessionStoreTests {
    let bench = exercise("ベンチプレス", .weightReps)

    @Test("最初のセット記録で当日のセッションが作られ、2 セット目は同じセッションに入る")
    func firstSetCreatesTodaySession() async throws {
        let clock = TestClock("2026-09-30T07:00:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        #expect(source.sessions.isEmpty) // 開くだけではセッションを作らない

        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        clock.now = clock.now.addingTimeInterval(180)
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 65, reps: 8))
        #expect(source.sessions.count == 1)
        #expect(Set(source.sets.map(\.sessionId)).count == 1)
        #expect(source.sets.map(\.setIndex).sorted() == [1, 2])
    }

    @Test("前日のセッションは次のロードで最後のセットの時刻で閉じ、今日は新しいセッションになる")
    func staleSessionClosedOnLoad() async throws {
        let clock = TestClock("2026-09-29T07:00:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        let lastSetAt = clock.now

        clock.now = date("2026-09-30T07:00:00+09:00")
        await store.load()
        #expect(store.session == nil)
        #expect(store.sets.isEmpty)
        #expect(source.sessions.first?.endedAt == WorkoutLogic.endDate(startedAt: lastSetAt, now: lastSetAt))

        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 62.5, reps: 8))
        #expect(source.sessions.count == 2)
        await store.loadHistory(exerciseId: bench.id)
        #expect(store.previousDay(for: bench.id)?.sets.map(\.weight) == [60])
    }

    @Test("日付をまたいで開いたままの画面から記録しても、前日のセッションに混ざらない")
    func recordAcrossMidnightWithoutReload() async throws {
        let clock = TestClock("2026-09-29T23:50:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        clock.now = date("2026-09-30T00:10:00+09:00")
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        #expect(source.sessions.count == 2)
        #expect(source.sessions.filter(\.isInProgress).count == 1)
    }

    @Test("記録ボタンの二度押しで同じ set_index / セッションを重複 INSERT しない")
    func doubleTapGuard() async throws {
        let source = MockWorkoutDataSource(exercises: [bench])
        source.addSetDelayNanoseconds = 50_000_000
        let store = WorkoutSessionStore(dataSource: source, calendar: jst)
        await store.load()
        let input = WorkoutSetInput(weight: 60, reps: 10)

        async let first = store.addSet(exercise: bench, input: input)
        async let second = store.addSet(exercise: bench, input: input)
        let results = await [first, second]

        #expect(results.filter { if case .success = $0 { return true } else { return false } }.count == 1)
        #expect(source.sets.count == 1)
        #expect(source.sessions.count == 1)
    }

    @Test("INSERT 後に応答だけ失われたセットは、翌日の自動クローズで破棄 (CASCADE) されない")
    func lostResponseSetSurvivesClose() async throws {
        let clock = TestClock("2026-09-29T07:00:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        source.dropNextAddSetResponse = true
        let result = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        if case .success = result { Issue.record("応答喪失なのに成功扱いになった") }
        #expect(store.sets.count == 1) // サーバーの状態に合わせ直している

        clock.now = date("2026-09-30T07:00:00+09:00")
        await store.load()
        #expect(source.sets.count == 1)
        #expect(source.sessions.first?.endedAt != nil)
    }

    @Test("セットの無い前日セッションは破棄する")
    func emptyStaleSessionDeleted() async throws {
        let stale = WorkoutSession(id: UUID(), actualTaskId: nil, routineId: nil,
                                   startedAt: date("2026-09-29T07:00:00+09:00"), endedAt: nil, note: nil)
        let source = MockWorkoutDataSource(exercises: [bench], sessions: [stale])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { date("2026-09-30T07:00:00+09:00") })
        await store.load()
        #expect(source.sessions.isEmpty)
    }

    @Test("再ロード (タブ再表示) で、手動追加した未記録の種目が消えない")
    func reloadKeepsManuallyAddedExercises() async {
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst)
        await store.load()
        await store.addPlannedExercise(bench.id)
        await store.load()
        #expect(store.todayExerciseIds == [bench.id])
    }

    @Test("種目を追加すると前回の値で行が埋まり、✓ でその行だけ記録される")
    func draftsPrefilledAndCompleted() async throws {
        let clock = TestClock("2026-09-29T07:00:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 65, reps: 8))

        clock.now = date("2026-09-30T07:00:00+09:00")
        await store.load()
        await store.addPlannedExercise(bench.id)
        let drafts = try #require(store.drafts[bench.id])
        #expect(drafts.map(\.input.weight) == [60, 65])
        #expect(store.previousSet(for: bench.id, position: 1)?.weight == 65)

        var edited = drafts[0].input
        edited.weight = 62.5
        store.updateDraft(exerciseId: bench.id, draftId: drafts[0].id, input: edited)
        let result = await store.completeDraft(exercise: bench, draftId: drafts[0].id)
        #expect((try? result.get())?.weight == 62.5)
        #expect(store.drafts[bench.id]?.map(\.input.weight) == [65])
        #expect(store.sets(for: bench.id).count == 1)

        store.addDraft(exerciseId: bench.id)
        #expect(store.drafts[bench.id]?.map(\.input.weight) == [65, 65])
    }

    @Test("残りのセットに適用: 下の行だけ同じ値になり、ウォームアップ区分は各行のまま")
    func applyToRemaining() async throws {
        let clock = TestClock("2026-09-29T07:00:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 40, reps: 12, isWarmup: true))
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 65, reps: 8))
        clock.now = date("2026-09-30T07:00:00+09:00")
        await store.load()
        await store.addPlannedExercise(bench.id)
        let drafts = try #require(store.drafts[bench.id])
        var edited = drafts[1].input
        edited.weight = 70
        store.updateDraft(exerciseId: bench.id, draftId: drafts[1].id, input: edited)
        store.applyToRemaining(exerciseId: bench.id, from: drafts[1].id)
        #expect(store.drafts[bench.id]?.map(\.input.weight) == [40, 70, 70])
        #expect(store.drafts[bench.id]?.map(\.input.isWarmup) == [true, false, false])
        #expect(store.bestOneRMBeforeToday(exerciseId: bench.id) == WorkoutProgress.estimatedOneRM(weight: 65, reps: 8))
    }

    @Test("記録しても種目の並びは追加した順のまま")
    func orderStableOnRecord() async {
        let squat = exercise("スクワット", .weightReps)
        let source = MockWorkoutDataSource(exercises: [bench, squat])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst)
        await store.load()
        await store.addPlannedExercise(bench.id)
        await store.addPlannedExercise(squat.id)
        _ = await store.addSet(exercise: squat, input: WorkoutSetInput(weight: 80, reps: 5))
        #expect(store.todayExerciseIds == [bench.id, squat.id])
        await store.load()
        #expect(store.todayExerciseIds == [bench.id, squat.id])
    }

    @Test("画面離脱によるキャンセルはエラー扱いしない")
    func cancellationIsNotAnError() {
        #expect(WorkoutSessionStore.isCancellation(CancellationError()))
        #expect(WorkoutSessionStore.isCancellation(URLError(.cancelled)))
        #expect(!WorkoutSessionStore.isCancellation(URLError(.notConnectedToInternet)))
    }
}

@Suite("記録済みセットの編集・取り消し・削除の詰め直し (2026-10-03)")
@MainActor
struct WorkoutSetEditTests {
    let bench = exercise("ベンチプレス", .weightReps)

    /// 今日 07:00 から 3 分おきに重量 60・65・70 の 3 セットを記録した store
    private func recordedStore() async -> (MockWorkoutDataSource, WorkoutSessionStore, TestClock) {
        let clock = TestClock("2026-10-03T07:00:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        await store.addPlannedExercise(bench.id)
        for weight in [60.0, 65, 70] {
            _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: weight, reps: 10))
            clock.now = clock.now.addingTimeInterval(180)
        }
        return (source, store, clock)
    }

    @Test("Mock の削除は同じセッション×種目の残りだけを 1..n に詰め、他の種目・セッションは触らない。無い id は何もしない")
    func mockDeleteRenumbers() async throws {
        let session = UUID(), other = UUID(), squat = UUID()
        let target = set(session: session, exercise: bench.id, index: 2)
        let source = MockWorkoutDataSource(sets: [
            set(session: session, exercise: bench.id, index: 1),
            target,
            set(session: session, exercise: bench.id, index: 4),
            set(session: session, exercise: squat, index: 3),
            set(session: other, exercise: bench.id, index: 5),
        ])
        try await source.deleteSet(id: target.id)
        #expect(source.sets.filter { $0.sessionId == session && $0.exerciseId == bench.id }.map(\.setIndex).sorted() == [1, 2])
        #expect(source.sets.first { $0.exerciseId == squat }?.setIndex == 3)
        #expect(source.sets.first { $0.sessionId == other }?.setIndex == 5)

        try await source.deleteSet(id: UUID())
        #expect(source.sets.count == 4)
    }

    @Test("スワイプ削除: DB・今日の sets・履歴の番号が 1..n に詰まり、次の記録は n+1 で重複しない")
    func deleteRenumbersStoreAndHistory() async throws {
        let (source, store, _) = await recordedStore()
        let middle = try #require(store.sets(for: bench.id).first { $0.setIndex == 2 })
        #expect(await store.deleteSet(middle) == nil)

        #expect(source.sets.map(\.setIndex).sorted() == [1, 2])
        #expect(store.sets(for: bench.id).map(\.setIndex) == [1, 2])
        #expect(store.sets(for: bench.id).map(\.weight) == [60, 70])
        #expect(store.history[bench.id]?.sorted { $0.setIndex < $1.setIndex }.map(\.weight) == [60, 70])
        #expect(store.history[bench.id]?.map(\.setIndex).sorted() == [1, 2])

        let result = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 75, reps: 8))
        #expect((try? result.get())?.setIndex == 3)
        #expect(source.sets.map(\.setIndex).sorted() == [1, 2, 3])
    }

    @Test("✓ の取り消し: DB から消え、同じ値 (ウォームアップ区分も) で未保存の行の先頭に戻り、番号が詰まる")
    func undoRestoresDraft() async throws {
        let (source, store, _) = await recordedStore()
        _ = await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 40, reps: 12, isWarmup: true))
        let draftsBefore = store.drafts[bench.id] ?? []
        let first = try #require(store.sets(for: bench.id).first)
        let last = try #require(store.sets(for: bench.id).last)

        let draftId = try (await store.undoSet(last)).get()
        #expect(store.drafts[bench.id]?.first?.id == draftId)
        #expect(store.drafts[bench.id]?.first?.input == WorkoutSetInput(weight: 40, reps: 12, isWarmup: true))
        #expect(store.drafts[bench.id]?.count == draftsBefore.count + 1)
        #expect(!source.sets.contains { $0.id == last.id })

        _ = try (await store.undoSet(first)).get()
        #expect(store.drafts[bench.id]?.prefix(2).map(\.input.weight) == [60, 40])
        #expect(source.sets.sorted { $0.setIndex < $1.setIndex }.map(\.weight) == [65, 70])
        #expect(source.sets.map(\.setIndex).sorted() == [1, 2])
        #expect(store.sets(for: bench.id).map(\.setIndex) == [1, 2])
        #expect(store.history[bench.id]?.count == 2)
    }

    @Test("取り消し → 再 ✓ で番号は 1..n のまま、記録時刻は押し直した時刻になる")
    func undoThenRecompleteKeepsSequence() async throws {
        let (source, store, clock) = await recordedStore()
        let second = try #require(store.sets(for: bench.id).first { $0.setIndex == 2 })
        let draftId = try (await store.undoSet(second)).get()
        clock.now = clock.now.addingTimeInterval(60)
        let redone = try (await store.completeDraft(exercise: bench, draftId: draftId)).get()
        #expect(redone.weight == 65)
        #expect(redone.setIndex == 3)
        #expect(redone.completedAt == clock.now)
        #expect(source.sets.map(\.setIndex).sorted() == [1, 2, 3])
    }

    @Test("今日の唯一のセットを取り消すと今日は未記録に戻る (継続の recordedToday = !sets.isEmpty)")
    func undoOnlySetClearsRecordedToday() async throws {
        let clock = TestClock("2026-10-03T07:00:00+09:00")
        let source = MockWorkoutDataSource(exercises: [bench])
        let store = WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now })
        await store.load()
        await store.addPlannedExercise(bench.id)
        let only = try (await store.addSet(exercise: bench, input: WorkoutSetInput(weight: 60, reps: 10))).get()
        _ = try (await store.undoSet(only)).get()
        #expect(store.sets.isEmpty)
        #expect(try await source.fetchTrainingDays().isEmpty)
        #expect(store.todayExerciseIds == [bench.id]) // カードは残り、戻した行から記録し直せる
    }

    @Test("編集: 値とウォームアップだけが変わり、completed_at・set_index は変わらない。履歴・合計にも反映される")
    func editKeepsTimeAndIndex() async throws {
        let (source, store, clock) = await recordedStore()
        let second = try #require(store.sets(for: bench.id).first { $0.setIndex == 2 })
        clock.now = clock.now.addingTimeInterval(600)

        let updated = try (await store.updateSet(second, exercise: bench,
                                                 input: WorkoutSetInput(weight: 67.5, reps: 7, isWarmup: true))).get()
        #expect(updated.id == second.id)
        #expect(updated.completedAt == second.completedAt)
        #expect(updated.setIndex == 2)
        #expect(updated.weight == 67.5 && updated.reps == 7 && updated.isWarmup)
        #expect(source.sets.first { $0.id == second.id } == updated)
        #expect(store.sets(for: bench.id).map(\.weight) == [60, 67.5, 70])
        #expect(store.history[bench.id]?.first { $0.id == second.id } == updated)
        #expect(WorkoutSummary.dayTotals(store.sets) == WorkoutSummary.dayTotals(source.sets))
    }

    @Test("編集のバリデーションは addSet と同じ (回数が空なら書き込まない)")
    func editValidates() async throws {
        let (source, store, _) = await recordedStore()
        let first = try #require(store.sets(for: bench.id).first)
        let result = await store.updateSet(first, exercise: bench, input: WorkoutSetInput(weight: 60, reps: nil))
        guard case .failure(let error) = result else { Issue.record("空の回数で保存できた"); return }
        #expect(error as? WorkoutSetInput.ValidationError == .missingReps)
        #expect(source.sets.first { $0.id == first.id } == first)
    }

    @Test("WorkoutLogic.removingAndRenumbering は欠番のある並びも 1..n にする")
    func renumberWithGaps() {
        let session = UUID()
        let sets = [1, 3, 4, 7].map { set(session: session, exercise: bench.id, index: $0) }
        let result = WorkoutLogic.removingAndRenumbering(sets[1], from: sets)
        #expect(result.map(\.setIndex) == [1, 2, 3])
        #expect(result.map(\.id) == [sets[0].id, sets[2].id, sets[3].id])
    }
}
