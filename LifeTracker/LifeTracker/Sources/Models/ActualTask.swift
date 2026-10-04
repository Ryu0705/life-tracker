import Foundation

/// 実績 (actual_task)。段階 2 で状態・回へのつながり・一覧に出る日を持つようになった (migration 0007)。
/// つながり: 繰り返しの予定の回 = templateId ＋ occurrenceDate / 繰り返さない予定 = scheduledTaskId / どちらも nil = 予定外の実績。
/// スキップは時刻なし (startAt / endAt が nil)。docs/day-cycle-walkthrough.md「段階 2 確定仕様」
struct ActualTask: Codable, Identifiable, Hashable {
    enum Status: String, Codable, Hashable {
        case done
        case skipped
    }

    let id: UUID
    var name: String
    var categoryId: UUID
    var startAt: Date?
    var endAt: Date?
    var status: Status
    var templateId: UUID?
    /// 一覧に出る日 (JST 0 時)。繰り返しの回はその回の日、単発は単発の日、予定外は開始の日
    var occurrenceDate: Date
    var scheduledTaskId: UUID?

    init(id: UUID, name: String, categoryId: UUID, startAt: Date?, endAt: Date?, status: Status = .done,
         templateId: UUID? = nil, occurrenceDate: Date? = nil, scheduledTaskId: UUID? = nil) {
        self.id = id
        self.name = name
        self.categoryId = categoryId
        self.startAt = startAt
        self.endAt = endAt
        self.status = status
        self.templateId = templateId
        // 省略時は開始の JST 日 (段階 1 までの呼び出し・テスト向け)
        self.occurrenceDate = occurrenceDate ?? Self.jstDay(startAt ?? Date())
        self.scheduledTaskId = scheduledTaskId
    }

    /// 予定外の実績 (回につながっていない)
    var isUnplanned: Bool { templateId == nil && scheduledTaskId == nil }

    private static func jstDay(_ date: Date) -> Date {
        DateOnly.formatter.date(from: DateOnly.formatter.string(from: date))!
    }

    // MARK: - Codable (occurrence_date は DATE。睡眠は actual_task に持たない = sleep_record。docs/sleep-design)

    private enum CodingKeys: String, CodingKey {
        case id, name, categoryId, startAt, endAt, status, templateId, occurrenceDate, scheduledTaskId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        categoryId = try c.decode(UUID.self, forKey: .categoryId)
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
        endAt = try c.decodeIfPresent(Date.self, forKey: .endAt)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .done
        templateId = try c.decodeIfPresent(UUID.self, forKey: .templateId)
        occurrenceDate = try c.decode(DateOnly.self, forKey: .occurrenceDate).wrappedValue
        scheduledTaskId = try c.decodeIfPresent(UUID.self, forKey: .scheduledTaskId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(categoryId, forKey: .categoryId)
        try c.encode(startAt, forKey: .startAt)
        try c.encode(endAt, forKey: .endAt)
        try c.encode(status, forKey: .status)
        try c.encode(templateId, forKey: .templateId)
        try c.encode(DateOnly(wrappedValue: occurrenceDate), forKey: .occurrenceDate)
        try c.encode(scheduledTaskId, forKey: .scheduledTaskId)
    }
}
