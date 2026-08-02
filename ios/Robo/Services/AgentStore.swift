import Foundation
import SwiftUI

/// Single source of truth for agent metadata.
/// Records store stable `agentId` only; display metadata is resolved here at render time.
enum AgentStore {
    struct Metadata {
        let name: String
        let icon: String
        let color: Color
    }

    private static let lookup: [String: Metadata] = {
        var map: [String: Metadata] = [:]
        for agent in MockAgentService.loadAgents() {
            map[agent.id.uuidString] = Metadata(
                name: agent.name,
                icon: agent.iconSystemName,
                color: agent.accentColor
            )
        }
        return map
    }()

    static func metadata(for agentId: String) -> Metadata? {
        lookup[agentId]
    }

    /// Resolve agent name from store, falling back to denormalized record value.
    static func name(for agentId: String, fallback: String?) -> String {
        lookup[agentId]?.name ?? fallback ?? "Unknown Agent"
    }

    static func icon(for agentId: String) -> String {
        lookup[agentId]?.icon ?? "questionmark.circle"
    }

    static func color(for agentId: String) -> Color {
        lookup[agentId]?.color ?? .secondary
    }
}
