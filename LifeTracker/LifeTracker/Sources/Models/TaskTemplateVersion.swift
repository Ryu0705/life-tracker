import Foundation

/// 予定 (系列) の中身の 1 世代 (task_template_version)。effective_from から次の世代の前日まで効く。
/// is_ended = この日以降は出ない (中身は直前の世代のコピー)。docs/day-cycle-walkthrough.md「段階 1 確定仕様」。
/// 時刻なしの世代 (やること) は開始・長さが nil (0012。docs/untimed-tasks-implementation-plan.md 2-1)
struct TaskTemplateVersion: Identifiable, Hashable {
    let id: UUID
    /// 系列の id (task_template.id)。除外日・その日だけ変えた回はこれを指す
    let templateId: UUID
    @DateOnly var effectiveFrom: Date
    let isEnded: Bool
    let name: String
    let categoryId: UUID
    let startMinutesFromMidnight: Int?
    let durationMinutes: Int?
    let rrule: String?
    /// 目標の回数 (既定 1)
    var targetCount: Int = 1
    /// 終わらなければ翌日以降にも出す (時刻なしの繰り返しだけ)
    var carryOver: Bool = false
    /// 並び (系列の最初の世代の作成順) に使う
    var createdAt: Date?

    var timing: ScheduleTiming {
        guard let startMinutesFromMidnight, let durationMinutes else { return .untimed }
        return .timed(startMinutes: startMinutesFromMidnight, durationMinutes: durationMinutes)
    }

    /// 解決後の形 (DayBuilder の入力)。id は系列の id。時刻なしの世代は nil (DayBuilder に入れない)
    var timedTemplate: TaskTemplate? {
        guard let startMinutesFromMidnight, let durationMinutes else { return nil }
        return TaskTemplate(id: templateId, name: name, categoryId: categoryId, startMinutesFromMidnight: startMinutesFromMidnight,
                            durationMinutes: durationMinutes, rrule: rrule, targetCount: targetCount)
    }
}

extension TaskTemplateVersion: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, templateId, effectiveFrom, isEnded, name, categoryId, startMinutesFromMidnight, durationMinutes, rrule
        case targetCount, carryOver, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), templateId: try c.decode(UUID.self, forKey: .templateId),
                  effectiveFrom: try c.decode(DateOnly.self, forKey: .effectiveFrom).wrappedValue,
                  isEnded: try c.decode(Bool.self, forKey: .isEnded), name: try c.decode(String.self, forKey: .name),
                  categoryId: try c.decode(UUID.self, forKey: .categoryId),
                  startMinutesFromMidnight: try c.decodeIfPresent(Int.self, forKey: .startMinutesFromMidnight),
                  durationMinutes: try c.decodeIfPresent(Int.self, forKey: .durationMinutes),
                  rrule: try c.decodeIfPresent(String.self, forKey: .rrule),
                  targetCount: try c.decodeIfPresent(Int.self, forKey: .targetCount) ?? 1,
                  carryOver: try c.decodeIfPresent(Bool.self, forKey: .carryOver) ?? false,
                  createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(templateId, forKey: .templateId)
        try c.encode(DateOnly(wrappedValue: effectiveFrom), forKey: .effectiveFrom)
        try c.encode(isEnded, forKey: .isEnded)
        try c.encode(name, forKey: .name)
        try c.encode(categoryId, forKey: .categoryId)
        try c.encode(startMinutesFromMidnight, forKey: .startMinutesFromMidnight)
        try c.encode(durationMinutes, forKey: .durationMinutes)
        try c.encode(rrule, forKey: .rrule)
        try c.encode(targetCount, forKey: .targetCount)
        try c.encode(carryOver, forKey: .carryOver)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

/// 祝日に出すか (パターンへの登録) の世代版 (pattern_version_membership)
struct PatternVersionMembership: Codable, Hashable {
    let patternId: UUID
    let versionId: UUID
}
