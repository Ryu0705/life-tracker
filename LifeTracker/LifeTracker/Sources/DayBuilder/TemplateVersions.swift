import Foundation

/// 世代の解決 (pure)。規則の原本はここ。SQL の RPC はこの写し (supabase/migrations/0006_template_version.sql)
enum TemplateVersions {
    /// その日に効く世代を系列ごとに 1 つ選ぶ (effective_from ≤ その日 の最新)。
    /// is_ended の世代は template も membership も出さない。effective_from より前の日は何も出さない。
    /// 返す TaskTemplate.id は系列の id、membership は選んだ世代の分だけ
    static func resolve(
        versions: [TaskTemplateVersion],
        memberships: [PatternVersionMembership],
        on date: Date,
        calendar: Calendar
    ) -> (templates: [TaskTemplate], memberships: [PatternTemplateMembership]) {
        let effective = effectiveVersions(versions: versions, on: date, calendar: calendar)
        let byVersion = Dictionary(grouping: memberships, by: \.versionId)
        let templates = effective.map(\.template)
        let resolved = effective.flatMap { version in
            (byVersion[version.id] ?? []).map { PatternTemplateMembership(patternId: $0.patternId, templateId: version.templateId) }
        }
        return (templates, resolved)
    }

    /// その日に効く世代 (is_ended を除く)。並びは系列の最初の世代の順ではなく、名前順で安定させる
    static func effectiveVersions(versions: [TaskTemplateVersion], on date: Date, calendar: Calendar) -> [TaskTemplateVersion] {
        let day = calendar.startOfDay(for: date)
        var latest: [UUID: TaskTemplateVersion] = [:]
        for version in versions where calendar.startOfDay(for: version.effectiveFrom) <= day {
            if let current = latest[version.templateId], current.effectiveFrom >= version.effectiveFrom { continue }
            latest[version.templateId] = version
        }
        return latest.values
            .filter { !$0.isEnded }
            .sorted { ($0.startMinutesFromMidnight, $0.name, $0.templateId.uuidString) < ($1.startMinutesFromMidnight, $1.name, $1.templateId.uuidString) }
    }

    /// 1 系列のその日に効く世代 (is_ended なら nil)
    static func effectiveVersion(templateId: UUID, versions: [TaskTemplateVersion], on date: Date, calendar: Calendar) -> TaskTemplateVersion? {
        effectiveVersions(versions: versions.filter { $0.templateId == templateId }, on: date, calendar: calendar).first
    }

    /// DayBuilder への入力 (当日分と前日分を別に解決する。レビュー DB §3-2)
    static func context(
        date: Date,
        versions: [TaskTemplateVersion],
        versionMemberships: [PatternVersionMembership],
        patterns: [Pattern],
        exdates: [TemplateExdate],
        previousExdates: [TemplateExdate],
        dayMeta: DayMeta?,
        previousDayMeta: DayMeta?,
        scheduledTasks: [ScheduledTask],
        actualTasks: [ActualTask],
        holidayChecker: @escaping (Date) -> Bool,
        calendar: Calendar
    ) -> DayBuilderContext {
        let dayStart = calendar.startOfDay(for: date)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: dayStart)!
        let today = resolve(versions: versions, memberships: versionMemberships, on: dayStart, calendar: calendar)
        let previous = resolve(versions: versions, memberships: versionMemberships, on: previousDay, calendar: calendar)
        return DayBuilderContext(
            templates: today.templates,
            patterns: patterns,
            memberships: today.memberships,
            previousTemplates: previous.templates,
            previousMemberships: previous.memberships,
            exdates: exdates,
            previousExdates: previousExdates,
            dayMeta: dayMeta,
            previousDayMeta: previousDayMeta,
            scheduledTasks: scheduledTasks,
            actualTasks: actualTasks,
            holidayChecker: holidayChecker,
            calendar: calendar
        )
    }
}
