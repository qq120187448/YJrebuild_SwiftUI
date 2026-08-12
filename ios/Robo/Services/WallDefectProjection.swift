import ARKit
import ARKit
import CoreVideo
import CoreGraphics
import Foundation
import simd

struct DefectPointCloudPoint {
    let world: SIMD3<Float>
    let image: CGPoint
}

struct DefectWallPlane {
    let normal: SIMD3<Float>
    let d: Float
}

struct CrackDepthContext {
    let pointCloud: [DefectPointCloudPoint]
    let cropRect: CGRect
    let sensorImageSize: CGSize
    let analysisToCaptureRatio: Float
}

/// ARMesh 上下文：拍摄瞬间的 Scene Reconstruction 网格锚点。
/// 与 depthContext 职责分离：ARMesh 负责最终表面几何，Depth 只做快速对应与回退。
struct CrackMeshContext {
    let anchors: [ARMeshAnchor]
    let cropRect: CGRect
    let sensorImageSize: CGSize
    let analysisToCaptureRatio: Float

    var anchorCount: Int { anchors.count }
    var vertexCount: Int {
        anchors.reduce(0) { $0 + $1.geometry.vertices.count }
    }
    var faceCount: Int {
        anchors.reduce(0) { $0 + $1.geometry.faces.count }
    }
}

enum WallDefectProjection {

    /// Apple SceneDepth point cloud projection. Every depth-map sample is
    /// unprojected with the official chain:
    /// depth pixel -> camera image pixel -> intrinsics.inverse -> depth
    /// -> viewMatrix(for:).inverse * rotateToARCamera -> world.
    /// No displayTransform or manual intrinsics rotation is involved.
    static func makePointCloud(
        frame: ARFrame,
        depthMap: CVPixelBuffer,
        sampleStep: Int = 2
    ) -> [DefectPointCloudPoint] {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return []
        }
        let imageWidth = Float(frame.camera.imageResolution.width)
        let imageHeight = Float(frame.camera.imageResolution.height)
        let intrinsicsInverse = frame.camera.intrinsics.inverse
        let localToWorld = frame.camera.viewMatrix(
            for: .portrait
        ).inverse * rotateToARCameraMatrix(orientation: .portrait)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            return []
        }
        let pointer = base.assumingMemoryBound(to: Float32.self)
        let stride = bytesPerRow / MemoryLayout<Float32>.size
        let step = max(1, sampleStep)
        var points: [DefectPointCloudPoint] = []
        points.reserveCapacity(
            (width / step) * (height / step)
        )
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let depthValue = pointer[y * stride + x]
                if depthValue.isFinite,
                   depthValue > 0.05,
                   depthValue < 8 {
                    let u = Float(x) * imageWidth / Float(width)
                    let v = Float(y) * imageHeight / Float(height)
                    let local = intrinsicsInverse
                        * SIMD3<Float>(u, v, 1)
                        * depthValue
                    let world = localToWorld * SIMD4<Float>(
                        local.x,
                        local.y,
                        local.z,
                        1
                    )
                    points.append(
                        DefectPointCloudPoint(
                            world: SIMD3<Float>(
                                world.x,
                                world.y,
                                world.z
                            ),
                            image: CGPoint(
                                x: CGFloat(u),
                                y: CGFloat(v)
                            )
                        )
                    )
                }
                x += step
            }
            y += step
        }
        return points
    }

    /// Restores a YOLO analysis pixel to capturedImage pixel space, then
    /// looks up the closest official point-cloud samples around it.
    static func depthWorldPoint(
        pixel: CGPoint,
        analysisSize: CGSize,
        context: CrackDepthContext
    ) -> SIMD3<Float>? {
        guard analysisSize.width > 0, analysisSize.height > 0,
              !context.pointCloud.isEmpty,
              context.cropRect.width > 0,
              context.cropRect.height > 0,
              context.sensorImageSize.width > 0,
              context.sensorImageSize.height > 0,
              context.analysisToCaptureRatio > 0 else {
            return nil
        }
        let imageX = (pixel.x / analysisSize.width
            / CGFloat(context.analysisToCaptureRatio))
            * context.sensorImageSize.width
        let imageY = (pixel.y / analysisSize.height
            / CGFloat(context.analysisToCaptureRatio))
            * context.sensorImageSize.height
        guard context.cropRect.contains(
            CGPoint(x: imageX, y: imageY)
        ) else {
            return nil
        }
        guard imageX >= 0, imageY >= 0,
              imageX <= context.sensorImageSize.width,
              imageY <= context.sensorImageSize.height else {
            return nil
        }
        return worldPoint(
            near: CGPoint(x: imageX, y: imageY),
            in: context.pointCloud
        )
    }

    /// Averages official world points whose image coordinate is within a
    /// small radius of the requested pixel. Falls back to the nearest point.
    static func worldPoint(
        near imagePixel: CGPoint,
        in points: [DefectPointCloudPoint],
        radius: CGFloat = 4
    ) -> SIMD3<Float>? {
        guard !points.isEmpty else { return nil }
        var bestDistance = CGFloat.infinity
        var bestIndex = 0
        for index in points.indices {
            let point = points[index]
            let dx = point.image.x - imagePixel.x
            let dy = point.image.y - imagePixel.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        let radiusSquared = radius * radius
        guard bestDistance <= radiusSquared else {
            return points[bestIndex].world
        }
        var sum = SIMD3<Float>(0, 0, 0)
        var count = 0
        for point in points {
            let dx = point.image.x - imagePixel.x
            let dy = point.image.y - imagePixel.y
            if dx * dx + dy * dy <= radiusSquared {
                sum += point.world
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : points[bestIndex].world
    }

    /// Fits the dominant wall plane from point-cloud samples inside the
    /// retake crop region using RANSAC. The plane is n.P + d = 0.
    static func fitPlane(
        points: [DefectPointCloudPoint],
        cropRect: CGRect,
        iterations: Int = 120,
        threshold: Float = 0.012
    ) -> DefectWallPlane? {
        guard cropRect.width > 0, cropRect.height > 0 else {
            return nil
        }
        let margin = min(cropRect.width, cropRect.height) * 0.15
        let region = cropRect.insetBy(dx: -margin, dy: -margin)
        let candidates = points
            .filter { region.contains($0.image) }
            .map(\.world)
        guard candidates.count >= 20 else { return nil }

        var rng = SystemRandomNumberGenerator()
        let subset: [SIMD3<Float>]
        if candidates.count > 30000 {
            subset = Array(
                candidates.shuffled(using: &rng).prefix(30000)
            )
        } else {
            subset = candidates
        }
        let count = subset.count
        var bestNormal = SIMD3<Float>(0, 1, 0)
        var bestD: Float = 0
        var bestInliers = 0
        for _ in 0..<max(iterations, 40) {
            let i0 = Int.random(in: 0..<count, using: &rng)
            var i1 = Int.random(in: 0..<count, using: &rng)
            while i1 == i0 {
                i1 = Int.random(in: 0..<count, using: &rng)
            }
            var i2 = Int.random(in: 0..<count, using: &rng)
            while i2 == i0 || i2 == i1 {
                i2 = Int.random(in: 0..<count, using: &rng)
            }
            let p0 = subset[i0]
            let p1 = subset[i1]
            let p2 = subset[i2]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let length = simd_length(cross)
            guard length > 0.0001 else { continue }
            let normal = cross / length
            let d = -simd_dot(normal, p0)
            var inliers = 0
            for point in subset {
                if abs(simd_dot(normal, point) + d) <= threshold {
                    inliers += 1
                }
            }
            if inliers > bestInliers {
                bestInliers = inliers
                bestNormal = normal
                bestD = d
            }
        }
        guard bestInliers >= 10 else { return nil }

        var sum = SIMD3<Float>(0, 0, 0)
        var inlierCount = 0
        for point in subset {
            if abs(simd_dot(bestNormal, point) + bestD) <= threshold {
                sum += point
                inlierCount += 1
            }
        }
        if inlierCount > 0 {
            let mean = sum / Float(inlierCount)
            bestD = -simd_dot(bestNormal, mean)
        }
        return DefectWallPlane(normal: bestNormal, d: bestD)
    }

    static func projectToPlane(
        point: SIMD3<Float>,
        plane: DefectWallPlane
    ) -> SIMD3<Float> {
        let distance = simd_dot(plane.normal, point) + plane.d
        return point - plane.normal * distance
    }

    static func cameraToDisplayRotation(
        orientation: UIInterfaceOrientation
    ) -> Int {
        switch orientation {
        case .landscapeLeft:
            return 180
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return -90
        default:
            return 0
        }
    }

    static func rotateToARCameraMatrix(
        orientation: UIInterfaceOrientation
    ) -> simd_float4x4 {
        let flipYZ = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(0, 0, -1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        let angle = Float(
            cameraToDisplayRotation(orientation: orientation)
        ) * Float.pi / 180
        let rotation = simd_float4x4(
            simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1))
        )
        return flipYZ * rotation
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

    // MARK: - ARMesh 射线求交（P0：最终表面几何）

    /// 把 YOLO 分析像素还原到 sensor 像素，再与 ARMesh 求交得到世界点。
    /// 返回 nil 表示未命中 mesh（调用方回退到 sceneDepth / 平面）。
    static func meshWorldPoint(
        pixel: CGPoint,
        analysisSize: CGSize,
        context: CrackMeshContext,
        pose: [Float],
        intrinsics: [Float],
        maxDistance: Float = 3
    ) -> SIMD3<Float>? {
        guard analysisSize.width > 0, analysisSize.height > 0,
              !context.anchors.isEmpty,
              context.cropRect.width > 0,
              context.cropRect.height > 0,
              context.sensorImageSize.width > 0,
              context.sensorImageSize.height > 0,
              context.analysisToCaptureRatio > 0 else {
            return nil
        }
        let imageX = (pixel.x / analysisSize.width
            / CGFloat(context.analysisToCaptureRatio))
            * context.sensorImageSize.width
        let imageY = (pixel.y / analysisSize.height
            / CGFloat(context.analysisToCaptureRatio))
            * context.sensorImageSize.height
        guard context.cropRect.contains(
            CGPoint(x: imageX, y: imageY)
        ) else {
            return nil
        }
        let camera = Camera(pose: pose, intrinsics: intrinsics)
        guard camera.isValid else { return nil }
        let ray = camera.ray(pixel: CGPoint(x: imageX, y: imageY))
        return rayMeshIntersection(
            rayOrigin: SIMD3<Float>(
                Float(ray.origin.x),
                Float(ray.origin.y),
                Float(ray.origin.z)
            ),
            rayDirection: SIMD3<Float>(
                Float(ray.direction.x),
                Float(ray.direction.y),
                Float(ray.direction.z)
            ),
            anchors: context.anchors,
            maxDistance: maxDistance
        )
    }

    /// 把分析图像素映射回 sensor 图像像素（与 depthWorldPoint 相同的换算链）。
    static func sensorPoint(
        for pixel: CGPoint,
        analysisSize: CGSize,
        context: CrackMeshContext
    ) -> CGPoint? {
        guard analysisSize.width > 0, analysisSize.height > 0,
              context.cropRect.width > 0,
              context.cropRect.height > 0,
              context.sensorImageSize.width > 0,
              context.sensorImageSize.height > 0,
              context.analysisToCaptureRatio > 0 else {
            return nil
        }
        let imageX = (pixel.x / analysisSize.width
            / CGFloat(context.analysisToCaptureRatio))
            * context.sensorImageSize.width
        let imageY = (pixel.y / analysisSize.height
            / CGFloat(context.analysisToCaptureRatio))
            * context.sensorImageSize.height
        let point = CGPoint(x: imageX, y: imageY)
        guard context.cropRect.contains(point),
              imageX >= 0, imageY >= 0,
              imageX <= context.sensorImageSize.width,
              imageY <= context.sensorImageSize.height else {
            return nil
        }
        return point
    }

    /// 对全部 ARMeshAnchor 做 Möller–Trumbore 三角形求交，返回最近命中点。
    static func rayMeshIntersection(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        anchors: [ARMeshAnchor],
        maxDistance: Float = 3
    ) -> SIMD3<Float>? {
        guard !anchors.isEmpty else { return nil }
        let direction = simd_normalize(rayDirection)
        var bestT = Float.greatestFiniteMagnitude
        var bestPoint: SIMD3<Float>?

        for anchor in anchors {
            let transform = anchor.transform
            let vertices = anchor.geometry.vertices
            let faces = anchor.geometry.faces
            let vertexCount = vertices.count
            let faceCount = faces.count
            guard vertexCount > 0, faceCount > 0 else { continue }

            let vertexBuffer = vertices.buffer
                .contents()
                .assumingMemoryBound(to: SIMD3<Float>.self)
            let indexBuffer = faces.buffer
                .contents()
                .assumingMemoryBound(to: UInt32.self)
            let indexStride = faces.bytesPerIndex / MemoryLayout<UInt32>.size

            func worldVertex(_ index: Int) -> SIMD3<Float> {
                let local = vertexBuffer[index]
                let world = transform * SIMD4<Float>(
                    local.x,
                    local.y,
                    local.z,
                    1
                )
                return SIMD3<Float>(world.x, world.y, world.z)
            }

            for faceIndex in 0..<faceCount {
                let i0 = Int(indexBuffer[faceIndex * 3 * indexStride])
                let i1 = Int(indexBuffer[(faceIndex * 3 + 1) * indexStride])
                let i2 = Int(indexBuffer[(faceIndex * 3 + 2) * indexStride])
                guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else {
                    continue
                }
                let v0 = worldVertex(i0)
                let v1 = worldVertex(i1)
                let v2 = worldVertex(i2)
                guard let t = rayTriangleIntersection(
                    rayOrigin: rayOrigin,
                    rayDirection: direction,
                    v0: v0,
                    v1: v1,
                    v2: v2
                ), t > 0, t < maxDistance, t < bestT else {
                    continue
                }
                bestT = t
                bestPoint = rayOrigin + direction * t
            }
        }
        return bestPoint
    }

    /// 公开的相机射线构造（sensor 像素坐标 + sensor 内参），供闭环测试使用。
    static func cameraRay(
        pixel: CGPoint,
        pose: [Float],
        intrinsics: [Float]
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let camera = Camera(pose: pose, intrinsics: intrinsics)
        guard camera.isValid else { return nil }
        let ray = camera.ray(pixel: pixel)
        return (
            SIMD3<Float>(
                Float(ray.origin.x),
                Float(ray.origin.y),
                Float(ray.origin.z)
            ),
            SIMD3<Float>(
                Float(ray.direction.x),
                Float(ray.direction.y),
                Float(ray.direction.z)
            )
        )
    }

    /// Möller–Trumbore 射线-三角形求交，返回参数 t。
    static func rayTriangleIntersection(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        v0: SIMD3<Float>,
        v1: SIMD3<Float>,
        v2: SIMD3<Float>
    ) -> Float? {
        let e1 = v1 - v0
        let e2 = v2 - v0
        let p = simd_cross(rayDirection, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-9 else { return nil }
        let invDet = 1 / det
        let tVec = rayOrigin - v0
        let u = simd_dot(tVec, p) * invDet
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(tVec, e1)
        let v = simd_dot(rayDirection, q) * invDet
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * invDet
        return t > 0 ? t : nil
    }

    // MARK: - 屏幕闭环测试（screen -> world -> screen）

    /// 把世界点投影回 sensor 图像像素（用于验证重投影误差）。
    static func projectToScreen(
        world: SIMD3<Float>,
        pose: [Float],
        intrinsics: [Float]
    ) -> CGPoint? {
        let camera = Camera(pose: pose, intrinsics: intrinsics)
        guard camera.isValid else { return nil }
        let inv = camera.matrix.inverse
        let cam = inv * SIMD4<Float>(world.x, world.y, world.z, 1)
        let z = -cam.z
        guard z > 0.0001 else { return nil }
        let fx = camera.intrinsics.columns.0.x
        let fy = camera.intrinsics.columns.1.y
        let cx = camera.intrinsics.columns.2.x
        let cy = camera.intrinsics.columns.2.y
        let x = fx * cam.x / z + cx
        let y = fy * cam.y / z + cy
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    // MARK: - Surface UV 折线与多边形（P1：墙面展开图上的物理测量）

    /// 折线长度：sum hypot(dU, dV)，单位米。
    static func uvPolylineLength(_ polyline: [SIMD2<Double>]) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var length = 0.0
        for i in 1..<polyline.count {
            let delta = polyline[i] - polyline[i - 1]
            length += (delta.x * delta.x + delta.y * delta.y).squareRoot()
        }
        return length
    }

    /// 多边形面积（鞋带公式），输入为闭合或未闭合 UV 点列，单位 m²。
    static func uvPolygonArea(_ polygon: [SIMD2<Double>]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
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
