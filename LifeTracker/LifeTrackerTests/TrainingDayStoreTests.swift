import Testing
import Foundation
@testable import LifeTracker

// トレーニングの日 (週の帯で選んだ日に記録する・前の日は翌日の 2:00 まで) の store と Mock の制約
// (docs/training-day-implementation-plan.md 付録 A-4・A-6 の ①〜⑪)

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

private func exercise(_ name: String) -> Exercise {
    Exercise(id: UUID(), name: name, muscleGroup: .chest, equipment: .barbell, metricKind: .weightReps, note: nil, isArchived: false, sortOrder: nil)
}

private let w = { (weight: Double) in WorkoutSetInput(weight: weight, reps: 10) }

/// テスト内で進められる時計
@MainActor
private final class DayClock {
    var now: Date
    init(_ local: String) { now = jstDate(local) }
}

private func isDayClosed(_ error: Error?) -> Bool {
    guard let error, case WorkoutSessionStore.StoreError.dayClosed = error else { return false }
    return true
}

private func isDayClosed<T>(_ result: Result<T, Error>) -> Bool {
    guard case .failure(let error) = result else { return false }
    return isDayClosed(error)
}

/// 今日 = 10/23 (金)・前の日 = 10/22 (木)
private let today = jstDate("2026-10-23T00:00:00")
private let previous = jstDate("2026-10-22T00:00:00")

@Suite("WorkoutSessionStore — トレーニングの日 (前の日は翌日の 2:00 まで)")
@MainActor
struct TrainingDayStoreTests {
    let bench = exercise("ベンチプレス")
    let squat = exercise("スクワット")
    let curl = exercise("ダンベルカール")

    private func makeStore(_ clock: DayClock, sessions: [WorkoutSession] = [], sets: [WorkoutSet] = []) -> (MockWorkoutDataSource, WorkoutSessionStore) {
        let source = MockWorkoutDataSource(exercises: [bench, squat, curl], sessions: sessions, sets: sets)
        return (source, WorkoutSessionStore(dataSource: source, calendar: jst, now: { clock.now }))
    }

    /// 種目をその日 (activeDay) に足し、行を weights の値にする (足りない行は「＋セット」で足す)
    private func addCard(_ store: WorkoutSessionStore, _ exercise: Exercise, weights: [Double]) async throws -> (TodayCard, [UUID]) {
        let card = await store.addPlannedExercise(exercise.id)
        while (store.drafts[card.id]?.count ?? 0) < weights.count { store.addDraft(cardId: card.id) }
        let rows = try #require(store.drafts[card.id])
        for (row, weight) in zip(rows, weights) { store.updateDraft(cardId: card.id, draftId: row.id, input: w(weight)) }
        return (card, rows.prefix(weights.count).map(\.id))
    }

    @Test("① 0:30 に前の日 (activeDay) へ ✓ → セッションの日は前の日・started_at は 0:30・セットの日も前の日")
    func recordToPreviousDayAfterMidnight() async throws {
        let clock = DayClock("2026-10-23T00:30:00")
        let (source, store) = makeStore(clock)
        await store.load()
        #expect(store.openDays == [today, previous])
        #expect(store.activeDay == today)
        store.setActiveDay(previous)
        #expect(store.activeDay == previous)

        let (card, rows) = try await addCard(store, bench, weights: [60])
        #expect(store.day(ofCard: card.id) == previous)
        let set = try (await store.completeDraft(card: card, exercise: bench, draftId: rows[0])).get()
        let session = try #require(source.sessions.first)
        #expect(source.sessions.count == 1)
        #expect(session.day == previous)
        #expect(session.startedAt == clock.now)
        #expect(set.day == previous && set.completedAt == clock.now && set.sessionId == session.id)
        #expect(store.sets(on: previous).map(\.id) == [set.id])
        #expect(store.sets(on: today).isEmpty)
        #expect(store.openDays == [today, previous]) // 前の日の記録は今日の記録ではない
    }

    @Test("② 0:30 に読み直しても前の日のカードと行が消えない")
    func reloadKeepsPreviousDayCards() async throws {
        let clock = DayClock("2026-10-23T00:30:00")
        let (_, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        let (checked, rows) = try await addCard(store, bench, weights: [60, 65])
        _ = try (await store.completeDraft(card: checked, exercise: bench, draftId: rows[0])).get()
        let (planned, _) = try await addCard(store, squat, weights: [80])
        let draftsBefore = store.drafts

        clock.now = jstDate("2026-10-23T00:40:00")
        await store.load()
        #expect(store.openDays == [today, previous])
        #expect(store.activeDay == previous)
        #expect(store.cards.map(\.id) == [checked.id, planned.id])
        #expect(store.sets.count == 1)
        #expect(store.drafts[checked.id] == draftsBefore[checked.id])
        #expect(store.drafts[planned.id] == draftsBefore[planned.id])
    }

    /// ③④ の前提: 0:30 に前の日に ✓ 済みのカード (行が 1 つ残る) と ✓ していないカード、今日にカードを 1 枚
    private struct ClosingSetup {
        let source: MockWorkoutDataSource
        let store: WorkoutSessionStore
        let checked: TodayCard
        let planned: TodayCard
        let todayCard: TodayCard
        let todayRow: UUID
    }

    private func closingSetup() async throws -> ClosingSetup {
        let clock = DayClock("2026-10-23T00:30:00")
        let (source, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        let (checked, rows) = try await addCard(store, bench, weights: [60, 65])
        _ = try (await store.completeDraft(card: checked, exercise: bench, draftId: rows[0])).get()
        let (planned, _) = try await addCard(store, squat, weights: [80])
        store.setActiveDay(today)
        let (todayCard, todayRows) = try await addCard(store, curl, weights: [12])
        store.setActiveDay(previous) // 前の日を見ている間に、今日のカードに ✓ が入る (閉じたら今日へ戻る)
        return ClosingSetup(source: source, store: store, checked: checked, planned: planned,
                            todayCard: todayCard, todayRow: todayRows[0])
    }

    @Test("③ 今日に ✓ → 前の日が閉じ、前の日のカードと行は消える (今日へ移さない。2026-10-23 本人「移さない」)・activeDay は今日")
    func todayRecordClosesPreviousDay() async throws {
        let s = try await closingSetup()
        let store = s.store
        _ = try (await store.completeDraft(card: s.todayCard, exercise: curl, draftId: s.todayRow)).get()

        #expect(store.openDays == [today])
        #expect(store.days[previous] == nil)
        #expect(store.activeDay == today)
        // 今日のカードは今日のものだけ。前の日の ✓ していないカードも、✓ 済みのカードの残りの行も今日に来ない
        #expect(store.days[today]?.cards.map(\.id) == [s.todayCard.id])
        #expect(store.day(ofCard: s.checked.id) == nil && store.day(ofCard: s.planned.id) == nil)
        #expect(store.drafts[s.checked.id] == nil && store.drafts[s.planned.id] == nil)
        // 「今日に記録があるから閉じた」だけなのでサーバーの前の日のセッションは開いたまま (また開きうる)
        #expect(s.source.sessions.first { $0.day == previous }?.isInProgress == true)
    }

    @Test("④ 今日の記録を全部取り消す → 前の日が開き、✓ 済みのカードだけが戻る (✓ していなかったカードは消えたまま)")
    func undoTodayReopensPreviousDay() async throws {
        let s = try await closingSetup()
        let store = s.store
        let todaySet = try (await store.completeDraft(card: s.todayCard, exercise: curl, draftId: s.todayRow)).get()
        _ = try (await store.undoSet(todaySet)).get()
        #expect(store.openDays == [today, previous])
        let reopened = try #require(store.days[previous])
        #expect(reopened.cards.count == 1)
        #expect(reopened.cards.first?.exerciseId == bench.id && reopened.cards.first?.entryId != nil)
        #expect(reopened.sets.map(\.weight) == [60])
        #expect(store.days[today]?.cards.map(\.id) == [s.todayCard.id])
        #expect(store.day(ofCard: s.planned.id) == nil)
        #expect(store.activeDay == today)
        store.setActiveDay(previous)
        #expect(store.activeDay == previous)
    }

    @Test("⑤ 2:00 の reconcile で前の日が閉じ、サーバーの前の日のセッションは最後のセットの時刻で閉じる")
    func closesAtTwoAndEndsServerSession() async throws {
        let clock = DayClock("2026-10-23T01:30:00")
        let (source, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        let (card, rows) = try await addCard(store, bench, weights: [60])
        let set = try (await store.completeDraft(card: card, exercise: bench, draftId: rows[0])).get()

        clock.now = jstDate("2026-10-23T01:59:00")
        #expect(await store.reconcile(now: clock.now).isEmpty) // まだ開いている (毎分呼ばれても何もしない)
        clock.now = jstDate("2026-10-23T02:00:00")
        #expect(await store.reconcile(now: clock.now) == [previous])
        #expect(store.openDays == [today])
        #expect(store.activeDay == today)
        let session = try #require(source.sessions.first)
        #expect(session.endedAt == WorkoutLogic.endDate(startedAt: session.startedAt, now: set.completedAt!))
    }

    @Test("⑤ 前の日のセッションにセットが無ければ、2:00 の reconcile で消える")
    func closesAtTwoAndDeletesEmptySession() async throws {
        let clock = DayClock("2026-10-23T01:30:00")
        let (source, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        let (card, rows) = try await addCard(store, bench, weights: [60])
        let set = try (await store.completeDraft(card: card, exercise: bench, draftId: rows[0])).get()
        _ = try (await store.undoSet(set)).get()
        #expect(source.sessions.count == 1 && source.sets.isEmpty)

        clock.now = jstDate("2026-10-23T02:00:00")
        #expect(await store.reconcile(now: clock.now) == [previous])
        #expect(source.sessions.isEmpty)
    }

    @Test("⑥ 1:59:59 に前の日へ ✓ している間に 2:00:30 の reconcile → ✓ が終わってから閉じる・✓ したセットは前の日に 1 つ・前の日のカードと行は消える")
    func reconcileWaitsForWrite() async throws {
        let clock = DayClock("2026-10-23T01:59:59")
        let (source, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        let (card, rows) = try await addCard(store, bench, weights: [60, 65])

        source.addSetDelayNanoseconds = 50_000_000
        async let recording = store.completeDraft(card: card, exercise: bench, draftId: rows[0])
        while source.sets.isEmpty { await Task.yield() } // Mock は INSERT してから応答を遅らせる (= ✓ の途中)
        #expect(store.isWriting)
        clock.now = jstDate("2026-10-23T02:00:30")
        let closed = await store.reconcile(now: clock.now)
        let recorded = try await recording.get()

        #expect(closed == [previous])
        #expect(recorded.day == previous)
        #expect(source.sets.filter { $0.day == previous }.map(\.id) == [recorded.id])
        #expect(store.days[today]?.cards.isEmpty == true)
        #expect(store.day(ofCard: card.id) == nil)
        #expect(store.drafts[card.id] == nil)
        #expect(source.sessions.first?.endedAt != nil) // もう記録できない日なのでサーバーでも閉じた
    }

    @Test("⑦ 時計だけ 2:01 にして (reconcile なし) 前の日のカードに ✓ → dayClosed・セットは増えない・前の日のカードと行は消えている")
    func recordAfterTwoWithoutReconcileFails() async throws {
        let clock = DayClock("2026-10-23T01:00:00")
        let (source, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        let (card, rows) = try await addCard(store, bench, weights: [60])

        clock.now = jstDate("2026-10-23T02:01:00")
        let result = await store.completeDraft(card: card, exercise: bench, draftId: rows[0])
        #expect(isDayClosed(result))
        #expect(WorkoutSessionStore.StoreError.dayClosed.localizedDescription == "前の日には記録できなくなりました")
        #expect(source.sets.isEmpty && source.sessions.isEmpty)
        #expect(store.day(ofCard: card.id) == nil)
        #expect(store.drafts[card.id] == nil)
        #expect(store.openDays == [today])
        #expect(store.activeDay == today)
    }

    @Test("閉じた日のセットの取り消し・編集・削除は dayClosed (サーバーのセットは残る)")
    func editingClosedDayFails() async throws {
        let clock = DayClock("2026-10-23T01:00:00")
        let (source, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        let (card, rows) = try await addCard(store, bench, weights: [60])
        let set = try (await store.completeDraft(card: card, exercise: bench, draftId: rows[0])).get()

        clock.now = jstDate("2026-10-23T02:01:00")
        #expect(isDayClosed(await store.undoSet(set)))
        #expect(isDayClosed(await store.updateSet(set, exercise: bench, input: w(70))))
        #expect(isDayClosed(await store.deleteSet(set)))
        #expect(source.sets.map(\.id) == [set.id])
        #expect(source.sets.first?.weight == 60)
    }

    @Test("⑧ load の片付けは閉じてよい日だけ: 2 日前の開いたままは閉じる・前の日の 1:00 は閉じない")
    func loadCleansUpOnlyPermanentlyClosedDays() async throws {
        let twoDaysAgo = jstDate("2026-10-21T00:00:00")
        let old = WorkoutSession(id: UUID(), actualTaskId: nil, routineId: nil, startedAt: jstDate("2026-10-21T07:00:00"),
                                 endedAt: nil, note: nil, day: twoDaysAgo)
        let open = WorkoutSession(id: UUID(), actualTaskId: nil, routineId: nil, startedAt: jstDate("2026-10-22T23:00:00"),
                                  endedAt: nil, note: nil, day: previous)
        func set(_ session: WorkoutSession, at local: String) -> WorkoutSet {
            WorkoutSet(id: UUID(), sessionId: session.id, exerciseId: bench.id, entryId: UUID(), setIndex: 1, weight: 60, reps: 10,
                       durationSec: nil, distanceM: nil, rpe: nil, isWarmup: false, completedAt: jstDate(local), day: session.day)
        }
        let clock = DayClock("2026-10-23T01:00:00")
        let (source, store) = makeStore(clock, sessions: [old, open],
                                        sets: [set(old, at: "2026-10-21T07:10:00"), set(open, at: "2026-10-23T00:20:00")])
        await store.load()
        let lastOld = jstDate("2026-10-21T07:10:00")
        #expect(source.sessions.first { $0.id == old.id }?.endedAt == WorkoutLogic.endDate(startedAt: old.startedAt, now: lastOld))
        #expect(source.sessions.first { $0.id == open.id }?.isInProgress == true)
        #expect(store.openDays == [today, previous])
        #expect(store.days[previous]?.session?.id == open.id)
        #expect(store.days[previous]?.cards.count == 1) // 0:20 に前の日へ記録したカード
        #expect(store.days[twoDaysAgo] == nil)
    }

    @Test("⑨ 別の端末が今日のセッションを先に作っていたら (1 日 1 つに当たる)、日で引き直してそのセッションに入る")
    func usesSessionCreatedByAnotherDevice() async throws {
        let clock = DayClock("2026-10-23T07:00:00")
        let (source, store) = makeStore(clock)
        await store.load()
        let other = source.insertSessionFromAnotherDevice(day: today, startedAt: jstDate("2026-10-23T06:50:00"))
        let otherEntry = source.insertEntryFromAnotherDevice(sessionId: other.id, exerciseId: squat.id)
        _ = try await source.addSet(NewWorkoutSet(sessionId: other.id, exerciseId: squat.id, entryId: otherEntry.id, setIndex: 1,
                                                  weight: 80, reps: 5, durationSec: nil, distanceM: nil, isWarmup: false,
                                                  completedAt: jstDate("2026-10-23T06:55:00"), day: today))

        let card = await store.addPlannedExercise(bench.id)
        let set = try (await store.addSet(card: card, exercise: bench, input: w(60))).get()
        #expect(set.sessionId == other.id && set.day == today)
        #expect(source.sessions.count == 1)
        #expect(store.session?.id == other.id)
        #expect(store.sets.count == 2) // 相手のセットも取り直している
        #expect(store.cards.contains { $0.entryId == otherEntry.id })
        #expect(Set(source.entries.map(\.sortOrder)) == [1, 2])
    }

    @Test("⑩ 23:50 に今日へ ✓ → 0:10 の reconcile で開く日は [新しい今日, 前の日]・activeDay は前の日のまま → 同じカードの ✓ は同じセッション")
    func midnightKeepsSelectedDay() async throws {
        let clock = DayClock("2026-10-22T23:50:00")
        let (source, store) = makeStore(clock)
        await store.load()
        #expect(store.openDays == [previous]) // 10/22 23:50 の今日 = 10/22
        let (card, rows) = try await addCard(store, bench, weights: [60, 65])
        let first = try (await store.completeDraft(card: card, exercise: bench, draftId: rows[0])).get()

        clock.now = jstDate("2026-10-23T00:10:00")
        #expect(await store.reconcile(now: clock.now).isEmpty)
        #expect(store.today == today)
        #expect(store.openDays == [today, previous])
        #expect(store.activeDay == previous)
        #expect(store.cards.map(\.id) == [card.id])

        let second = try (await store.completeDraft(card: card, exercise: bench, draftId: rows[1])).get()
        #expect(source.sessions.count == 1)
        #expect(second.sessionId == first.sessionId)
        #expect(second.day == previous && second.setIndex == 2)
        #expect(second.completedAt == clock.now)
        #expect(store.openDays == [today, previous]) // 前の日への記録では閉じない
    }

    @Test("開いていない日は activeDay にできない (今日になる)")
    func setActiveDayOnlyOpenDays() async {
        let clock = DayClock("2026-10-23T07:00:00")
        let (_, store) = makeStore(clock)
        await store.load()
        store.setActiveDay(previous)
        #expect(store.activeDay == today)
        store.setActiveDay(jstDate("2026-10-23T15:00:00"))
        #expect(store.activeDay == today)
    }
}

@Suite("MockWorkoutDataSource — 0015 の制約の写し")
@MainActor
struct TrainingDayMockTests {
    let bench = exercise("ベンチプレス")

    @Test("⑪ 同じ日のセッション・窓の外の時刻・日の食い違い・別のセッションの entry を拒む")
    func constraints() async throws {
        typealias E = MockWorkoutDataSource.MockError
        let source = MockWorkoutDataSource(exercises: [bench])
        // 窓 = 日の 0:00 以上・翌日 2:00 未満
        await #expect(throws: E.outsideWindow) {
            _ = try await source.startSession(day: previous, routineId: nil, startedAt: jstDate("2026-10-23T02:00:00"))
        }
        await #expect(throws: E.outsideWindow) {
            _ = try await source.startSession(day: previous, routineId: nil, startedAt: jstDate("2026-10-21T23:59:59"))
        }
        let previousSession = try await source.startSession(day: previous, routineId: nil, startedAt: jstDate("2026-10-23T01:59:59"))
        await #expect(throws: E.duplicateDay) {
            _ = try await source.startSession(day: previous, routineId: nil, startedAt: jstDate("2026-10-22T07:00:00"))
        }
        let todaySession = try await source.startSession(day: today, routineId: nil, startedAt: jstDate("2026-10-23T07:00:00"))
        let previousEntry = try await source.addEntry(sessionId: previousSession.id, exerciseId: bench.id, sortOrder: 1)
        func new(_ session: WorkoutSession, _ entry: WorkoutEntry, day: Date, at local: String) -> NewWorkoutSet {
            NewWorkoutSet(sessionId: session.id, exerciseId: bench.id, entryId: entry.id, setIndex: 1, weight: 60, reps: 10,
                          durationSec: nil, distanceM: nil, isWarmup: false, completedAt: jstDate(local), day: day)
        }
        // セットの日 ≠ セッションの日
        await #expect(throws: E.dayMismatch) { _ = try await source.addSet(new(previousSession, previousEntry, day: today, at: "2026-10-23T01:00:00")) }
        // completed_at が窓の外
        await #expect(throws: E.outsideWindow) { _ = try await source.addSet(new(previousSession, previousEntry, day: previous, at: "2026-10-23T02:00:00")) }
        // 前の日の種目 1 回分に今日のセットを付ける (entry のセッションが違う)
        await #expect(throws: E.entryMismatch) { _ = try await source.addSet(new(todaySession, previousEntry, day: today, at: "2026-10-23T07:10:00")) }

        let ok = try await source.addSet(new(previousSession, previousEntry, day: previous, at: "2026-10-23T01:30:00"))
        #expect(ok.day == previous)
        #expect(try await source.fetchTrainingDays() == [previous])
        #expect(try await source.fetchSets(daysFrom: previous, to: today).map(\.id) == [ok.id])
    }
}
