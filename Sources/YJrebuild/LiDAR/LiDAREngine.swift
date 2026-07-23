import ARKit
import Foundation

final class LiDAREngine: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isScanning = false
    @Published var meshVertexCount: Int = 0
    @Published var errorMessage: String?
    @Published var trackingOK = true

    let arView = ARView(frame: .zero)

    override init() {
        super.init()
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorMessage = "Device does not support LiDAR. Requires iPhone 12 Pro or newer."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        arView.session.delegate = self
        arView.session.run(config)
        arView.automaticallyConfigureSession = false
    }

    func startScanning() {
        isScanning = true
        meshVertexCount = 0
    }

    func stopScanning() {
        isScanning = false
        arView.session.pause()
    }

    deinit { stopScanning() }

    func exportMeshData() -> Data? {
        let header = "# YJrebuild LiDAR\n# Vertices: " + String(meshVertexCount) + "\n"
        return header.data(using: .utf8)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.meshVertexCount += meshAnchor.geometry.vertices.count
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async { [weak self] in
            switch camera.trackingState {
            case .normal: self?.trackingOK = true
            case .limited, .notAvailable: self?.trackingOK = false
            @unknown default: break
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.isScanning = false
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {}
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {}
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {}
}
