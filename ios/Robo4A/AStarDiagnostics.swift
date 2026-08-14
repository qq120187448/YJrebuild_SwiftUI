import ARKit
import Foundation
import RealityKit
import RoomPlan
import UIKit

/// A' 三轨对照实验（专家批准，2026-08-14）：
/// 同一批采样点同时计算三套结果：
///   Raw   —— estimatedPlane 原始世界点 → 20mm 正式分配（snapMaxM=nil）
///   Snap  —— 法向吸附到最近 RoomPlan Surface（debugSafetyCap=150mm，仅实验）
///   Isect —— 拍照帧相机射线 → RoomPlan Surface 直接求交（方案 C 验证基准）
/// 输出：assignment、snapDistance P50/P90/P95/max、三路 reprojection、
/// 三路 UV length、A vs C 长度差异、trackingState、anchor 门控。
/// 仅诊断，不改变主测量路径。
enum AStarDiagnostics {

    struct RunResult {
        let total: Int
        let assignmentRaw: Int
        let assignmentSnap: Int
        let assignmentIsect: Int
        let snapDistancesMM: [Double]
        let rawErrorsPx: [Double]
        let snapErrorsPx: [Double]
        let isectErrorsPx: [Double]
        let uvLengthRawM: Double?
        let uvLengthSnapM: Double?
        let uvLengthIsectM: Double?
        let trackingState: String
        let anchorConsistencyMM: Double?

        var text: String {
            var lines = ["A' 三轨对照（Debug）："]
            lines.append("采样点 \(total)")
            lines.append(
                String(
                    format: "assignment: Raw=%d(%.1f%%) · Snap=%d(%.1f%%) · Isect=%d(%.1f%%)",
                    assignmentRaw,
                    total == 0 ? 0 : Double(assignmentRaw) / Double(total) * 100,
                    assignmentSnap,
                    total == 0 ? 0 : Double(assignmentSnap) / Double(total) * 100,
                    assignmentIsect,
                    total == 0 ? 0 : Double(assignmentIsect) / Double(total) * 100
                )
            )
            let snap = AStarDiagnostics.percentileText(snapDistancesMM)
            lines.append("snapDistance(debugSafetyCap=150mm): \(snap)")
            lines.append(
                "reprojection(px): Raw \(AStarDiagnostics.statsText(rawErrorsPx)) · Snap \(AStarDiagnostics.statsText(snapErrorsPx)) · Isect \(AStarDiagnostics.statsText(isectErrorsPx))"
            )
            lines.append(
                String(
                    format: "UV length(m): Raw %@ · Snap %@ · Isect %@ · |Snap-Isect|/Isect %@",
                    AStarDiagnostics.mText(uvLengthRawM),
                    AStarDiagnostics.mText(uvLengthSnapM),
                    AStarDiagnostics.mText(uvLengthIsectM),
                    AStarDiagnostics.diffText(uvLengthSnapM, uvLengthIsectM)
                )
            )
            lines.append(
                "门控: tracking=\(trackingState) · anchor=\(AStarDiagnostics.anchorStatusText(anchorConsistencyMM, tracking: trackingState))"
            )
            return lines.joined(separator: "\n")
        }
    }

    @MainActor
    static func run(
        arView: ARView,
        context: CaptureFrameSpatialContext?,
        room: CapturedRoom,
        raycast: Raycast4BReport,
        viewPointScale: CGFloat,
        trackingState: String,
        anchorConsistencyMM: Double?
    ) -> RunResult {
        let surfaces =
            room.walls + room.floors + room.doors + room.windows + room.openings

        var total = 0
        var assignmentRaw = 0
        var assignmentSnap = 0
        var assignmentIsect = 0
        var snapDistancesMM: [Double] = []
        var rawErrorsPx: [Double] = []
        var snapErrorsPx: [Double] = []
        var isectErrorsPx: [Double] = []
        var uvRaw: [(id: UUID?, u: Double?, v: Double?)] = []
        var uvSnap: [(id: UUID?, u: Double?, v: Double?)] = []
        var uvIsect: [(id: UUID?, u: Double?, v: Double?)] = []

        for polyline in raycast.polylines {
            for point in polyline.points {
                total += 1
                let viewPoint = CGPoint(
                    x: CGFloat(point.source.x) * viewPointScale,
                    y: CGFloat(point.source.y) * viewPointScale
                )
                guard let worldRaw = point.world else {
                    uvRaw.append((nil, nil, nil))
                    uvSnap.append((nil, nil, nil))
                    uvIsect.append((nil, nil, nil))
                    continue
                }

                // Raw：正式 20mm 分配（不吸附）
                let rawMapped = SurfaceUV4C.map(
                    world: worldRaw,
                    surfaces: surfaces,
                    toleranceM: 0.02,
                    snapMaxM: nil
                )
                if let rawMapped {
                    assignmentRaw += 1
                    uvRaw.append(
                        (
                            rawMapped.surface.identifier,
                            Double(rawMapped.local.x),
                            Double(rawMapped.local.y)
                        )
                    )
                } else {
                    uvRaw.append((nil, nil, nil))
                }

                // Snap：法向吸附（debugSafetyCap=150mm）
                let snapMapped = SurfaceUV4C.map(
                    world: worldRaw,
                    surfaces: surfaces,
                    toleranceM: 0.02,
                    snapMaxM: 0.15
                )
                if let snapMapped {
                    assignmentSnap += 1
                    uvSnap.append(
                        (
                            snapMapped.surface.identifier,
                            Double(snapMapped.local.x),
                            Double(snapMapped.local.y)
                        )
                    )
                    let rawLocal = SurfaceUV4C.surfaceLocal(
                        worldRaw,
                        surface: snapMapped.surface
                    )
                    snapDistancesMM.append(Double(abs(rawLocal.z)) * 1000)
                } else {
                    uvSnap.append((nil, nil, nil))
                }

                // Isect：拍照帧相机射线 → RoomPlan Surface 求交（方案 C 验证基准）
                var worldIsect: SIMD3<Float>?
                if let context {
                    let sensor = CaptureFrameSurfaceMapper.sensorPoint(
                        viewPoint: viewPoint,
                        displayTransform: context.displayTransform,
                        viewportSize: context.viewportSize,
                        imageWidth: context.imageResolution.width,
                        imageHeight: context.imageResolution.height
                    )
                    let fx = context.cameraIntrinsics.columns.0.x
                    let fy = context.cameraIntrinsics.columns.1.y
                    let cx = context.cameraIntrinsics.columns.2.x
                    let cy = context.cameraIntrinsics.columns.2.y
                    let localDirection = SIMD3<Float>(
                        (sensor.x - cx) / fx,
                        -(sensor.y - cy) / fy,
                        -1
                    )
                    let rotation = simd_float3x3(columns: (
                        SIMD3<Float>(
                            context.cameraTransform.columns.0.x,
                            context.cameraTransform.columns.0.y,
                            context.cameraTransform.columns.0.z
                        ),
                        SIMD3<Float>(
                            context.cameraTransform.columns.1.x,
                            context.cameraTransform.columns.1.y,
                            context.cameraTransform.columns.1.z
                        ),
                        SIMD3<Float>(
                            context.cameraTransform.columns.2.x,
                            context.cameraTransform.columns.2.y,
                            context.cameraTransform.columns.2.z
                        )
                    ))
                    let worldDirection = simd_normalize(
                        rotation * localDirection
                    )
                    worldIsect = CaptureFrameSurfaceMapper
                        .nearestSurfaceIntersection(
                            origin: context.cameraTransform.position,
                            direction: worldDirection,
                            surfaces: surfaces,
                            toleranceM: 0.02
                        )?.world
                }
                if let worldIsect,
                   let isectMapped = SurfaceUV4C.map(
                       world: worldIsect,
                       surfaces: surfaces,
                       toleranceM: 0.02,
                       snapMaxM: nil
                   ) {
                    assignmentIsect += 1
                    uvIsect.append(
                        (
                            isectMapped.surface.identifier,
                            Double(isectMapped.local.x),
                            Double(isectMapped.local.y)
                        )
                    )
                } else {
                    uvIsect.append((nil, nil, nil))
                }

                // 重投影闭环：World → Camera Projection → 与原像素误差
                if let projected = arView.project(worldRaw) {
                    rawErrorsPx.append(
                        hypot(
                            Double(projected.x - viewPoint.x),
                            Double(projected.y - viewPoint.y)
                        )
                    )
                }
                if let snapMapped,
                   let projected = arView.project(
                       snapWorld(
                           local: snapMapped.local,
                           surface: snapMapped.surface
                       )
                   ) {
                    snapErrorsPx.append(
                        hypot(
                            Double(projected.x - viewPoint.x),
                            Double(projected.y - viewPoint.y)
                        )
                    )
                }
                if let worldIsect,
                   let context,
                   let projected = projectToCaptureFrame(
                       worldIsect,
                       context: context
                   ) {
                    isectErrorsPx.append(
                        hypot(
                            Double(projected.x - viewPoint.x),
                            Double(projected.y - viewPoint.y)
                        )
                    )
                }
            }
        }

        return RunResult(
            total: total,
            assignmentRaw: assignmentRaw,
            assignmentSnap: assignmentSnap,
            assignmentIsect: assignmentIsect,
            snapDistancesMM: snapDistancesMM,
            rawErrorsPx: rawErrorsPx,
            snapErrorsPx: snapErrorsPx,
            isectErrorsPx: isectErrorsPx,
            uvLengthRawM: uvLength(uvRaw),
            uvLengthSnapM: uvLength(uvSnap),
            uvLengthIsectM: uvLength(uvIsect),
            trackingState: trackingState,
            anchorConsistencyMM: anchorConsistencyMM
        )
    }

    /// 拍照帧相机投影：world → 相机局部 → sensor 像素 → displayTransform → 屏幕点。
    /// 用于 Isect 路重投影（Isect 世界点基于拍照帧，不能用当前帧 arView.project）。
    private static func projectToCaptureFrame(
        _ world: SIMD3<Float>,
        context: CaptureFrameSpatialContext
    ) -> CGPoint? {
        let local4 = context.cameraTransform.inverse
            * SIMD4<Float>(world.x, world.y, world.z, 1)
        let depth = -local4.z
        guard depth > 0.001 else { return nil }
        let fx = context.cameraIntrinsics.columns.0.x
        let fy = context.cameraIntrinsics.columns.1.y
        let cx = context.cameraIntrinsics.columns.2.x
        let cy = context.cameraIntrinsics.columns.2.y
        let sensorX = fx * local4.x / depth + cx
        let sensorY = fy * local4.y / depth + cy
        let normalizedImage = CGPoint(
            x: CGFloat(sensorX) / context.imageResolution.width,
            y: CGFloat(sensorY) / context.imageResolution.height
        )
        let normalizedView = normalizedImage.applying(context.displayTransform)
        return CGPoint(
            x: normalizedView.x * context.viewportSize.width,
            y: normalizedView.y * context.viewportSize.height
        )
    }

    private static func snapWorld(
        local: SIMD3<Float>,
        surface: CapturedRoom.Surface
    ) -> SIMD3<Float> {
        let world4 = surface.transform
            * SIMD4<Float>(local.x, local.y, local.z, 1)
        return SIMD3<Float>(world4.x, world4.y, world4.z)
    }

    /// 连续同面 assigned 点 UV 长度（跨面/未分配断开）。
    private static func uvLength(
        _ points: [(id: UUID?, u: Double?, v: Double?)]
    ) -> Double? {
        var segments: [Double] = []
        var segmentLength = 0.0
        var segmentPoints = 0
        var prevID: UUID?
        var prevU: Double?
        var prevV: Double?
        for point in points {
            guard let u = point.u,
                  let v = point.v,
                  let id = point.id else {
                if segmentPoints >= 2 {
                    segments.append(segmentLength)
                }
                segmentLength = 0
                segmentPoints = 0
                prevID = nil
                prevU = nil
                prevV = nil
                continue
            }
            if prevID == id, let pu = prevU, let pv = prevV {
                segmentLength += hypot(u - pu, v - pv)
                segmentPoints += 1
            } else {
                if segmentPoints >= 2 {
                    segments.append(segmentLength)
                }
                segmentLength = 0
                segmentPoints = 1
            }
            prevID = id
            prevU = u
            prevV = v
        }
        if segmentPoints >= 2 {
            segments.append(segmentLength)
        }
        return segments.isEmpty ? nil : segments.reduce(0, +)
    }

    private static func percentileText(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "无" }
        let sorted = values.sorted()
        return String(
            format: "P50=%.1f P90=%.1f P95=%.1f max=%.1f mm",
            percentile(sorted, 50),
            percentile(sorted, 90),
            percentile(sorted, 95),
            sorted.last ?? 0
        )
    }

    private static func statsText(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "无" }
        let sorted = values.sorted()
        let avg = values.reduce(0, +) / Double(values.count)
        return String(
            format: "avg=%.1f max=%.1f P95=%.1f",
            avg,
            sorted.last ?? 0,
            percentile(sorted, 95)
        )
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = Double(sorted.count - 1) * p / 100.0
        let lower = Int(floor(rank))
        let upper = min(sorted.count - 1, Int(ceil(rank)))
        let fraction = rank - Double(lower)
        if lower == upper { return sorted[lower] }
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    private static func mText(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.3f", value)
    }

    private static func diffText(_ a: Double?, _ b: Double?) -> String {
        guard let a, let b, b > 0 else { return "-" }
        return String(format: "%.2f%%", abs(a - b) / b * 100)
    }

    private static func anchorStatusText(
        _ consistencyMM: Double?,
        tracking: String
    ) -> String {
        guard tracking == "normal" else {
            return "UNSAFE(tracking=\(tracking))"
        }
        guard let consistencyMM else { return "N/A" }
        if consistencyMM <= 5 {
            return "GOOD(\(String(format: "%.1f", consistencyMM))mm)"
        }
        if consistencyMM <= 10 {
            return "WARNING(\(String(format: "%.1f", consistencyMM))mm)"
        }
        return "UNSAFE(\(String(format: "%.1f", consistencyMM))mm)"
    }
}
