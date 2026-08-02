import Foundation

/// Metadata returned by GET /api/keys (key_value is masked server-side)
struct APIKeyMeta: Codable, Identifiable {
    let id: String
    let keyHint: String
    let label: String?
    let createdAt: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, label
        case keyHint = "key_hint"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    var expiresDate: Date? {
        guard let s = expiresAt else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    var daysRemaining: Int? {
        guard let exp = expiresDate else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0)
    }
}

/// Full key returned only on POST /api/keys (one-time visible)
struct APIKeyCreated: Decodable {
    let id: String
    let keyValue: String
    let label: String?
    let createdAt: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, label
        case keyValue = "key_value"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct APIKeyListResponse: Decodable {
    let keys: [APIKeyMeta]
    let count: Int
}
