import SwiftUI
import SceneKit
import RoomPlan

struct Room3DView: UIViewRepresentable {
    let room: RoomScanRecord

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = .clear
        scnView.autoenablesDefaultLighting = true

        scnView.scene = loadScene()
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func loadScene() -> SCNScene {
        // Try loading from stored USDZ data
        if let usdzData = room.usdzData, let scene = sceneFromUSDZ(usdzData) {
            return scene
        }

        // Fallback: try reconstructing USDZ from fullRoomDataJSON
        if let scene = reconstructFromFullData() {
            return scene
        }

        // Final fallback: empty scene with message
        return SCNScene()
    }

    private func sceneFromUSDZ(_ data: Data) -> SCNScene? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usdz")
        do {
            try data.write(to: tempURL)
            let scene = try SCNScene(url: tempURL, options: [
                .checkConsistency: true
            ])
            try? FileManager.default.removeItem(at: tempURL)
            return scene
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    private func reconstructFromFullData() -> SCNScene? {
        guard let capturedRoom = try? RoomDataProcessor.decodeFullRoom(room.fullRoomDataJSON) else {
            return nil
        }

        let usdzURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usdz")
        do {
            try capturedRoom.export(to: usdzURL, exportOptions: .model)
            let data = try Data(contentsOf: usdzURL)
            try? FileManager.default.removeItem(at: usdzURL)
            return sceneFromUSDZ(data)
        } catch {
            try? FileManager.default.removeItem(at: usdzURL)
            return nil
        }
    }
}
