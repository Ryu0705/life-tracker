import Foundation

enum SupabaseConfig {
    enum ConfigError: Error, LocalizedError {
        case missingURL
        case invalidURL(String)
        case missingAnonKey

        var errorDescription: String? {
            switch self {
            case .missingURL:
                return "SUPABASE_URL が Info.plist に設定されていません (xcconfig 未投入の可能性)"
            case .invalidURL(let raw):
                return "SUPABASE_URL の形式が不正: \(raw)"
            case .missingAnonKey:
                return "SUPABASE_ANON_KEY が Info.plist に設定されていません (xcconfig 未投入の可能性)"
            }
        }
    }

    static func loadURL() throws -> URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              !raw.isEmpty else {
            throw ConfigError.missingURL
        }
        guard let url = URL(string: raw) else {
            throw ConfigError.invalidURL(raw)
        }
        return url
    }

    static func loadAnonKey() throws -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              !raw.isEmpty else {
            throw ConfigError.missingAnonKey
        }
        return raw
    }
}
