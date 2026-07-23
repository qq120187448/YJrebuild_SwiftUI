import ARKit
import RealityKit
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
            errorMessage = "Device does not support LiDAR"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        arView.session.delegate = self
        arView.session.run(config)
        arView.automaticallyConfigureSession = false
    }

    func startScanning() { isScanning = true; meshVertexCount = 0 }
    func stopScanning() { isScanning = false; arView.session.pause() }
    deinit { stopScanning() }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }
        for anchor in anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            let vc = ma.geometry.vertices.count
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.meshVertexCount += vc
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let normal = camera.trackingState == .normal
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trackingOK = normal
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.isScanning = false }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {}
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {}
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {}
}
