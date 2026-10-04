import Foundation

/// 予定の書き込み (段階 1)。今日の組み立て (DayDataSource) とは別の protocol (Round 1 の決定「write 系は別 protocol」)。
/// 書き込みは操作の単位 (ScheduleOperation) で受ける。Supabase 実装は 1 操作 = 1 RPC、
/// メモリ上の実装 (InMemoryScheduleDataSource) は同じ規則 (世代・O・X・D ≥ 今日の検査) を Swift で持つ。
/// 実績 (段階 2) も同じ protocol で受ける。Supabase は 1 操作 = 1 RPC (migration 0007)
protocol ScheduleDataSource {
    func fetchCatalog() async throws -> ScheduleCatalog
    func apply(_ operation: ScheduleOperation) async throws
    func applyCheckIn(_ operation: CheckInOperation) async throws
    func createCategory(name: String) async throws -> Category
}

enum ScheduleRuleError: Error, LocalizedError, Equatable {
    /// D < 今日 (過去日は編集できない)
    case pastDay
    case notFound
    /// 曜日も祝日もない系列は作れない (単発にする)
    case noRepeat
    /// D より前の実体が残っていて系列を消せない (DB では FK RESTRICT)
    case referencedByPast

    var errorDescription: String? {
        switch self {
        case .pastDay: return "過去の日の予定は変えられません"
        case .notFound: return "予定が見つかりません。読み直してください"
        case .noRepeat: return "曜日か祝日を選んでください"
        case .referencedByPast: return "過去の予定から参照されているため消せません"
        }
    }
}
