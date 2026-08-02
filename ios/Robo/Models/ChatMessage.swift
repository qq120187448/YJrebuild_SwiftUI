import Foundation

struct ChatMessage: Identifiable {
    let id: UUID
    var role: Role
    var content: String
    let timestamp: Date

    enum Role {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
