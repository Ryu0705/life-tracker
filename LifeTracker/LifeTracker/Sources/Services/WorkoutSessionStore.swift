import Foundation
import Combine

/// トレーニング画面の状態。書き込みは WorkoutDataSource 経由のみ、導出は WorkoutLogic / WorkoutProgress に委ねる。
///
/// 開始・終了の操作は持たない (2026-09-30 本人フィードバック「単純に何をしたのかを記録したい」)。
/// その日最初のセット記録で当日の workout_session を作り、前日以前の進行中セッションは次のロード時に閉じる
@MainActor
final class WorkoutSessionStore: ObservableObject {
    @Published private(set) var exercises: [Exercise] = []
    /// 当日のセッション (まだ 1 セットも記録していなければ nil)
    @Published private(set) var session: WorkoutSession?
    /// 当日のセット
    @Published private(set) var sets: [WorkoutSet] = []
    /// 今日の画面のカードの並び。記録済みカードの相対順は entry の sort_order (= 実施した順) と一致させる。
    /// 記録しても勝手には動かさない (記録のたびにカードが動くと押し間違えるため)。動かすのは並べ替えだけ
    @Published private(set) var cards: [TodayCard] = []
    /// 当日のセッションの entry
    @Published private(set) var entries: [WorkoutEntry] = []
    /// 未保存の行 (カード id → 行)。アプリ内メモリのみで、✓ を押した行だけ DB に入る
    @Published private(set) var drafts: [UUID: [DraftSet]] = [:]
    /// 種目ごとの全セット (前回・推移・履歴の元データ)
    @Published private(set) var history: [UUID: [WorkoutSet]] = [:]
    /// 前回の日の entry (前回の対応と履歴の区切りの順番)。history を取るときに前回の日のセッション分だけ取る
    @Published private(set) var historyEntries: [UUID: WorkoutEntry] = [:]
    @Published private(set) var isLoading = false
    /// 書き込み中。二度押しで同じ set_index / 当日セッションを重複 INSERT しないためのガード
    @Published private(set) var isWriting = false
    @Published var error: Error?

    private let dataSource: WorkoutDataSource
    let calendar: Calendar
    /// 今日の判定の時計 (テストで差し替える)。前回・履歴の導出 (WorkoutSessionStore+Previous.swift) でも使う
    let now: () -> Date

    init(dataSource: WorkoutDataSource, calendar: Calendar, now: @escaping () -> Date = { Date() }) {
        self.dataSource = dataSource
        self.calendar = calendar
        self.now = now
    }

    var exercisesById: [UUID: Exercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    /// 今日の種目 (画面順・同じ種目は枚数ぶん重複する)。プログラムへの保存・同じ並びの判定に使う
    var todayExerciseIds: [UUID] { cards.map(\.exerciseId) }

    func card(id: UUID) -> TodayCard? { cards.first { $0.id == id } }

    /// そのカードのセット (set_index 順)。未記録のカードは空
    func sets(for card: TodayCard) -> [WorkoutSet] {
        guard let entryId = card.entryId else { return [] }
        return sets.filter { $0.entryId == entryId }.sorted { $0.setIndex < $1.setIndex }
    }

    /// その種目の今日の全セット (記録順)。自己ベストの判定など種目単位の用途
    func sets(for exerciseId: UUID) -> [WorkoutSet] {
        sets.filter { $0.exerciseId == exerciseId }
            .sorted { ($0.completedAt ?? .distantPast, $0.setIndex) < ($1.completedAt ?? .distantPast, $1.setIndex) }
    }

    /// 全件取得してから一括で反映する (途中で失敗したときに半端な状態を作らない)
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let exercisesResp = dataSource.fetchExercises()
            async let sessionResp = dataSource.fetchInProgressSession()
            let (exercises, inProgress) = try await (exercisesResp, sessionResp)

            var todaySession: WorkoutSession?
            var todaySets: [WorkoutSet] = []
            var todayEntries: [WorkoutEntry] = []
            if let inProgress {
                if calendar.isDate(inProgress.startedAt, inSameDayAs: now()) {
                    todaySession = inProgress
                    async let setsResp = dataSource.fetchSets(sessionId: inProgress.id)
                    async let entriesResp = dataSource.fetchEntries(sessionId: inProgress.id)
                    (todaySets, todayEntries) = try await (setsResp, entriesResp)
                } else {
                    try await close(staleSession: inProgress)
                }
            }

            if todaySession?.id != session?.id {
                cards = []
                drafts = [:]
            }
            self.exercises = exercises
            self.session = todaySession
            self.sets = todaySets
            self.entries = todayEntries
            self.cards = WorkoutLogic.reconcile(cards, with: todayEntries)
            self.history = [:] // 日付が変わった後の再表示でも前回・推移を取り直す
        } catch {
            report(error)
            return
        }
        for exerciseId in Set(cards.map(\.exerciseId)) { await loadHistory(exerciseId: exerciseId) }
        for card in cards { prepareDrafts(card) }
    }

    /// 種目を今日の画面に足し、前回の値で埋めた行を用意する。同じ種目が今日にあっても 2 枚目として足す
    @discardableResult
    func addPlannedExercise(_ exerciseId: UUID) async -> TodayCard {
        let card = TodayCard(id: UUID(), exerciseId: exerciseId, entryId: nil)
        cards.append(card)
        await loadHistory(exerciseId: exerciseId)
        prepareDrafts(card)
        return card
    }

    /// 未記録のカードを外す (記録済みのカードは外せない)。セットの無い entry の残骸があれば消す
    func removePlannedCard(_ card: TodayCard) async {
        guard let current = self.card(id: card.id), sets(for: current).isEmpty else { return }
        cards.removeAll { $0.id == card.id }
        drafts[card.id] = nil
        await discardEmptyEntry(current.entryId)
    }

    /// 未記録のカードの種目を差し替える (Gymwork の ⇄)。位置は保ち、行は差し替え先の前回値で作り直す。
    /// 今日にある種目への差し替えも可 (2 枚目になる)。記録済みのカード・同じ種目への差し替えは何もしない
    func replacePlannedCard(_ card: TodayCard, with exerciseId: UUID) async {
        guard let index = cards.firstIndex(where: { $0.id == card.id }), sets(for: cards[index]).isEmpty,
              cards[index].exerciseId != exerciseId else { return }
        let old = cards[index]
        let replacement = TodayCard(id: UUID(), exerciseId: exerciseId, entryId: nil)
        cards[index] = replacement
        drafts[old.id] = nil
        await discardEmptyEntry(old.entryId)
        await loadHistory(exerciseId: exerciseId)
        prepareDrafts(replacement)
    }

    /// 並べ替え (シートの ≡)。画面の並びだけを同期で変える (List の onMove は同期で反映しないと行が跳ねる)。
    /// 続けて saveCardOrder で DB に書く
    func moveCard(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Array.move(fromOffsets:toOffset:) は SwiftUI のため、同じ規則 (destination は移動前の位置) で並べ直す
        let moving = source.map { cards[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        var rest = cards.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: insertAt)
        cards = rest
    }

    /// 記録済みカードの相対順が DB と違うときだけ書く (未記録のカードの移動では書かない)。
    /// 進行中の書き込み (✓ など) が終わってから送る。失敗は戻り値で返す (画面の並びはそのまま)
    @discardableResult
    func saveCardOrder() async -> Error? {
        while isWriting { try? await Task.sleep(for: .milliseconds(20)) }
        isWriting = true
        defer { isWriting = false }
        do {
            try await writeEntryOrderIfChanged()
            return nil
        } catch {
            return error
        }
    }

    func updateDraft(cardId: UUID, draftId: UUID, input: WorkoutSetInput) {
        guard let index = drafts[cardId]?.firstIndex(where: { $0.id == draftId }) else { return }
        drafts[cardId]?[index].input = input
    }

    func addDraft(cardId: UUID) {
        guard let card = card(id: cardId) else { return }
        let rows = drafts[cardId] ?? []
        let recorded = sets(for: card)
        let lastRow = rows.last?.input ?? recorded.last.map { WorkoutLogic.input(from: $0, keepWarmup: false) }
        let position = recorded.count + rows.count
        let input = WorkoutLogic.nextDraft(lastRow: lastRow, previousAtPosition: previousSet(for: card, position: position))
        drafts[cardId, default: []].append(DraftSet(input: input))
    }

    /// 「残りのセットに適用」: この行より下の未保存の行を同じ値にする (ウォームアップ区分は各行のまま)
    func applyToRemaining(cardId: UUID, from draftId: UUID) {
        guard let rows = drafts[cardId], let index = rows.firstIndex(where: { $0.id == draftId }) else { return }
        let source = rows[index].input
        for i in rows.indices where i > index {
            var input = source
            input.isWarmup = rows[i].input.isWarmup
            drafts[cardId]?[i].input = input
        }
    }

    func removeDraft(cardId: UUID, draftId: UUID) {
        drafts[cardId]?.removeAll { $0.id == draftId }
    }

    /// ✓: 行を DB に保存し、成功したら未保存の行から外す
    @discardableResult
    func completeDraft(card: TodayCard, exercise: Exercise, draftId: UUID) async -> Result<WorkoutSet, Error> {
        guard let draft = drafts[card.id]?.first(where: { $0.id == draftId }) else {
            return .failure(StoreError.busy)
        }
        let result = await addSet(card: card, exercise: exercise, input: draft.input)
        if case .success = result { removeDraft(cardId: card.id, draftId: draftId) }
        return result
    }

    /// 行の初期値: 前回の同じ順番のかたまり。それが無い 2 枚目以降は、今日のその種目の最後のセット
    /// (まだ無ければ前回の日の最後のセット) を写した 1 行 (Q2「a」)
    private func prepareDrafts(_ card: TodayCard) {
        guard drafts[card.id] == nil else { return }
        let current = sets(for: card)
        let previous = previousSets(for: card)
        if previous.isEmpty, current.isEmpty, ordinal(of: card) > 1 {
            let source = sets(for: card.exerciseId).last ?? previousDay(for: card.exerciseId)?.sets.last
            drafts[card.id] = [DraftSet(input: source.map { WorkoutLogic.input(from: $0, keepWarmup: false) } ?? WorkoutSetInput())]
            return
        }
        drafts[card.id] = WorkoutLogic.initialDrafts(currentSets: current, previousSets: previous).map { DraftSet(input: $0) }
    }

    func loadHistory(exerciseId: UUID) async {
        guard history[exerciseId] == nil else { return }
        do {
            let loaded = try await dataSource.fetchExerciseSets(exerciseId: exerciseId)
            let previous = WorkoutProgress.previousDay(loaded, today: now(), calendar: calendar)
            let sessionIds = Set(previous?.sets.map(\.sessionId) ?? []).subtracting(historyEntries.values.map(\.sessionId))
            if !sessionIds.isEmpty {
                for entry in try await dataSource.fetchEntries(sessionIds: Array(sessionIds)) { historyEntries[entry.id] = entry }
            }
            history[exerciseId] = loaded
        } catch {
            report(error)
        }
    }

    /// 失敗は戻り値で返す (呼び出し側の画面で表示する。push 先から root の alert は出ないことがあるため)。
    /// カードの最初の ✓ で entry を作り、画面上の位置に差し込む (実施した順の初期値)
    @discardableResult
    func addSet(card: TodayCard, exercise: Exercise, input: WorkoutSetInput) async -> Result<WorkoutSet, Error> {
        guard !isWriting else { return .failure(StoreError.busy) }
        let validated: WorkoutSetInput.Validated
        switch input.validate(for: exercise.metricKind) {
        case .failure(let validationError): return .failure(validationError)
        case .success(let v): validated = v
        }

        isWriting = true
        defer { isWriting = false }
        let session: WorkoutSession
        let entryId: UUID
        do {
            session = try await todaySessionCreatingIfNeeded()
            entryId = try await entryCreatingIfNeeded(cardId: card.id, session: session)
        } catch {
            return .failure(error)
        }

        do {
            let created = try await dataSource.addSet(NewWorkoutSet(
                sessionId: session.id,
                exerciseId: exercise.id,
                entryId: entryId,
                setIndex: WorkoutLogic.nextSetIndex(forEntry: entryId, in: sets),
                weight: validated.weight, reps: validated.reps,
                durationSec: validated.durationSec, distanceM: validated.distanceM,
                isWarmup: validated.isWarmup,
                completedAt: now()
            ))
            sets.append(created)
            // 未ロードの履歴に 1 件だけ入れると loadHistory が「ロード済み」と誤認して前回が出なくなる
            history[exercise.id]?.append(created)
            return .success(created)
        } catch {
            // INSERT が通ってレスポンスだけ失われた可能性があるため、サーバーの状態に合わせ直す
            await refreshToday(sessionId: session.id)
            if let refreshedHistory = try? await dataSource.fetchExerciseSets(exerciseId: exercise.id) {
                history[exercise.id] = refreshedHistory
            }
            return .failure(error)
        }
    }

    /// カードの entry。無ければ作り (sort_order = 最大 + 1)、画面でそのカードより下に記録済みカードがあれば
    /// 画面順に並べ直す。作成に失敗したら取り直し、応答だけ失われた自分の entry があればそれを使い、
    /// 無ければ (別端末と同時に作って UNIQUE に当たった = E5) 1 回だけやり直す
    private func entryCreatingIfNeeded(cardId: UUID, session: WorkoutSession) async throws -> UUID {
        guard let card = card(id: cardId) else { throw StoreError.busy }
        if let entryId = card.entryId, entries.contains(where: { $0.id == entryId }) { return entryId }
        let created: WorkoutEntry
        do {
            created = try await dataSource.addEntry(sessionId: session.id, exerciseId: card.exerciseId, sortOrder: nextSortOrder())
            entries.append(created)
        } catch {
            let referenced = Set(cards.compactMap(\.entryId))
            let fetched = try await dataSource.fetchEntries(sessionId: session.id)
            entries = fetched
            if let lost = fetched.last(where: { entry in
                !referenced.contains(entry.id) && entry.exerciseId == card.exerciseId && !sets.contains { $0.entryId == entry.id }
            }) {
                created = lost
            } else {
                cards = WorkoutLogic.reconcile(cards, with: fetched)
                created = try await dataSource.addEntry(sessionId: session.id, exerciseId: card.exerciseId, sortOrder: nextSortOrder())
                entries.append(created)
            }
        }
        // 画面の並びは変えない (reconcile は DB の順に並べ直すので、ここでは使わない)
        if let index = cards.firstIndex(where: { $0.id == cardId }) { cards[index].entryId = created.id }
        // 差し込みの失敗はセットの記録を止めない (entry は末尾のまま。次の並べ替えで画面順が入る)
        try? await writeEntryOrderIfChanged()
        return created.id
    }

    private func nextSortOrder() -> Int { (entries.map(\.sortOrder).max() ?? 0) + 1 }

    /// 記録済みの行の編集 (入力シートの「保存」)。completed_at・set_index は変えない。休憩タイマーには触れない
    @discardableResult
    func updateSet(_ set: WorkoutSet, exercise: Exercise, input: WorkoutSetInput) async -> Result<WorkoutSet, Error> {
        guard !isWriting else { return .failure(StoreError.busy) }
        let validated: WorkoutSetInput.Validated
        switch input.validate(for: exercise.metricKind) {
        case .failure(let validationError): return .failure(validationError)
        case .success(let v): validated = v
        }

        isWriting = true
        defer { isWriting = false }
        do {
            let updated = try await dataSource.updateSet(id: set.id, values: validated)
            replace(updated)
            return .success(updated)
        } catch {
            return .failure(error)
        }
    }

    /// スワイプの削除。後ろのセットの番号は詰める (DB は RPC で、ローカルは同じ規則で振り直す)
    @discardableResult
    func deleteSet(_ set: WorkoutSet) async -> Error? {
        guard !isWriting else { return StoreError.busy }
        isWriting = true
        defer { isWriting = false }
        return await removeOnServer(set)
    }

    /// ✓ の取り消し: 行を DB から消し、同じ値で未保存の行の先頭に戻す (確認なし。失うのは記録時刻だけ)。
    /// entry が空になってもカードは残る (再 ✓ で entry を作り直し、画面の位置に差し込む = E1)。
    /// 成功したら戻した行の id を返す
    @discardableResult
    func undoSet(_ set: WorkoutSet) async -> Result<UUID, Error> {
        guard !isWriting else { return .failure(StoreError.busy) }
        isWriting = true
        defer { isWriting = false }
        let cardId = cards.first { $0.entryId == set.entryId }?.id
        if let error = await removeOnServer(set) { return .failure(error) }
        let draft = DraftSet(input: WorkoutLogic.input(from: set, keepWarmup: true))
        if let cardId { drafts[cardId, default: []].insert(draft, at: 0) }
        return .success(draft.id)
    }

    /// 削除して sets・entries・history の番号を詰め直す。失敗時は削除が通って応答だけ失われた可能性があるため、サーバーに合わせ直す
    private func removeOnServer(_ set: WorkoutSet) async -> Error? {
        do {
            try await dataSource.deleteSet(id: set.id)
            sets = WorkoutLogic.removingAndRenumbering(set, from: sets)
            entries = WorkoutLogic.pruningEntry(set.entryId, remainingSets: sets, entries: entries)
            cards = WorkoutLogic.reconcile(cards, with: entries)
            if let loaded = history[set.exerciseId] {
                history[set.exerciseId] = WorkoutLogic.removingAndRenumbering(set, from: loaded)
            }
            return nil
        } catch {
            if Self.isCancellation(error) { return nil }
            if set.sessionId == session?.id { await refreshToday(sessionId: set.sessionId) }
            if history[set.exerciseId] != nil,
               let refreshedHistory = try? await dataSource.fetchExerciseSets(exerciseId: set.exerciseId) {
                history[set.exerciseId] = refreshedHistory
            }
            return error
        }
    }

    /// 今日のセットと entry をサーバーに合わせ直す (失敗は黙って諦める。呼び出し元が元のエラーを返す)
    private func refreshToday(sessionId: UUID) async {
        if let refreshed = try? await dataSource.fetchSets(sessionId: sessionId) { sets = refreshed }
        if let refreshed = try? await dataSource.fetchEntries(sessionId: sessionId) {
            entries = refreshed
            cards = WorkoutLogic.reconcile(cards, with: refreshed)
        }
    }

    /// 記録済みカードの画面順が entry の sort_order と違えば RPC で揃える
    private func writeEntryOrderIfChanged() async throws {
        guard let session else { return }
        let screen = cards.compactMap(\.entryId)
        guard screen != entries.sorted(by: { $0.sortOrder < $1.sortOrder }).map(\.id) else { return }
        try await dataSource.reorderEntries(sessionId: session.id, entryIds: screen)
        entries = WorkoutLogic.reordering(entries, sessionId: session.id, entryIds: screen)
    }

    /// セットの無い entry (E6 の残骸) を消す。失敗しても画面には影響しない (過去日には出ない)
    private func discardEmptyEntry(_ entryId: UUID?) async {
        guard let entryId, !sets.contains(where: { $0.entryId == entryId }) else { return }
        guard (try? await dataSource.deleteEntry(id: entryId)) != nil else { return }
        entries.removeAll { $0.id == entryId }
    }

    private func replace(_ updated: WorkoutSet) {
        if let index = sets.firstIndex(where: { $0.id == updated.id }) { sets[index] = updated }
        if let index = history[updated.exerciseId]?.firstIndex(where: { $0.id == updated.id }) {
            history[updated.exerciseId]?[index] = updated
        }
    }

    private func todaySessionCreatingIfNeeded() async throws -> WorkoutSession {
        if let session, calendar.isDate(session.startedAt, inSameDayAs: now()) { return session }
        // 日付をまたいで開いたままの画面から記録した場合: 前日分を閉じてから今日の分を作る
        if let stale = try await dataSource.fetchInProgressSession() {
            if calendar.isDate(stale.startedAt, inSameDayAs: now()) {
                session = stale
                return stale
            }
            try await close(staleSession: stale)
        }
        let created = try await dataSource.startSession(routineId: nil, startedAt: now())
        session = created
        sets = []
        entries = []
        cards = WorkoutLogic.reconcile(cards, with: [])
        return created
    }

    /// 前日以前の進行中セッションを閉じる。破棄の判定はサーバーのセットで行う
    /// (応答だけ失われたセットを CASCADE で消さないため)。終了時刻は最後のセットの時刻
    private func close(staleSession: WorkoutSession) async throws {
        let serverSets = try await dataSource.fetchSets(sessionId: staleSession.id)
        if serverSets.isEmpty {
            try await dataSource.deleteSession(id: staleSession.id)
        } else {
            let lastSetAt = serverSets.compactMap(\.completedAt).max() ?? staleSession.startedAt
            try await dataSource.endSession(
                id: staleSession.id,
                endedAt: WorkoutLogic.endDate(startedAt: staleSession.startedAt, now: lastSetAt)
            )
        }
    }

    /// 画面離脱で .task がキャンセルされた場合はエラー表示しない
    private func report(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        self.error = error
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    struct DraftSet: Identifiable, Hashable {
        let id = UUID()
        var input: WorkoutSetInput
    }

    enum StoreError: Error, LocalizedError {
        case busy

        var errorDescription: String? {
            switch self {
            case .busy: return "記録中です"
            }
        }
    }
}
