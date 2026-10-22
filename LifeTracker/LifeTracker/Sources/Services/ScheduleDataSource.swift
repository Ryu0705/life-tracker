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
    /// サインインの直後に、その人の初期データ (予定の種類など) が無ければ入れる (0014 の RPC `ensure_user_defaults`。設計 §3・計画 §2-4)。
    /// メモリ上の実装は何もしない
    func ensureUserDefaults() async throws
}

/// 「やること」(時刻なしの回) の読み取り (0012 todo_fetch。1 往復)。予定タブ (ScheduleStore) だけが loadDayContext と並列で呼ぶ
/// (睡眠タブ・今日のカードは呼ばない。失敗が伝わらないように。計画 2-4)
protocol TodoDataSource {
    func loadTodos(date: Date) async throws -> TodoFetch
}

enum ScheduleRuleError: Error, LocalizedError, Equatable {
    /// D < 今日 (過去日は編集できない)
    case pastDay
    case notFound
    /// 曜日も祝日もない系列は作れない (単発にする)
    case noRepeat
    /// D より前の実体が残っていて系列を消せない (DB では FK RESTRICT)
    case referencedByPast
    /// 「この予定」(その日だけ) の保存で時刻の有無を変えようとした (これ以降で変える)
    case timingMismatch
    /// 閉じた (目標に届いた・スキップした) 単発の日付は変えられない
    case closedSingleDate
    /// 目標の回数は 1〜99 (DB の CHECK と同じ。丸めない)
    case invalidTarget

    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "目標の回数は 1〜99 回にしてください"
        case .closedSingleDate: return "終わった予定の日付は変えられません"
        case .timingMismatch: return "時刻の有無は「これ以降のすべての予定」で変えてください"
        case .pastDay: return "過去の日の予定は変えられません"
        case .notFound: return "予定が見つかりません。読み直してください"
        case .noRepeat: return "曜日か祝日を選んでください"
        case .referencedByPast: return "過去の予定から参照されているため消せません"
        }
    }
}
