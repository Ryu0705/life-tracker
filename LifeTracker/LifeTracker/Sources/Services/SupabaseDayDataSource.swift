import Foundation
import Supabase

final class SupabaseDayDataSource: DayDataSource {
    private let client: SupabaseClient
    private let calendar: Calendar
    private let holidayChecker: (Date) -> Bool

    init(
        client: SupabaseClient,
        calendar: Calendar,
        holidayChecker: @escaping (Date) -> Bool
    ) {
        self.client = client
        self.calendar = calendar
        self.holidayChecker = holidayChecker
    }

    func loadDayContext(date: Date) async throws -> DayBuilderContext {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let previousDayStart = calendar.date(byAdding: .day, value: -1, to: dayStart) else {
            throw SupabaseDayDataSourceError.invalidDate(date)
        }

        let dayString = DateOnly.formatter.string(from: dayStart)
        let previousDayString = DateOnly.formatter.string(from: previousDayStart)
        let startStr = supabaseTimestampFormatter.string(from: dayStart)
        let endStr = supabaseTimestampFormatter.string(from: dayEnd)

        async let templatesResp: [TaskTemplate] = client.from("task_template")
            .select()
            .execute()
            .value

        async let patternsResp: [Pattern] = client.from("pattern")
            .select()
            .execute()
            .value

        async let membershipsResp: [PatternTemplateMembership] = client.from("pattern_template_membership")
            .select()
            .execute()
            .value

        async let exdatesResp: [TemplateExdate] = client.from("task_template_exdate")
            .select()
            .in("date", values: [dayString, previousDayString])
            .execute()
            .value

        async let dayMetaResp: [DayMeta] = client.from("day_meta")
            .select()
            .in("date", values: [dayString, previousDayString])
            .execute()
            .value

        async let scheduledResp: [ScheduledTask] = client.from("scheduled_task")
            .select()
            .lt("start_at", value: endStr)
            .gt("end_at", value: startStr)
            .execute()
            .value

        async let actualResp: [ActualTask] = client.from("actual_task")
            .select()
            .lt("start_at", value: endStr)
            .gt("end_at", value: startStr)
            .execute()
            .value

        let (templates, patterns, memberships, exdatesAll, dayMetaList, scheduled, actual) = try await (
            templatesResp,
            patternsResp,
            membershipsResp,
            exdatesResp,
            dayMetaResp,
            scheduledResp,
            actualResp
        )

        let cal = calendar
        let todayExdates = exdatesAll.filter { cal.isDate($0.date, inSameDayAs: dayStart) }
        let previousExdates = exdatesAll.filter { cal.isDate($0.date, inSameDayAs: previousDayStart) }
        let todayMeta = dayMetaList.first { cal.isDate($0.date, inSameDayAs: dayStart) }
        let previousMeta = dayMetaList.first { cal.isDate($0.date, inSameDayAs: previousDayStart) }

        return DayBuilderContext(
            templates: templates,
            patterns: patterns,
            memberships: memberships,
            exdates: todayExdates,
            previousExdates: previousExdates,
            dayMeta: todayMeta,
            previousDayMeta: previousMeta,
            scheduledTasks: scheduled,
            actualTasks: actual,
            holidayChecker: holidayChecker,
            calendar: calendar
        )
    }
}

enum SupabaseDayDataSourceError: Error {
    case invalidDate(Date)
}
