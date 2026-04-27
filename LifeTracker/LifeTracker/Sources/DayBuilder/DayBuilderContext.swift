import Foundation

struct DayBuilderContext {
    let templates: [TaskTemplate]
    let patterns: [Pattern]
    let memberships: [PatternTemplateMembership]
    let exdates: [TemplateExdate]
    let dayMeta: DayMeta?
    let scheduledTasks: [ScheduledTask]
    let actualTasks: [ActualTask]
    let holidayChecker: (Date) -> Bool
    let calendar: Calendar
}
