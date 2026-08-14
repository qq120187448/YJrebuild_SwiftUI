import ARKit
import RoomPlan
import simd

/// P4C-Drift 第一阶段（专家批准）：只做“漂移检测/诊断”，不改变测量结果。
///
/// 扫描完成（finishRoomReview）时在墙 A / 墙 B / 地面放置 ARAnchor 并记录初始位姿；
/// 轮询 `currentFrame.anchors` 计算各锚点当前位姿 → 平移 mm / 旋转° / 一致性，
/// 供真机“3 次走动测试”验证锚点变化能否稳定反映 4C 世界漂移。
final class AnchorDriftTracker {

    struct PlacedAnchor {
        let surfaceID: UUID
        let label: String
        let anchor: ARAnchor
        let initialTransform: simd_float4x4
    }

    struct DriftSample {
        let timestamp: Date
        let trackingState: String
        let drifts: [(label: String, translationMM: Double, rotationDeg: Double)]
        let maxTranslationMM: Double
        let consistencyMM: Double

        var text: String {
            let parts = drifts.map {
                String(
                    format: "%@ %.1fmm/%.1f°",
                    $0.label,
                    $0.translationMM,
                    $0.rotationDeg
                )
            }.joined(separator: " · ")
            return "漂移 \(parts) · 一致性(Δmax-min) \(String(format: "%.1f", consistencyMM))mm · tracking=\(trackingState)"
        }
    }

    private(set) var placedAnchors: [PlacedAnchor] = []

    /// 在墙 A / 墙 B / 地面放置锚点（尽力而为，至少 1 个）。
    /// 返回实际放置数量；调用前先移除旧锚点，避免重复扫描累积。
    @discardableResult
    func place(
        surfaces: [CapturedRoom.Surface],
        session: ARSession
    ) -> Int {
        removeAll(session: session)
        var count = 0
        for (label, surface) in Self.selectSurfaces(surfaces) {
            let anchor = ARAnchor(name: label, transform: surface.transform)
            session.add(anchor: anchor)
            placedAnchors.append(
                PlacedAnchor(
                    surfaceID: surface.identifier,
                    label: label,
                    anchor: anchor,
                    initialTransform: surface.transform
                )
            )
            count += 1
        }
        return count
    }

    func removeAll(session: ARSession) {
        for item in placedAnchors {
            session.remove(anchor: item.anchor)
        }
        placedAnchors.removeAll()
    }

    /// 从当前帧读取各锚点最新位姿并计算漂移；无帧或无线索返回 nil。
    func sample(session: ARSession) -> DriftSample? {
        guard let frame = session.currentFrame else { return nil }
        let tracking = Self.trackingStateText(frame.camera.trackingState)
        let anchors = frame.anchors
        var drifts: [(label: String, translationMM: Double, rotationDeg: Double)] = []
        for item in placedAnchors {
            guard let current = anchors
                .first(where: { $0.identifier == item.anchor.identifier })?
                .transform else {
                continue
            }
            let delta = current.position - item.initialTransform.position
            let translationMM = Double(simd_length(delta)) * 1000
            let rotationDeg = Self.rotationDeltaDeg(
                item.initialTransform,
                current
            )
            drifts.append((item.label, translationMM, rotationDeg))
        }
        guard !drifts.isEmpty else { return nil }
        let translations = drifts.map { $0.translationMM }
        let maxT = translations.max() ?? 0
        let minT = translations.min() ?? 0
        return DriftSample(
            timestamp: Date(),
            trackingState: tracking,
            drifts: drifts,
            maxTranslationMM: maxT,
            consistencyMM: maxT - minT
        )
    }

    // MARK: - 表面选择：墙 A（最大墙）、墙 B（离 A 最远）、地面

    private static func selectSurfaces(
        _ surfaces: [CapturedRoom.Surface]
    ) -> [(label: String, surface: CapturedRoom.Surface)] {
        let walls = surfaces
            .filter { $0.category == .wall }
            .sorted { area($0) > area($1) }
        var result: [(label: String, surface: CapturedRoom.Surface)] = []

        if let wallA = walls.first {
            result.append(("墙A", wallA))
            let centerA = wallA.transform.position
            if let wallB = walls
                .filter({ $0.identifier != wallA.identifier })
                .max(by: {
                    simd_distance($0.transform.position, centerA)
                        < simd_distance($1.transform.position, centerA)
                }) {
                result.append(("墙B", wallB))
            }
        }
        if let floor = surfaces.first(where: { $0.category == .floor }) {
            result.append(("地面", floor))
        }
        return result
    }

    private static func area(_ surface: CapturedRoom.Surface) -> Float {
        abs(surface.dimensions.x * surface.dimensions.y)
    }

    private static func rotationDeltaDeg(
        _ a: simd_float4x4,
        _ b: simd_float4x4
    ) -> Double {
        let ra = simd_float3x3(columns: (
            SIMD3<Float>(a.columns.0.x, a.columns.0.y, a.columns.0.z),
            SIMD3<Float>(a.columns.1.x, a.columns.1.y, a.columns.1.z),
            SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        ))
        let rb = simd_float3x3(columns: (
            SIMD3<Float>(b.columns.0.x, b.columns.0.y, b.columns.0.z),
            SIMD3<Float>(b.columns.1.x, b.columns.1.y, b.columns.1.z),
            SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z)
        ))
        let relative = rb * ra.transpose
        let trace = relative.columns.0.x
            + relative.columns.1.y
            + relative.columns.2.z
        let cosAngle = min(1, max(-1, (trace - 1) / 2))
        return Double(acos(cosAngle)) * 180 / .pi
    }

    private static func trackingStateText(
        _ state: ARCamera.TrackingState?
    ) -> String {
        guard let state else { return "nil" }
        switch state {
        case .normal:
            return "normal"
        case .limited:
            return "limited"
        case .notAvailable:
            return "notAvailable"
        @unknown default:
            return "unknown"
        }
    }
}
