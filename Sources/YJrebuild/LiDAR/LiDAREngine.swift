import ARKit
import RealityKit
import Combine

/// LiDAR ???? - ?? ARSession ? mesh ??
final class LiDAREngine: NSObject, ObservableObject, ARSessionDelegate {
    // MARK: - Published
    @Published var isScanning = false
    @Published var scanProgress: Float = 0.0
    @Published var scannedAreaEstimate: Float = 0.0
    @Published var meshVertexCount: Int = 0
    @Published var trackingNormal = true
    @Published var errorMessage: String?

    // MARK: - ARKit
    let arView = ARView(frame: .zero)
    private var meshAnchors: [ARMeshAnchor] = []
    private var cancellables = Set<AnyCancellable>()
    private let maxAnchors = 500
    private let memoryThreshold: UInt64 = 300 * 1024 * 1024 // 300MB

    override init() {
        super.init()
        setupSession()
        observeMemory()
    }

    deinit {
        stopScanning()
    }

    // MARK: - Setup
    private func setupSession() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorMessage = "?????LiDAR"
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

    // MARK: - Scan Control
    func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0.0
        meshVertexCount = 0
        scannedAreaEstimate = 0.0
        meshAnchors.removeAll(keepingCapacity: true)
    }

    func stopScanning() {
        isScanning = false
        arView.session.pause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.cleanup()
        }
    }

    private func cleanup() {
        meshAnchors.removeAll(keepingCapacity: false)
        cancellables.removeAll()
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - Memory
    private func observeMemory() {
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                if (self?.meshAnchors.count ?? 0) > 100 { self?.trimAnchors() }
            }
            .store(in: &cancellables)
    }

    private func trimAnchors() {
        let excess = meshAnchors.count - 100
        guard excess > 0 else { return }
        meshAnchors.removeFirst(excess)
    }

    private func checkMemory() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS && info.phys_footprint > memoryThreshold
    }

    // MARK: - Export
    func exportMeshData() -> Data? {
        guard !meshAnchors.isEmpty else { return nil }
        var obj = "# YJrebuild LiDAR\n# Vertices: \(meshVertexCount)\n"
        for anchor in meshAnchors {
            let verts = anchor.geometry.vertices
            let faces = anchor.geometry.faces
            let vBuf = verts.buffer.contents()
            let fBuf = faces.buffer.contents()

            for i in 0..<verts.count {
                let base = vBuf.advanced(by: i * verts.stride)
                let ptr = base.assumingMemoryBound(to: (Float, Float, Float).self).pointee
                obj += "v \(ptr.0) \(ptr.1) \(ptr.2)\n"
            }
            for i in 0..<faces.count {
                let base = fBuf.advanced(by: i * faces.bytesPerIndex * faces.indexCountPerPrimitive)
                let ptr = base.assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee
                obj += "f \(ptr.0 + 1) \(ptr.1 + 1) \(ptr.2 + 1)\n"
            }
        }
        return obj.data(using: .utf8)
    }

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scanProgress = min((self?.scanProgress ?? 0) + 0.001, 1.0)
        }
        if Int(frame.timestamp) % 60 == 0 && checkMemory() {
            DispatchQueue.main.async { [weak self] in self?.trimAnchors() }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor, isScanning else { continue }
            if meshAnchors.count >= maxAnchors { meshAnchors.removeFirst(50) }
            meshAnchors.append(meshAnchor)
            DispatchQueue.main.async { [weak self] in
                self?.meshVertexCount += meshAnchor.geometry.vertices.count
                self?.scannedAreaEstimate += Float(meshAnchor.geometry.faces.count) * 0.0001
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {}
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        meshAnchors.removeAll { a in anchors.contains { $0.identifier == a.identifier } }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async { [weak self] in
            switch camera.trackingState {
            case .normal: self?.trackingNormal = true
            case .limited: self?.trackingNormal = false
            case .notAvailable: self?.errorMessage = "?????"
            @unknown default: break
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in self?.isScanning = false }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in self?.startScanning() }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "????: \(error.localizedDescription)"
            self?.isScanning = false
        }
    }
}
