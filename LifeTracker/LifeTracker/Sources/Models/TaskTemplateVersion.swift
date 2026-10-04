import Foundation

/// 予定 (系列) の中身の 1 世代 (task_template_version)。effective_from から次の世代の前日まで効く。
/// is_ended = この日以降は出ない (中身は直前の世代のコピー)。docs/day-cycle-walkthrough.md「段階 1 確定仕様」
struct TaskTemplateVersion: Codable, Identifiable, Hashable {
    let id: UUID
    /// 系列の id (task_template.id)。除外日・その日だけ変えた回はこれを指す
    let templateId: UUID
    @DateOnly var effectiveFrom: Date
    let isEnded: Bool
    let name: String
    let categoryId: UUID
    let startMinutesFromMidnight: Int
    let durationMinutes: Int
    let rrule: String?

    /// 解決後の形 (DayBuilder の入力)。id は系列の id
    var template: TaskTemplate {
        TaskTemplate(id: templateId, name: name, categoryId: categoryId,
                     startMinutesFromMidnight: startMinutesFromMidnight, durationMinutes: durationMinutes, rrule: rrule)
    }
}

/// 祝日に出すか (パターンへの登録) の世代版 (pattern_version_membership)
struct PatternVersionMembership: Codable, Hashable {
    let patternId: UUID
    let versionId: UUID
}
