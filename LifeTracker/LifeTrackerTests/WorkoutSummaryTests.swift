import Testing
import Foundation
@testable import LifeTracker

private let jst: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    cal.locale = Locale(identifier: "ja_JP") // ja_JP は日曜始まり。月曜始まりが calendar に依存しないことを確かめる
    return cal
}()

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

private func jstDate(_ local: String) -> Date { date("\(local)+09:00") }

private func exercise(_ name: String, _ kind: MetricKind = .weightReps, _ muscle: Exercise.MuscleGroup = .chest) -> Exercise {
    Exercise(id: UUID(), name: name, muscleGroup: muscle, equipment: nil, metricKind: kind, note: nil, isArchived: false, sortOrder: nil)
}

private func set(_ exercise: Exercise, _ index: Int = 1, weight: Double? = nil, reps: Int? = nil, sec: Int? = nil,
                 warmup: Bool = false, at: Date) -> WorkoutSet {
    WorkoutSet(id: UUID(), sessionId: UUID(), exerciseId: exercise.id, entryId: UUID(), setIndex: index, weight: weight, reps: reps,
               durationSec: sec, distanceM: nil, rpe: nil, isWarmup: warmup, completedAt: at)
}

@Suite("WorkoutSummary — 日の合計")
@MainActor
struct WorkoutSummaryDayTests {
    let bench = exercise("ベンチプレス")
    let pullUp = exercise("懸垂", .repsOnly, .back)
    let plank = exercise("プランク", .duration, .core)

    @Test("空の日は volume なし・0 件")
    func empty() {
        let t = WorkoutSummary.dayTotals([])
        #expect(t == DayTotals(volume: nil, workingSets: 0, exerciseCount: 0, totalSets: 0, firstAt: nil, lastAt: nil))
    }

    @Test("W だけの日は volume なし・本番 0・種目 1")
    func warmupOnly() {
        let t = WorkoutSummary.dayTotals([set(bench, weight: 40, reps: 10, warmup: true, at: jstDate("2026-09-30T07:00:00"))])
        #expect(t.volume == nil)
        #expect((t.workingSets, t.exerciseCount, t.totalSets) == (0, 1, 1))
    }

    @Test("混在: ボリュームは重量種目のみ、本番セット数は自重・時間も数える。時刻範囲は種目横断の min/max")
    func mixed() {
        let t0 = jstDate("2026-09-30T07:02:00")
        let t = WorkoutSummary.dayTotals([
            set(pullUp, reps: 12, at: t0.addingTimeInterval(600)),
            set(bench, weight: 60, reps: 10, at: t0),
            set(plank, sec: 60, at: t0.addingTimeInterval(2280)),
        ])
        #expect(t.volume == 600)
        #expect((t.workingSets, t.exerciseCount) == (3, 3))
        #expect(t.firstAt == t0)
        #expect(t.lastAt == t0.addingTimeInterval(2280))
        #expect(WorkoutSummary.timeRangeText(t, calendar: jst) == "7:02–7:40 · 38分")
    }

    @Test("時刻範囲: 1 セットは出さない / 同時刻 2 セットは 0分 / 昼に足すと範囲が伸びる")
    func timeRange() {
        let t0 = jstDate("2026-09-30T07:02:00")
        #expect(WorkoutSummary.timeRangeText(WorkoutSummary.dayTotals([set(bench, weight: 60, reps: 10, at: t0)]), calendar: jst) == nil)
        let same = WorkoutSummary.dayTotals([set(bench, 1, weight: 60, reps: 10, at: t0), set(bench, 2, weight: 60, reps: 10, at: t0)])
        #expect(WorkoutSummary.timeRangeText(same, calendar: jst) == "7:02–7:02 · 0分")
        let noon = WorkoutSummary.dayTotals([set(bench, 1, weight: 60, reps: 10, at: t0),
                                             set(bench, 2, weight: 60, reps: 10, at: jstDate("2026-09-30T12:30:00"))])
        #expect(WorkoutSummary.timeRangeText(noon, calendar: jst) == "7:02–12:30 · 328分")
    }

    @Test("日付ラベルと表示用ボリューム")
    func labels() {
        #expect(WorkoutSummary.dayLabel(jstDate("2026-09-30T07:00:00"), calendar: jst) == "9/30(水)")
        #expect(WorkoutLogic.formatVolume(1440) == "1,440")
        #expect(WorkoutLogic.formatVolume(402.5) == "402.5")
        #expect(WorkoutLogic.formatVolume(0) == "0")
        #expect(ProgressMetric.volume.format(1440) == "1,440kg")
    }

    @Test("今日の分は今日の store のセットが勝つ")
    func mergeToday() {
        let today = jstDate("2026-09-30T12:00:00")
        let yesterday = set(bench, weight: 60, reps: 10, at: jstDate("2026-09-29T07:00:00"))
        let staleToday = set(bench, weight: 50, reps: 10, at: jstDate("2026-09-30T07:00:00"))
        let fresh = set(bench, weight: 70, reps: 5, at: jstDate("2026-09-30T07:05:00"))
        let merged = WorkoutSummary.mergeToday(historySets: [yesterday, staleToday], todaySets: [fresh], today: today, calendar: jst)
        #expect(merged.map(\.id) == [yesterday.id, fresh.id])
        #expect(WorkoutSummary.mergeToday(historySets: [yesterday, staleToday], todaySets: [], today: today, calendar: jst).map(\.id) == [yesterday.id])
    }
}

@Suite("WorkoutSummary — 週 (月曜始まり・半開区間)")
@MainActor
struct WorkoutSummaryWeekTests {
    @Test("週頭は月曜。calendar のロケール (日曜始まり) に依存しない")
    func weekStart() {
        let monday = jstDate("2026-09-28T00:00:00")
        #expect(WorkoutSummary.weekStart(containing: jstDate("2026-09-28T07:00:00"), calendar: jst) == monday)
        #expect(WorkoutSummary.weekStart(containing: jstDate("2026-09-30T07:00:00"), calendar: jst) == monday)
        #expect(WorkoutSummary.weekStart(containing: jstDate("2026-10-04T23:59:00"), calendar: jst) == monday)
        #expect(WorkoutSummary.weekStart(containing: date("2026-10-04T15:30:00Z"), calendar: jst) == jstDate("2026-10-05T00:00:00"))
        #expect(WorkoutSummary.weekStart(containing: jstDate("2027-01-01T07:00:00"), calendar: jst) == jstDate("2026-12-28T00:00:00"))
    }

    @Test("weekDays は月〜日の連続 7 日")
    func weekDays() {
        let days = WorkoutSummary.weekDays(containing: jstDate("2026-09-30T07:00:00"), calendar: jst)
        #expect(days.count == 7)
        #expect(days.first == jstDate("2026-09-28T00:00:00"))
        #expect(days.last == jstDate("2026-10-04T00:00:00"))
        #expect(days.map { WorkoutSummary.weekdaySymbol($0, calendar: jst) } == ["月", "火", "水", "木", "金", "土", "日"])
    }

    @Test("区間は半開: 日曜 23:59:59 は今週、翌月曜 0:00:00 は次週")
    func halfOpen() {
        let bench = exercise("ベンチプレス")
        let sets = [set(bench, 1, weight: 100, reps: 1, at: jstDate("2026-10-04T23:59:59")),
                    set(bench, 2, weight: 100, reps: 1, at: jstDate("2026-10-05T00:00:00")),
                    set(bench, 3, weight: 100, reps: 1, at: jstDate("2026-09-27T23:59:59"))]
        let interval = WorkoutSummary.weekInterval(containing: jstDate("2026-09-30T07:00:00"), calendar: jst)
        #expect(interval.end == jstDate("2026-10-05T00:00:00"))
        let totals = WorkoutSummary.weekTotals(sets: sets, exercisesById: [bench.id: bench], week: jstDate("2026-09-30T00:00:00"), calendar: jst)
        #expect(totals.volume == 100)
        #expect(totals.totalWorkingSets == 1)
    }

    @Test("週送り: 同じ曜日へ。未来になるなら今日に丸める")
    func shiftWeek() {
        let today = jstDate("2026-09-30T12:00:00")
        #expect(WorkoutSummary.shiftWeek(selected: jstDate("2026-09-24T00:00:00"), by: 1, today: today, calendar: jst) == jstDate("2026-09-30T00:00:00"))
        #expect(WorkoutSummary.shiftWeek(selected: jstDate("2026-09-30T00:00:00"), by: -1, today: today, calendar: jst) == jstDate("2026-09-23T00:00:00"))
    }

    @Test("未来日は選べない")
    func selectable() {
        let today = jstDate("2026-09-30T12:00:00")
        #expect(WorkoutSummary.isSelectable(day: jstDate("2026-09-30T00:00:00"), today: today, calendar: jst))
        #expect(WorkoutSummary.isSelectable(day: jstDate("2026-09-29T00:00:00"), today: today, calendar: jst))
        #expect(!WorkoutSummary.isSelectable(day: jstDate("2026-10-01T00:00:00"), today: today, calendar: jst))
    }

    @Test("記録がある日は JST の暦日 (UTC 前日 15:30 は JST の当日)")
    func recordedDays() {
        let bench = exercise("ベンチプレス")
        let days = WorkoutSummary.recordedDays([set(bench, at: date("2026-09-29T15:30:00Z"))], calendar: jst)
        #expect(days == [jstDate("2026-09-30T00:00:00")])
    }

    @Test("週の合計: 空週 / 自重だけの日は棒 0・セット数に加算 / 部位別は多い順・同数は表示名順")
    func weekTotals() {
        let bench = exercise("ベンチプレス")
        let pushdown = exercise("プッシュダウン", .weightReps, .triceps)
        let pullUp = exercise("懸垂", .repsOnly, .back)
        let byId = [bench.id: bench, pushdown.id: pushdown, pullUp.id: pullUp]
        let week = jstDate("2026-09-28T00:00:00")
        let empty = WorkoutSummary.weekTotals(sets: [], exercisesById: byId, week: week, calendar: jst)
        #expect(empty.volume == nil && empty.byDayMuscle.isEmpty && empty.workingSetsByMuscle.isEmpty)

        let sets = [set(bench, 1, weight: 60, reps: 10, at: jstDate("2026-09-28T07:00:00")),
                    set(bench, 2, weight: 40, reps: 10, warmup: true, at: jstDate("2026-09-28T07:03:00")),
                    set(pushdown, 1, weight: 20, reps: 10, at: jstDate("2026-09-28T07:10:00")),
                    set(pullUp, 1, reps: 10, at: jstDate("2026-09-29T07:00:00")),
                    set(pullUp, 2, reps: 8, at: jstDate("2026-09-29T07:03:00"))]
        let totals = WorkoutSummary.weekTotals(sets: sets, exercisesById: byId, week: week, calendar: jst)
        #expect(totals.volume == 800)
        #expect(totals.totalWorkingSets == 4)
        #expect(totals.byDayMuscle.contains(.init(day: jstDate("2026-09-29T00:00:00"), muscle: .back, volume: 0)))
        #expect(totals.byDayMuscle.contains(.init(day: week, muscle: .chest, volume: 600)))
        #expect(totals.workingSetsByMuscle == [.init(muscle: .back, count: 2), .init(muscle: .triceps, count: 1), .init(muscle: .chest, count: 1)])
    }

    @Test("前週の同じ曜日まで: 水曜なら前週の月〜水だけを数える (木曜 0:00 ちょうどは含めない)")
    func weekTotalsThrough() {
        let bench = exercise("ベンチプレス")
        let previousWeek = jstDate("2026-09-21T00:00:00")
        let sets = [set(bench, weight: 60, reps: 10, at: jstDate("2026-09-21T07:00:00")), // 月
                    set(bench, weight: 50, reps: 10, at: jstDate("2026-09-23T23:59:00")), // 水
                    set(bench, weight: 40, reps: 10, at: jstDate("2026-09-24T00:00:00")), // 木
                    set(bench, weight: 70, reps: 10, at: jstDate("2026-09-27T07:00:00"))] // 日
        let byId = [bench.id: bench]
        let through = WorkoutSummary.weekTotals(sets: sets, exercisesById: byId, week: previousWeek,
                                                through: jstDate("2026-09-23T12:00:00"), calendar: jst)
        #expect(through.volume == 1100)
        #expect(through.totalWorkingSets == 2)
        let whole = WorkoutSummary.weekTotals(sets: sets, exercisesById: byId, week: previousWeek, calendar: jst)
        #expect(whole.volume == 2200)
        // 週の外 (日曜の次) を渡しても週末で止まる
        let beyond = WorkoutSummary.weekTotals(sets: sets, exercisesById: byId, week: previousWeek,
                                               through: jstDate("2026-09-30T00:00:00"), calendar: jst)
        #expect(beyond.volume == 2200)
    }

    @Test("前週比は四捨五入。前週なし / 0 は nil")
    func volumeChange() {
        #expect(WorkoutSummary.volumeChange(current: 2545, previous: 2270) == 12)
        #expect(WorkoutSummary.volumeChange(current: 90, previous: 100) == -10)
        #expect(WorkoutSummary.volumeChange(current: 100, previous: nil) == nil)
        #expect(WorkoutSummary.volumeChange(current: 100, previous: 0) == nil)
    }
}

@Suite("WorkoutSummary — プログラムの前回表示")
@MainActor
struct WorkoutSummaryLatestDayTests {
    let bench = exercise("ベンチプレス")
    let squat = exercise("スクワット", .weightReps, .quads)
    let today = jstDate("2026-09-30T12:00:00")

    @Test("種目ごとに今日より前の最新の日。今日の分は含めない")
    func latest() {
        let sets = [
            set(bench, 1, weight: 60, reps: 10, sec: 0, at: jstDate("2026-09-25T07:00:00")),
            set(bench, 1, weight: 65, reps: 8, sec: 0, at: jstDate("2026-09-28T07:00:00")),
            set(bench, 2, weight: 65, reps: 6, sec: 0, at: jstDate("2026-09-28T07:03:00")),
            set(bench, 1, weight: 70, reps: 5, sec: 0, at: jstDate("2026-09-30T07:00:00")),
            set(squat, 1, weight: 80, reps: 5, sec: 0, at: jstDate("2026-09-30T07:10:00")),
        ]
        let latest = WorkoutSummary.latestDaySets(sets, today: today, calendar: jst)
        #expect(latest[bench.id]?.map(\.weight) == [65, 65])
        #expect(latest[squat.id] == nil)
    }
}

@Suite("WorkoutSummary — カード見出し")
@MainActor
struct WorkoutSummaryHeadlineTests {
    let bench = exercise("ベンチプレス")
    let t0 = jstDate("2026-09-30T07:00:00")

    @Test("重量: 今日あり・前回あり / 今日なし・前回あり / 両方なし / 今日 W だけは今日なし扱い")
    func weightReps() {
        let today = [set(bench, 1, weight: 60, reps: 10, at: t0), set(bench, 2, weight: 65, reps: 8, at: t0)]
        let previous = [set(bench, 1, weight: 60, reps: 8, at: t0)]
        #expect(WorkoutSummary.cardHeadline(kind: .weightReps, todaySets: today, previousSets: previous) == "今日 1,120kg · e1RM 82.3kg（前回 76kg）")
        #expect(WorkoutSummary.cardHeadline(kind: .weightReps, todaySets: [], previousSets: previous) == "前回 e1RM 76kg")
        #expect(WorkoutSummary.cardHeadline(kind: .weightReps, todaySets: [], previousSets: []) == nil)
        let warmup = [set(bench, 1, weight: 40, reps: 10, warmup: true, at: t0)]
        #expect(WorkoutSummary.cardHeadline(kind: .weightReps, todaySets: warmup, previousSets: previous) == "前回 e1RM 76kg")
        #expect(WorkoutSummary.cardHeadline(kind: .weightReps, todaySets: today, previousSets: []) == "今日 1,120kg · e1RM 82.3kg")
    }

    @Test("回数のみ・時間: 推移の初期指標で出す")
    func otherKinds() {
        let pullUp = exercise("懸垂", .repsOnly, .back)
        let plank = exercise("プランク", .duration, .core)
        #expect(WorkoutSummary.cardHeadline(kind: .repsOnly, todaySets: [], previousSets: [set(pullUp, reps: 12, at: t0)]) == "前回 最多 12回")
        #expect(WorkoutSummary.cardHeadline(kind: .repsOnly, todaySets: [set(pullUp, reps: 10, at: t0)], previousSets: [set(pullUp, reps: 12, at: t0)]) == "今日 最多 10回（前回 12回）")
        #expect(WorkoutSummary.cardHeadline(kind: .duration, todaySets: [set(plank, sec: 90, at: t0)], previousSets: []) == "今日 最長 1:30")
        #expect(WorkoutSummary.setsSummary(kind: .weightReps, sets: [set(bench, weight: 60, reps: 10, at: t0)]) == "600kg · e1RM 80kg")
    }
}
