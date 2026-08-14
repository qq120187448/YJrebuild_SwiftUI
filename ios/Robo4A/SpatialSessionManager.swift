import ARKit
import RealityKit

/// 0.74D（专家第五阶段）：SpatialSessionManager 统一管理 ARSession 生命周期、
/// WorldMap 保存/恢复、relocalization、tracking/worldMappingStatus 状态机。
/// Standard Mode（RoomPlan 语义层）与 Quick Mode（纯 ARKit）共用。
enum SpatialSessionState: String {
    case ready = "READY"
    case tracking = "TRACKING"
    case spatialDegraded = "SPATIAL_DEGRADED"
    case relocalizing = "RELOCALIZING"
    case recovered = "RECOVERED"
    case unsafe = "UNSAFE"
}

final class SpatialSessionManager {

    private(set) var state: SpatialSessionState = .ready
    private(set) var worldMap: ARWorldMap?
    private(set) var lastDiagnostic = ""
    private(set) var lastMappingStatusText = ""
    var onLog: ((String) -> Void)?

    private var autoSaved = false
    private var relocalizeStart: Date?

    // MARK: - 生命周期

    func start(arView: ARView) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(
            .meshWithClassification
        ) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)
        setState(.tracking, text: "ARSession 已启动（TRACKING）")
    }

    func stop(session: ARSession) {
        session.pause()
        setState(.ready, text: "ARSession 已停止（READY）")
    }

    // MARK: - WorldMap

    /// 自动保存：worldMappingStatus == .mapped 时保存（仅一次）。
    @MainActor
    func autoSaveWorldMap(
        arView: ARView,
        force: Bool = false
    ) async -> Bool {
        if autoSaved, !force { return true }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard let frame = arView.session.currentFrame else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            lastMappingStatusText = mappingStatusText(
                frame.worldMappingStatus
            )
            if frame.worldMappingStatus == .mapped {
                do {
                    let map: ARWorldMap =
                        try await withCheckedThrowingContinuation {
                            continuation in
                            arView.session.getCurrentWorldMap {
                                worldMap, error in
                                if let worldMap {
                                    continuation.resume(
                                        returning: worldMap
                                    )
                                } else {
                                    continuation.resume(
                                        throwing: error
                                            ?? NSError(
                                                domain: "SpatialSession",
                                                code: 1,
                                                userInfo: [
                                                    NSLocalizedDescriptionKey:
                                                        "getCurrentWorldMap 返回空"
                                                ]
                                            )
                                    )
                                }
                            }
                        }
                    worldMap = map
                    autoSaved = true
                    setState(
                        .tracking,
                        text: "WorldMap 已自动保存（\(map.anchors.count) 锚点，mapped）"
                    )
                    return true
                } catch {
                    setState(
                        .tracking,
                        text: "WorldMap 保存失败：\(error.localizedDescription)"
                    )
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        setState(
            .tracking,
            text: "WorldMap 未保存：worldMappingStatus=\(lastMappingStatusText)（等待 mapped）"
        )
        return false
    }

    /// 用 initialWorldMap 重启（唯一允许 resetTracking 处）→ RELOCALIZING。
    @MainActor
    func loadWorldMap(arView: ARView) -> Bool {
        guard let worldMap else {
            setState(.spatialDegraded, text: "无 WorldMap，无法恢复")
            return false
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = worldMap
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(
            .meshWithClassification
        ) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.environmentTexturing = .automatic
        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        relocalizeStart = Date()
        setState(
            .relocalizing,
            text: "ARWorldMap recovery 已触发（RELOCALIZING…请缓慢移动手机观察已扫描区域）"
        )
        return true
    }

    // MARK: - 状态机

    /// 轮询：tracking 状态 + 测量健康（hitRate）推进状态机。
    @MainActor
    func poll(
        arView: ARView,
        hitRate: Double?
    ) {
        guard let frame = arView.session.currentFrame else { return }
        let tracking = frame.camera.trackingState

        switch tracking {
        case .normal:
            if state == .relocalizing {
                setState(
                    .recovered,
                    text: "recovery 成功：RECOVERED（tracking normal）"
                )
                setState(.tracking, text: "TRACKING（已恢复）")
            } else if let hitRate, hitRate < 0.8 {
                setState(
                    .spatialDegraded,
                    text: String(
                        format: "SPATIAL_DEGRADED（命中率 %.1f%% <80%%）",
                        hitRate * 100
                    )
                )
            } else if state != .tracking {
                setState(.tracking, text: "TRACKING（normal）")
            }
        case .limited:
            if state == .relocalizing {
                setState(
                    .relocalizing,
                    text: "RELOCALIZING…（等待 tracking normal）"
                )
            } else {
                setState(
                    .spatialDegraded,
                    text: "SPATIAL_DEGRADED（tracking limited）"
                )
            }
        case .notAvailable:
            setState(.unsafe, text: "UNSAFE（tracking notAvailable）")
        @unknown default:
            setState(.unsafe, text: "UNSAFE（tracking unknown）")
        }
    }

    /// 是否允许拍照/测量（relocalizing 禁测量）。
    var isMeasurementAllowed: Bool {
        state != .relocalizing && state != .unsafe
    }

    /// 当前测量模式（诊断/持久化标注）。
    var measurementMode: String {
        state == .recovered ? "recovered" : "normal"
    }

    // MARK: - 工具

    private func setState(
        _ newState: SpatialSessionState,
        text: String
    ) {
        let changed = state != newState || lastDiagnostic != text
        state = newState
        lastDiagnostic = text
        if changed {
            onLog?(text)
        }
    }

    private func mappingStatusText(
        _ status: ARFrame.WorldMappingStatus
    ) -> String {
        switch status {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }
}
