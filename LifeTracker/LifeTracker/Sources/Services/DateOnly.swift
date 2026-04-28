import Foundation

@propertyWrapper
struct DateOnly: Codable, Hashable {
    var wrappedValue: Date

    init(wrappedValue: Date) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let date = Self.formatter.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid DATE (expected yyyy-MM-dd in JST): \(raw)"
            )
        }
        self.wrappedValue = date
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.formatter.string(from: wrappedValue))
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
