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
    /// 実績。段階 2 からは「一覧に出る日が前日か当日」の行 (occurrence_date IN (D-1, D))。スキップ行 (時刻なし) も含む
    let actualTasks: [ActualTask]
    /// 当日 (JST) に完了したトレーニングのセットの completed_at。ジムの回の表示時判定に使う (段階 2 決定 C4)
    let workoutSetTimes: [Date]
    /// 睡眠の記録 (sleep_record)。[D−1 0:00, D+2 0:00) に重なるもの。睡眠の行との結びは表示時 (SleepRules.assign)
    let sleepRecords: [SleepRecord]
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
        workoutSetTimes: [Date] = [],
        sleepRecords: [SleepRecord] = [],
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
        self.workoutSetTimes = workoutSetTimes
        self.sleepRecords = sleepRecords
        self.holidayChecker = holidayChecker
        self.calendar = calendar
    }
}
