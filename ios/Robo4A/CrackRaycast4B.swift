import ARKit
import Foundation
import RealityKit
import RoomPlan
import UIKit

extension simd_float4x4 {
    var position: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

// MARK: - 单点结果

struct Raycast4BPointResult {
    let source: CrackPoint
    let world: SIMD3<Float>?
    let projected: CGPoint?
    let errorPx: Double?
    let missReason: String?
    let raycastResultsCount: Int?
    let firstRaycastDistance: Double?
    let raycastAnchorType: String?
    let raycastTarget: String?
    let raycastTargetAlignment: String?
    let existingWorld: SIMD3<Float>?
    let existingFirstRaycastDistance: Double?
    let existingRaycastAnchorType: String?
    let existingRaycastResultsCount: Int?
}

// MARK: - 单条折线结果

struct Raycast4BPolylineResult {
    let index: Int
    let sampleCount: Int
    let hitCount: Int
    let errors: [Double]
    let orderInversions: Int
    let orderPairs: Int
    let points: [Raycast4BPointResult]

    var avgError: Double {
        errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
    }
}

// MARK: - 4B 基线报告

struct Raycast4BReport {
    let scenario: String
    let totalSamples: Int
    let hitCount: Int
    let validCount: Int
    let errors: [Double]
    let missReasons: [String: Int]
    let polylines: [Raycast4BPolylineResult]
    /// 每条裂缝的简化折线（≤7 段）raycast 结果，用于 4D.1 长度计算。
    let centerlinePolylines: [Raycast4BPolylineResult]
    let orderInversions: Int
    let orderPairs: Int
    let captureToRaycastDelayMs: Double?

    var hitRate: Double {
        totalSamples == 0 ? 0 : Double(hitCount) / Double(totalSamples)
    }

    var validRatio: Double {
        totalSamples == 0 ? 0 : Double(validCount) / Double(totalSamples)
    }

    var avgError: Double {
        errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
    }

    var maxError: Double {
        errors.max() ?? 0
    }

    var p95Error: Double {
        guard !errors.isEmpty else { return 0 }
        let sorted = errors.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return sorted[index]
    }

    var orderConsistency: Double {
        orderPairs == 0 ? 1 : 1 - Double(orderInversions) / Double(orderPairs)
    }

    func text() -> String {
        var lines: [String] = []
        lines.append("4B 基线报告")
        lines.append("场景：\(scenario)")
        if let delay = captureToRaycastDelayMs {
            lines.append(String(format: "Capture→Raycast 延迟：%.0f ms", delay))
        }
        lines.append("总采样点：\(totalSamples)")
        lines.append("Mesh 命中点：\(hitCount)")
        lines.append(String(format: "Mesh 命中率：%.1f%%（目标 ≥90%%）", hitRate * 100))
        lines.append(String(format: "有效 3D 点比例：%.1f%%（目标 ≥命中率）", validRatio * 100))
        lines.append(String(format: "平均重投影误差：%.2f px", avgError))
        lines.append(String(format: "最大重投影误差：%.2f px", maxError))
        lines.append(String(format: "P95 重投影误差：%.2f px", p95Error))
        lines.append(String(
            format: "点序一致性：%.1f%%（倒置 %d/%d 对，目标 100%%）",
            orderConsistency * 100,
            orderInversions,
            orderPairs
        ))
        if missReasons.isEmpty {
            lines.append("miss 原因统计：无")
        } else {
            let reasons = missReasons
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            lines.append("miss 原因统计：\(reasons)")
        }
        lines.append("折线明细：")
        for polyline in polylines {
            lines.append(String(
                format: "[%d] 采样点 %d | 命中 %d | 平均误差 %.2f px | 顺序倒置 %d/%d",
                polyline.index + 1,
                polyline.sampleCount,
                polyline.hitCount,
                polyline.avgError,
                polyline.orderInversions,
                polyline.orderPairs
            ))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 4B 测量

enum CrackRaycast4B {

    static let scenarios = [
        "正对墙面 ~1m",
        "正对墙面 ~2m",
        "斜视 15°",
        "斜视 30°",
        "斜视 45°",
        "小裂缝",
        "大裂缝",
        "墙面边缘",
        "白墙低纹理"
    ]

    /// 4B 核心：pixel P → ARView.raycast → world W → arView.project → pixel P'。
    /// 生产路径固定使用已验证的 ARView.raycast；captureTime 仅用于统计延迟指标。
    @MainActor
    static func measure(
        arView: ARView,
        scenario: String,
        samplePointsPerPolyline: [[CrackPoint]],
        imageToViewScale: CGFloat,
        captureTime: Date? = nil,
        centerlinesPerPolyline: [[CrackPoint]] = []
    ) -> Raycast4BReport {
        let raycastStart = Date()
        var totalSamples = 0
        var hitCount = 0
        var validCount = 0
        var errors: [Double] = []
        var missReasons: [String: Int] = [:]
        var polylines: [Raycast4BPolylineResult] = []
        var orderInversions = 0
        var orderPairs = 0

        // 单点 raycast + 反投影（供密集采样点与简化折线共用）。
        func raycastOnePoint(_ point: CrackPoint) -> Raycast4BPointResult {
            totalSamples += 1
            let viewPoint = CGPoint(
                x: CGFloat(point.x) * imageToViewScale,
                y: CGFloat(point.y) * imageToViewScale
            )
            let estimatedResults = arView.raycast(
                from: viewPoint,
                allowing: .estimatedPlane,
                alignment: .any
            )
            let existingResults = arView.raycast(
                from: viewPoint,
                allowing: .existingPlaneGeometry,
                alignment: .any
            )
            let cameraPosition = arView.session.currentFrame?.camera.transform.position
            let existingWorld = existingResults.first?.worldTransform.position
            let existingFirstRaycastDistance: Double? = {
                guard let existingWorld, let cameraPosition else { return nil }
                return Double(simd_distance(existingWorld, cameraPosition))
            }()
            let existingRaycastAnchorType = existingResults.first.map {
                Self.anchorTypeName($0.anchor)
            }

            guard let result = estimatedResults.first else {
                missReasons["noRaycastResult", default: 0] += 1
                return Raycast4BPointResult(
                    source: point,
                    world: nil,
                    projected: nil,
                    errorPx: nil,
                    missReason: "noRaycastResult",
                    raycastResultsCount: 0,
                    firstRaycastDistance: nil,
                    raycastAnchorType: nil,
                    raycastTarget: nil,
                    raycastTargetAlignment: nil,
                    existingWorld: existingWorld,
                    existingFirstRaycastDistance: existingFirstRaycastDistance,
                    existingRaycastAnchorType: existingRaycastAnchorType,
                    existingRaycastResultsCount: existingResults.count
                )
            }

            hitCount += 1
            let world = result.worldTransform.position
            let firstDistance = cameraPosition.map {
                Double(simd_distance(world, $0))
            }
            let raycastAnchorType = Self.anchorTypeName(result.anchor)
            let raycastTarget = Self.targetName(result.target)
            let raycastTargetAlignment = Self.alignmentName(result.targetAlignment)

            guard let projected = arView.project(world) else {
                missReasons["projectNil", default: 0] += 1
                return Raycast4BPointResult(
                    source: point,
                    world: world,
                    projected: nil,
                    errorPx: nil,
                    missReason: "projectNil",
                    raycastResultsCount: estimatedResults.count,
                    firstRaycastDistance: firstDistance,
                    raycastAnchorType: raycastAnchorType,
                    raycastTarget: raycastTarget,
                    raycastTargetAlignment: raycastTargetAlignment,
                    existingWorld: existingWorld,
                    existingFirstRaycastDistance: existingFirstRaycastDistance,
                    existingRaycastAnchorType: existingRaycastAnchorType,
                    existingRaycastResultsCount: existingResults.count
                )
            }

            validCount += 1
            let error = hypot(
                Double(projected.x - viewPoint.x),
                Double(projected.y - viewPoint.y)
            )
            errors.append(error)
            return Raycast4BPointResult(
                source: point,
                world: world,
                projected: projected,
                errorPx: error,
                missReason: nil,
                raycastResultsCount: estimatedResults.count,
                firstRaycastDistance: firstDistance,
                raycastAnchorType: raycastAnchorType,
                raycastTarget: raycastTarget,
                raycastTargetAlignment: raycastTargetAlignment,
                existingWorld: existingWorld,
                existingFirstRaycastDistance: existingFirstRaycastDistance,
                existingRaycastAnchorType: existingRaycastAnchorType,
                existingRaycastResultsCount: existingResults.count
            )
        }

        for (index, polyline) in samplePointsPerPolyline.enumerated() {
            var points: [Raycast4BPointResult] = []
            var polyErrors: [Double] = []
            var polyHits = 0

            for point in polyline {
                let result = raycastOnePoint(point)
                points.append(result)
                if result.world != nil {
                    polyHits += 1
                }
                if let error = result.errorPx {
                    polyErrors.append(error)
                }
            }

            // 点序一致性：相邻采样点与其反投影点的屏幕方向应一致（dot ≥ 0）
            var polyInversions = 0
            var polyPairs = 0
            for pairIndex in 0..<(points.count - 1) {
                guard let a = points[pairIndex].projected,
                      let b = points[pairIndex + 1].projected else {
                    continue
                }
                let sourceA = CGPoint(
                    x: CGFloat(points[pairIndex].source.x) * imageToViewScale,
                    y: CGFloat(points[pairIndex].source.y) * imageToViewScale
                )
                let sourceB = CGPoint(
                    x: CGFloat(points[pairIndex + 1].source.x) * imageToViewScale,
                    y: CGFloat(points[pairIndex + 1].source.y) * imageToViewScale
                )
                let screenDelta = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let sourceDelta = CGPoint(x: sourceB.x - sourceA.x, y: sourceB.y - sourceA.y)
                let dot = screenDelta.x * sourceDelta.x
                    + screenDelta.y * sourceDelta.y
                polyPairs += 1
                if dot < 0 {
                    polyInversions += 1
                }
            }
            orderInversions += polyInversions
            orderPairs += polyPairs

            polylines.append(
                Raycast4BPolylineResult(
                    index: index,
                    sampleCount: polyline.count,
                    hitCount: polyHits,
                    errors: polyErrors,
                    orderInversions: polyInversions,
                    orderPairs: polyPairs,
                    points: points
                )
            )
        }

        var centerlinePolylines: [Raycast4BPolylineResult] = []
        for (index, centerline) in centerlinesPerPolyline.enumerated() {
            var points: [Raycast4BPointResult] = []
            var centerlineHits = 0
            for point in centerline {
                let result = raycastOnePoint(point)
                if result.world != nil {
                    centerlineHits += 1
                }
                points.append(result)
            }
            centerlinePolylines.append(
                Raycast4BPolylineResult(
                    index: index,
                    sampleCount: centerline.count,
                    hitCount: centerlineHits,
                    errors: [],
                    orderInversions: 0,
                    orderPairs: 0,
                    points: points
                )
            )
        }

        return Raycast4BReport(
            scenario: scenario,
            totalSamples: totalSamples,
            hitCount: hitCount,
            validCount: validCount,
            errors: errors,
            missReasons: missReasons,
            polylines: polylines,
            centerlinePolylines: centerlinePolylines,
            orderInversions: orderInversions,
            orderPairs: orderPairs,
            captureToRaycastDelayMs: captureTime.map {
                raycastStart.timeIntervalSince($0) * 1000
            }
        )
    }

    /// 拍照时刻帧锁定：用拍照瞬间的 ARFrame 相机射线与 RoomPlan Surface 平面求交。
    /// 不暂停 ARSession，保留 AR 红线投影；移动设备不影响拍照帧的对应关系。
    @MainActor
    static func measureFrameLocked(
        arView: ARView,
        frame: ARFrame,
        room: CapturedRoom,
        samplePointsPerPolyline: [[CrackPoint]],
        imageToViewScale: CGFloat,
        captureTime: Date? = nil,
        centerlinesPerPolyline: [[CrackPoint]] = []
    ) -> Raycast4BReport {
        let raycastStart = Date()
        let surfaces =
            room.walls + room.floors + room.doors + room.windows + room.openings
        let orientation =
            arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let displayTransform = frame.displayTransform(
            for: orientation,
            viewportSize: arView.bounds.size
        )
        let inverseDisplay = displayTransform.inverted()
        let imageWidth = CGFloat(frame.camera.imageResolution.width)
        let imageHeight = CGFloat(frame.camera.imageResolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let cameraTransform = frame.camera.transform
        let rotation = simd_float3x3(columns: (
            SIMD3<Float>(
                cameraTransform.columns.0.x,
                cameraTransform.columns.0.y,
                cameraTransform.columns.0.z
            ),
            SIMD3<Float>(
                cameraTransform.columns.1.x,
                cameraTransform.columns.1.y,
                cameraTransform.columns.1.z
            ),
            SIMD3<Float>(
                cameraTransform.columns.2.x,
                cameraTransform.columns.2.y,
                cameraTransform.columns.2.z
            )
        ))
        let cameraOrigin = cameraTransform.position

        var totalSamples = 0
        var hitCount = 0
        var validCount = 0
        var missReasons: [String: Int] = [:]
        var polylines: [Raycast4BPolylineResult] = []

        // 单点：拍照帧相机射线 → RoomPlan Surface 平面求交。
        func framePoint(_ point: CrackPoint) -> Raycast4BPointResult {
            totalSamples += 1
            let viewPoint = CGPoint(
                x: CGFloat(point.x) * imageToViewScale,
                y: CGFloat(point.y) * imageToViewScale
            )
            let normalized = viewPoint.applying(inverseDisplay)
            let sensorX = Float(normalized.x * imageWidth)
            let sensorY = Float(normalized.y * imageHeight)
            let localDirection = SIMD3<Float>(
                (sensorX - cx) / fx,
                (sensorY - cy) / fy,
                -1
            )
            let worldDirection = simd_normalize(
                rotation * localDirection
            )

            guard let hit = Self.nearestSurfaceIntersection(
                origin: cameraOrigin,
                direction: worldDirection,
                surfaces: surfaces
            ) else {
                missReasons["noSurfaceIntersection", default: 0] += 1
                return Raycast4BPointResult(
                    source: point,
                    world: nil,
                    projected: nil,
                    errorPx: nil,
                    missReason: "noSurfaceIntersection",
                    raycastResultsCount: 0,
                    firstRaycastDistance: nil,
                    raycastAnchorType: nil,
                    raycastTarget: nil,
                    raycastTargetAlignment: nil,
                    existingWorld: nil,
                    existingFirstRaycastDistance: nil,
                    existingRaycastAnchorType: nil,
                    existingRaycastResultsCount: 0
                )
            }

            hitCount += 1
            validCount += 1
            let distance = Double(
                simd_distance(hit.world, cameraOrigin)
            )
            return Raycast4BPointResult(
                source: point,
                world: hit.world,
                projected: nil,
                errorPx: nil,
                missReason: nil,
                raycastResultsCount: 1,
                firstRaycastDistance: distance,
                raycastAnchorType: nil,
                raycastTarget: "estimatedPlane",
                raycastTargetAlignment: "any",
                existingWorld: nil,
                existingFirstRaycastDistance: nil,
                existingRaycastAnchorType: nil,
                existingRaycastResultsCount: 0
            )
        }

        for (index, polyline) in samplePointsPerPolyline.enumerated() {
            var points: [Raycast4BPointResult] = []
            var polyHits = 0

            for point in polyline {
                let result = framePoint(point)
                points.append(result)
                if result.world != nil {
                    polyHits += 1
                }
            }

            polylines.append(
                Raycast4BPolylineResult(
                    index: index,
                    sampleCount: polyline.count,
                    hitCount: polyHits,
                    errors: [],
                    orderInversions: 0,
                    orderPairs: 0,
                    points: points
                )
            )
        }

        var centerlinePolylines: [Raycast4BPolylineResult] = []
        for (index, centerline) in centerlinesPerPolyline.enumerated() {
            var points: [Raycast4BPointResult] = []
            var centerlineHits = 0
            for point in centerline {
                let result = framePoint(point)
                if result.world != nil {
                    centerlineHits += 1
                }
                points.append(result)
            }
            centerlinePolylines.append(
                Raycast4BPolylineResult(
                    index: index,
                    sampleCount: centerline.count,
                    hitCount: centerlineHits,
                    errors: [],
                    orderInversions: 0,
                    orderPairs: 0,
                    points: points
                )
            )
        }

        return Raycast4BReport(
            scenario: "",
            totalSamples: totalSamples,
            hitCount: hitCount,
            validCount: validCount,
            errors: [],
            missReasons: missReasons,
            polylines: polylines,
            centerlinePolylines: centerlinePolylines,
            orderInversions: 0,
            orderPairs: 0,
            captureToRaycastDelayMs: captureTime.map {
                raycastStart.timeIntervalSince($0) * 1000
            }
        )
    }

    private struct FrameSurfaceHit {
        let world: SIMD3<Float>
        let distance: Float
    }

    private static func nearestSurfaceIntersection(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        surfaces: [CapturedRoom.Surface],
        toleranceM: Float = 0.02
    ) -> FrameSurfaceHit? {
        var best: FrameSurfaceHit?
        for surface in surfaces {
            let inverse = surface.transform.inverse
            let localOrigin4 = inverse
                * SIMD4<Float>(origin.x, origin.y, origin.z, 1)
            let localDirection4 = inverse
                * SIMD4<Float>(direction.x, direction.y, direction.z, 0)
            let localOrigin = SIMD3<Float>(
                localOrigin4.x,
                localOrigin4.y,
                localOrigin4.z
            )
            let localDirection = SIMD3<Float>(
                localDirection4.x,
                localDirection4.y,
                localDirection4.z
            )
            guard abs(localDirection.z) > 0.0001 else { continue }
            let t = -localOrigin.z / localDirection.z
            guard t > 0 else { continue }
            let localHit = localOrigin + localDirection * t
            let halfX = surface.dimensions.x * 0.5 + toleranceM
            let halfY = surface.dimensions.y * 0.5 + toleranceM
            let halfZ = surface.dimensions.z * 0.5 + toleranceM
            guard abs(localHit.x) <= halfX,
                  abs(localHit.y) <= halfY,
                  abs(localHit.z) <= halfZ else {
                continue
            }
            let world4 = surface.transform
                * SIMD4<Float>(localHit.x, localHit.y, localHit.z, 1)
            let world = SIMD3<Float>(world4.x, world4.y, world4.z)
            let distance = simd_length(world - origin)
            if best == nil || distance < best!.distance {
                best = FrameSurfaceHit(world: world, distance: distance)
            }
        }
        return best
    }

    private static func anchorTypeName(_ anchor: ARAnchor?) -> String {
        guard let anchor else { return "nil" }
        if anchor is ARPlaneAnchor { return "ARPlaneAnchor" }
        if anchor is ARMeshAnchor { return "ARMeshAnchor" }
        if anchor is ARImageAnchor { return "ARImageAnchor" }
        if anchor is ARFaceAnchor { return "ARFaceAnchor" }
        if anchor is ARObjectAnchor { return "ARObjectAnchor" }
        return String(describing: type(of: anchor))
    }

    private static func targetName(_ target: ARRaycastQuery.Target) -> String {
        switch target {
        case .estimatedPlane:
            return "estimatedPlane"
        case .existingPlaneGeometry:
            return "existingPlaneGeometry"
        case .existingPlaneInfinite:
            return "existingPlaneInfinite"
        @unknown default:
            return "unknown"
        }
    }

    private static func alignmentName(
        _ alignment: ARRaycastQuery.TargetAlignment
    ) -> String {
        switch alignment {
        case .any:
            return "any"
        case .horizontal:
            return "horizontal"
        case .vertical:
            return "vertical"
        @unknown default:
            return "unknown"
        }
    }
}
