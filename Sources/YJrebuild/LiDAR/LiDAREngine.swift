import ARKit
import RealityKit
import Foundation

/// LiDAR 扫描引擎 - full ARKit mesh collection with camera integration
final class LiDAREngine: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isScanning = false
    @Published var meshVertexCount: Int = 0
    @Published var meshFaceCount: Int = 0
    @Published var errorMessage: String?
    @Published var trackingOK = true
    @Published var scanProgress: Float = 0.0

    let arView = ARView(frame: .zero)
    private var meshAnchors: [ARMeshAnchor] = []
    private let maxAnchors = 500

    override init() {
        super.init()
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorMessage = "Device does not support LiDAR"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic
        arView.session.delegate = self
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [.disableCameraGrain, .disableMotionBlur]
    }

    func startScanning() {
        isScanning = true
        meshVertexCount = 0
        meshFaceCount = 0
        scanProgress = 0
    }

    func stopScanning() {
        isScanning = false
        arView.session.pause()
    }

    deinit { stopScanning() }

    /// Export collected mesh as OBJ format
    func exportMeshData() -> Data? {
        guard !meshAnchors.isEmpty else { return nil }
        var obj = "# YJrebuild LiDAR Mesh\n# Vertices: \(meshVertexCount)\n# Faces: \(meshFaceCount)\n"
        for anchor in meshAnchors {
            let geom = anchor.geometry
            let vSrc = geom.vertices
            let fSrc = geom.faces
            let vBuf = vSrc.buffer.contents()
            let fBuf = fSrc.buffer.contents()
            for i in 0..<vSrc.count {
                let ptr = vBuf.advanced(by: i * vSrc.stride).assumingMemoryBound(to: (Float, Float, Float).self).pointee
                obj += "v \(ptr.0) \(ptr.1) \(ptr.2)\n"
            }
            for i in 0..<fSrc.count {
                let ptr = fBuf.advanced(by: i * fSrc.bytesPerIndex * fSrc.indexCountPerPrimitive).assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee
                obj += "f \(ptr.0 + 1) \(ptr.1 + 1) \(ptr.2 + 1)\n"
            }
        }
        return obj.data(using: .utf8)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }
        for anchor in anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            if meshAnchors.count >= maxAnchors { meshAnchors.removeFirst(50) }
            meshAnchors.append(ma)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.meshVertexCount += ma.geometry.vertices.count
                self.meshFaceCount += ma.geometry.faces.count
                self.scanProgress = min(self.scanProgress + 0.002, 1.0)
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async { [weak self] in self?.trackingOK = camera.trackingState == .normal }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.isScanning = false }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {}
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {}
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        meshAnchors.removeAll { a in anchors.contains { $0.identifier == a.identifier } }
    }
}
