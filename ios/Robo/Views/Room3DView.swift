import SwiftUI
import SceneKit
import RoomPlan

struct Room3DView: View {
    let room: RoomScanRecord

    var body: some View {
        ZStack(alignment: .topLeading) {
            representable
            Text(room.roomName)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(10)
        }
    }

    private var representable: some View {
        Room3DSceneView(room: room)
    }

    private struct Room3DSceneView: UIViewRepresentable {
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
            if let usdzData = room.usdzData, let scene = sceneFromUSDZ(usdzData) {
                return scene
            }
            if let scene = reconstructFromFullData() {
                return scene
            }
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
}
