import ARKit
import RealityKit
import RoomPlan

/// 4C-L：Long-Term Spatial Recovery（专家更新意见，2026-08-14）。
/// ARWorldMap recovery 提升为长期空间恢复主方案（替代自研 T_currentToRoom 修正）：
/// 正常持续工作 → snapDistance/tracking 检测失配 → 事件触发 recovery
/// → initialWorldMap 重启（relocalizing，禁测量）→ normal → Surface 校验 ≤20mm → 恢复测量。
/// 状态机：MEASUREMENT_READY → SPACE_WARNING(>20mm) → RELOCALIZATION_REQUIRED(>50mm)
/// → recovery → relocalizing → normal+alignment good → MEASUREMENT_READY；超时 → NEED_USER_RELOCALIZATION。
enum SpatialHealthState {
    case notReady
    case measurementReady
    case spaceWarning
    case relocalizationRequired
    case relocalizing
    case needUserRelocalization

    var text: String {
        switch self {
        case .notReady:
            return "未建立空间基准"
        case .measurementReady:
            return "空间就绪，可测量"
        case .spaceWarning:
            return "空间定位调整中…（暂不做高精度测量）"
        case .relocalizationRequired:
            return "空间失配，触发重定位"
        case .relocalizing:
            return "正在重新定位空间…请缓慢移动手机观察已扫描区域"
        case .needUserRelocalization:
            return "重定位超时，请回到刚才扫描过的区域"
        }
    }
}

/// 统一管理 WorldMap 保存/恢复、relocalization、tracking 状态（专家：SpatialSessionCoordinator 雏形）。
final class SpatialRecoveryManager {

    /// 状态变化日志回调（4C 接入累计日志）。
    var onLog: ((String) -> Void)?

    private(set) var worldMap: ARWorldMap?
    private(set) var state: SpatialHealthState = .notReady
    private(set) var lastHealthText = ""
    private var recoveryStart: Date?
    private var recoveryTimeout: TimeInterval = 30
    /// 去重：仅在状态或文本变化时记录一次。
    private var lastReportedText = ""

    /// 校验锚点（recovery 后用于 Surface alignment 检查）。
    private struct VerifyAnchor {
        let label: String
        let anchor: ARAnchor
        let roomPosition: SIMD3<Float>
    }
    private var verifyAnchors: [VerifyAnchor] = []

    // MARK: - WorldMap 保存

    /// RoomPlan 完成后保存基准 WorldMap；等待 worldMappingStatus == .mapped（最多 timeout）。
    @MainActor
    func saveWorldMap(
        session: ARSession,
        surfaces: [CapturedRoom.Surface],
        timeout: TimeInterval = 8
    ) async -> Bool {
        // 先放置校验锚点
        placeVerifyAnchors(surfaces: surfaces, session: session)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = session.currentFrame,
               frame.worldMappingStatus == .mapped {
                do {
                    let map: ARWorldMap = try await withCheckedThrowingContinuation {
                        continuation in
                        session.getCurrentWorldMap { worldMap, error in
                            if let worldMap {
                                continuation.resume(returning: worldMap)
                            } else {
                                continuation.resume(
                                    throwing: error
                                        ?? NSError(
                                            domain: "SpatialRecovery",
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
                    setState(
                        .measurementReady,
                        text: "WorldMap 已保存（\(map.anchors.count) 锚点，mapped）"
                    )
                    return true
                } catch {
                    setState(
                        .notReady,
                        text: "WorldMap 保存失败：\(error.localizedDescription)"
                    )
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        setState(
            .notReady,
            text: "worldMappingStatus 未达 mapped（超时），WorldMap 未保存"
        )
        return false
    }

    // MARK: - 健康评估

    /// 用测量得到的 snapDistance 与 tracking 评估空间健康，必要时返回"应触发 recovery"。
    @MainActor
    func evaluate(
        snapDistanceMM: Double?,
        tracking: String
    ) -> Bool {
        guard tracking == "normal" else {
            setState(
                .relocalizationRequired,
                text: "tracking=\(tracking)，空间失配"
            )
            return true
        }
        guard let snapDistanceMM else {
            setState(
                .relocalizationRequired,
                text: "无 snapDistance（未分配表面），空间失配"
            )
            return true
        }
        if snapDistanceMM <= 20 {
            setState(
                .measurementReady,
                text: String(
                    format: "空间健康 GOOD（snap %.1fmm ≤20）",
                    snapDistanceMM
                )
            )
            return false
        }
        if snapDistanceMM <= 50 {
            setState(
                .spaceWarning,
                text: String(
                    format: "空间 WARNING（snap %.1fmm，20~50）",
                    snapDistanceMM
                )
            )
            return false
        }
        setState(
            .relocalizationRequired,
            text: String(
                format: "空间失配 SPACE_LOST（snap %.1fmm >50），触发 recovery",
                snapDistanceMM
            )
        )
        return true
    }

    // MARK: - Recovery

    /// 事件触发式 recovery：用 initialWorldMap 重启 ARSession（唯一允许 resetTracking 的地方）。
    @MainActor
    func startRecovery(
        arView: ARView
    ) -> Bool {
        guard let worldMap else {
            setState(
                .relocalizationRequired,
                text: "无基准 WorldMap，无法 recovery"
            )
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
        setState(.relocalizing, text: "ARWorldMap recovery 已触发（relocalizing…）")
        recoveryStart = Date()
        return true
    }

    /// 轮询 recovery：等 normal → Surface 校验 → MEASUREMENT_READY；超时 → NEED_USER。
    @MainActor
    func pollRecovery(
        arView: ARView,
        surfaces: [CapturedRoom.Surface]
    ) {
        guard state == .relocalizing else { return }
        guard let recoveryStart else {
            setState(.relocalizationRequired, text: "recovery 状态异常，重新触发")
            return
        }
        guard Date().timeIntervalSince(recoveryStart) < recoveryTimeout else {
            setState(
                .needUserRelocalization,
                text: "recovery 超时（30s），请回到刚才扫描过的区域"
            )
            return
        }
        guard let frame = arView.session.currentFrame,
              frame.camera.trackingState == .normal else {
            setState(
                .relocalizing,
                text: "relocalizing…（等待 tracking normal）"
            )
            return
        }
        // normal 后校验 Surface alignment
        let snapMM = verifySnapDistance(
            arView: arView,
            surfaces: surfaces
        )
        if let snapMM, snapMM <= 20 {
            setState(
                .measurementReady,
                text: String(
                    format: "recovery 成功：normal + Surface alignment %.1fmm ≤20",
                    snapMM
                )
            )
        } else {
            setState(
                .needUserRelocalization,
                text: snapMM.map {
                    String(
                        format: "recovery 后 alignment 仍差（%.1fmm），请回到已扫描区域",
                        $0
                    )
                } ?? "recovery 后无表面观测，请回到已扫描区域"
            )
        }
    }

    /// 校验：对校验锚点 raycast → 最近表面法向距离（snapDistance）。
    @MainActor
    private func verifySnapDistance(
        arView: ARView,
        surfaces: [CapturedRoom.Surface]
    ) -> Double? {
        guard !verifyAnchors.isEmpty else { return nil }
        var distances: [Double] = []
        let viewport = arView.bounds
        for item in verifyAnchors {
            let worldPos = item.anchor.transform.position
            guard let screen = arView.project(worldPos) else { continue }
            guard screen.x >= 0, screen.x <= viewport.width,
                  screen.y >= 0, screen.y <= viewport.height else {
                continue
            }
            let results = arView.raycast(
                from: screen,
                allowing: .estimatedPlane,
                alignment: .any
            )
            guard let hit = results.first else { continue }
            let world = hit.worldTransform.position
            guard let mapped = SurfaceUV4C.map(
                world: world,
                surfaces: surfaces,
                toleranceM: 0.02,
                snapMaxM: 0.02
            ) else { continue }
            let local = SurfaceUV4C.surfaceLocal(world, surface: mapped.surface)
            distances.append(Double(abs(local.z)) * 1000)
        }
        guard !distances.isEmpty else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }

    /// 放置校验锚点（墙 1~2 中心 + 地面中心）。
    private func placeVerifyAnchors(
        surfaces: [CapturedRoom.Surface],
        session: ARSession
    ) {
        removeVerifyAnchors(session: session)
        let walls = surfaces.filter { $0.category == .wall }
        let floors = surfaces.filter { $0.category == .floor }
        var items: [(String, CapturedRoom.Surface)] = []
        for (index, wall) in walls.prefix(2).enumerated() {
            items.append(("校验墙\(index + 1)", wall))
        }
        if let floor = floors.first {
            items.append(("校验地面", floor))
        }
        for (label, surface) in items {
            let anchor = ARAnchor(
                name: label,
                transform: surface.transform
            )
            session.add(anchor: anchor)
            verifyAnchors.append(
                VerifyAnchor(
                    label: label,
                    anchor: anchor,
                    roomPosition: surface.transform.position
                )
            )
        }
    }

    func removeVerifyAnchors(session: ARSession) {
        for item in verifyAnchors {
            session.remove(anchor: item.anchor)
        }
        verifyAnchors.removeAll()
    }

    func reset(session: ARSession) {
        worldMap = nil
        state = .notReady
        lastHealthText = ""
        lastReportedText = ""
        recoveryStart = nil
        removeVerifyAnchors(session: session)
    }

    /// 是否允许测量（normal + alignment good）。
    var isMeasurementAllowed: Bool {
        state == .measurementReady
    }

    // MARK: - 状态设置（变化时写日志，去重）

    private func setState(
        _ newState: SpatialHealthState,
        text: String
    ) {
        let changed = state != newState || lastHealthText != text
        state = newState
        lastHealthText = text
        if changed, text != lastReportedText {
            lastReportedText = text
            onLog?(text)
        }
    }
}
