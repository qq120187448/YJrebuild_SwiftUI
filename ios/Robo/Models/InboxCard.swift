import Foundation

struct InboxCard: Codable, Identifiable {
    let id: String
    let deviceId: String
    let cardType: CardType
    let title: String
    let body: String?
    let response: String?
    let status: Status
    let createdAt: Date
    let respondedAt: Date?

    enum CardType: String, Codable {
        case decision
        case task
        case info
    }

    enum Status: String, Codable {
        case pending
        case responded
        case expired
    }

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case cardType = "card_type"
        case title, body, response, status
        case createdAt = "created_at"
        case respondedAt = "responded_at"
    }
}
