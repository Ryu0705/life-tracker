import Foundation
import CryptoKit

enum DayBuilder {
    static func build(date: Date, context: DayBuilderContext) -> Day {
        let dayStart = context.calendar.startOfDay(for: date)
        guard let dayEnd = context.calendar.date(byAdding: .day, value: 1, to: dayStart),
              let previousDayStart = context.calendar.date(byAdding: .day, value: -1, to: dayStart) else {
            return Day(date: dayStart, scheduled: [], actual: [])
        }

        let todayMode = resolveMode(dayStart: dayStart, dayMeta: context.dayMeta, context: context)
        let previousMode = resolveMode(dayStart: previousDayStart, dayMeta: context.previousDayMeta, context: context)

        let todaySeeds = composeVirtualSeeds(
            mode: todayMode,
            dayStart: dayStart,
            templates: context.templates,
            memberships: context.memberships,
            exdates: context.exdates,
            context: context
        )
        let previousSeeds = composeVirtualSeeds(
            mode: previousMode,
            dayStart: previousDayStart,
            templates: context.previousTemplates,
            memberships: context.previousMemberships,
            exdates: context.previousExdates,
            context: context
        )

        let virtualScheduled: [DayScheduledTask] = (todaySeeds + previousSeeds).compactMap { seed in
            guard let (membership, visibleRange) = computeMembership(
                startAt: seed.task.startAt,
                endAt: seed.task.endAt,
                dayStart: dayStart,
                dayEnd: dayEnd,
                calendar: context.calendar
            ) else {
                return nil
            }
            return DayScheduledTask(
                task: seed.task,
                membership: membership,
                visibleRange: visibleRange,
                origin: seed.origin,
                isVirtual: true
            )
        }

        let scheduledFromEntities = collectScheduledEntities(
            dayStart: dayStart,
            dayEnd: dayEnd,
            context: context
        )

        // 仮想の抑制は clip 前の実体から作る。前日の「その日だけ変えた回」が当日に重ならない形
        // (例: 前日 21:00–23:00) でも、前日の仮想の流入を消すため (レビュー DB §3-1 の既存バグ)
        let editedOnDate = editedTemplateIds(
            tasks: context.scheduledTasks,
            targetDayStart: dayStart,
            calendar: context.calendar
        )
        let editedOnPreviousDay = editedTemplateIds(
            tasks: context.scheduledTasks,
            targetDayStart: previousDayStart,
            calendar: context.calendar
        )

        let virtualFiltered = virtualScheduled.filter { dayTask in
            guard let templateId = dayTask.task.templateId else { return true }
            let sourceDay = context.calendar.startOfDay(for: dayTask.task.startAt)
            if sourceDay == dayStart {
                return !editedOnDate.contains(templateId)
            } else if sourceDay == previousDayStart {
                return !editedOnPreviousDay.contains(templateId)
            } else {
                return true
            }
        }

        let mergedScheduled = (scheduledFromEntities + virtualFiltered)
            .sorted { $0.task.startAt < $1.task.startAt }

        // 時刻のある「やった」だけを時刻の範囲で並べる。スキップ (時刻なし) は records から丸の状態で扱う
        let actuals = context.actualTasks
            .compactMap { actual -> DayActualTask? in
                guard actual.status == .done, let startAt = actual.startAt, let endAt = actual.endAt,
                      let (membership, visibleRange) = computeMembership(
                    startAt: startAt,
                    endAt: endAt,
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
            .sorted { $0.visibleRange.start < $1.visibleRange.start }

        return Day(date: dayStart, scheduled: mergedScheduled, actual: actuals,
                   records: context.actualTasks, workoutSetTimes: context.workoutSetTimes.sorted(),
                   sleepRecords: context.sleepRecords.sorted { $0.startAt < $1.startAt })
    }

    // MARK: - Mode resolution

    private enum Mode {
        case doNothing
        case pattern(UUID)
        case normal
    }

    private static func resolveMode(
        dayStart: Date,
        dayMeta: DayMeta?,
        context: DayBuilderContext
    ) -> Mode {
        if let dayMeta = dayMeta {
            if let appliedPatternId = dayMeta.appliedPatternId {
                return .pattern(appliedPatternId)
            } else {
                return .doNothing
            }
        }

        if context.holidayChecker(dayStart) {
            if let holidayPattern = context.patterns.first(where: { $0.applyDay == .holiday }) {
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
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    // MARK: - Virtual seed composition (membership 計算なし)

    private struct VirtualSeed {
        let task: ScheduledTask
        let origin: TaskOrigin
    }

    private static func composeVirtualSeeds(
        mode: Mode,
        dayStart: Date,
        templates: [TaskTemplate],
        memberships: [PatternTemplateMembership],
        exdates: [TemplateExdate],
        context: DayBuilderContext
    ) -> [VirtualSeed] {
        switch mode {
        case .doNothing:
            return []

        case .pattern(let patternId):
            let templateIds = memberships
                .filter { $0.patternId == patternId }
                .map { $0.templateId }
            return templates.filter { templateIds.contains($0.id) }.compactMap { template in
                makeVirtualSeed(
                    template: template,
                    dayStart: dayStart,
                    exdates: exdates,
                    context: context,
                    origin: .pattern,
                    patternId: patternId
                )
            }

        case .normal:
            return templates.compactMap { template in
                guard let rrule = template.rrule, rruleMatches(rrule, on: dayStart, calendar: context.calendar) else {
                    return nil
                }
                return makeVirtualSeed(
                    template: template,
                    dayStart: dayStart,
                    exdates: exdates,
                    context: context,
                    origin: .rrule,
                    patternId: nil
                )
            }
        }
    }

    private static func makeVirtualSeed(
        template: TaskTemplate,
        dayStart: Date,
        exdates: [TemplateExdate],
        context: DayBuilderContext,
        origin: TaskOrigin,
        patternId: UUID?
    ) -> VirtualSeed? {
        let isExcluded = exdates.contains { exdate in
            exdate.templateId == template.id
                && context.calendar.isDate(exdate.date, inSameDayAs: dayStart)
        }
        if isExcluded { return nil }

        let startAt = dayStart.addingTimeInterval(TimeInterval(template.startMinutesFromMidnight * 60))
        let endAt = startAt.addingTimeInterval(TimeInterval(template.durationMinutes * 60))

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
        return VirtualSeed(task: virtualTask, origin: origin)
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
                origin: origin,
                isVirtual: false
            )
        }
    }

    private static func editedTemplateIds(
        tasks: [ScheduledTask],
        targetDayStart: Date,
        calendar: Calendar
    ) -> Set<UUID> {
        Set(tasks.compactMap { task -> UUID? in
            guard let templateId = task.templateId else { return nil }
            let scheduledDay = calendar.startOfDay(for: task.startAt)
            guard scheduledDay == targetDayStart else { return nil }
            return templateId
        })
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

    // MARK: - rrule (Phase 1 minimal: FREQ=DAILY, FREQ=WEEKLY;BYDAY=...)

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

        switch freq {
        case "DAILY":
            return true
        case "WEEKLY":
            guard !byday.isEmpty else { return true }
            let weekday = calendar.component(.weekday, from: dayStart)
            let token = bydayToken(weekday)
            return byday.contains(token)
        default:
            return false
        }
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
