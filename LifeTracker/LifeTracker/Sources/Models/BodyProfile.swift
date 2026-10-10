import Foundation

// 強さの級に使うプロフィールと体重 (migration 0011)。級は保存しない (INV-5)

/// 基準の表の性別 (Strength Level の male / female)
enum Sex: String, Codable, CaseIterable, Identifiable {
    case male, female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male: return "男性"
        case .female: return "女性"
        }
    }
}

/// user_profile (1 行だけ)。年齢は生年月日から計算する (保存しない)
struct UserProfile: Codable, Equatable {
    let sex: Sex
    @DateOnly var birthDate: Date

    func age(on day: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.year], from: birthDate, to: day).year ?? 0
    }
}

/// body_weight_record (1 日 1 件。同じ日は上書き)
struct BodyWeightRecord: Codable, Equatable, Hashable {
    @DateOnly var recordedOn: Date
    let weightKg: Double
}
