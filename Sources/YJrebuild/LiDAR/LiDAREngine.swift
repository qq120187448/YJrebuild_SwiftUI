import ARKit
import RealityKit
import Combine
import os.log

/// LiDAR ???? - ?? ARSession ?????mesh ???????
final class LiDAREngine: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isScanning = false
    @Published var scanProgress: Float = 0.0
    @Published var scannedAreaEstimate: Float = 0.0
    @Published var meshVertexCount: Int = 0
    @Published var sessionState: ARSession.State = .initializing
    @Published var errorMessage: String?

    // MARK: - ARKit Properties
    let arView = ARView(frame: .zero)
    private var meshAnchors: [ARMeshAnchor] = []
    private var cancellables = Set<AnyCancellable>()
    private let log = Logger(subsystem: "com.youjiscan.yjrebuild", category: "LiDAR")

    // MARK: - Memory Management
    private let maxMeshAnchors = 500
    private let memoryWarningThreshold: UInt64 = 300 * 1024 * 1024 // 300MB

    override init() {
        super.init()
        setupARSession()
        observeMemoryPressure()
    }

    deinit {
        stopScanning()
        log.info("LiDAREngine deinitialized - all resources cleaned")
    }

    // MARK: - Session Setup
    private func setupARSession() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            errorMessage = "?????LiDAR?????iPhone 12 Pro?????"
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic
        config.frameSemantics = [.smoothedSceneDepth, .sceneDepth]
        arView.session.delegate = self
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [
            .disableCameraGrain,
            .disableMotionBlur,
            .disableAREnvironmentLighting
        ]

        log.info("ARSession configured with LiDAR mesh reconstruction")
    }

    // MARK: - Scan Control
    func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0.0
        scannedAreaEstimate = 0.0
        meshVertexCount = 0
        meshAnchors.removeAll(keepingCapacity: true)
        log.info("Scan started")
    }

    func stopScanning() {
        isScanning = false
        arView.session.pause()
        log.info("Scan stopped - \(self.meshVertexCount) vertices captured")

        // Force cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.performMemoryCleanup()
        }
    }

    func resumeScanning() {
        guard !isScanning else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        arView.session.run(config)
        isScanning = true
        log.info("Scan resumed")
    }

    // MARK: - Memory Cleanup
    private func performMemoryCleanup() {
        meshAnchors.removeAll(keepingCapacity: false)
        cancellables.removeAll()
        URLCache.shared.removeAllCachedResponses()
        log.info("Memory cleanup completed")
    }

    private func observeMemoryPressure() {
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                self?.log.warning("Memory warning received - trimming anchors")
                if self?.meshAnchors.count ?? 0 > 100 {
                    self?.trimOldAnchors()
                }
            }
            .store(in: &cancellables)
    }

    private func trimOldAnchors() {
        let excess = meshAnchors.count - 100
        guard excess > 0 else { return }
        meshAnchors.removeFirst(excess)
        log.info("Trimmed \(excess) old anchors")
    }

    private func checkMemoryPressure() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let usedMemory = info.phys_footprint
            if usedMemory > memoryWarningThreshold {
                log.warning("Memory pressure: \(usedMemory / 1024 / 1024)MB used")
                return true
            }
        }
        return false
    }

    // MARK: - Mesh Export
    func exportMeshData() -> Data? {
        guard !meshAnchors.isEmpty else {
            log.warning("No mesh data to export")
            return nil
        }
        // Export as OBJ string
        var objString = "# YJrebuild LiDAR Mesh Export\n"
        objString += "# Vertices: \(meshVertexCount)\n\n"
        for anchor in meshAnchors {
            let mesh = anchor.geometry
            for i in 0..<mesh.vertices.count {
                let v = mesh.vertices.buffer.contents().advanced(by: i * mesh.vertices.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                objString += "v \(v.x) \(v.y) \(v.z)\n"
            }
            for i in 0..<mesh.faces.count {
                let f = mesh.faces.buffer.contents().advanced(by: i * mesh.faces.stride).assumingMemoryBound(to: SIMD3<Int32>.self).pointee
                objString += "f \(f.x + 1) \(f.y + 1) \(f.z + 1)\n"
            }
        }
        return objString.data(using: .utf8)
    }
}

// MARK: - ARSessionDelegate
extension LiDAREngine: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }

        // Update scanning progress
        DispatchQueue.main.async { [weak self] in
            self?.sessionState = .running
            self?.scanProgress = min(self?.scanProgress ?? 0 + 0.001, 1.0)
        }

        // Check memory every ~60 frames
        if frame.timestamp.truncatingRemainder(dividingBy: 60) < 1 {
            if checkMemoryPressure() {
                DispatchQueue.main.async { [weak self] in
                    self?.trimOldAnchors()
                }
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor, isScanning else { continue }

            if meshAnchors.count >= maxMeshAnchors {
                meshAnchors.removeFirst(50)
            }
            meshAnchors.append(meshAnchor)

            let vertexCount = meshAnchor.geometry.vertices.count
            let faceCount = meshAnchor.geometry.faces.count

            DispatchQueue.main.async { [weak self] in
                self?.meshVertexCount += vertexCount
                self?.scannedAreaEstimate += Float(faceCount) * 0.0001
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Mesh updates are handled by RealityKit rendering
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        meshAnchors.removeAll { anchor in
            anchors.contains { $0.identifier == anchor.identifier }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async { [weak self] in
            switch camera.trackingState {
            case .normal:
                self?.sessionState = .running
            case .limited(let reason):
                self?.sessionState = .limited(reason)
            case .notAvailable:
                self?.errorMessage = "????????"
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.sessionState = .interrupted
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.resumeScanning()
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "????: \(error.localizedDescription)"
            self?.isScanning = false
        }
    }
}

extension ARSession.State: @retroactive Equatable {
    public static func == (lhs: ARSession.State, rhs: ARSession.State) -> Bool {
        switch (lhs, rhs) {
        case (.initializing, .initializing), (.running, .running), (.interrupted, .interrupted):
            return true
        case (.limited(let a), .limited(let b)):
            return a == b
        default:
            return false
        }
    }
}

extension ARCamera.TrackingState.Reason: @retroactive Equatable {
    public static func == (lhs: ARCamera.TrackingState.Reason, rhs: ARCamera.TrackingState.Reason) -> Bool {
        switch (lhs, rhs) {
        case (.initializing, .initializing), (.relocalizing, .relocalizing), (.excessiveMotion, .excessiveMotion), (.insufficientFeatures, .insufficientFeatures):
            return true
        default:
            return false
        }
    }
}
