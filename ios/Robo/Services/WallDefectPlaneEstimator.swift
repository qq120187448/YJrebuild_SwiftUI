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
    let residualM: Double

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

    func withResidual(_ value: Double) -> WallDefectPlane {
        WallDefectPlane(
            origin: origin,
            normal: normal,
            uAxis: uAxis,
            vAxis: vAxis,
            width: width,
            height: height,
            sampleCount: sampleCount,
            source: source,
            residualM: value
        )
    }

    private func double3(_ value: SIMD3<Float>) -> [Double] {
        [Double(value.x), Double(value.y), Double(value.z)]
    }
}

/// Fits the wall/floor plane under the retake viewfinder from ARKit data.
/// A raycast plane and a LiDAR depth PCA plane are both estimated and the
/// one with the smaller residual is used, so a stray hit on furniture or a
/// wrong surface does not pull the AR projection meters off the wall.
enum WallDefectPlaneEstimator {

    private static let maxResidualM = 0.04

    static func estimate(
        frame: ARFrame,
        view: ARSCNView?,
        center: CGPoint? = nil
    ) -> WallDefectPlane? {
        let points = depthPoints(frame: frame, view: view, center: center)
        var candidates: [(plane: WallDefectPlane, residual: Double)] = []
        if let raycast = raycastPlane(frame: frame, view: view, center: center) {
            candidates.append(
                (raycast, residual(of: raycast, points: points))
            )
        }
        if let depth = depthPlane(points: points, frame: frame) {
            candidates.append(
                (depth, residual(of: depth, points: points))
            )
        }
        guard let best = candidates.min(by: {
            $0.residual < $1.residual
        }) else {
            return nil
        }
        return best.plane.withResidual(best.residual)
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
        view: ARSCNView,
        center: CGPoint?
    ) -> WallDefectPlane? {
        let target = center
            ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let targets: [ARRaycastQuery.Target] = [
            .existingPlaneGeometry,
            .estimatedPlane
        ]
        for targetType in targets {
            guard let query = view.raycastQuery(
                from: target,
                allowing: targetType,
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
                source: "raycast",
                residualM: 0
            )
        }
        return nil
    }

    private static func depthPlane(
        points: [SIMD3<Float>],
        frame: ARFrame
    ) -> WallDefectPlane? {
        guard points.count >= 20 else { return nil }
        var centroid = SIMD3<Float>.zero
        for point in points {
            centroid += point
        }
        centroid /= Float(points.count)

        var covariance = [
            [Double](repeating: 0, count: 3),
            [Double](repeating: 0, count: 3),
            [Double](repeating: 0, count: 3)
        ]
        for point in points {
            let d = SIMD3<Double>(
                Double(point.x - centroid.x),
                Double(point.y - centroid.y),
                Double(point.z - centroid.z)
            )
            covariance[0][0] += d.x * d.x
            covariance[0][1] += d.x * d.y
            covariance[0][2] += d.x * d.z
            covariance[1][1] += d.y * d.y
            covariance[1][2] += d.y * d.z
            covariance[2][2] += d.z * d.z
        }
        let count = Double(points.count)
        for i in 0..<3 {
            for j in i..<3 {
                let value = covariance[i][j] / count
                covariance[i][j] = value
                covariance[j][i] = value
            }
        }
        guard let eigenvector = smallestEigenvector(covariance) else {
            return nil
        }
        var normal = SIMD3<Float>(
            Float(eigenvector.x),
            Float(eigenvector.y),
            Float(eigenvector.z)
        )
        let length = simd_length(normal)
        guard length > 0.0001 else { return nil }
        normal /= length

        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        if simd_dot(normal, cameraPosition - centroid) < 0 {
            normal = -normal
        }
        if abs(normal.y) > 0.7 {
            normal = SIMD3<Float>(
                0,
                normal.y > 0 ? 1 : -1,
                0
            )
        } else {
            let horizontal = SIMD3<Float>(normal.x, 0, normal.z)
            let horizontalLength = simd_length(horizontal)
            guard horizontalLength > 0.05 else { return nil }
            normal = horizontal / horizontalLength
        }
        let planeResidual = residual(
            origin: centroid,
            normal: normal,
            points: points
        )
        guard planeResidual <= maxResidualM else { return nil }

        let axes = planeAxes(for: normal)
        return WallDefectPlane(
            origin: centroid,
            normal: normal,
            uAxis: axes.u,
            vAxis: axes.v,
            width: 20,
            height: 20,
            sampleCount: points.count,
            source: "depth",
            residualM: 0
        )
    }

    private static func residual(
        of plane: WallDefectPlane,
        points: [SIMD3<Float>]
    ) -> Double {
        residual(
            origin: plane.origin,
            normal: plane.normal,
            points: points
        )
    }

    private static func residual(
        origin: SIMD3<Float>,
        normal: SIMD3<Float>,
        points: [SIMD3<Float>]
    ) -> Double {
        guard !points.isEmpty else {
            return .greatestFiniteMagnitude
        }
        let originD = SIMD3<Double>(
            Double(origin.x),
            Double(origin.y),
            Double(origin.z)
        )
        let normal = SIMD3<Double>(
            Double(normal.x),
            Double(normal.y),
            Double(normal.z)
        )
        let length = simd_length(normal)
        guard length > 0.0001 else {
            return .greatestFiniteMagnitude
        }
        let unitNormal = normal / length
        var sum = 0.0
        for point in points {
            let value = SIMD3<Double>(
                Double(point.x),
                Double(point.y),
                Double(point.z)
            )
            sum += abs(simd_dot(value - originD, unitNormal))
        }
        return sum / Double(points.count)
    }

    private static func depthPoints(
        frame: ARFrame,
        view: ARSCNView?,
        center: CGPoint?
    ) -> [SIMD3<Float>] {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap
            ?? frame.sceneDepth?.depthMap else {
            return []
        }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { return [] }

        let viewport = view?.bounds.size
            ?? CGSize(
                width: CGFloat(depthWidth),
                height: CGFloat(depthHeight)
            )
        let transform = frame.displayTransform(
            for: .portrait,
            viewportSize: viewport
        )
        let screenPoint = center
            ?? CGPoint(
                x: viewport.width * 0.5,
                y: viewport.height * 0.5
            )
        let imagePoint = screenPoint.applying(transform.inverted())
        let centerX = Int(imagePoint.x * CGFloat(depthWidth))
        let centerY = Int(imagePoint.y * CGFloat(depthHeight))
        guard centerX >= 0, centerY >= 0,
              centerX < depthWidth, centerY < depthHeight else {
            return []
        }

        var points: [SIMD3<Float>] = []
        let offsets = Array(stride(from: -16, through: 16, by: 4))
        for dy in offsets {
            for dx in offsets {
                if let world = depthWorldPoint(
                    frame: frame,
                    depthMap: depthMap,
                    x: centerX + dx,
                    y: centerY + dy
                ) {
                    points.append(world)
                }
            }
        }
        return points
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

    private static func smallestEigenvector(
        _ matrix: [[Double]]
    ) -> SIMD3<Double>? {
        guard matrix.count == 3,
              matrix[0].count == 3,
              matrix[1].count == 3,
              matrix[2].count == 3 else {
            return nil
        }
        var a = matrix
        var vectors = [
            [1.0, 0, 0],
            [0, 1.0, 0],
            [0, 0, 1.0]
        ]
        for _ in 0..<64 {
            var p = 0
            var q = 1
            var maxValue = abs(a[0][1])
            for i in 0..<3 {
                for j in (i + 1)..<3 {
                    let value = abs(a[i][j])
                    if value > maxValue {
                        maxValue = value
                        p = i
                        q = j
                    }
                }
            }
            if maxValue < 1e-12 { break }

            let app = a[p][p]
            let aqq = a[q][q]
            let apq = a[p][q]
            let angle = 0.5 * atan2(2 * apq, aqq - app)
            let c = cos(angle)
            let s = sin(angle)

            let newPP = c * c * app - 2 * s * c * apq + s * s * aqq
            let newQQ = s * s * app + 2 * s * c * apq + c * c * aqq
            let newPQ = (c * c - s * s) * apq + s * c * (app - aqq)
            a[p][p] = newPP
            a[q][q] = newQQ
            a[p][q] = newPQ
            a[q][p] = newPQ

            for k in 0..<3 where k != p && k != q {
                let akp = a[k][p]
                let akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[p][k] = a[k][p]
                a[k][q] = s * akp + c * akq
                a[q][k] = a[k][q]
            }
            for k in 0..<3 {
                let vkp = vectors[k][p]
                let vkq = vectors[k][q]
                vectors[k][p] = c * vkp - s * vkq
                vectors[k][q] = s * vkp + c * vkq
            }
        }

        var minIndex = 0
        for i in 1..<3 where a[i][i] < a[minIndex][minIndex] {
            minIndex = i
        }
        return SIMD3<Double>(
            vectors[0][minIndex],
            vectors[1][minIndex],
            vectors[2][minIndex]
        )
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
