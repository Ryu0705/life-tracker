import Foundation

/// 強さの基準: Strength Level の体重比の表 (Resources/strength_level_standards.json) と、
/// 種目名 → 基準の対応表 (Resources/strength_mapping.json。docs/strength-standards/build_mapping.py の生成物)。
/// 個人用アプリの中だけで使い、公開・再配布しない (docs/body-strength-and-heatmap-period.md 本人 Q2-2)。
/// 読み込みに失敗した表・崩れた表は「基準なし」に落とす (起動を止めない)
struct StrengthStandards {
    enum Unit: String, Decodable {
        case kg, reps, seconds
    }

    /// 体重 1 行 = Beginner / Novice / Intermediate / Advanced / Elite の 5 値
    struct Row: Equatable {
        let bodyWeight: Double
        let values: [Double]
    }

    struct Standard {
        let unit: Unit
        /// 性別 → 体重の表 (体重の昇順)
        let rows: [Sex: [Row]]
        /// 自重種目の加重 1RM の表 (kg。マイナス = アシスト)。pull-ups・chin-ups・dips だけ
        let addedRows: [Sex: [Row]]?
    }

    enum Match: String, Decodable {
        case exact, approx, derived, excluded
    }

    /// セットの値を表に当てる前の変換 (換算の下書き derived-standards-draft.md)
    enum Transform: String, Decodable {
        /// 自重の weight_reps: 加重 0 → 回数の表、加重あり → (体重＋加重)×Epley − 体重 を加重の表へ
        case bodyweightAdded = "bodyweight_added"
        /// アシストチンニング: アシスト 0 → 回数の表、アシストあり → (体重 − アシスト)×Epley − 体重 を加重の表へ
        case assistToAdded = "assist_to_added"
        /// ロシアンツイスト: 加重 0 → 回数、加重あり → 上半身の負荷 (体重×0.3) に対する相当回数
        case weightedRepsEquivalent = "weighted_reps_equivalent"
    }

    enum Multiplier: Equatable {
        /// 段ごとの倍率 (静止系 3 件: plank の表 × Endura の比)
        case perLevel([Sex: [Double]])
        /// 同じ体重行の別の 2 表の比 (近似の係数 2 件)
        case ratioOf(String, String)
    }

    struct Mapping: Equatable {
        let name: String
        let match: Match
        let slug: String?
        let transform: Transform?
        let multiplier: Multiplier?
        /// 画面に出す 1 語 (近似・換算の代用元)
        let label: String?
    }

    /// 種目の当て先
    enum Resolution {
        case excluded
        /// 対応が無い・表が崩れている・単位が合わない
        case none
        case standard(Mapping, Standard)
    }

    let standards: [String: Standard]
    let mappings: [String: Mapping]

    static let levelNames = ["Beginner", "Novice", "Intermediate", "Advanced", "Elite"]

    /// アプリ同梱の表 (初回参照で 1 回だけ読む)
    static let bundled: StrengthStandards = load(bundle: .main)

    static func load(bundle: Bundle) -> StrengthStandards {
        func data(_ name: String) -> Data? {
            bundle.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        }
        let standards = data("strength_level_standards").flatMap { try? decodeStandards($0) } ?? [:]
        let mappings = data("strength_mapping").flatMap { try? decodeMappings($0) } ?? [:]
        return StrengthStandards(standards: standards, mappings: mappings)
    }

    func resolve(_ exercise: Exercise) -> Resolution {
        guard let mapping = mappings[exercise.name] else { return .none }
        if mapping.match == .excluded { return .excluded }
        guard let slug = mapping.slug, let standard = standards[slug],
              standard.unit == Self.requiredUnit(kind: exercise.metricKind, transform: mapping.transform) else { return .none }
        switch mapping.transform {
        case .bodyweightAdded, .assistToAdded:
            guard standard.addedRows != nil else { return .none }
        case .weightedRepsEquivalent, nil:
            break
        }
        if case .ratioOf(let a, let b) = mapping.multiplier, standards[a] == nil || standards[b] == nil { return .none }
        return .standard(mapping, standard)
    }

    /// 記録の単位と表の単位が一致する対応だけを使う (レビュー A-1)。nil = どの表にも当てられない
    static func requiredUnit(kind: MetricKind, transform: Transform?) -> Unit? {
        if transform != nil { return kind == .weightReps ? .reps : nil }
        switch kind {
        case .weightReps: return .kg
        case .repsOnly: return .reps
        case .duration: return .seconds
        case .durationDistance: return nil
        }
    }

    /// その体重の閾値 5 値。行の間は線形補間、範囲外は端の行 (外挿しない)。倍率は補間の後に掛ける
    func thresholds(_ mapping: Mapping, standard: Standard, sex: Sex, bodyWeight: Double, added: Bool = false) -> [Double]? {
        guard let rows = (added ? standard.addedRows : standard.rows)?[sex],
              var values = Self.interpolate(rows, bodyWeight: bodyWeight) else { return nil }
        switch mapping.multiplier {
        case .perLevel(let bySex):
            guard let factors = bySex[sex], factors.count == 5 else { return nil }
            values = zip(values, factors).map(*)
        case .ratioOf(let a, let b):
            guard let top = standards[a]?.rows[sex].flatMap({ Self.interpolate($0, bodyWeight: bodyWeight) }),
                  let bottom = standards[b]?.rows[sex].flatMap({ Self.interpolate($0, bodyWeight: bodyWeight) }),
                  !bottom.contains(where: { $0 <= 0 }) else { return nil }
            values = (0..<5).map { values[$0] * top[$0] / bottom[$0] }
        case nil:
            break
        }
        return values
    }

    static func interpolate(_ rows: [Row], bodyWeight: Double) -> [Double]? {
        guard let first = rows.first, let last = rows.last else { return nil }
        if bodyWeight <= first.bodyWeight { return first.values }
        if bodyWeight >= last.bodyWeight { return last.values }
        guard let upper = rows.firstIndex(where: { $0.bodyWeight >= bodyWeight }) else { return last.values }
        let hi = rows[upper], lo = rows[upper - 1]
        let t = (bodyWeight - lo.bodyWeight) / (hi.bodyWeight - lo.bodyWeight)
        return zip(lo.values, hi.values).map { $0 + ($1 - $0) * t }
    }

    // MARK: 読み込み

    /// 表を検証して、崩れたものを落とす: 体重が 5kg 刻みの昇順・5 値・行内で非減少 (レビュー A-3)。
    /// 「< 1」は 1 として読む (同値の隣接閾値は StrengthLevels.score の規則で吸収する。A-2)
    static func decodeStandards(_ data: Data) throws -> [String: Standard] {
        let file = try JSONDecoder().decode(StandardsFile.self, from: data)
        var result: [String: Standard] = [:]
        for (slug, raw) in file.exercises {
            guard let rows = validRows(raw.male, raw.female) else { continue }
            var added: [Sex: [Row]]?
            if let a = raw.addedWeightKg {
                guard let rows = validRows(a.male, a.female) else { continue }
                added = rows
            }
            result[slug] = Standard(unit: raw.unit, rows: rows, addedRows: added)
        }
        return result
    }

    static func decodeMappings(_ data: Data) throws -> [String: Mapping] {
        let file = try JSONDecoder().decode(MappingFile.self, from: data)
        return Dictionary(file.exercises.map { ($0.name, $0.mapping) }, uniquingKeysWith: { first, _ in first })
    }

    private static func validRows(_ male: RawSex, _ female: RawSex) -> [Sex: [Row]]? {
        var result: [Sex: [Row]] = [:]
        for (sex, raw) in [(Sex.male, male), (.female, female)] {
            let rows = raw.bodyweight.compactMap { row -> Row? in
                let values = row.values.compactMap(\.number)
                return values.count == 5 ? Row(bodyWeight: row.bw, values: values) : nil
            }
            guard rows.count == raw.bodyweight.count, !rows.isEmpty,
                  zip(rows, rows.dropFirst()).allSatisfy({ $1.bodyWeight - $0.bodyWeight == 5 }),
                  rows.allSatisfy({ zip($0.values, $0.values.dropFirst()).allSatisfy { $0 <= $1 } }) else { return nil }
            result[sex] = rows
        }
        return result
    }

    private struct StandardsFile: Decodable {
        let exercises: [String: RawStandard]
    }

    private struct RawStandard: Decodable {
        let unit: Unit
        let male: RawSex
        let female: RawSex
        let addedWeightKg: RawAdded?

        enum CodingKeys: String, CodingKey {
            case unit, male, female
            case addedWeightKg = "added_weight_kg"
        }
    }

    private struct RawAdded: Decodable {
        let male: RawSex
        let female: RawSex
    }

    private struct RawSex: Decodable {
        let bodyweight: [RawRow]
    }

    private struct RawRow: Decodable {
        let bw: Double
        let values: [Cell]
    }

    /// 数値か「< 1」(= 1)。それ以外の文字列は nil (その行ごと崩れ扱い)
    private enum Cell: Decodable {
        case number(Double)
        case text(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .number(v) } else { self = .text(try c.decode(String.self)) }
        }

        var number: Double? {
            switch self {
            case .number(let v): return v
            case .text(let s): return s == "< 1" ? 1 : nil
            }
        }
    }

    private struct MappingFile: Decodable {
        let exercises: [RawMapping]
    }

    private struct RawMapping: Decodable {
        let name: String
        let match: Match
        let slug: String?
        let transform: Transform?
        let multiplier: RawMultiplier?
        let label: String?

        var mapping: Mapping {
            let m: Multiplier? = multiplier.flatMap { raw in
                if let bySex = raw.bySex {
                    return .perLevel(Dictionary(uniqueKeysWithValues: bySex.compactMap { k, v in Sex(rawValue: k).map { ($0, v) } }))
                }
                if let pair = raw.ratioOf, pair.count == 2 { return .ratioOf(pair[0], pair[1]) }
                return nil
            }
            return Mapping(name: name, match: match, slug: slug, transform: transform, multiplier: m, label: label)
        }
    }

    private struct RawMultiplier: Decodable {
        let bySex: [String: [Double]]?
        let ratioOf: [String]?

        enum CodingKeys: String, CodingKey {
            case bySex = "by_sex"
            case ratioOf = "ratio_of"
        }
    }
}
