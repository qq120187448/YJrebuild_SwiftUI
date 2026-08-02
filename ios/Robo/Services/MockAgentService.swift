import Foundation
import SwiftUI

enum MockAgentService {
    static func loadAgents() -> [AgentConnection] {
        [
            AgentConnection(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
                name: "Claude Code",
                description: "Bridge sensor data to Claude Code via MCP. Any capture — room scans, photos, barcodes — is instantly available in your terminal.",
                iconSystemName: "terminal",
                accentColor: .orange,
                status: .connected,
                lastSyncDate: nil,
                pendingRequest: AgentRequest(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!,
                    title: "Capture data for Claude Code",
                    description: "Scan a room, photograph something, or scan a barcode — then ask Claude about it. Visit robo.app/connect for setup.",
                    skillType: .lidar,
                    roomNameHint: nil
                )
            ),
            AgentConnection(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Interior Designer",
                description: "AI-powered room design and furniture placement",
                iconSystemName: "sofa",
                accentColor: .purple,
                status: .connected,
                lastSyncDate: nil,
                pendingRequest: AgentRequest(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                    title: "Send me the floor plan of your master bedroom",
                    description: "I'll use LiDAR measurements to suggest furniture layouts that actually fit.",
                    skillType: .lidar,
                    roomNameHint: "Master Bedroom"
                )
            )
        ]
    }
}
