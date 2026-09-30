import Foundation

struct DayBuilderContext {
    let templates: [TaskTemplate]
    let patterns: [Pattern]
    let memberships: [PatternTemplateMembership]
    /// 前日の分 (日をまたぐ予定の流入) を組み立てる世代。既定は当日と同じ (世代を持たない呼び出し・既存テスト)
    let previousTemplates: [TaskTemplate]
    let previousMemberships: [PatternTemplateMembership]
    let exdates: [TemplateExdate]
    let previousExdates: [TemplateExdate]
    let dayMeta: DayMeta?
    let previousDayMeta: DayMeta?
    let scheduledTasks: [ScheduledTask]
    let actualTasks: [ActualTask]
    let holidayChecker: (Date) -> Bool
    let calendar: Calendar

    init(
        templates: [TaskTemplate],
        patterns: [Pattern],
        memberships: [PatternTemplateMembership],
        previousTemplates: [TaskTemplate]? = nil,
        previousMemberships: [PatternTemplateMembership]? = nil,
        exdates: [TemplateExdate],
        previousExdates: [TemplateExdate] = [],
        dayMeta: DayMeta?,
        previousDayMeta: DayMeta? = nil,
        scheduledTasks: [ScheduledTask],
        actualTasks: [ActualTask],
        holidayChecker: @escaping (Date) -> Bool,
        calendar: Calendar
    ) {
        self.templates = templates
        self.patterns = patterns
        self.memberships = memberships
        self.previousTemplates = previousTemplates ?? templates
        self.previousMemberships = previousMemberships ?? memberships
        self.exdates = exdates
        self.previousExdates = previousExdates
        self.dayMeta = dayMeta
        self.previousDayMeta = previousDayMeta
        self.scheduledTasks = scheduledTasks
        self.actualTasks = actualTasks
        self.holidayChecker = holidayChecker
        self.calendar = calendar
    }
}
