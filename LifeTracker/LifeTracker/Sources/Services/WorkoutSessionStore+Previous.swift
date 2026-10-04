import Foundation

/// 今日の store の読み取り専用の導出: 前回の対応 (Q2「a」)・推移・履歴・自己ベスト。
/// 書き込みは持たない (WorkoutSessionStore.swift の行数を抑えるために分けた)
extension WorkoutSessionStore {
    /// 同じ種目のカードの中で何枚目か (画面順・1 始まり)。表示には出さず、前回の対応にだけ使う (Q4)
    func ordinal(of card: TodayCard) -> Int {
        cards.prefix { $0.id != card.id }.filter { $0.exerciseId == card.exerciseId }.count + 1
    }

    func previousDay(for exerciseId: UUID) -> DailySets? {
        history[exerciseId].flatMap { WorkoutProgress.previousDay($0, today: now(), calendar: calendar) }
    }

    /// 前回の日の、同じ順番のかたまりのセット (Q2「a」: 2 枚目 ↔ 前回の 2 回目。無ければ空)
    func previousSets(for card: TodayCard) -> [WorkoutSet] {
        guard let day = previousDay(for: card.exerciseId) else { return [] }
        let blocks = WorkoutLogic.blocks(of: day.sets, entriesById: historyEntries)
        let index = ordinal(of: card) - 1
        return blocks.indices.contains(index) ? blocks[index] : []
    }

    /// 前回の同じ位置のセット (行の「前回」列)
    func previousSet(for card: TodayCard, position: Int) -> WorkoutSet? {
        let previous = previousSets(for: card)
        return previous.indices.contains(position) ? previous[position] : nil
    }

    func daily(for exerciseId: UUID) -> [DailySets] {
        WorkoutProgress.daily(history[exerciseId] ?? [], calendar: calendar)
    }

    /// 今日より前の日 (履歴表示用)。新しい日が先頭
    func pastDays(for exerciseId: UUID) -> [DailySets] {
        let todayStart = calendar.startOfDay(for: now())
        return daily(for: exerciseId).filter { $0.day < todayStart }
    }

    /// 今日より前の推定1RMのベスト (自己ベスト更新の判定用。日単位なのでカードに依らない)
    func bestOneRMBeforeToday(exerciseId: UUID) -> Double? {
        WorkoutProgress.bestOneRM(pastDays(for: exerciseId).flatMap(\.sets))
    }
}
