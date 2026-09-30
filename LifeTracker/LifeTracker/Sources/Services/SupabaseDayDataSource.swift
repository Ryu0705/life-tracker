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
        let previousStartStr = supabaseTimestampFormatter.string(from: previousDayStart)

        // 世代・祝日の登録・パターンは日に依らないので全件 (数十行)。日ごとの解決は端末でする (TemplateVersions)
        async let versionsResp: [TaskTemplateVersion] = client.from("task_template_version")
            .select()
            .execute()
            .value

        async let versionMembershipsResp: [PatternVersionMembership] = client.from("pattern_version_membership")
            .select()
            .execute()
            .value

        async let patternsResp: [Pattern] = client.from("pattern")
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

        // 前日 0 時から翌日 0 時までに重なる実体。前日のその日だけ変えた回が当日に重ならなくても、
        // 前日の仮想の流入を抑制できるようにする (レビュー DB §3-1 の既存バグ)
        async let scheduledResp: [ScheduledTask] = client.from("scheduled_task")
            .select()
            .lt("start_at", value: endStr)
            .gt("end_at", value: previousStartStr)
            .execute()
            .value

        async let actualResp: [ActualTask] = client.from("actual_task")
            .select()
            .lt("start_at", value: endStr)
            .gt("end_at", value: startStr)
            .execute()
            .value

        let (versions, versionMemberships, patterns, exdatesAll, dayMetaList, scheduled, actual) = try await (
            versionsResp,
            versionMembershipsResp,
            patternsResp,
            exdatesResp,
            dayMetaResp,
            scheduledResp,
            actualResp
        )

        let cal = calendar
        return TemplateVersions.context(
            date: dayStart,
            versions: versions,
            versionMemberships: versionMemberships,
            patterns: patterns,
            exdates: exdatesAll.filter { cal.isDate($0.date, inSameDayAs: dayStart) },
            previousExdates: exdatesAll.filter { cal.isDate($0.date, inSameDayAs: previousDayStart) },
            dayMeta: dayMetaList.first { cal.isDate($0.date, inSameDayAs: dayStart) },
            previousDayMeta: dayMetaList.first { cal.isDate($0.date, inSameDayAs: previousDayStart) },
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

extension SupabaseDayDataSource: ScheduleDataSource {
    func fetchCatalog() async throws -> ScheduleCatalog {
        async let categories: [Category] = client.from("category").select().execute().value
        async let patterns: [Pattern] = client.from("pattern").select().execute().value
        async let versions: [TaskTemplateVersion] = client.from("task_template_version").select().execute().value
        async let memberships: [PatternVersionMembership] = client.from("pattern_version_membership").select().execute().value
        return try await ScheduleCatalog(categories: categories, patterns: patterns, versions: versions,
                                         versionMemberships: memberships)
    }

    /// 1 操作 = 1 RPC (1 トランザクション。D ≥ 今日の検査も関数の中。migration 0006)
    func apply(_ operation: ScheduleOperation) async throws {
        let call = ScheduleRPC.call(for: operation, calendar: calendar)
        try await client.rpc(call.function, params: call.params).execute()
    }

    func createCategory(name: String) async throws -> Category {
        try await client.from("category")
            .insert(NewCategory(name: name))
            .select()
            .single()
            .execute()
            .value
    }
}

private struct NewCategory: Encodable {
    let name: String
}

/// 操作 → RPC の関数名と引数 (pure。引数名は migration 0006 の関数と同じ)
enum ScheduleRPC {
    enum Value: Encodable, Equatable {
        case string(String)
        case int(Int)
        case bool(Bool)
        case null

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    /// nil も null として送る (省くと PostgREST が引数の合う関数を見つけられない)
    struct Params: Encodable, Equatable {
        let values: [String: Value]

        private struct Key: CodingKey {
            let stringValue: String
            init(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for (key, value) in values {
                try container.encode(value, forKey: Key(stringValue: key))
            }
        }
    }

    struct Call: Equatable {
        let function: String
        let params: Params
    }

    static func call(for operation: ScheduleOperation, calendar: Calendar) -> Call {
        func date(_ date: Date) -> Value { .string(DateOnly.formatter.string(from: calendar.startOfDay(for: date))) }
        func uuid(_ id: UUID?) -> Value { id.map { .string($0.uuidString) } ?? .null }
        func content(_ c: ScheduleContent) -> [String: Value] {
            ["p_name": .string(c.name), "p_category_id": uuid(c.categoryId),
             "p_start": .int(c.startMinutes), "p_duration": .int(c.durationMinutes)]
        }
        func repeatRule(_ r: ScheduleRepeatRule) -> [String: Value] {
            ["p_rrule": r.rrule.map { .string($0) } ?? .null, "p_show_on_holiday": .bool(r.showsOnHoliday)]
        }
        func make(_ function: String, _ parts: [String: Value]...) -> Call {
            Call(function: function, params: Params(values: parts.reduce(into: [:]) { $0.merge($1) { _, new in new } }))
        }

        switch operation {
        case .createSingle(let d, let c):
            return make("schedule_single_save", ["p_id": .null, "p_date": date(d)], content(c))
        case .updateSingle(let id, let d, let c):
            return make("schedule_single_save", ["p_id": uuid(id), "p_date": date(d)], content(c))
        case .deleteSingle(let id):
            return make("schedule_single_delete", ["p_id": uuid(id)])
        case .createSeries(let d, let c, let r, let replacing):
            return make("schedule_template_create", ["p_date": date(d), "p_replace_single_id": uuid(replacing)], content(c), repeatRule(r))
        case .saveFollowing(let t, let d, let c, let r):
            return make("schedule_template_save_following", ["p_template_id": uuid(t), "p_date": date(d)], content(c), repeatRule(r))
        case .deleteFollowing(let t, let d):
            return make("schedule_template_delete_following", ["p_template_id": uuid(t), "p_date": date(d)])
        case .endSeriesToSingle(let t, let d, let c):
            return make("schedule_template_end_to_single", ["p_template_id": uuid(t), "p_date": date(d)], content(c))
        case .saveOccurrence(let t, let d, let p, let c):
            return make("schedule_occurrence_save", ["p_template_id": uuid(t), "p_date": date(d), "p_pattern_id": uuid(p)], content(c))
        case .deleteOccurrence(let t, let d):
            return make("schedule_occurrence_delete", ["p_template_id": uuid(t), "p_date": date(d)])
        }
    }
}
