import ARKit
import CoreGraphics
import CoreVideo
import Foundation
import SceneKit
import simd
import UIKit

struct WallDefectPlane {
    let origin: SIMD3<Float>
    let normal: SIMD3<Float>
    let uAxis: SIMD3<Float>
    let vAxis: SIMD3<Float>
    let width: Double
    let height: Double
    let sampleCount: Int
    let source: String

    func makeSurface(id: UUID = UUID()) -> WallDefectSurface {
        WallDefectSurface(
            id: id,
            kind: .wall,
            label: "墙面",
            width: width,
            height: height,
            area: width * height,
            origin: double3(origin),
            uAxis: double3(uAxis * Float(width)),
            vAxis: double3(vAxis * Float(height)),
            normal: double3(normal)
        )
    }

    private func double3(_ value: SIMD3<Float>) -> [Double] {
        [Double(value.x), Double(value.y), Double(value.z)]
    }
}

/// Fits the wall/floor plane under the retake viewfinder from ARKit data.
/// Raycast plane anchors are preferred; LiDAR depth plane fitting is the
/// fallback so the crack length always has a metric reference plane.
enum WallDefectPlaneEstimator {

    static func estimate(frame: ARFrame, view: ARSCNView?) -> WallDefectPlane? {
        if let view, let raycast = raycastPlane(frame: frame, view: view) {
            return raycast
        }
        return depthPlane(frame: frame, view: view)
    }

    static func samePlane(
        _ lhs: WallDefectSurface,
        _ rhs: WallDefectSurface
    ) -> Bool {
        let a = WallDefectGeometry.planeNormal(for: lhs)
        let b = WallDefectGeometry.planeNormal(for: rhs)
        let aLength = simd_length(a)
        let bLength = simd_length(b)
        guard aLength > 0.0001, bLength > 0.0001 else { return false }
        let dot = simd_dot(a / aLength, b / bLength)
        guard abs(dot) > 0.9 else { return false }
        let originA = WallDefectGeometry.planeOrigin(for: lhs)
        let originB = WallDefectGeometry.planeOrigin(for: rhs)
        let offset = originB - originA
        let planeDistance = abs(
            simd_dot(offset, a / aLength)
        )
        return planeDistance < 0.15
    }

    private static func raycastPlane(
        frame: ARFrame,
        view: ARSCNView
    ) -> WallDefectPlane? {
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let targets: [ARRaycastQuery.Target] = [
            .existingPlaneGeometry,
            .estimatedPlane
        ]
        for target in targets {
            guard let query = view.raycastQuery(
                from: center,
                allowing: target,
                alignment: .any
            ), let result = view.session.raycast(query).first else {
                continue
            }
            let position = SIMD3<Float>(
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z
            )
            var normal = simd_normalize(SIMD3<Float>(
                result.worldTransform.columns.1.x,
                result.worldTransform.columns.1.y,
                result.worldTransform.columns.1.z
            ))
            let cameraPosition = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            if simd_dot(normal, cameraPosition - position) < 0 {
                normal = -normal
            }
            let axes = planeAxes(for: normal)
            return WallDefectPlane(
                origin: position,
                normal: normal,
                uAxis: axes.u,
                vAxis: axes.v,
                width: 20,
                height: 20,
                sampleCount: 1,
                source: "raycast"
            )
        }
        return nil
    }

    private static func depthPlane(
        frame: ARFrame,
        view: ARSCNView?
    ) -> WallDefectPlane? {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap
            ?? frame.sceneDepth?.depthMap else {
            return nil
        }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { return nil }

        let viewport = view?.bounds.size
            ?? CGSize(
                width: CGFloat(depthWidth),
                height: CGFloat(depthHeight)
            )
        let transform = frame.displayTransform(
            for: .portrait,
            viewportSize: viewport
        )
        let screenPoint = CGPoint(
            x: viewport.width * 0.5,
            y: viewport.height * 0.5
        )
        let imagePoint = screenPoint.applying(transform.inverted())
        let centerX = Int(imagePoint.x * CGFloat(depthWidth))
        let centerY = Int(imagePoint.y * CGFloat(depthHeight))
        guard centerX >= 0, centerY >= 0,
              centerX < depthWidth, centerY < depthHeight else {
            return nil
        }

        let offsets: [Int] = [-8, -4, 0, 4, 8]
        var grid: [[SIMD3<Float>?]] = []
        var points: [SIMD3<Float>] = []
        for dy in offsets {
            var row: [SIMD3<Float>?] = []
            for dx in offsets {
                let x = centerX + dx
                let y = centerY + dy
                guard let world = depthWorldPoint(
                    frame: frame,
                    depthMap: depthMap,
                    x: x,
                    y: y
                ) else {
                    row.append(nil)
                    continue
                }
                row.append(world)
                points.append(world)
            }
            grid.append(row)
        }
        guard points.count >= 8 else { return nil }

        var centroid = SIMD3<Float>.zero
        for point in points {
            centroid += point
        }
        centroid /= Float(points.count)

        var normalSum = SIMD3<Float>.zero
        var normalCount = 0
        for row in 0..<(grid.count - 1) {
            for column in 0..<(grid[row].count - 1) {
                guard let center = grid[row][column],
                      let right = grid[row][column + 1],
                      let down = grid[row + 1][column] else {
                    continue
                }
                let tangentX = right - center
                let tangentY = down - center
                guard simd_length(tangentX) > 0.002,
                      simd_length(tangentY) > 0.002 else {
                    continue
                }
                var normal = simd_normalize(
                    simd_cross(tangentY, tangentX)
                )
                let cameraPosition = SIMD3<Float>(
                    frame.camera.transform.columns.3.x,
                    frame.camera.transform.columns.3.y,
                    frame.camera.transform.columns.3.z
                )
                if simd_dot(normal, cameraPosition - center) < 0 {
                    normal = -normal
                }
                normalSum += normal
                normalCount += 1
            }
        }
        guard normalCount >= 4 else { return nil }
        let normal = simd_normalize(normalSum)
        let axes = planeAxes(for: normal)
        return WallDefectPlane(
            origin: centroid,
            normal: normal,
            uAxis: axes.u,
            vAxis: axes.v,
            width: 20,
            height: 20,
            sampleCount: points.count,
            source: "depth"
        )
    }

    private static func planeAxes(
        for normal: SIMD3<Float>
    ) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let reference: SIMD3<Float> = abs(normal.y) > 0.7
            ? SIMD3<Float>(0, 0, 1)
            : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(simd_cross(normal, reference))
        let v = simd_normalize(simd_cross(normal, u))
        return (u, v)
    }

    private static func depthWorldPoint(
        frame: ARFrame,
        depthMap: CVPixelBuffer,
        x: Int,
        y: Int
    ) -> SIMD3<Float>? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard x >= 4, y >= 4, x < width - 4, y < height - 4 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let pointer = base
            .advanced(by: y * bytesPerRow + x * MemoryLayout<Float32>.size)
            .assumingMemoryBound(to: Float32.self)
        let depthValue = pointer.pointee
        guard depthValue.isFinite, depthValue > 0.05, depthValue < 8 else {
            return nil
        }

        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let imageWidth = Float(frame.camera.imageResolution.width)
        let imageHeight = Float(frame.camera.imageResolution.height)
        let u = Float(x) * imageWidth / Float(width)
        let v = Float(y) * imageHeight / Float(height)
        let local = SIMD3<Float>(
            (u - cx) / fx * depthValue,
            -(v - cy) / fy * depthValue,
            -depthValue
        )
        let world = frame.camera.transform * SIMD4<Float>(
            local.x,
            local.y,
            local.z,
            1
        )
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
