import Foundation
import SwiftUI

struct AgentConnection: Identifiable {
    let id: UUID
    let name: String
    let description: String
    let iconSystemName: String
    let accentColor: Color
    var status: Status
    var lastSyncDate: Date?
    var pendingRequest: AgentRequest?

    enum Status {
        case connected
        case pendingApproval
        case syncing
    }
}

struct AgentRequest: Identifiable {
    let id: UUID
    let title: String
    let description: String
    let skillType: SkillType
    let photoChecklist: [PhotoTask]?
    let roomNameHint: String?

    enum SkillType {
        case lidar
        case barcode
        case camera
        case motion
        case productScan
        case beacon
        case health
    }

    init(
        id: UUID,
        title: String,
        description: String,
        skillType: SkillType,
        photoChecklist: [PhotoTask]? = nil,
        roomNameHint: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.skillType = skillType
        self.photoChecklist = photoChecklist
        self.roomNameHint = roomNameHint
    }
}

struct PhotoTask: Identifiable {
    let id: UUID
    let label: String
    var isCompleted: Bool
}

/// Shared context threaded through all capture views so records are tagged consistently.
struct CaptureContext {
    let agentId: String
    let agentName: String
    let requestId: UUID
}
