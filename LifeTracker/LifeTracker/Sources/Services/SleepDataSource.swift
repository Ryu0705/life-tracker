import Foundation

/// 睡眠の記録 (sleep_record) の読み書き。書き込みは RPC にせず表へ直接 (トレーニングと同じ。synthesis §1-0)。
/// Supabase は SupabaseDayDataSource の extension (client を増やさない)、`-mock-day` とテストは InMemoryScheduleDataSource
/// (予定と同じインスタンス。睡眠タブで書いた記録が予定タブに出る)
protocol SleepDataSource {
    /// [from, to) に重なる記録 (start_at < to AND end_at > from)。就寝の順
    func fetchSleepRecords(from: Date, to: Date) async throws -> [SleepRecord]
    func insertSleepRecord(start: Date, end: Date, kind: SleepKind) async throws -> SleepRecord
    func updateSleepRecord(id: UUID, start: Date, end: Date, kind: SleepKind) async throws
    func deleteSleepRecord(id: UUID) async throws
}
