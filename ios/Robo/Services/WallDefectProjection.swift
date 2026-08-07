import CoreGraphics
import Foundation
import simd

enum WallDefectProjection {

    static func portraitIntrinsics(
        intrinsics: [Float],
        rawWidth: Int,
        rawHeight: Int
    ) -> [Float] {
        guard intrinsics.count == 9, rawWidth > 0, rawHeight > 0 else {
            return intrinsics
        }
        let fx = intrinsics[0]
        let fy = intrinsics[4]
        let cx = intrinsics[2]
        let cy = intrinsics[5]
        return [
            fy, 0, Float(rawHeight) - cy,
            0, fx, cx,
            0, 0, 1
        ]
    }

    static func associations(
        pose: [Float],
        intrinsics: [Float],
        imageSize: CGSize,
        surfaces: [WallDefectSurface]
    ) -> [WallDefectSurfaceAssociation] {
        guard imageSize.width > 0, imageSize.height > 0, !surfaces.isEmpty else {
            return []
        }
        let camera = Camera(pose: pose, intrinsics: intrinsics)
        guard camera.isValid else { return [] }

        var hitCounts: [UUID: Int] = [:]
        let samples = 16
        for gy in 0..<samples {
            for gx in 0..<samples {
                let x = (Double(gx) + 0.5) * Double(imageSize.width) / Double(samples)
                let y = (Double(gy) + 0.5) * Double(imageSize.height) / Double(samples)
                guard let hit = nearestSurface(
                    at: CGPoint(x: x, y: y),
                    camera: camera,
                    surfaces: surfaces
                ) else {
                    continue
                }
                hitCounts[hit, default: 0] += 1
            }
        }

        let total = Double(samples * samples)
        return surfaces.compactMap { surface in
            guard let count = hitCounts[surface.id] else { return nil }
            return WallDefectSurfaceAssociation(
                surfaceID: surface.id,
                label: surface.label,
                coverageRatio: Double(count) / total
            )
        }
        .sorted { $0.coverageRatio > $1.coverageRatio }
    }

    static func uvPoint(
        at pixel: CGPoint,
        pose: [Float],
        intrinsics: [Float],
        surface: WallDefectSurface
    ) -> SIMD2<Double>? {
        let camera = Camera(pose: pose, intrinsics: intrinsics)
        guard camera.isValid else { return nil }
        let ray = camera.ray(pixel: pixel)
        guard let hit = rayPlaneIntersection(
            rayOrigin: ray.origin,
            rayDirection: ray.direction,
            planeOrigin: WallDefectGeometry.planeOrigin(for: surface),
            uAxis: WallDefectGeometry.planeUAxis(for: surface),
            vAxis: WallDefectGeometry.planeVAxis(for: surface),
            normal: WallDefectGeometry.planeNormal(for: surface),
            width: surface.width,
            height: surface.height
        ) else {
            return nil
        }
        return hit.uv
    }

    static func splitMaskBySurfaces(
        mask: [Bool],
        width: Int,
        height: Int,
        pose: [Float],
        intrinsics: [Float],
        surfaces: [WallDefectSurface]
    ) -> [SurfaceMaskSplit] {
        guard width > 0, height > 0,
              mask.count == width * height,
              !surfaces.isEmpty else {
            return []
        }
        let camera = Camera(pose: pose, intrinsics: intrinsics)
        guard camera.isValid else { return [] }

        var indicesBySurface: [UUID: [Int]] = [:]
        for index in 0..<mask.count where mask[index] {
            let x = index % width
            let y = index / width
            guard let surfaceID = nearestSurface(
                at: CGPoint(x: x, y: y),
                camera: camera,
                surfaces: surfaces
            ) else {
                continue
            }
            indicesBySurface[surfaceID, default: []].append(index)
        }

        return surfaces.compactMap { surface in
            guard let indices = indicesBySurface[surface.id], !indices.isEmpty else {
                return nil
            }
            var subMask = [Bool](repeating: false, count: width * height)
            var uvByIndex: [Int: SIMD2<Double>] = [:]
            for index in indices {
                subMask[index] = true
                let x = index % width
                let y = index / width
                if let uv = uvCoordinate(
                    at: CGPoint(x: x, y: y),
                    camera: camera,
                    surface: surface
                ) {
                    uvByIndex[index] = uv
                }
            }
            return SurfaceMaskSplit(
                surfaceID: surface.id,
                label: surface.label,
                width: width,
                height: height,
                mask: subMask,
                uvByIndex: uvByIndex,
                pixelCount: indices.count
            )
        }
        .sorted { $0.pixelCount > $1.pixelCount }
    }

    private static func uvCoordinate(
        at pixel: CGPoint,
        camera: Camera,
        surface: WallDefectSurface
    ) -> SIMD2<Double>? {
        let ray = camera.ray(pixel: pixel)
        return rayPlaneIntersection(
            rayOrigin: ray.origin,
            rayDirection: ray.direction,
            planeOrigin: WallDefectGeometry.planeOrigin(for: surface),
            uAxis: WallDefectGeometry.planeUAxis(for: surface),
            vAxis: WallDefectGeometry.planeVAxis(for: surface),
            normal: WallDefectGeometry.planeNormal(for: surface),
            width: surface.width,
            height: surface.height
        )?.uv
    }

    private static func nearestSurface(
        at pixel: CGPoint,
        camera: Camera,
        surfaces: [WallDefectSurface]
    ) -> UUID? {
        let ray = camera.ray(pixel: pixel)
        var bestID: UUID?
        var bestDistance = Float.greatestFiniteMagnitude

        for surface in surfaces {
            let origin = WallDefectGeometry.planeOrigin(for: surface)
            let uAxis = WallDefectGeometry.planeUAxis(for: surface)
            let vAxis = WallDefectGeometry.planeVAxis(for: surface)
            let normal = WallDefectGeometry.planeNormal(for: surface)

            guard let uv = rayPlaneIntersection(
                rayOrigin: ray.origin,
                rayDirection: ray.direction,
                planeOrigin: origin,
                uAxis: uAxis,
                vAxis: vAxis,
                normal: normal,
                width: surface.width,
                height: surface.height
            ) else {
                continue
            }
            if uv.distance < bestDistance {
                bestDistance = uv.distance
                bestID = surface.id
            }
        }
        return bestID
    }

    static func rayPlaneIntersection(
        rayOrigin: SIMD3<Double>,
        rayDirection: SIMD3<Double>,
        planeOrigin: SIMD3<Double>,
        uAxis: SIMD3<Double>,
        vAxis: SIMD3<Double>,
        normal: SIMD3<Double>,
        width: Double,
        height: Double
    ) -> (uv: SIMD2<Double>, distance: Float)? {
        let denominator = simd_dot(rayDirection, normal)
        guard abs(denominator) > 0.0001 else { return nil }
        let t = simd_dot(planeOrigin - rayOrigin, normal) / denominator
        guard t > 0 else { return nil }

        let point = rayOrigin + rayDirection * t
        let delta = point - planeOrigin
        let u = simd_dot(delta, uAxis) / max(simd_dot(uAxis, uAxis), 0.0001)
        let v = simd_dot(delta, vAxis) / max(simd_dot(vAxis, vAxis), 0.0001)
        guard u >= -0.03, v >= -0.03,
              u <= width + 0.03,
              v <= height + 0.03 else {
            return nil
        }
        return (SIMD2<Double>(u, v), Float(t))
    }

    private struct Camera {
        let matrix: simd_float4x4
        let intrinsics: simd_float3x3
        let isValid: Bool

        init(pose: [Float], intrinsics: [Float]) {
            if pose.count == 16, intrinsics.count == 9 {
                self.matrix = simd_float4x4(columns: (
                    SIMD4<Float>(pose[0], pose[1], pose[2], pose[3]),
                    SIMD4<Float>(pose[4], pose[5], pose[6], pose[7]),
                    SIMD4<Float>(pose[8], pose[9], pose[10], pose[11]),
                    SIMD4<Float>(pose[12], pose[13], pose[14], pose[15])
                ))
                self.intrinsics = simd_float3x3(columns: (
                    SIMD3<Float>(intrinsics[0], intrinsics[1], intrinsics[2]),
                    SIMD3<Float>(intrinsics[3], intrinsics[4], intrinsics[5]),
                    SIMD3<Float>(intrinsics[6], intrinsics[7], intrinsics[8])
                ))
                isValid = true
            } else {
                self.matrix = matrix_identity_float4x4
                self.intrinsics = matrix_identity_float3x3
                isValid = false
            }
        }

        func ray(pixel: CGPoint) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
            let fx = Double(intrinsics.columns.0.x)
            let fy = Double(intrinsics.columns.1.y)
            let cx = Double(intrinsics.columns.2.x)
            let cy = Double(intrinsics.columns.2.y)
            let local = SIMD3<Float>(
                Float((Double(pixel.x) - cx) / fx),
                Float((Double(pixel.y) - cy) / fy),
                1
            )
            let rotation = simd_float3x3(columns: (
                SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
            ))
            let worldDirection = simd_normalize(rotation * local)
            let origin = SIMD3<Float>(
                matrix.columns.3.x,
                matrix.columns.3.y,
                matrix.columns.3.z
            )
            return (
                SIMD3<Double>(Double(origin.x), Double(origin.y), Double(origin.z)),
                SIMD3<Double>(
                    Double(worldDirection.x),
                    Double(worldDirection.y),
                    Double(worldDirection.z)
                )
            )
        }
    }
}

struct SurfaceMaskSplit {
    let surfaceID: UUID
    let label: String
    let width: Int
    let height: Int
    let mask: [Bool]
    let uvByIndex: [Int: SIMD2<Double>]
    let pixelCount: Int
}
