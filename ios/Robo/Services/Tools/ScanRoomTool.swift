#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26, *)
struct ScanRoomTool: Tool {
    let name = "scan_room"
    let description = """
        Launches the LiDAR room scanner to capture a 3D scan of the user's room. \
        Use this when the user wants to scan, measure, or map a room. \
        Returns room dimensions, wall count, floor area, and object details.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Name for the room being scanned, or 'unnamed' if not specified")
        var roomName: String
    }

    let captureCoordinator: CaptureCoordinator

    func call(arguments: Arguments) async throws -> String {
        let name = arguments.roomName == "unnamed" ? nil : arguments.roomName
        return try await captureCoordinator.requestCapture(type: .lidar, roomName: name)
    }
}

#endif
