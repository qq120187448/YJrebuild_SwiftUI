import ARKit
import RealityKit
import Combine

final class LiDAREngine: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var meshVertexCount: Int = 0
    @Published var errorMessage: String?

    let arView = ARView(frame: .zero)
    private var meshAnchors: [ARMeshAnchor] = []

    override init() {
        super.init()
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorMessage = "device_no_lidar"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        arView.session.delegate = self
        arView.session.run(config)
        arView.automaticallyConfigureSession = false
    }

    func startScanning() { isScanning = true; meshAnchors.removeAll() }
    func stopScanning() { isScanning = false; arView.session.pause() }
    deinit { stopScanning() }
}

extension LiDAREngine: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let mesh = anchor as? ARMeshAnchor, isScanning else { continue }
            meshAnchors.append(mesh)
            DispatchQueue.main.async { [weak self] in
                self?.meshVertexCount += mesh.geometry.vertices.count
            }
        }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.isScanning = false }
    }
}
