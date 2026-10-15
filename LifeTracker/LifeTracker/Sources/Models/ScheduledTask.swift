import Foundation

/// 時刻つきの予定の実体 (scheduled_task のうち start_at / end_at のある行)。
/// 時刻なしの行 (やること) は取得の境界で TodoEntity に分ける (ScheduledTaskRow)
struct ScheduledTask: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let categoryId: UUID
    let startAt: Date
    let endAt: Date
    let templateId: UUID?
    let patternId: UUID?
    /// 目標の回数 (既定 1)
    var targetCount: Int = 1
    /// 作成時刻 (0012。時刻なしへ切り替えたときも残す = やることの並び「作った順」)。仮想の回は nil
    var createdAt: Date? = nil
}

extension ScheduledTask {
    private enum CodingKeys: String, CodingKey {
        case id, name, categoryId, startAt, endAt, templateId, patternId, targetCount, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  categoryId: try c.decode(UUID.self, forKey: .categoryId), startAt: try c.decode(Date.self, forKey: .startAt),
                  endAt: try c.decode(Date.self, forKey: .endAt), templateId: try c.decodeIfPresent(UUID.self, forKey: .templateId),
                  patternId: try c.decodeIfPresent(UUID.self, forKey: .patternId),
                  // 0012 より前の行・テストの JSON には無い
                  targetCount: try c.decodeIfPresent(Int.self, forKey: .targetCount) ?? 1,
                  createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt))
    }
}

/// 時刻なしの予定の実体 (やること)。単発 (templateId nil) か、繰り返しのその日だけ変えた回 O(d)
struct TodoEntity: Identifiable, Hashable {
    let id: UUID
    var name: String
    var categoryId: UUID
    let templateId: UUID?
    var patternId: UUID?
    /// 回の日 (JST 0 時)。繰り越し中の単発も元の日のまま
    var occurrenceDate: Date
    var targetCount: Int
    /// 並びに使う (無ければ回の日・名前の順)
    var createdAt: Date?
}

/// scheduled_task の取得の行 (時刻 Optional。0012)。境界で ScheduledTask か TodoEntity に分ける
struct ScheduledTaskRow: Decodable, Hashable {
    let id: UUID
    let name: String
    let categoryId: UUID
    let startAt: Date?
    let endAt: Date?
    let templateId: UUID?
    let patternId: UUID?
    let occurrenceDate: Date
    let targetCount: Int
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, categoryId, startAt, endAt, templateId, patternId, occurrenceDate, targetCount, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        categoryId = try c.decode(UUID.self, forKey: .categoryId)
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
        endAt = try c.decodeIfPresent(Date.self, forKey: .endAt)
        templateId = try c.decodeIfPresent(UUID.self, forKey: .templateId)
        patternId = try c.decodeIfPresent(UUID.self, forKey: .patternId)
        occurrenceDate = try c.decode(DateOnly.self, forKey: .occurrenceDate).wrappedValue
        targetCount = try c.decodeIfPresent(Int.self, forKey: .targetCount) ?? 1
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    var timed: ScheduledTask? {
        guard let startAt, let endAt else { return nil }
        return ScheduledTask(id: id, name: name, categoryId: categoryId, startAt: startAt, endAt: endAt, templateId: templateId,
                             patternId: patternId, targetCount: targetCount, createdAt: createdAt)
    }

    var todo: TodoEntity? {
        guard startAt == nil else { return nil }
        return TodoEntity(id: id, name: name, categoryId: categoryId, templateId: templateId, patternId: patternId,
                          occurrenceDate: occurrenceDate, targetCount: targetCount, createdAt: createdAt)
    }
}
