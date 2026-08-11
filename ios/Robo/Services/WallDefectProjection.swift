import ARKit
import CoreVideo
import CoreGraphics
import Foundation
import simd

struct CrackDepthContext {
    let depth: Data
    let depthWidth: Int
    let depthHeight: Int
    let depthBytesPerRow: Int
    let sensorIntrinsics: [Float]
    let cropRect: CGRect
    let sensorImageSize: CGSize
    let cameraTransform: [Float]
    let analysisToCaptureRatio: Float
}

enum WallDefectProjection {

    /// Unprojects an analysis-image pixel to AR world coordinates using the
    /// LiDAR depth from the exact same frame as the photo. The YOLO pixel is
    /// first restored to the capturedImage pixel, then projected with the
    /// native ARCamera intrinsics and transform. No CI orientation,
    /// displayTransform or portrait intrinsics are involved in the ray.
    static func depthWorldPoint(
        pixel: CGPoint,
        analysisSize: CGSize,
        context: CrackDepthContext
    ) -> SIMD3<Float>? {
        guard analysisSize.width > 0, analysisSize.height > 0,
              context.depthWidth > 0, context.depthHeight > 0,
              context.depthBytesPerRow > 0,
              context.sensorIntrinsics.count == 9,
              context.cameraTransform.count == 16,
              context.analysisToCaptureRatio > 0 else {
            return nil
        }
        let imageX = context.cropRect.minX
            + (pixel.x / analysisSize.width
                / CGFloat(context.analysisToCaptureRatio))
                * context.cropRect.width
        let imageY = context.cropRect.minY
            + (pixel.y / analysisSize.height
                / CGFloat(context.analysisToCaptureRatio))
                * context.cropRect.height
        guard context.sensorImageSize.width > 0,
              context.sensorImageSize.height > 0,
              imageX >= 0, imageY >= 0,
              imageX <= context.sensorImageSize.width,
              imageY <= context.sensorImageSize.height else {
            return nil
        }
        guard let depthValue = medianDepth(
            imageX: imageX,
            imageY: imageY,
            imageSize: context.sensorImageSize,
            depth: context.depth,
            depthWidth: context.depthWidth,
            depthHeight: context.depthHeight,
            depthBytesPerRow: context.depthBytesPerRow
        ) else {
            return nil
        }

        let fx = context.sensorIntrinsics[0]
        let fy = context.sensorIntrinsics[4]
        let cx = context.sensorIntrinsics[2]
        let cy = context.sensorIntrinsics[5]
        let local = SIMD4<Float>(
            (Float(imageX) - cx) / fx * depthValue,
            -(Float(imageY) - cy) / fy * depthValue,
            -depthValue,
            1
        )
        let matrix = simd_float4x4(columns: (
            SIMD4<Float>(context.cameraTransform[0], context.cameraTransform[1], context.cameraTransform[2], context.cameraTransform[3]),
            SIMD4<Float>(context.cameraTransform[4], context.cameraTransform[5], context.cameraTransform[6], context.cameraTransform[7]),
            SIMD4<Float>(context.cameraTransform[8], context.cameraTransform[9], context.cameraTransform[10], context.cameraTransform[11]),
            SIMD4<Float>(context.cameraTransform[12], context.cameraTransform[13], context.cameraTransform[14], context.cameraTransform[15])
        ))
        let world = matrix * local
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// Live version used by the center-point verification marker. It reads
    /// the frame directly, so it is only called from the AR session delegate.
    static func depthWorldPoint(
        imagePixel: CGPoint,
        frame: ARFrame
    ) -> SIMD3<Float>? {
        guard let depthMap = frame.sceneDepth?.depthMap else {
            return nil
        }
        let imageSize = CGSize(
            width: CGFloat(frame.camera.imageResolution.width),
            height: CGFloat(frame.camera.imageResolution.height)
        )
        guard imageSize.width > 0, imageSize.height > 0,
              imagePixel.x >= 0, imagePixel.y >= 0,
              imagePixel.x <= imageSize.width,
              imagePixel.y <= imageSize.height else {
            return nil
        }
        guard let depthValue = medianDepth(
            imageX: imagePixel.x,
            imageY: imagePixel.y,
            imageSize: imageSize,
            pixelBuffer: depthMap
        ) else {
            return nil
        }
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let local = SIMD4<Float>(
            (Float(imagePixel.x) - cx) / fx * depthValue,
            -(Float(imagePixel.y) - cy) / fy * depthValue,
            -depthValue,
            1
        )
        let world = frame.camera.transform * local
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    private static func medianDepth(
        imageX: CGFloat,
        imageY: CGFloat,
        imageSize: CGSize,
        depth: Data,
        depthWidth: Int,
        depthHeight: Int,
        depthBytesPerRow: Int
    ) -> Float? {
        guard depthWidth > 0, depthHeight > 0,
              depthBytesPerRow > 0 else {
            return nil
        }
        let depthX = Int(imageX / imageSize.width * CGFloat(depthWidth))
        let depthY = Int(imageY / imageSize.height * CGFloat(depthHeight))
        var values: [Float] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let x = min(max(depthX + dx, 0), depthWidth - 1)
                let y = min(max(depthY + dy, 0), depthHeight - 1)
                let offset = y * depthBytesPerRow
                    + x * MemoryLayout<Float32>.size
                guard offset >= 0,
                      offset + MemoryLayout<Float32>.size <= depth.count else {
                    continue
                }
                let value = depth.withUnsafeBytes { bytes -> Float in
                    bytes.loadUnaligned(
                        fromByteOffset: offset,
                        as: Float.self
                    )
                }
                if value.isFinite, value > 0.05, value < 8 {
                    values.append(value)
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    private static func medianDepth(
        imageX: CGFloat,
        imageY: CGFloat,
        imageSize: CGSize,
        pixelBuffer: CVPixelBuffer
    ) -> Float? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let pointer = base.assumingMemoryBound(to: Float32.self)
        let stride = bytesPerRow / MemoryLayout<Float32>.size
        let depthX = Int(imageX / imageSize.width * CGFloat(width))
        let depthY = Int(imageY / imageSize.height * CGFloat(height))
        var values: [Float] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let x = min(max(depthX + dx, 0), width - 1)
                let y = min(max(depthY + dy, 0), height - 1)
                let value = pointer[y * stride + x]
                if value.isFinite, value > 0.05, value < 8 {
                    values.append(value)
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
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

    static func projectSparsePoints(
        points: Set<CrackPoint>,
        pose: [Float],
        intrinsics: [Float],
        surfaces: [WallDefectSurface]
    ) -> [UUID: [SparseSurfaceProjection]] {
        guard !points.isEmpty, !surfaces.isEmpty else {
            return [UUID: [SparseSurfaceProjection]]()
        }
        let camera = Camera(pose: pose, intrinsics: intrinsics)
        guard camera.isValid else {
            return [UUID: [SparseSurfaceProjection]]()
        }

        var result: [UUID: [SparseSurfaceProjection]] = [:]
        for point in points {
            let pixel = CGPoint(x: point.x, y: point.y)
            guard let surfaceID = nearestSurface(
                at: pixel,
                camera: camera,
                surfaces: surfaces
            ), let surface = surfaces.first(where: { $0.id == surfaceID }),
                let uv = uvCoordinate(
                    at: pixel,
                    camera: camera,
                    surface: surface
                ), let world = worldPoint(uv: uv, surface: surface) else {
                continue
            }
            result[surfaceID, default: []].append(
                SparseSurfaceProjection(
                    point: point,
                    uv: uv,
                    world: world
                )
            )
        }
        return result
    }

    static func worldPoint(
        uv: SIMD2<Double>,
        surface: WallDefectSurface
    ) -> SIMD3<Float>? {
        guard surface.origin.count == 3,
              surface.uAxis.count == 3,
              surface.vAxis.count == 3,
              surface.width > 0,
              surface.height > 0 else {
            return nil
        }
        let origin = SIMD3<Double>(
            surface.origin[0],
            surface.origin[1],
            surface.origin[2]
        )
        let uAxis = SIMD3<Double>(
            surface.uAxis[0],
            surface.uAxis[1],
            surface.uAxis[2]
        )
        let vAxis = SIMD3<Double>(
            surface.vAxis[0],
            surface.vAxis[1],
            surface.vAxis[2]
        )
        let point = origin
            + uAxis * (uv.x / surface.width)
            + vAxis * (uv.y / surface.height)
        return SIMD3<Float>(
            Float(point.x),
            Float(point.y),
            Float(point.z)
        )
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
        let uLength = max(simd_length(uAxis), 0.0001)
        let vLength = max(simd_length(vAxis), 0.0001)
        let u = simd_dot(delta, uAxis) / uLength
        let v = simd_dot(delta, vAxis) / vLength
        guard abs(u) <= width + 0.03,
              abs(v) <= height + 0.03 else {
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
            // Raw sensor intrinsics and pixels: camera-space ray is
            // ((x - cx)/fx, (y - cy)/fy, -1); ARKit camera looks along -Z.
            let fx = Double(intrinsics.columns.0.x)
            let fy = Double(intrinsics.columns.1.y)
            let cx = Double(intrinsics.columns.2.x)
            let cy = Double(intrinsics.columns.2.y)
            let local = SIMD3<Float>(
                Float((Double(pixel.x) - cx) / fx),
                Float((Double(pixel.y) - cy) / fy),
                -1
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

struct SparseSurfaceProjection {
    let point: CrackPoint
    let uv: SIMD2<Double>
    let world: SIMD3<Float>
}
