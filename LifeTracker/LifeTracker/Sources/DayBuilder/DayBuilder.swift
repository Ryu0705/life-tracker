import Foundation
import CryptoKit

enum DayBuilder {
    static func build(date: Date, context: DayBuilderContext) -> Day {
        let dayStart = context.calendar.startOfDay(for: date)
        guard let dayEnd = context.calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return Day(date: dayStart, scheduled: [], actual: [])
        }

        let mode = resolveMode(date: dayStart, context: context)
        let virtualScheduled = composeVirtual(mode: mode, dayStart: dayStart, context: context)
        let scheduledFromEntities = collectScheduledEntities(
            dayStart: dayStart,
            dayEnd: dayEnd,
            context: context
        )

        let editedTemplateIdsOnDate = Set(
            scheduledFromEntities.compactMap { dayTask -> UUID? in
                guard let templateId = dayTask.task.templateId else { return nil }
                let startInJST = dayTask.task.startAt
                let scheduledDay = context.calendar.startOfDay(for: startInJST)
                guard scheduledDay == dayStart else { return nil }
                return templateId
            }
        )

        let virtualFiltered = virtualScheduled.filter { dayTask in
            guard let templateId = dayTask.task.templateId else { return true }
            return !editedTemplateIdsOnDate.contains(templateId)
        }

        let mergedScheduled = (scheduledFromEntities + virtualFiltered)
            .sorted { $0.task.startAt < $1.task.startAt }

        let actuals = context.actualTasks
            .compactMap { actual -> DayActualTask? in
                guard let (membership, visibleRange) = computeMembership(
                    startAt: actual.startAt,
                    endAt: actual.endAt,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    calendar: context.calendar
                ) else {
                    return nil
                }
                return DayActualTask(
                    task: actual,
                    membership: membership,
                    visibleRange: visibleRange
                )
            }
            .sorted { $0.task.startAt < $1.task.startAt }

        return Day(date: dayStart, scheduled: mergedScheduled, actual: actuals)
    }

    // MARK: - Mode resolution

    private enum Mode {
        case doNothing
        case pattern(UUID)
        case normal
    }

    private static func resolveMode(date dayStart: Date, context: DayBuilderContext) -> Mode {
        if let dayMeta = context.dayMeta {
            if let appliedPatternId = dayMeta.appliedPatternId {
                return .pattern(appliedPatternId)
            } else {
                return .doNothing
            }
        }

        if context.holidayChecker(dayStart) {
            if let holidayPattern = context.patterns.first(where: { $0.applyDay == .Holiday }) {
                return .pattern(holidayPattern.id)
            }
            return .normal
        }

        let weekday = context.calendar.component(.weekday, from: dayStart)
        if let applyDay = applyDayFromWeekday(weekday),
           let weekdayPattern = context.patterns.first(where: { $0.applyDay == applyDay }) {
            return .pattern(weekdayPattern.id)
        }

        return .normal
    }

    private static func applyDayFromWeekday(_ weekday: Int) -> Pattern.ApplyDay? {
        switch weekday {
        case 1: return .Sunday
        case 2: return .Monday
        case 3: return .Tuesday
        case 4: return .Wednesday
        case 5: return .Thursday
        case 6: return .Friday
        case 7: return .Saturday
        default: return nil
        }
    }

    // MARK: - Virtual composition

    private static func composeVirtual(
        mode: Mode,
        dayStart: Date,
        context: DayBuilderContext
    ) -> [DayScheduledTask] {
        switch mode {
        case .doNothing:
            return []

        case .pattern(let patternId):
            let templateIds = context.memberships
                .filter { $0.patternId == patternId }
                .map { $0.templateId }
            let templates = context.templates.filter { templateIds.contains($0.id) }
            return templates.compactMap { template in
                makeVirtual(
                    template: template,
                    dayStart: dayStart,
                    context: context,
                    origin: .pattern,
                    patternId: patternId
                )
            }

        case .normal:
            return context.templates.compactMap { template in
                guard let rrule = template.rrule, rruleMatches(rrule, on: dayStart, calendar: context.calendar) else {
                    return nil
                }
                return makeVirtual(
                    template: template,
                    dayStart: dayStart,
                    context: context,
                    origin: .rrule,
                    patternId: nil
                )
            }
        }
    }

    private static func makeVirtual(
        template: TaskTemplate,
        dayStart: Date,
        context: DayBuilderContext,
        origin: TaskOrigin,
        patternId: UUID?
    ) -> DayScheduledTask? {
        let isExcluded = context.exdates.contains { exdate in
            exdate.templateId == template.id
                && context.calendar.isDate(exdate.date, inSameDayAs: dayStart)
        }
        if isExcluded { return nil }

        let startAt = dayStart.addingTimeInterval(TimeInterval(template.startMinutesFromMidnight * 60))
        let endAt = startAt.addingTimeInterval(TimeInterval(template.durationMinutes * 60))

        guard let dayEnd = context.calendar.date(byAdding: .day, value: 1, to: dayStart),
              let (membership, visibleRange) = computeMembership(
                startAt: startAt,
                endAt: endAt,
                dayStart: dayStart,
                dayEnd: dayEnd,
                calendar: context.calendar
              )
        else {
            return nil
        }

        let virtualId = UUID.virtual(templateId: template.id, startAt: startAt)
        let virtualTask = ScheduledTask(
            id: virtualId,
            name: template.name,
            categoryId: template.categoryId,
            startAt: startAt,
            endAt: endAt,
            templateId: template.id,
            patternId: patternId
        )
        return DayScheduledTask(
            task: virtualTask,
            membership: membership,
            visibleRange: visibleRange,
            origin: origin
        )
    }

    // MARK: - Entity collection

    private static func collectScheduledEntities(
        dayStart: Date,
        dayEnd: Date,
        context: DayBuilderContext
    ) -> [DayScheduledTask] {
        context.scheduledTasks.compactMap { task in
            guard let (membership, visibleRange) = computeMembership(
                startAt: task.startAt,
                endAt: task.endAt,
                dayStart: dayStart,
                dayEnd: dayEnd,
                calendar: context.calendar
            ) else {
                return nil
            }
            let origin: TaskOrigin
            if task.templateId == nil {
                origin = .manual
            } else if task.patternId != nil {
                origin = .pattern
            } else {
                origin = .rrule
            }
            return DayScheduledTask(
                task: task,
                membership: membership,
                visibleRange: visibleRange,
                origin: origin
            )
        }
    }

    // MARK: - Membership / visibleRange

    private static func computeMembership(
        startAt: Date,
        endAt: Date,
        dayStart: Date,
        dayEnd: Date,
        calendar: Calendar
    ) -> (DayMembership, DateInterval)? {
        guard startAt < dayEnd, endAt > dayStart else { return nil }
        let clippedStart = max(startAt, dayStart)
        let clippedEnd = min(endAt, dayEnd)
        guard clippedEnd > clippedStart else { return nil }
        let visibleRange = DateInterval(start: clippedStart, end: clippedEnd)

        if startAt < dayStart {
            let previousDayStart = calendar.startOfDay(for: dayStart.addingTimeInterval(-1))
            return (.spillover(from: previousDayStart), visibleRange)
        }
        if endAt > dayEnd {
            return (.overflow(to: dayEnd), visibleRange)
        }
        return (.primary, visibleRange)
    }

    // MARK: - rrule (Phase 1 minimal: FREQ=WEEKLY;BYDAY=MO,TU,...)

    private static func rruleMatches(_ rrule: String, on dayStart: Date, calendar: Calendar) -> Bool {
        let parts = rrule.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var freq: String?
        var byday: [String] = []

        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0) }
            guard kv.count == 2 else { continue }
            switch kv[0].uppercased() {
            case "FREQ":
                freq = kv[1].uppercased()
            case "BYDAY":
                byday = kv[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            default:
                continue
            }
        }

        guard freq == "WEEKLY" else { return false }
        guard !byday.isEmpty else { return true }

        let weekday = calendar.component(.weekday, from: dayStart)
        let token = bydayToken(weekday)
        return byday.contains(token)
    }

    private static func bydayToken(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "SU"
        case 2: return "MO"
        case 3: return "TU"
        case 4: return "WE"
        case 5: return "TH"
        case 6: return "FR"
        case 7: return "SA"
        default: return ""
        }
    }
}

extension UUID {
    static func virtual(templateId: UUID, startAt: Date) -> UUID {
        let seed = "\(templateId.uuidString)-\(Int(startAt.timeIntervalSince1970))"
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
