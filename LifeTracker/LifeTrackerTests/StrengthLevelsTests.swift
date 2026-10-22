import Testing
import Foundation
@testable import LifeTracker

private let jst: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return cal
}()

private func at(_ local: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: "\(local)+09:00")!
}

private func day(_ ymd: String) -> Date { at("\(ymd)T00:00:00") }

private func exercise(_ name: String, _ muscle: Exercise.MuscleGroup = .chest, _ kind: MetricKind = .weightReps,
                      equipment: Exercise.Equipment? = nil) -> Exercise {
    Exercise(id: UUID(), name: name, muscleGroup: muscle, equipment: equipment, metricKind: kind, note: nil, isArchived: false, sortOrder: nil)
}

/// 日 (トレーニングの日) を指定しなければ date の JST の日
private func set(_ exercise: Exercise, weight: Double? = nil, reps: Int? = nil, sec: Int? = nil, distance: Double? = nil,
                 warmup: Bool = false, at date: Date, day trainingDay: Date? = nil) -> WorkoutSet {
    WorkoutSet(id: UUID(), sessionId: UUID(), exerciseId: exercise.id, entryId: UUID(), setIndex: 1,
               weight: weight, reps: reps, durationSec: sec, distanceM: distance, rpe: nil, isWarmup: warmup, completedAt: date,
               day: trainingDay ?? trainingDayJST(date))
}

private func weight(_ kg: Double, on ymd: String) -> BodyWeightRecord {
    BodyWeightRecord(recordedOn: day(ymd), weightKg: kg)
}

private func approx(_ a: [Double], _ b: [Double], tolerance: Double = 0.01) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < tolerance }
}

/// 同梱の表 (テストはアプリをホストに動くので Bundle.main = アプリ)
private let standards = StrengthStandards.bundled

private func thresholds(_ name: String, kind: MetricKind = .weightReps, sex: Sex = .male, bw: Double, added: Bool = false) -> [Double]? {
    guard case .standard(let mapping, let standard) = standards.resolve(exercise(name, .chest, kind)) else { return nil }
    return standards.thresholds(mapping, standard: standard, sex: sex, bodyWeight: bw, added: added)
}

private func level(_ name: String, _ s: WorkoutSet, kind: MetricKind = .weightReps, sex: Sex = .male, bw: Double) -> Double? {
    guard case .standard(let mapping, let standard) = standards.resolve(exercise(name, .chest, kind)) else { return nil }
    return StrengthLevels.setLevel(s, kind: kind, mapping: mapping, standard: standard, standards: standards, sex: sex, bodyWeight: bw)
}

@Suite("StrengthLevels — 部位ごとの強さの級 (docs/body-strength-and-heatmap-period.md)")
struct StrengthLevelsTests {
    // MARK: T-1 読み込み・対応表の整合

    @Test("同梱の 122 表がすべて検証を通り、対応表 159 種目のうち対象外以外はすべて表に当たる")
    func bundledTablesAndMapping() throws {
        #expect(standards.standards.count == 122)
        #expect(standards.mappings.count == 159)
        let url = try #require(Bundle.main.url(forResource: "strength_mapping", withExtension: "json"))
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try #require(raw["exercises"] as? [[String: Any]])
        var resolved = 0, excluded = 0
        for row in rows {
            let name = row["name"] as! String
            let kind = MetricKind(rawValue: row["metric_kind"] as! String)!
            switch standards.resolve(exercise(name, .chest, kind)) {
            case .standard: resolved += 1
            case .excluded: excluded += 1
            case .none: Issue.record("基準なし: \(name)")
            }
        }
        #expect(resolved == 142 && excluded == 17)
    }

    @Test("換算・近似を掛けた後も、全種目・男女・体重 40〜145kg で閾値が非減少")
    func derivedThresholdsNonDecreasing() {
        for mapping in standards.mappings.values where mapping.match != .excluded {
            guard case .standard(let m, let standard) = standards.resolve(exercise(mapping.name, .chest, kindFor(mapping))) else { continue }
            for sex in Sex.allCases {
                for bw in stride(from: 40.0, through: 145, by: 2.5) {
                    for added in [false, true] where !added || standard.addedRows != nil {
                        let t = standards.thresholds(m, standard: standard, sex: sex, bodyWeight: bw, added: added) ?? []
                        #expect(t.count == 5 && zip(t, t.dropFirst()).allSatisfy { $0 <= $1 }, "\(mapping.name) \(sex) \(bw)")
                    }
                }
            }
        }
    }

    private func kindFor(_ mapping: StrengthStandards.Mapping) -> MetricKind {
        guard let slug = mapping.slug, let unit = standards.standards[slug]?.unit else { return .weightReps }
        if mapping.transform != nil { return .weightReps }
        switch unit {
        case .kg: return .weightReps
        case .reps: return .repsOnly
        case .seconds: return .duration
        }
    }

    @Test("記録の単位と表の単位が合わない対応は基準なし (A-1)。対応が無い名前も基準なし")
    func unitMismatchIsNoStandard() {
        if case .none = standards.resolve(exercise("ベンチプレス", .chest, .repsOnly)) {} else { Issue.record("reps のベンチが表に当たった") }
        if case .none = standards.resolve(exercise("プランク", .core, .weightReps)) {} else { Issue.record("kg のプランクが表に当たった") }
        if case .none = standards.resolve(exercise("自作の種目")) {} else { Issue.record("名前の無い種目が表に当たった") }
        if case .excluded = standards.resolve(exercise("ハンドグリップ", .forearms, .repsOnly)) {} else { Issue.record("対象外が外れていない") }
    }

    @Test("崩れた表 (刻みが 5kg でない・値が 5 個でない・行内で減る) は読み込みで落とす")
    func brokenTablesDropped() throws {
        func table(_ male: String) -> Data {
            let female = #"{"bodyweight": [{"bw": 40, "values": [1, 2, 3, 4, 5]}]}"#
            return Data(#"{"exercises": {"x": {"unit": "kg", "male": \#(male), "female": \#(female)}}}"#.utf8)
        }
        let ok = try StrengthStandards.decodeStandards(table(#"{"bodyweight": [{"bw": 50, "values": ["< 1", 2, 3, 4, 5]}, {"bw": 55, "values": [1, 2, 3, 4, 6]}]}"#))
        #expect(ok["x"]?.rows[.male]?.first?.values == [1, 2, 3, 4, 5])
        #expect(try StrengthStandards.decodeStandards(table(#"{"bodyweight": [{"bw": 50, "values": [1, 2, 3, 4, 5]}, {"bw": 60, "values": [1, 2, 3, 4, 5]}]}"#)).isEmpty)
        #expect(try StrengthStandards.decodeStandards(table(#"{"bodyweight": [{"bw": 50, "values": [1, 2, 3, 4]}]}"#)).isEmpty)
        #expect(try StrengthStandards.decodeStandards(table(#"{"bodyweight": [{"bw": 50, "values": [1, 3, 2, 4, 5]}]}"#)).isEmpty)
        #expect(try StrengthStandards.decodeStandards(table(#"{"bodyweight": [{"bw": 50, "values": ["?", 2, 3, 4, 5]}]}"#)).isEmpty)
    }

    // MARK: T-2 閾値の補間

    @Test("体重行の間は線形補間、範囲外は端の行 (外挿しない)、女性は 40〜120kg、「< 1」は 1")
    func thresholdInterpolation() throws {
        #expect(approx(try #require(thresholds("ベンチプレス", bw: 72.5)), [49, 67, 88.5, 113.5, 140]))
        #expect(thresholds("ベンチプレス", bw: 48) == [27, 41, 58, 78, 101])
        #expect(thresholds("ベンチプレス", bw: 145) == [104, 129, 158, 191, 225])
        #expect(thresholds("ベンチプレス", sex: .female, bw: 35) == [10, 19, 33, 49, 68])
        #expect(thresholds("チンニング（順手懸垂）", sex: .female, bw: 60) == [1, 1, 6, 12, 20])
        #expect(thresholds("チンニング（順手懸垂）", sex: .female, bw: 60, added: true) == [-16, -4, 9, 23, 38])
    }

    @Test("近似の係数: インクラインチェストプレス = chest-press × incline/flat の比。静止系 = plank × Endura の比")
    func multipliers() throws {
        let incline = try #require(thresholds("インクラインチェストプレス（マシン）", bw: 70))
        #expect(approx(incline, [33 * 41 / 47.0, 53 * 56 / 64.0, 80 * 75 / 85.0, 112 * 96 / 110.0, 147 * 119 / 136.0]))
        let hang = try #require(thresholds("デッドハング", kind: .duration, bw: 70))
        #expect(approx(hang, [6, 20.5, 40.5, 84.04, 105], tolerance: 0.1))
    }

    // MARK: T-3 0〜5 の値

    @Test("Beginner 未満は比例・閾値ちょうど・中間は線形・Elite 超は 5・同値の隣接閾値は上の段")
    func score() {
        let t: [Double] = [47, 64, 85, 110, 136]
        #expect(StrengthLevels.score(23.5, thresholds: t) == 0.5)
        #expect(StrengthLevels.score(64, thresholds: t) == 2)
        #expect(StrengthLevels.score(74.5, thresholds: t) == 2.5)
        #expect(StrengthLevels.score(136, thresholds: t) == 5)
        #expect(StrengthLevels.score(300, thresholds: t) == 5)
        #expect(StrengthLevels.score(0, thresholds: t) == 0)
        let same: [Double] = [1, 1, 6, 12, 20]
        #expect(StrengthLevels.score(1, thresholds: same) == 2)
        #expect(StrengthLevels.score(3.5, thresholds: same) == 2.5)
        #expect(StrengthLevels.score(0.5, thresholds: same) == 0.5)
    }

    @Test("加重の表の Beginner 未満は総負荷 (体重＋値) の比")
    func belowBeginnerTotalLoad() {
        let v = StrengthLevels.score(-16.67, thresholds: [-2, 13, 31, 50, 71], totalLoadBodyWeight: 70)
        #expect(abs(v - 53.33 / 68) < 0.001)
    }

    @Test("ランク: 段は切り捨て、細分は小数部の 4 等分、Master は細分なし")
    func rankName() {
        #expect(StrengthLevels.rankName(0) == "Bronze IV")
        #expect(StrengthLevels.rankName(0.9) == "Bronze I")
        #expect(StrengthLevels.rankName(1) == "Silver IV")
        #expect(StrengthLevels.rankName(2.8) == "Gold I")
        #expect(StrengthLevels.rankName(3.24) == "Platinum IV")
        #expect(StrengthLevels.rankName(3.25) == "Platinum III")
        #expect(StrengthLevels.rankName(3.5) == "Platinum II")
        #expect(StrengthLevels.rankName(4.75) == "Diamond I")
        #expect(StrengthLevels.rankName(4.999) == "Diamond I")
        #expect(StrengthLevels.rankName(5) == "Master")
    }

    @Test("名前は切り捨て、1 未満は Beginner 未満")
    func levelName() {
        #expect(StrengthLevels.levelName(0.9) == "Beginner 未満")
        #expect(StrengthLevels.levelName(1) == "Beginner")
        #expect(StrengthLevels.levelName(2.99) == "Novice")
        #expect(StrengthLevels.levelName(5) == "Elite")
    }

    // MARK: T-4 セットの値

    @Test("weight_reps は Epley の推定 1RM、回数・秒はそのまま")
    func plainSets() throws {
        let bench = exercise("ベンチプレス")
        // 60×10 → 80kg → 男性 70kg [47, 64, 85, 110, 136] で 2 + 16/21
        #expect(abs(try #require(level("ベンチプレス", set(bench, weight: 60, reps: 10, at: Date()), bw: 70)) - (2 + 16.0 / 21)) < 1e-9)
        let plank = exercise("プランク", .core, .duration)
        #expect(level("プランク", set(plank, sec: 81, at: Date()), kind: .duration, bw: 70) == 3)
        #expect(level("プランク", set(plank, reps: 10, at: Date()), kind: .duration, bw: 70) == nil)
    }

    @Test("自重の weight_reps: 加重 0 / nil → 回数の表、加重あり → (体重＋加重)×Epley − 体重 を加重の表")
    func bodyweightAdded() throws {
        let pullUp = exercise("チンニング（順手懸垂）", .back)
        let name = "チンニング（順手懸垂）"
        #expect(level(name, set(pullUp, weight: 0, reps: 14, at: Date()), bw: 70) == 3)
        #expect(level(name, set(pullUp, reps: 7, at: Date()), bw: 70) == 2)
        // 10kg × 5 → 80 × 1.1667 − 70 = 23.33 → [-2, 13, 31, 50, 71]
        let weighted = try #require(level(name, set(pullUp, weight: 10, reps: 5, at: Date()), bw: 70))
        let value: Double = 80 * (1 + 5.0 / 30) - 70
        #expect(abs(weighted - (2 + (value - 13) / 18)) < 1e-9)
    }

    @Test("アシストチンニング: アシスト 0 → 回数の表、アシストあり → (体重 − アシスト)×Epley − 体重")
    func assist() throws {
        let name = "アシストチンニング（マシン）"
        let ex = exercise(name, .back)
        #expect(level(name, set(ex, weight: 0, reps: 14, at: Date()), bw: 70) == 3)
        let v = try #require(level(name, set(ex, weight: 30, reps: 10, at: Date()), bw: 70))
        let total: Double = 40 * (1 + 10.0 / 30)
        #expect(abs(v - total / 68) < 1e-9)
    }

    @Test("ロシアンツイスト: 加重 0 は回数、加重ありは相当回数 (70kg・5kg×20 → 約 31.9 回)")
    func russianTwist() throws {
        let name = "ロシアンツイスト"
        let ex = exercise(name, .core)
        #expect(level(name, set(ex, weight: 0, reps: 18, at: Date()), bw: 70) == 2)
        let load: Double = 26 * (1 + 20.0 / 30) / 21
        let equivalent: Double = (load - 1) * 30
        let expected: Double = 2 + (equivalent - 18) / 25
        let v = try #require(level(name, set(ex, weight: 5, reps: 20, at: Date()), bw: 70))
        #expect(abs(v - expected) < 1e-9)
    }

    // MARK: T-5 体重の参照

    @Test("その日以前で最新の体重。以前が無ければ最新の記録。0 件は nil")
    func bodyWeightLookup() {
        let records = [weight(72, on: "2026-10-05"), weight(70, on: "2026-10-01")]
        #expect(StrengthLevels.bodyWeight(on: day("2026-10-05"), records: records) == 72)
        #expect(StrengthLevels.bodyWeight(on: day("2026-10-04"), records: records) == 70)
        #expect(StrengthLevels.bodyWeight(on: day("2026-09-01"), records: records) == 72)
        #expect(StrengthLevels.bodyWeight(on: day("2026-10-05"), records: []) == nil)
    }

    // MARK: T-6 部位の集計

    private let period = (start: day("2026-09-11"), end: day("2026-10-11"))

    private func summarize(_ sets: [WorkoutSet], _ exercises: [Exercise], weights: [BodyWeightRecord] = [weight(70, on: "2026-09-01")]) -> [Exercise.MuscleGroup: MuscleStrength] {
        let result = StrengthLevels.summarize(sets: sets, exercisesById: Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) }),
                                              standards: standards, sex: .male, bodyWeights: weights, interval: period, calendar: jst)
        return Dictionary(uniqueKeysWithValues: result.map { ($0.muscle, $0) })
    }

    @Test("種目 = セットの最大、部位 = 種目の平均 (max → mean)。W と期間外は除く")
    func maxThenMean() throws {
        let bench = exercise("ベンチプレス")
        let pushUp = exercise("プッシュアップ", .chest, .repsOnly)
        let sets = [
            set(bench, weight: 47, reps: 1, at: at("2026-10-01T07:00:00")),        // 1.0
            set(bench, weight: 64, reps: 1, at: at("2026-10-02T07:00:00")),        // 2.0 (最大)
            set(bench, weight: 200, reps: 1, warmup: true, at: at("2026-10-02T07:05:00")),
            set(bench, weight: 200, reps: 1, at: at("2026-09-10T23:59:00")),       // 期間外
        ]
        let pushUpLevel = try #require(level("プッシュアップ", set(pushUp, reps: 30, at: Date()), kind: .repsOnly, bw: 70))
        let chest = try #require(summarize(sets + [set(pushUp, reps: 30, at: at("2026-10-03T07:00:00"))], [bench, pushUp])[.chest])
        #expect(chest.state == .level((2 + pushUpLevel) / 2))
        let best = try #require(chest.exercises.first { $0.exercise.id == bench.id })
        if case .level(let v, let set, let bw) = best.status {
            #expect(v == 2 && set.weight == 64 && bw == 70)
        } else {
            Issue.record("ベンチの級が出ていない")
        }
    }

    @Test("記録なし → noRecord、基準なしだけ → noStandard(n)、対象外だけ → noRecord (一覧に対象外)。cardio は部位に出さず、全身は行で出る")
    func muscleStates() throws {
        let own = exercise("自作のフライ")
        let grip = exercise("ハンドグリップ", .forearms, .repsOnly)
        let swing = exercise("ケトルベルスイング", .fullBody)
        let run = exercise("ランニング（屋外）", .cardio, .durationDistance)
        let result = summarize([
            set(own, weight: 20, reps: 10, at: at("2026-10-01T07:00:00")),
            set(grip, reps: 20, at: at("2026-10-01T07:00:00")),
            set(swing, weight: 24, reps: 10, at: at("2026-10-01T07:00:00")),
            set(run, sec: 1800, distance: 5000, at: at("2026-10-01T07:00:00")),
        ], [own, grip, swing, run])
        #expect(result[.chest]?.state == .noStandard(1))
        #expect(result[.forearms]?.state == .noRecord)
        #expect(result[.forearms]?.exercises.first?.status == .excluded)
        #expect(result[.back]?.state == .noRecord)
        #expect(result[.cardio] == nil)
        if case .level = result[.fullBody]?.state {} else { Issue.record("全身の級が出ていない") }
        #expect(result[.fullBody]?.exercises.first?.label == "換算（dumbbell-romanian-deadlift の表）")
    }

    @Test("アーカイブ済み (exercisesById に無い) 種目は除く・体重 0 件なら級を出さない")
    func archivedAndNoWeight() {
        let bench = exercise("ベンチプレス")
        let s = set(bench, weight: 60, reps: 10, at: at("2026-10-01T07:00:00"))
        #expect(summarize([s], [])[.chest]?.state == .noRecord)
        #expect(summarize([s], [bench], weights: [])[.chest]?.state == .noStandard(1))
    }

    @Test("期間中に体重が変わると、セットごとにその日の体重の行を当てる")
    func weightPerSet() throws {
        let pullUp = exercise("チンニング（順手懸垂）", .back)
        // 70kg の日の 14 回 = 3.0、90kg の日の 14 回は 90kg の行で別の値 → 種目は高い方
        let back = try #require(summarize([
            set(pullUp, weight: 0, reps: 14, at: at("2026-10-01T07:00:00")),
            set(pullUp, weight: 0, reps: 14, at: at("2026-10-05T07:00:00")),
        ], [pullUp], weights: [weight(70, on: "2026-09-01"), weight(90, on: "2026-10-05")])[.back])
        guard case .level(let v) = back.state else { Issue.record("級なし"); return }
        let expected = try #require(level("チンニング（順手懸垂）", set(pullUp, weight: 0, reps: 14, at: Date()), bw: 90))
        #expect(v == max(3, expected))
    }

    // MARK: T-7 期間

    @Test("直近 30 日と、先月・先々月のカレンダー月 (JST の 0:00 境界)")
    func periods() {
        let today = at("2026-10-07T23:59:00")
        let recent = StrengthPeriod.recent.interval(today: today, calendar: jst)
        let previous = StrengthPeriod.previous.interval(today: today, calendar: jst)
        let earlier = StrengthPeriod.earlier.interval(today: today, calendar: jst)
        #expect(recent.start == day("2026-09-08") && recent.end == day("2026-10-08"))
        #expect(previous.start == day("2026-09-01") && previous.end == day("2026-10-01"))
        #expect(earlier.start == day("2026-08-01") && earlier.end == previous.start)
        #expect(StrengthPeriod.recent.label(today: today, calendar: jst) == "9/8〜10/7")
        #expect(StrengthPeriod.previous.label(today: today, calendar: jst) == "2026/09")
        #expect(StrengthPeriod.earlier.label(today: today, calendar: jst) == "2026/08")
    }

    @Test("月の段: 月末・月初の今日でも当月を含めず前の月から。年またぎは 2027/01 → 2026/12")
    func monthPeriods() {
        // 月末 (31 日) と月初 0:00 のどちらでも、先月 = 前のカレンダー月
        #expect(StrengthPeriod.previous.interval(today: at("2026-10-31T23:59:00"), calendar: jst).start == day("2026-09-01"))
        #expect(StrengthPeriod.previous.interval(today: at("2026-10-01T00:00:00"), calendar: jst).start == day("2026-09-01"))
        // 2 月の末日まで (半開区間の終わりは 3/1)
        let february = StrengthPeriod.previous.interval(today: at("2026-03-31T12:00:00"), calendar: jst)
        #expect(february.start == day("2026-02-01") && february.end == day("2026-03-01"))
        // 年またぎ
        let january = at("2027-01-15T12:00:00")
        let december = StrengthPeriod.previous.interval(today: january, calendar: jst)
        #expect(december.start == day("2026-12-01") && december.end == day("2027-01-01"))
        #expect(StrengthPeriod.previous.label(today: january, calendar: jst) == "2026/12")
        #expect(StrengthPeriod.earlier.label(today: january, calendar: jst) == "2026/11")
        #expect(StrengthPeriod.recent.label(today: january, calendar: jst) == "12/17〜1/15")
        // 期間内の日: 月の最初の日は入り、翌月 1 日は入らない
        #expect(StrengthPeriod.previous.contains(day("2026-12-01"), today: january, calendar: jst))
        #expect(StrengthPeriod.previous.contains(day("2026-12-31"), today: january, calendar: jst))
        #expect(!StrengthPeriod.previous.contains(day("2027-01-01"), today: january, calendar: jst))
    }

    @Test("期間ナビ: 先々月より前も月単位で戻れて月は隣接したまま。newer は直近で止まる")
    func periodNavigation() {
        let today = at("2026-10-07T12:00:00")
        let fourth = StrengthPeriod.earlier.older
        #expect(fourth.offset == 3)
        #expect(fourth.label(today: today, calendar: jst) == "2026/07")
        #expect(fourth.interval(today: today, calendar: jst).end == StrengthPeriod.earlier.interval(today: today, calendar: jst).start)
        #expect(StrengthPeriod(offset: 10).label(today: today, calendar: jst) == "2025/12")
        #expect(StrengthPeriod.recent.newer == .recent && StrengthPeriod.recent.isRecent)
        #expect(StrengthPeriod.previous.newer == .recent)
    }

    @Test("期間の境界: 前日 23:59 JST は入らず、当日 0:00 は入る")
    func periodBoundary() throws {
        let bench = exercise("ベンチプレス")
        let inside = summarize([set(bench, weight: 64, reps: 1, at: at("2026-09-11T00:00:00"))], [bench])
        let outside = summarize([set(bench, weight: 64, reps: 1, at: at("2026-09-10T23:59:59"))], [bench])
        #expect(inside[.chest]?.state == .level(2))
        #expect(outside[.chest]?.state == .noRecord)
    }

    @Test("期間と体重の日はセットの day: 期間の最後の日 (10/10) に翌 0:30 に記録したセットは入り、その日の体重を当てる。最初の日の前の日の分は入らない (付録 B-5)")
    func periodUsesTrainingDay() throws {
        let bench = exercise("ベンチプレス")
        let late = set(bench, weight: 64, reps: 1, at: at("2026-10-11T00:30:00"), day: day("2026-10-10"))
        let chest = try #require(summarize([late], [bench], weights: [weight(70, on: "2026-09-01"), weight(90, on: "2026-10-11")])[.chest])
        let best = try #require(chest.exercises.first)
        guard case .level(let v, let used, let bw) = best.status else { Issue.record("級なし"); return }
        #expect(used.id == late.id && bw == 70 && v == 2)
        let early = set(bench, weight: 64, reps: 1, at: at("2026-09-11T00:30:00"), day: day("2026-09-10"))
        #expect(summarize([early], [bench])[.chest]?.state == .noRecord)

        let run = exercise("ランニング（屋外）", .cardio, .durationDistance)
        let totals = StrengthLevels.cardioTotals(sets: [
            set(run, sec: 1800, distance: 5000, at: at("2026-10-11T00:30:00"), day: day("2026-10-10")),
            set(run, sec: 600, distance: 1000, at: at("2026-09-11T00:30:00"), day: day("2026-09-10")),
        ], exercisesById: [run.id: run], interval: period)
        #expect(totals == CardioTotals(count: 1, durationSec: 1800, distanceM: 5000))
    }

    @Test("期間を含む週頭 (月曜) を列挙する")
    func periodWeekStarts() {
        // 9/8 (火) 〜 10/7 (水): 9/7 の週 〜 10/5 の週 = 5 週
        let weeks = StrengthPeriod.recent.weekStarts(today: at("2026-10-07T12:00:00"), calendar: jst)
        #expect(weeks.first == day("2026-09-07") && weeks.last == day("2026-10-05") && weeks.count == 5)
        // 2026/09 = 9/1 (火) 〜 9/30 (水): 8/31 の週 〜 9/28 の週 = 5 週
        let september = StrengthPeriod.previous.weekStarts(today: at("2026-10-07T12:00:00"), calendar: jst)
        #expect(september.first == day("2026-08-31") && september.last == day("2026-09-28") && september.count == 5)
    }

    // MARK: T-8 心肺

    @Test("心肺: 本番セットの件数・時間・距離 (nil は 0)。W・期間外・cardio 以外は除く")
    func cardio() {
        let run = exercise("ランニング（屋外）", .cardio, .durationDistance)
        let rope = exercise("縄跳び", .cardio, .duration)
        let bench = exercise("ベンチプレス")
        let byId = Dictionary(uniqueKeysWithValues: [run, rope, bench].map { ($0.id, $0) })
        let totals = StrengthLevels.cardioTotals(sets: [
            set(run, sec: 1800, distance: 5000, at: at("2026-10-01T07:00:00")),
            set(rope, sec: 300, at: at("2026-10-02T07:00:00")),
            set(run, sec: 600, distance: 1000, warmup: true, at: at("2026-10-02T07:00:00")),
            set(run, sec: 600, distance: 1000, at: at("2026-09-10T07:00:00")),
            set(bench, weight: 60, reps: 10, at: at("2026-10-02T07:00:00")),
        ], exercisesById: byId, interval: period)
        #expect(totals == CardioTotals(count: 2, durationSec: 2100, distanceM: 5000))
    }

    // MARK: T-9 1 か月のヒートマップ

    @Test("1 か月の直近30日: 今日−29〜今日を含む週を並べる。月曜始まり・最下行が今週 (火曜・日曜 23:59・月曜 0:30)")
    func monthWeeks() {
        for (now, monday, first, rows) in [("2026-10-06T12:00:00", "2026-10-05", "2026-09-07", 5),
                                           ("2026-10-11T23:59:00", "2026-10-05", "2026-09-07", 5),
                                           ("2026-10-12T00:30:00", "2026-10-12", "2026-09-07", 6)] {
            let weeks = MonthHeatmapView.weeks(today: at(now), calendar: jst)
            #expect(weeks.count == rows && weeks.allSatisfy { $0.count == 7 }, "\(now)")
            #expect(weeks.last?.first == day(monday), "\(now)")
            #expect(weeks.first?.first == day(first), "\(now)")
            #expect(weeks.allSatisfy { jst.component(.weekday, from: $0[0]) == 2 })
        }
        // 範囲外 (今日−30 以前・明日以降) は空白にするセル
        let today = at("2026-10-12T00:30:00")
        #expect(!StrengthPeriod.recent.contains(day("2026-09-12"), today: today, calendar: jst))
        #expect(StrengthPeriod.recent.contains(day("2026-09-13"), today: today, calendar: jst))
        #expect(StrengthPeriod.recent.contains(day("2026-10-12"), today: today, calendar: jst))
        #expect(!StrengthPeriod.recent.contains(day("2026-10-13"), today: today, calendar: jst))
    }

    @Test("1 か月の月の段: 1 日を含む週〜末日を含む週を並べ、その月の外の日は範囲外。年またぎ")
    func monthPages() {
        let today = at("2026-10-07T12:00:00")
        // 2026/08 = 8/1 (土) 〜 8/31 (月): 7/27 の週 〜 8/31 の週 = 6 行
        let august = MonthHeatmapView.weeks(today: today, period: .earlier, calendar: jst)
        #expect(august.count == 6 && august.first?.first == day("2026-07-27") && august.last?.last == day("2026-09-06"))
        #expect(!StrengthPeriod.earlier.contains(day("2026-07-31"), today: today, calendar: jst))
        #expect(StrengthPeriod.earlier.contains(day("2026-08-01"), today: today, calendar: jst))
        #expect(!StrengthPeriod.earlier.contains(day("2026-09-01"), today: today, calendar: jst))
        // 2026/02 = 2/1 (日) 〜 2/28 (土): 1/26 の週 〜 2/23 の週 = 5 行
        let february = MonthHeatmapView.weeks(today: today, period: StrengthPeriod(offset: 8), calendar: jst)
        #expect(february.count == 5 && february.first?.first == day("2026-01-26") && february.last?.first == day("2026-02-23"))
        // 2027/01 の先月 = 2026/12 (12/1 火 〜 12/31 木): 11/30 の週 〜 12/28 の週
        let december = MonthHeatmapView.weeks(today: at("2027-01-15T12:00:00"), period: .previous, calendar: jst)
        #expect(december.count == 5 && december.first?.first == day("2026-11-30") && december.last?.first == day("2026-12-28"))
    }

    @Test("閾値は 26 週の窓だけで出す: 窓の外の古い週を読んでも変わらず、1 か月と半年で同じ日が同じ段")
    func heatmapWindowThresholds() {
        let today = at("2026-10-07T12:00:00")
        var volumes: [Date: Double] = [:]
        for i in 0..<40 { volumes[jst.date(byAdding: .day, value: -i * 3, to: day("2026-10-07"))!] = Double(100 * (i + 1)) }
        let inWindow = TrainingHeatmap.windowThresholds(volumes: volumes, today: today, calendar: jst)
        var withOld = volumes
        withOld[day("2025-01-06")] = 1_000_000
        withOld[day("2025-01-07")] = 1
        #expect(TrainingHeatmap.windowThresholds(volumes: withOld, today: today, calendar: jst) == inWindow)
        let first = jst.date(byAdding: .day, value: -7 * 25, to: day("2026-10-05"))!
        #expect(inWindow == TrainingHeatmap.thresholds(volumes.filter { $0.key >= first }.map(\.value)))
    }
}

@Suite("ProfileStore — プロフィールと体重 (今日の store と別)")
@MainActor
struct ProfileStoreTests {
    @Test("状態は 未設定 → 体重なし → 揃った の 3 つ。体重だけ失敗したら、もう一度で体重だけ送り直せる")
    func setupAndResend() async {
        let mock = MockWorkoutDataSource()
        let store = ProfileStore(dataSource: mock, calendar: jst)
        await store.load()
        #expect(store.isLoaded && store.setup == .needsProfile)
        #expect(await store.saveProfile(sex: .female, birthDate: at("2001-05-05T15:00:00")) == nil)
        mock.failNextBodyWeightSave = true
        #expect(await store.saveWeight(55.04, on: at("2026-10-07T21:00:00")) != nil)
        #expect(store.setup == .needsWeight)
        #expect(await store.saveWeight(55.04, on: at("2026-10-07T21:00:00")) == nil)
        #expect(store.setup == .ready)
        #expect(mock.profile == UserProfile(sex: .female, birthDate: day("2001-05-05")))
        #expect(mock.bodyWeights == [BodyWeightRecord(recordedOn: day("2026-10-07"), weightKg: 55.04)])
    }

    @Test("同じ日の体重は上書き (1 日 1 件)")
    func sameDayOverwrites() async {
        let mock = MockWorkoutDataSource()
        let store = ProfileStore(dataSource: mock, calendar: jst)
        _ = await store.saveWeight(70, on: at("2026-10-07T07:00:00"))
        _ = await store.saveWeight(70.4, on: at("2026-10-07T22:00:00"))
        _ = await store.saveWeight(70.2, on: at("2026-10-08T07:00:00"))
        #expect(store.weights.map(\.weightKg) == [70.4, 70.2])
        #expect(store.latestWeight?.weightKg == 70.2)
    }

    @Test("体重を保存しても履歴 store のキャッシュは捨てない (invalidate を呼ばない・INV-3)")
    func savingWeightKeepsHistoryCache() async {
        let mock = MockWorkoutDataSource()
        let history = WorkoutHistoryStore(dataSource: mock, calendar: jst)
        let profile = ProfileStore(dataSource: mock, calendar: jst)
        await history.ensureLoaded(weekStarts: [day("2026-10-05")])
        #expect(mock.fetchRangeCallCount == 1)
        _ = await profile.saveWeight(70, on: day("2026-10-07"))
        await history.ensureLoaded(weekStarts: [day("2026-10-05")])
        #expect(mock.fetchRangeCallCount == 1 && history.isLoaded(weekStart: day("2026-10-05")))
    }

    @Test("プロフィールのタブの生年月日の行: 日本時間の日付と、その日の時点の年齢 (誕生日の前日までは 1 つ下)")
    func birthDateText() {
        let profile = UserProfile(sex: .female, birthDate: day("2001-05-05"))
        #expect(ProfileView.birthDateText(profile, today: day("2026-10-22"), calendar: jst) == "2001年5月5日（25歳）")
        #expect(ProfileView.birthDateText(profile, today: day("2026-05-04"), calendar: jst) == "2001年5月5日（24歳）")
        #expect(ProfileView.birthDateText(profile, today: day("2026-05-05"), calendar: jst) == "2001年5月5日（25歳）")
    }
}

