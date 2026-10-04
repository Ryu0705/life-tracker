import Testing
import Foundation
@testable import LifeTracker

// 同じ種目を 2 回・記録画面での種目の並べ替え (docs/gymwork-design-duplicate-and-reorder.md §13)

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

private func set(_ exercise: Exercise, session: UUID, entry: UUID, _ index: Int, weight: Double, reps: Int = 10,
                 warmup: Bool = false, at: Date?) -> WorkoutSet {
    WorkoutSet(id: UUID(), sessionId: session, exerciseId: exercise.id, entryId: entry, setIndex: index, weight: weight, reps: reps,
               durationSec: nil, distanceM: nil, rpe: nil, isWarmup: warmup, completedAt: at)
}

private func entry(_ id: UUID, session: UUID, _ exercise: Exercise, _ order: Int) -> WorkoutEntry {
    WorkoutEntry(id: id, sessionId: session, exerciseId: exercise.id, sortOrder: order)
}

private let w = { (weight: Double) in WorkoutSetInput(weight: weight, reps: 10) }

@Suite("WorkoutLogic — entry 単位の番号・並び (RPC の写し)")
@MainActor
struct WorkoutEntryLogicTests {
    let bench = exercise("ベンチプレス")
    let squat = exercise("スクワット")
    let session = UUID()
    let e1 = UUID(), e2 = UUID(), e3 = UUID()

    @Test("同じ種目の 2 つの entry は番号がそれぞれ 1 から。1 つ目を消して詰めても 2 つ目は変わらない")
    func renumberPerEntry() {
        let t = jstDate("2026-10-04T07:00:00")
        let sets = [set(bench, session: session, entry: e1, 1, weight: 60, at: t), set(bench, session: session, entry: e1, 2, weight: 65, at: t),
                    set(bench, session: session, entry: e1, 3, weight: 70, at: t), set(bench, session: session, entry: e3, 1, weight: 50, at: t),
                    set(bench, session: session, entry: e3, 2, weight: 50, at: t)]
        #expect(WorkoutLogic.nextSetIndex(forEntry: e1, in: sets) == 4)
        #expect(WorkoutLogic.nextSetIndex(forEntry: e3, in: sets) == 3)
        let after = WorkoutLogic.removingAndRenumbering(sets[1], from: sets)
        #expect(after.filter { $0.entryId == e1 }.map(\.setIndex) == [1, 2])
        #expect(after.filter { $0.entryId == e3 }.map(\.setIndex) == [1, 2])
    }

    @Test("空になった entry は消え、同じセッションの sort_order が 1..n に詰まる。セットが残れば何もしない")
    func pruneEmptyEntry() {
        let other = UUID()
        let entries = [entry(e1, session: session, bench, 1), entry(e2, session: session, squat, 2),
                       entry(e3, session: session, bench, 3), entry(UUID(), session: other, bench, 2)]
        let remaining = [set(bench, session: session, entry: e1, 1, weight: 60, at: nil), set(bench, session: session, entry: e3, 1, weight: 50, at: nil)]
        let pruned = WorkoutLogic.pruningEntry(e2, remainingSets: remaining, entries: entries)
        #expect(pruned.filter { $0.sessionId == session }.map(\.id) == [e1, e3])
        #expect(pruned.filter { $0.sessionId == session }.map(\.sortOrder) == [1, 2])
        #expect(pruned.first { $0.sessionId == other }?.sortOrder == 2)
        #expect(WorkoutLogic.pruningEntry(e1, remainingSets: remaining, entries: entries) == entries)
    }

    @Test("並べ替え: 配列順に 1..k、配列に無いものは旧順で後ろ。重複は最初の位置・他セッションは不変")
    func reorder() {
        let e4 = UUID(), other = entry(UUID(), session: UUID(), bench, 1)
        let entries = [entry(e1, session: session, bench, 1), entry(e2, session: session, squat, 2),
                       entry(e3, session: session, bench, 3), entry(e4, session: session, squat, 4), other]
        let result = WorkoutLogic.reordering(entries, sessionId: session, entryIds: [e3, e1, e3, other.id])
        let order = result.filter { $0.sessionId == session }.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
        #expect(order == [e3, e1, e2, e4])
        #expect(result.first { $0.id == other.id } == other)
    }

    @Test("1 日分の同じ種目のかたまり: entry の sort_order 順。entry が分からなければ最初の記録時刻順")
    func blocks() {
        let t = jstDate("2026-10-04T07:00:00")
        let sets = [set(bench, session: session, entry: e3, 1, weight: 50, at: t),
                    set(bench, session: session, entry: e1, 2, weight: 65, at: t.addingTimeInterval(600)),
                    set(bench, session: session, entry: e1, 1, weight: 60, at: t.addingTimeInterval(300))]
        let byEntry = [e1: entry(e1, session: session, bench, 1), e3: entry(e3, session: session, bench, 3)]
        #expect(WorkoutLogic.blocks(of: sets, entriesById: byEntry).map { $0.map(\.weight) } == [[60, 65], [50]])
        #expect(WorkoutLogic.blocks(of: sets, entriesById: [:]).map { $0.map(\.weight) } == [[50], [60, 65]])
        #expect(WorkoutSummary.blocksText(sets, kind: .weightReps, entriesById: byEntry, markWarmup: false) == "60×10 / 65×10 ｜ 50×10")
    }

    @Test("カードを DB に合わせる: 未記録のカードは位置ごと残り、記録済みの枠は sort_order 順、カードの無い entry は末尾、消えた entry は未記録に")
    func reconcile() {
        let planned = TodayCard(id: UUID(), exerciseId: squat.id, entryId: nil)
        let a = TodayCard(id: UUID(), exerciseId: bench.id, entryId: e1)
        let gone = TodayCard(id: UUID(), exerciseId: bench.id, entryId: UUID())
        let b = TodayCard(id: UUID(), exerciseId: bench.id, entryId: e3)
        let entries = [entry(e3, session: session, bench, 1), entry(e1, session: session, bench, 2), entry(e2, session: session, squat, 3)]
        let result = WorkoutLogic.reconcile([a, planned, gone, b], with: entries)
        #expect(result.map(\.entryId) == [e3, nil, nil, e1, e2])
        #expect(result.map(\.id).prefix(4) == [b.id, planned.id, gone.id, a.id])
    }
}

@Suite("WorkoutSessionStore — 同じ種目のカード 2 枚・実施した順")
@MainActor
struct WorkoutEntryStoreTests {
    let bench = exercise("ベンチプレス")
    let squat = exercise("スクワット")

    private func makeStore(sets: [WorkoutSet] = [], sessions: [WorkoutSession] = [], entries: [WorkoutEntry] = [],
                           now: String = "2026-10-04T07:00:00") -> (MockWorkoutDataSource, WorkoutSessionStore) {
        let source = MockWorkoutDataSource(exercises: [bench, squat], sessions: sessions, sets: sets, entries: entries)
        return (source, WorkoutSessionStore(dataSource: source, calendar: jst, now: { jstDate(now) }))
    }

    @Test("同じ種目を 2 枚足せ、2 枚目の最初の ✓ で別の entry が作られ番号は 1 から。1 枚目は変わらない")
    func sameExerciseTwice() async throws {
        let (source, store) = makeStore()
        await store.load()
        let first = await store.addPlannedExercise(bench.id)
        await store.addPlannedExercise(squat.id)
        let second = await store.addPlannedExercise(bench.id)
        #expect(store.todayExerciseIds == [bench.id, squat.id, bench.id])
        _ = try (await store.addSet(card: first, exercise: bench, input: w(60))).get()
        _ = try (await store.addSet(card: first, exercise: bench, input: w(65))).get()
        let s = try (await store.addSet(card: second, exercise: bench, input: w(50))).get()
        #expect(s.setIndex == 1)
        #expect(source.entries.count == 2)
        #expect(store.sets(for: try #require(store.card(id: first.id))).map(\.setIndex) == [1, 2])
        #expect(store.sets(for: try #require(store.card(id: second.id))).map(\.weight) == [50])
        #expect(WorkoutSummary.dayTotals(store.sets).exerciseCount == 1) // 種目数は種類数
    }

    @Test("最初の ✓ で entry を画面の位置に差し込む (上にある未記録カードを後から記録しても実施順は画面順)")
    func firstCheckInsertsAtScreenPosition() async throws {
        let (source, store) = makeStore()
        await store.load()
        let a = await store.addPlannedExercise(bench.id)
        let b = await store.addPlannedExercise(squat.id)
        _ = try (await store.addSet(card: b, exercise: squat, input: w(80))).get()
        #expect(source.reorderCalls.isEmpty) // 下に記録済みが無ければ並べ替えない
        _ = try (await store.addSet(card: a, exercise: bench, input: w(60))).get()
        let order = source.entries.sorted { $0.sortOrder < $1.sortOrder }.map(\.exerciseId)
        #expect(order == [bench.id, squat.id])
        #expect(source.reorderCalls.count == 1)
    }

    @Test("再読み込みは entry の sort_order 順でカードを作る (記録時刻順ではない)")
    func loadUsesSortOrder() async {
        let session = WorkoutSession(id: UUID(), actualTaskId: nil, routineId: nil, startedAt: jstDate("2026-10-04T06:50:00"), endedAt: nil, note: nil)
        let e1 = UUID(), e2 = UUID(), e3 = UUID()
        let (_, store) = makeStore(
            sets: [set(bench, session: session.id, entry: e1, 1, weight: 60, at: jstDate("2026-10-04T07:00:00")),
                   set(squat, session: session.id, entry: e2, 1, weight: 80, at: jstDate("2026-10-04T07:10:00")),
                   set(bench, session: session.id, entry: e3, 1, weight: 50, at: jstDate("2026-10-04T07:20:00"))],
            sessions: [session],
            entries: [entry(e3, session: session.id, bench, 1), entry(e1, session: session.id, bench, 2), entry(e2, session: session.id, squat, 3)],
            now: "2026-10-04T08:00:00")
        await store.load()
        #expect(store.cards.map(\.entryId) == [e3, e1, e2])
        #expect(store.todayExerciseIds == [bench.id, bench.id, squat.id])
    }

    @Test("唯一のセットの取り消しで entry は消えるがカードと下書きは残り、再 ✓ で entry を作り直して画面の位置に入る (E1)")
    func undoOnlySetKeepsCard() async throws {
        let (source, store) = makeStore()
        await store.load()
        let a = await store.addPlannedExercise(bench.id)
        let b = await store.addPlannedExercise(squat.id)
        let only = try (await store.addSet(card: a, exercise: bench, input: w(60))).get()
        _ = try (await store.addSet(card: b, exercise: squat, input: w(80))).get()
        let draftId = try (await store.undoSet(only)).get()
        #expect(store.card(id: a.id)?.entryId == nil)
        #expect(source.entries.map(\.exerciseId) == [squat.id])
        #expect(source.entries.first?.sortOrder == 1)
        #expect(store.drafts[a.id]?.first?.id == draftId)

        let redone = try (await store.completeDraft(card: try #require(store.card(id: a.id)), exercise: bench, draftId: draftId)).get()
        #expect(redone.setIndex == 1)
        #expect(source.entries.sorted { $0.sortOrder < $1.sortOrder }.map(\.exerciseId) == [bench.id, squat.id])
        #expect(store.cards.map(\.id) == [a.id, b.id])
    }

    @Test("1 枚目の全セットを消すと 1 枚目の entry が消え、2 枚目が sort_order 1 に詰まる (E2)")
    func deleteAllOfFirstCard() async throws {
        let (source, store) = makeStore()
        await store.load()
        let first = await store.addPlannedExercise(bench.id)
        let second = await store.addPlannedExercise(bench.id)
        let s1 = try (await store.addSet(card: first, exercise: bench, input: w(60))).get()
        _ = try (await store.addSet(card: second, exercise: bench, input: w(50))).get()
        #expect(await store.deleteSet(s1) == nil)
        #expect(source.entries.count == 1)
        #expect(source.entries.first?.sortOrder == 1)
        #expect(store.entries.first?.sortOrder == 1)
        #expect(store.sets(for: try #require(store.card(id: second.id))).map(\.weight) == [50])
    }

    @Test("前回の対応 (Q2「a」): 前回の 1 回目 ↔ 1 枚目、2 回目 ↔ 2 枚目")
    func previousMatchesSameOrdinal() async throws {
        let past = UUID(), p1 = UUID(), p2 = UUID(), p3 = UUID()
        let t = jstDate("2026-10-02T07:00:00")
        let (_, store) = makeStore(
            sets: [set(bench, session: past, entry: p1, 1, weight: 60, at: t), set(bench, session: past, entry: p1, 2, weight: 65, at: t.addingTimeInterval(180)),
                   set(squat, session: past, entry: p2, 1, weight: 80, at: t.addingTimeInterval(600)),
                   set(bench, session: past, entry: p3, 1, weight: 50, reps: 12, at: t.addingTimeInterval(1200))])
        await store.load()
        let first = await store.addPlannedExercise(bench.id)
        await store.addPlannedExercise(squat.id)
        let second = await store.addPlannedExercise(bench.id)
        #expect(store.drafts[first.id]?.map(\.input.weight) == [60, 65])
        #expect(store.drafts[second.id]?.map(\.input) == [WorkoutSetInput(weight: 50, reps: 12)])
        #expect(store.previousSet(for: second, position: 0)?.weight == 50)
        #expect(store.previousSet(for: second, position: 1) == nil)
        #expect(store.previousSets(for: first).map(\.weight) == [60, 65])
    }

    @Test("前回が 1 回だけの日の 2 枚目: 前回は「—」、行は今日のその種目の最後のセット (ウォームアップは外す) を写す (E9)")
    func secondCardFallsBackToTodaysLastSet() async throws {
        let past = UUID()
        let t = jstDate("2026-10-02T07:00:00")
        let pastEntry = UUID() // 前回はベンチを 1 回だけ
        let (_, store) = makeStore(sets: [set(bench, session: past, entry: pastEntry, 1, weight: 60, at: t),
                                          set(bench, session: past, entry: pastEntry, 2, weight: 65, at: t.addingTimeInterval(180))])
        await store.load()
        let first = await store.addPlannedExercise(bench.id)
        let beforeRecord = await store.addPlannedExercise(bench.id)
        #expect(store.previousSet(for: beforeRecord, position: 0) == nil)
        #expect(store.drafts[beforeRecord.id]?.map(\.input.weight) == [65]) // 今日の記録がまだ無ければ前回の最後のセット
        _ = try (await store.addSet(card: first, exercise: bench, input: WorkoutSetInput(weight: 70, reps: 5, isWarmup: true))).get()
        let third = await store.addPlannedExercise(bench.id)
        #expect(store.drafts[third.id]?.map(\.input) == [WorkoutSetInput(weight: 70, reps: 5)])
    }

    @Test("並べ替え: 未記録のカードだけ動かしても書かない。記録済みの相対順が変われば 1 回書き、再読み込みでも残る")
    func moveWritesOnlyRecordedOrder() async throws {
        let (source, store) = makeStore()
        await store.load()
        let a = await store.addPlannedExercise(bench.id)
        let b = await store.addPlannedExercise(squat.id)
        let c = await store.addPlannedExercise(bench.id)
        _ = try (await store.addSet(card: a, exercise: bench, input: w(60))).get()
        _ = try (await store.addSet(card: c, exercise: bench, input: w(50))).get()
        let callsBefore = source.reorderCalls.count

        store.moveCard(fromOffsets: [1], toOffset: 0) // 未記録の B を先頭へ: 記録済み A・C の相対順は同じ
        #expect(await store.saveCardOrder() == nil)
        #expect(source.reorderCalls.count == callsBefore)

        store.moveCard(fromOffsets: [2], toOffset: 0) // C を先頭へ
        #expect(store.cards.map(\.id) == [c.id, b.id, a.id])
        #expect(await store.saveCardOrder() == nil)
        #expect(source.reorderCalls.count == callsBefore + 1)
        let cEntry = try #require(store.card(id: c.id)?.entryId)
        #expect(source.entries.sorted { $0.sortOrder < $1.sortOrder }.first?.id == cEntry)

        await store.load() // pull-to-refresh: 並びはそのまま (未記録の B も位置を保つ)
        #expect(store.cards.map(\.id) == [c.id, b.id, a.id])
        let fresh = WorkoutSessionStore(dataSource: source, calendar: jst, now: { jstDate("2026-10-04T07:30:00") })
        await fresh.load() // 再起動相当: 記録済みカードが実施した順で戻る (未記録の予定は消える)
        #expect(fresh.cards.map(\.entryId) == [cEntry, store.card(id: a.id)?.entryId])
    }

    @Test("並べ替えの書き込みは進行中の ✓ が終わってから送る (行き違いで順が戻らない = E7)")
    func reorderWaitsForWrite() async throws {
        let (source, store) = makeStore()
        await store.load()
        let a = await store.addPlannedExercise(bench.id)
        let b = await store.addPlannedExercise(squat.id)
        _ = try (await store.addSet(card: a, exercise: bench, input: w(60))).get()
        source.addSetDelayNanoseconds = 50_000_000
        async let recording = store.addSet(card: b, exercise: squat, input: w(80))
        try await Task.sleep(nanoseconds: 10_000_000)
        store.moveCard(fromOffsets: [1], toOffset: 0)
        async let saving = store.saveCardOrder()
        let (recorded, saved) = await (recording, saving)
        #expect((try? recorded.get()) != nil)
        #expect(saved == nil)
        #expect(source.entries.sorted { $0.sortOrder < $1.sortOrder }.map(\.exerciseId) == [squat.id, bench.id])
    }

    @Test("別端末が先に entry を作っていたら (UNIQUE に当たる) 取り直して 1 回やり直す。相手のカードは末尾に出る (E5)")
    func retryOnConcurrentEntry() async throws {
        let (source, store) = makeStore()
        await store.load()
        let a = await store.addPlannedExercise(bench.id)
        _ = try (await store.addSet(card: a, exercise: bench, input: w(60))).get()
        let session = try #require(store.session)
        let other = source.insertEntryFromAnotherDevice(sessionId: session.id, exerciseId: squat.id)
        let b = await store.addPlannedExercise(bench.id)
        let s = try (await store.addSet(card: b, exercise: bench, input: w(50))).get()
        #expect(s.setIndex == 1)
        #expect(source.entries.count == 3)
        #expect(Set(source.entries.map(\.sortOrder)) == [1, 2, 3])
        #expect(store.cards.contains { $0.entryId == other.id })
    }

    @Test("未記録カードを外すとセットの無い entry の残骸も消える (E6)")
    func removePlannedDiscardsEmptyEntry() async throws {
        let session = WorkoutSession(id: UUID(), actualTaskId: nil, routineId: nil, startedAt: jstDate("2026-10-04T06:50:00"), endedAt: nil, note: nil)
        let residue = entry(UUID(), session: session.id, bench, 1)
        let (source, store) = makeStore(sessions: [session], entries: [residue])
        await store.load()
        let card = try #require(store.cards.first)
        #expect(card.entryId == residue.id) // 今日の画面では未記録カードとして出る
        await store.removePlannedCard(card)
        #expect(store.cards.isEmpty)
        #expect(source.entries.isEmpty)
    }
}

@Suite("MockWorkoutDataSource・プログラム・履歴 — workout_entry の制約の写し")
@MainActor
struct WorkoutEntryDataTests {
    let bench = exercise("ベンチプレス")
    let squat = exercise("スクワット")

    @Test("Mock: entry と set の種目の不一致・同じ entry の同じ番号・同じ sort_order・セットのある entry の削除を拒む")
    func mockConstraints() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, squat])
        let s = try await source.startSession(routineId: nil, startedAt: Date())
        let e = try await source.addEntry(sessionId: s.id, exerciseId: bench.id, sortOrder: 1)
        func new(_ exerciseId: UUID, _ index: Int) -> NewWorkoutSet {
            NewWorkoutSet(sessionId: s.id, exerciseId: exerciseId, entryId: e.id, setIndex: index, weight: 60, reps: 10,
                          durationSec: nil, distanceM: nil, isWarmup: false, completedAt: Date())
        }
        await #expect(throws: MockWorkoutDataSource.MockError.entryMismatch) { _ = try await source.addSet(new(squat.id, 1)) }
        _ = try await source.addSet(new(bench.id, 1))
        await #expect(throws: MockWorkoutDataSource.MockError.duplicateSetIndex) { _ = try await source.addSet(new(bench.id, 1)) }
        await #expect(throws: MockWorkoutDataSource.MockError.duplicateEntrySortOrder) {
            _ = try await source.addEntry(sessionId: s.id, exerciseId: squat.id, sortOrder: 1)
        }
        await #expect(throws: MockWorkoutDataSource.MockError.entryHasSets) { try await source.deleteEntry(id: e.id) }
    }

    @Test("プログラムに同じ種目を 2 行保存でき、確認シートは件数で追加済みを判定する (E8)")
    func programWithDuplicates() async throws {
        let source = MockWorkoutDataSource(exercises: [bench, squat])
        let programs = ProgramStore(dataSource: source)
        #expect(await programs.save(id: nil, name: "胸", exerciseIds: [bench.id, squat.id, bench.id]) == nil)
        let program = try #require(programs.programs.first)
        #expect(program.exerciseIds == [bench.id, squat.id, bench.id])
        #expect(ProgramLoadSheet.addedFlags(exerciseIds: program.exerciseIds, todayCounts: [bench.id: 1]) == [true, false, false])
        #expect(ProgramLoadSheet.addedFlags(exerciseIds: program.exerciseIds, todayCounts: [:]) == [false, false, false])
        #expect(ProgramLoadSheet.addedFlags(exerciseIds: program.exerciseIds, todayCounts: [bench.id: 2, squat.id: 1]) == [true, true, true])
        #expect(programs.program(withSameOrderAs: [bench.id, squat.id, bench.id])?.id == program.id)
        #expect(programs.program(withSameOrderAs: [bench.id, squat.id]) == nil)
    }

    @Test("履歴 store: 週のセッションの entry を取り、その日にセットのある entry だけを返す (E4)")
    func historyEntries() async throws {
        let session = UUID(), e1 = UUID(), e2 = UUID()
        let source = MockWorkoutDataSource(exercises: [bench], sets: [
            set(bench, session: session, entry: e1, 1, weight: 60, at: jstDate("2026-09-29T23:50:00")),
            set(bench, session: session, entry: e2, 1, weight: 50, at: jstDate("2026-09-30T00:10:00")),
        ])
        let store = WorkoutHistoryStore(dataSource: source, calendar: jst)
        await store.ensureLoaded(weekStarts: [jstDate("2026-09-28T00:00:00")])
        #expect(Set(store.entriesById.keys) == [e1, e2])
        #expect(store.entries(on: jstDate("2026-09-30T12:00:00")).map(\.id) == [e2])
        let groups = WorkoutLogic.groupByEntry(sets: store.sets(on: jstDate("2026-09-29T12:00:00")),
                                               entries: Array(store.entriesById.values)).filter { !$0.sets.isEmpty }
        #expect(groups.map(\.entry.id) == [e1]) // 過去日は セットの無い entry を出さない
        store.invalidate()
        #expect(store.entriesById.isEmpty)
    }
}
