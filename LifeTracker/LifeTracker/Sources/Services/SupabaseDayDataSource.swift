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

        // 実績は「一覧に出る日」で取る (段階 2。時刻の重なりではスキップ行が取れない。レビュー §3-1)
        async let actualResp: [ActualTask] = client.from("actual_task")
            .select()
            .in("occurrence_date", values: [previousDayString, dayString])
            .execute()
            .value

        // その日に完了したセット (ジムの回の表示時判定。決定 C4)。集計は端末でする (レビュー §4-1)
        async let setsResp: [WorkoutSetTime] = client.from("workout_set")
            .select("completed_at")
            .gte("completed_at", value: startStr)
            .lt("completed_at", value: endStr)
            .execute()
            .value

        // 睡眠の記録 (sleep_record)。睡眠の行との結びは表示時に時刻の重なりで決める (SleepRules.assign)。
        // 範囲は [D−1 0:00, D+2 0:00) に重なるもの (前日から続く行・今夜の行の本来の範囲を覆う)
        let sleepRange = SleepRules.fetchRange(for: dayStart, calendar: calendar)
        async let sleepResp: [SleepRecord] = fetchSleepRecords(from: sleepRange.from, to: sleepRange.to)

        let (versions, versionMemberships, patterns, exdatesAll, dayMetaList, scheduled, actual, sets, sleep) = try await (
            versionsResp,
            versionMembershipsResp,
            patternsResp,
            exdatesResp,
            dayMetaResp,
            scheduledResp,
            actualResp,
            setsResp,
            sleepResp
        )

        // 回数のタップ (0012。時刻つきで目標 2 以上の回の「1/3」) は別の問い合わせ。失敗 (0012 の無い DB など) は空として扱い、
        // 睡眠タブ・今日のカードを落とさない (R2)
        let taps = await fetchTaps(actualIds: actual.map(\.id))

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
            taps: taps,
            workoutSetTimes: sets.compactMap(\.completedAt),
            sleepRecords: sleep,
            holidayChecker: holidayChecker,
            calendar: calendar
        )
    }
}

enum SupabaseDayDataSourceError: Error {
    case invalidDate(Date)
}

private struct WorkoutSetTime: Decodable {
    let completedAt: Date?
}

extension SupabaseDayDataSource {
    /// 実績のタップ (actual_task_tap)。読めなければ空 (R2)
    func fetchTaps(actualIds: [UUID]) async -> [ActualTaskTap] {
        guard !actualIds.isEmpty else { return [] }
        do {
            return try await client.from("actual_task_tap")
                .select()
                .in("actual_task_id", values: actualIds.map(\.uuidString))
                .execute()
                .value
        } catch {
            return []
        }
    }
}

/// 「やること」の読み取り (0012 todo_fetch。範囲は Swift が決めて渡す: p_from = V−7、p_count_from = V−366)
extension SupabaseDayDataSource: TodoDataSource {
    func loadTodos(date: Date) async throws -> TodoFetch {
        let call = ScheduleRPC.todoFetch(date: date, calendar: calendar)
        return try await client.rpc(call.function, params: call.params).execute().value
    }
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

    /// 1 操作 = 1 RPC (1 トランザクション。D ≥ 今日の検査も関数の中。migration 0006)。規則のエラーはメモリ上の実装と同じ型にする (R10)
    func apply(_ operation: ScheduleOperation) async throws {
        let call = ScheduleRPC.call(for: operation, calendar: calendar)
        do {
            try await client.rpc(call.function, params: call.params).execute()
        } catch let error as PostgrestError {
            throw RuleErrorMapping.schedule(error) ?? error
        }
    }

    /// 実績の書き込み (1 操作 = 1 RPC。migration 0007・0012)
    func applyCheckIn(_ operation: CheckInOperation) async throws {
        let call = ScheduleRPC.call(for: operation, calendar: calendar)
        do {
            try await client.rpc(call.function, params: call.params).execute()
        } catch let error as PostgrestError {
            throw RuleErrorMapping.checkIn(error, operation: operation, now: Date(), calendar: calendar) ?? error
        }
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

/// 睡眠の記録 (sleep_record。migration 0009)。表へ直接 insert / update / delete。
/// 重なりは DB の EXCLUDE (23P01)、時刻・24 時間・kind は CHECK (23514) が止める (文言は SleepRules.message)
extension SupabaseDayDataSource: SleepDataSource {
    func fetchSleepRecords(from: Date, to: Date) async throws -> [SleepRecord] {
        try await client.from("sleep_record")
            .select()
            .lt("start_at", value: supabaseTimestampFormatter.string(from: to))
            .gt("end_at", value: supabaseTimestampFormatter.string(from: from))
            .order("start_at")
            .execute()
            .value
    }

    func insertSleepRecord(start: Date, end: Date, kind: SleepKind) async throws -> SleepRecord {
        try await client.from("sleep_record")
            .insert(SleepRecordWrite(startAt: start, endAt: end, kind: kind))
            .select()
            .single()
            .execute()
            .value
    }

    func updateSleepRecord(id: UUID, start: Date, end: Date, kind: SleepKind) async throws {
        try await client.from("sleep_record")
            .update(SleepRecordWrite(startAt: start, endAt: end, kind: kind))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func deleteSleepRecord(id: UUID) async throws {
        try await client.from("sleep_record")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }
}

/// sleep_record の書き込む列 (id・created_at は DB の既定)
private struct SleepRecordWrite: Encodable {
    let startAt: Date
    let endAt: Date
    let kind: SleepKind
}

/// 操作 → RPC の関数名と引数 (pure。引数名は migration 0006・0007・0012 の関数と同じ)
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

    /// 実績の操作 → RPC (引数名は migration 0007 の関数と同じ。時刻は timestamptz で送る＝回の日をまたぐため。レビュー §3-3)
    static func call(for operation: CheckInOperation, calendar: Calendar) -> Call {
        func date(_ date: Date) -> Value { .string(DateOnly.formatter.string(from: calendar.startOfDay(for: date))) }
        func uuid(_ id: UUID?) -> Value { id.map { .string($0.uuidString) } ?? .null }
        func time(_ date: Date?) -> Value { date.map { .string(supabaseTimestampFormatter.string(from: $0)) } ?? .null }
        func key(_ key: CheckInKey) -> [String: Value] {
            switch key {
            case .occurrence(let t, let d):
                return ["p_template_id": uuid(t), "p_occurrence_date": date(d), "p_scheduled_task_id": .null]
            case .single(let id):
                return ["p_template_id": .null, "p_occurrence_date": .null, "p_scheduled_task_id": uuid(id)]
            }
        }
        func make(_ function: String, _ parts: [String: Value]...) -> Call {
            Call(function: function, params: Params(values: parts.reduce(into: [:]) { $0.merge($1) { _, new in new } }))
        }

        switch operation {
        case .set(let k, let status, let name, let categoryId, let start, let end):
            return make("checkin_set", key(k), [
                "p_status": .string(status.rawValue), "p_name": .string(name), "p_category_id": uuid(categoryId),
                "p_start": time(start), "p_end": time(end),
            ])
        case .clear(let k):
            return make("checkin_clear", key(k))
        case .saveActual(let id, let name, let categoryId, let start, let end):
            return make("actual_save", ["p_id": uuid(id), "p_name": .string(name), "p_category_id": uuid(categoryId),
                                        "p_start": time(start), "p_end": time(end)])
        case .deleteActual(let id):
            return make("actual_delete", ["p_id": uuid(id)])
        case .tap(let k, let name, let categoryId, let at, let start, let end, let tapId):
            return make("record_tap_add", key(k), [
                "p_name": .string(name), "p_category_id": uuid(categoryId), "p_tapped_at": time(at),
                "p_start": time(start), "p_end": time(end), "p_tap_id": uuid(tapId),
            ])
        case .untap(let k, let asOf):
            return make("record_tap_remove", key(k), ["p_as_of": date(asOf)])
        case .skipCounted(let k, let name, let categoryId, let on):
            return make("record_skip_set", key(k), ["p_name": .string(name), "p_category_id": uuid(categoryId), "p_on": date(on)])
        case .unskipCounted(let k):
            return make("record_skip_clear", key(k))
        }
    }

    /// todo_fetch の引数 (p_date = V、p_from = V−7、p_count_from = V−366)
    static func todoFetch(date: Date, calendar: Calendar) -> Call {
        func day(_ date: Date) -> Value { .string(DateOnly.formatter.string(from: calendar.startOfDay(for: date))) }
        let range = TodoBuilder.fetchRange(for: date, calendar: calendar)
        return Call(function: "todo_fetch", params: Params(values: [
            "p_date": day(date), "p_from": day(range.from), "p_count_from": day(range.countFrom),
        ]))
    }

    static func call(for operation: ScheduleOperation, calendar: Calendar) -> Call {
        func date(_ date: Date) -> Value { .string(DateOnly.formatter.string(from: calendar.startOfDay(for: date))) }
        func uuid(_ id: UUID?) -> Value { id.map { .string($0.uuidString) } ?? .null }
        /// 時刻なしは p_start・p_duration を null で送る。p_target = 目標の回数 (0012)
        func content(_ c: ScheduleContent) -> [String: Value] {
            ["p_name": .string(c.name), "p_category_id": uuid(c.categoryId),
             "p_start": c.startMinutes.map { .int($0) } ?? .null, "p_duration": c.durationMinutes.map { .int($0) } ?? .null,
             "p_target": .int(c.targetCount)]
        }
        /// p_carry_over は時刻なしの繰り返しのときだけ true になり得る (carry_chk)
        func repeatRule(_ r: ScheduleRepeatRule, _ c: ScheduleContent) -> [String: Value] {
            ["p_rrule": r.rrule.map { .string($0) } ?? .null, "p_show_on_holiday": .bool(r.showsOnHoliday),
             "p_carry_over": .bool(!c.timing.isTimed && r.carriesOver)]
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
            return make("schedule_template_create", ["p_date": date(d), "p_replace_single_id": uuid(replacing)], content(c), repeatRule(r, c))
        case .saveFollowing(let t, let d, let c, let r):
            return make("schedule_template_save_following", ["p_template_id": uuid(t), "p_date": date(d)], content(c), repeatRule(r, c))
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

/// RPC の RAISE (PostgrestError の message・code) → メモリ上の実装と同じ規則のエラー (pure。R10)。
/// 文言は migration 0006・0007・0012 の RAISE EXCEPTION と CHECK / FK 制約。対応の無いものは nil (元のエラーのまま)
enum RuleErrorMapping {
    static func schedule(_ error: PostgrestError) -> ScheduleRuleError? {
        let message = error.message
        if message.hasPrefix("past day is not editable") || message.hasPrefix("timed single needs today or later") { return .pastDay }
        if message.hasPrefix("single task not found") || message.hasPrefix("occurrence not found") { return .notFound }
        if message.hasPrefix("closed single cannot change its date") { return .closedSingleDate }
        if message.hasPrefix("series needs weekdays or holiday") { return .noRepeat }
        if message.hasPrefix("occurrence cannot change timed/untimed") { return .timingMismatch }
        // 目標の回数の CHECK (task_template_version_target_chk・scheduled_task_target_chk)
        if error.code == "23514", message.contains("target_chk") { return .invalidTarget }
        // 系列を消すときの FK RESTRICT (過去の実体が系列を指している)
        if error.code == "23503" { return .referencedByPast }
        return nil
    }

    static func checkIn(_ error: PostgrestError, operation: CheckInOperation, now: Date, calendar: Calendar) -> CheckInRuleError? {
        let message = error.message
        if message.hasPrefix("future occurrence cannot be") || message.hasPrefix("future day cannot be recorded") { return .futureDay }
        if message.hasPrefix("sleep is recorded in sleep_record") { return .sleepIsSeparate }
        if message.hasPrefix("done needs start and end") || message.hasPrefix("timed occurrence needs planned start and end") {
            return .invalidTime
        }
        if message.hasPrefix("skipped occurrence cannot be") { return .skippedOccurrence }
        if message.hasPrefix("timed occurrence with target 1") { return .notCounted }
        if message.hasPrefix("single task not found") || message.hasPrefix("occurrence not found")
            || message.hasPrefix("actual not found") { return .notFound }
        // 「回の日以上・今日以下」は 1 つの文言なので、送った日で未来か回の日より前かを分ける
        if message.hasPrefix("tap must be between") || message.hasPrefix("skip day must be between") {
            let sent: Date? = {
                switch operation {
                case .tap(_, _, _, let at, _, _, _): return at
                case .skipCounted(_, _, _, let on): return on
                default: return nil
                }
            }()
            if let sent, calendar.startOfDay(for: sent) > calendar.startOfDay(for: now) { return .futureDay }
            return .beforeOccurrence
        }
        return nil
    }
}
