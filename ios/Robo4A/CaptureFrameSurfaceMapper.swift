import ARKit
import Foundation
import RoomPlan
import UIKit

/// 拍照瞬间空间上下文：创建后不可变，禁止被后续 ARFrame 覆盖。
struct CaptureFrameSpatialContext {
    let timestamp: TimeInterval
    let cameraTransform: simd_float4x4
    let cameraIntrinsics: simd_float3x3
    let imageResolution: CGSize
    let displayTransform: CGAffineTransform
}

/// 只负责：裂缝采样像素 → 拍照帧相机射线 → RoomPlan Surface → world。
/// 不承担 Mesh、Depth、RANSAC、Skeleton、NMS、Length、Dedup 等职责。
enum CaptureFrameSurfaceMapper {

    @MainActor
    static func map(
        arView: ARView,
        context: CaptureFrameSpatialContext,
        room: CapturedRoom,
        samplePointsPerPolyline: [[CrackPoint]],
        imageToViewScale: CGFloat,
        captureTime: Date? = nil
    ) -> Raycast4BReport {
        let raycastStart = Date()
        let surfaces =
            room.walls + room.floors + room.doors + room.windows + room.openings
        let displayTransform = context.displayTransform
        // ARView 内部没有直接保存帧，这里用上层传入的 context；
        // 屏幕像素与 sensor 像素的转换仍通过当前 ARView 的 viewport 计算。
        let imageWidth = context.imageResolution.width
        let imageHeight = context.imageResolution.height
        let intrinsics = context.cameraIntrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let cameraTransform = context.cameraTransform
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

        for (index, polyline) in samplePointsPerPolyline.enumerated() {
            var points: [Raycast4BPointResult] = []
            var polyHits = 0

            for point in polyline {
                totalSamples += 1
                let viewPoint = CGPoint(
                    x: CGFloat(point.x) * imageToViewScale,
                    y: CGFloat(point.y) * imageToViewScale
                )
                let sensorPoint = Self.sensorPoint(
                    viewPoint: viewPoint,
                    displayTransform: displayTransform,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
                let localDirection = SIMD3<Float>(
                    (sensorPoint.x - cx) / fx,
                    (sensorPoint.y - cy) / fy,
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
                    points.append(
                        Raycast4BPointResult(
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
                    )
                    continue
                }

                hitCount += 1
                polyHits += 1
                validCount += 1
                let distance = Double(
                    simd_distance(hit.world, cameraOrigin)
                )
                points.append(
                    Raycast4BPointResult(
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
                )
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

        return Raycast4BReport(
            scenario: "",
            totalSamples: totalSamples,
            hitCount: hitCount,
            validCount: validCount,
            errors: [],
            missReasons: missReasons,
            polylines: polylines,
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

    private static func sensorPoint(
        viewPoint: CGPoint,
        displayTransform: CGAffineTransform,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> SIMD3<Float> {
        let normalized = viewPoint.applying(displayTransform.inverted())
        return SIMD3<Float>(
            Float(normalized.x * imageWidth),
            Float(normalized.y * imageHeight),
            1
        )
    }
}
