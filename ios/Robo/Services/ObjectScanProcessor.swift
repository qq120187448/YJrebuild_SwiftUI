import Foundation
import UIKit
import SceneKit
import simd
import Manifold3D
import Voxels

private struct HullVector: Manifold3D.Vector3 {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

struct ObjectPoint: Codable, Sendable, Hashable {
    var x: Float
    var y: Float
    var z: Float
    var r: Float
    var g: Float
    var b: Float
    var classification: Int?

    init(
        x: Float,
        y: Float,
        z: Float,
        r: Float = 0.7,
        g: Float = 0.8,
        b: Float = 1.0,
        classification: Int? = nil
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.g = g
        self.b = b
        self.classification = classification
    }

    var position: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

struct ScanPlaneInfo: Sendable {
    var centerX: Float
    var centerY: Float
    var centerZ: Float
    var normalX: Float
    var normalY: Float
    var normalZ: Float
    var width: Float
    var height: Float
}

struct ObjectScanMetrics: Codable, Sendable {
    struct AABB: Codable, Sendable {
        var minX: Double
        var minY: Double
        var minZ: Double
        var maxX: Double
        var maxY: Double
        var maxZ: Double

        var sizeX: Double { maxX - minX }
        var sizeY: Double { maxY - minY }
        var sizeZ: Double { maxZ - minZ }
    }

    var pointCount: Int
    var processedPointCount: Int
    var targetPointCount: Int?
    var clusterCount: Int?
    var groundY: Double
    var aabb: AABB
    var obbLengthM: Double?
    var obbWidthM: Double?
    var obbHeightM: Double?
    var heightfieldVolumeM3: Double
    var heightfieldSurfaceAreaM2: Double
    var convexHullVolumeM3: Double
    var convexHullSurfaceAreaM2: Double
    var footprintAreaM2: Double?
    var groundContactAreaM2: Double?
    var wallContactAreaM2: Double?
    var voxelSizeM: Double?
    var voxelMeshVolumeM3: Double?
    var voxelMeshTotalSurfaceAreaM2: Double?
    var voxelMeshSurfaceAreaM2: Double?
    var voxelCoverageEstimate: Double?
    var voxelMeshVertexCount: Int?
    var voxelMeshTriangleCount: Int?
    var voxelReconstructionSucceeded: Bool?
    var voxelFailureReason: String?
    var voxelNote: String?
    var classificationRemovedCount: Int?
    var planeAnchorRemovedCount: Int?
    var groundRemovedCount: Int?
    var ransacRemovedCount: Int?
    var localPlaneRemovedCount: Int?
    var backgroundRemovedCount: Int?
    var backgroundRemovedRatio: Double?
}

struct ObjectScanProcessResult: Sendable {
    var clusters: [ObjectScanClusterOption]
    var allPoints: [ObjectPoint]
    var points: [ObjectPoint]
    var metrics: ObjectScanMetrics
    var metricsJSON: Data
    var plyData: Data
    var usdzData: Data?
}

struct ObjectScanClusterOption: Sendable {
    var points: [ObjectPoint]
    var metrics: ObjectScanMetrics
    var usdzData: Data?
}

struct OBBResult: Sendable {
    var lengthM: Double
    var widthM: Double
    var heightM: Double
}

struct VoxelReconstructionResult: Sendable {
    var succeeded: Bool = false
    var failureReason: String? = nil
    var voxelNote: String? = nil
    var voxelSizeM: Double?
    var volumeM3: Double?
    var totalSurfaceAreaM2: Double?
    var contactExcludedSurfaceAreaM2: Double?
    var groundContactAreaM2: Double?
    var wallContactAreaM2: Double?
    var coverageEstimate: Double?
    var vertexCount: Int?
    var triangleCount: Int?
    var usdzData: Data?
}

enum ObjectScanProcessor {
    private struct VoxelizationData {
        var filledKeys: Set<Int64>
        var origin: SIMD3<Float>
        var voxelSize: Float
        var floorIndex: Int
        var minIX: Int
        var minIY: Int
        var minIZ: Int
        var maxIX: Int
        var maxIY: Int
        var maxIZ: Int
        var knownColumnCount: Int
        var filledColumnCount: Int
    }

    private struct VoxelAccumulator {
        var sum = SIMD3<Float>.zero
        var sumColor = SIMD3<Float>.zero
        var count: Float = 0
    }

    static func process(
        points: [ObjectPoint],
        voxelSize: Float = 0.02,
        gridSize: Float = 0.05,
        planes: [ScanPlaneInfo] = []
    ) throws -> ObjectScanProcessResult {
        let effectiveVoxelSize = points.count > 180_000
            ? max(voxelSize * 2, 0.03)
            : voxelSize
        let downsampled = voxelDownsample(points, voxelSize: effectiveVoxelSize)
        let keptPoints = downsampled
        let groundY = keptPoints.map { $0.y }.min() ?? 0
        let candidates: [[ObjectPoint]] = [keptPoints]

        var options: [ObjectScanClusterOption] = []
        for cluster in candidates {
            let pair = metricsAndUSDZ(
                for: cluster,
                groundY: groundY,
                gridSize: gridSize,
                planes: [],
                backgroundRemovedCount: 0,
                backgroundRemovedRatio: 0
            )
            var metrics = pair.metrics
            metrics.pointCount = points.count
            metrics.processedPointCount = keptPoints.count
            metrics.clusterCount = 1
            metrics.classificationRemovedCount = 0
            metrics.planeAnchorRemovedCount = 0
            metrics.groundRemovedCount = 0
            metrics.ransacRemovedCount = 0
            metrics.localPlaneRemovedCount = 0
            options.append(
                ObjectScanClusterOption(
                    points: cluster,
                    metrics: metrics,
                    usdzData: pair.voxelUSDZData
                )
            )
        }

        let primary = options[0]
        let metricsJSON = try JSONEncoder().encode(primary.metrics)
        let ply = plyData(points: primary.points)
        return ObjectScanProcessResult(
            clusters: options,
            allPoints: keptPoints,
            points: primary.points,
            metrics: primary.metrics,
            metricsJSON: metricsJSON,
            plyData: ply,
            usdzData: primary.usdzData
        )
    }

    static func metricsAndUSDZ(
        for points: [ObjectPoint],
        groundY: Float? = nil,
        gridSize: Float = 0.05,
        planes: [ScanPlaneInfo] = [],
        backgroundRemovedCount: Int? = nil,
        backgroundRemovedRatio: Double? = nil
    ) -> (metrics: ObjectScanMetrics, voxelUSDZData: Data?) {
        guard !points.isEmpty else {
            return (
                ObjectScanMetrics(
                    pointCount: 0,
                    processedPointCount: 0,
                    targetPointCount: 0,
                    clusterCount: 0,
                    groundY: 0,
                    aabb: ObjectScanMetrics.AABB(
                        minX: 0, minY: 0, minZ: 0,
                        maxX: 0, maxY: 0, maxZ: 0
                    ),
                    obbLengthM: 0,
                    obbWidthM: 0,
                    obbHeightM: 0,
                    heightfieldVolumeM3: 0,
                    heightfieldSurfaceAreaM2: 0,
                    convexHullVolumeM3: 0,
                    convexHullSurfaceAreaM2: 0,
                    footprintAreaM2: 0,
                    groundContactAreaM2: 0,
                    wallContactAreaM2: 0
                ),
                nil
            )
        }
        let resolvedGroundY = groundY ?? (points.map { $0.y }.min() ?? 0)
        let aabb = computeAABB(points)
        let obb = computeOBB(points)
        let heightfield = computeHeightfield(points, groundY: resolvedGroundY, gridSize: gridSize)
        let hull = convexHull(points)
        let footprint = footprintArea(points)
        let voxel = voxelReconstruct(points, planes: planes)
        let metrics = ObjectScanMetrics(
            pointCount: points.count,
            processedPointCount: points.count,
            targetPointCount: points.count,
            clusterCount: 1,
            groundY: Double(resolvedGroundY),
            aabb: aabb,
            obbLengthM: obb.lengthM,
            obbWidthM: obb.widthM,
            obbHeightM: obb.heightM,
            heightfieldVolumeM3: heightfield.volumeM3,
            heightfieldSurfaceAreaM2: heightfield.surfaceAreaM2,
            convexHullVolumeM3: hull.volumeM3,
            convexHullSurfaceAreaM2: hull.surfaceAreaM2,
            footprintAreaM2: footprint,
            groundContactAreaM2: voxel.groundContactAreaM2 ?? footprint,
            wallContactAreaM2: voxel.wallContactAreaM2 ?? 0,
            voxelSizeM: voxel.voxelSizeM,
            voxelMeshVolumeM3: voxel.volumeM3,
            voxelMeshTotalSurfaceAreaM2: voxel.totalSurfaceAreaM2,
            voxelMeshSurfaceAreaM2: voxel.contactExcludedSurfaceAreaM2,
            voxelCoverageEstimate: voxel.coverageEstimate,
            voxelMeshVertexCount: voxel.vertexCount,
            voxelMeshTriangleCount: voxel.triangleCount,
            voxelReconstructionSucceeded: voxel.succeeded,
            voxelFailureReason: voxel.failureReason,
            voxelNote: voxel.voxelNote,
            backgroundRemovedCount: backgroundRemovedCount,
            backgroundRemovedRatio: backgroundRemovedRatio
        )
        return (metrics, voxel.usdzData ?? hull.usdzData)
    }

    static func metrics(for points: [ObjectPoint]) -> ObjectScanMetrics {
        metricsAndUSDZ(for: points).metrics
    }

    private static func buildVoxelization(
        points: [ObjectPoint],
        aabb: ObjectScanMetrics.AABB,
        initialVoxelSize: Float,
        maxVoxels: Int
    ) -> VoxelizationData? {
        var multiplier: Float = 1.0
        for _ in 0..<5 {
            let voxelSize = max(initialVoxelSize * multiplier, 0.001)
            let margin = voxelSize
            let origin = SIMD3<Float>(
                Float(aabb.minX) - margin,
                Float(aabb.minY) - margin,
                Float(aabb.minZ) - margin
            )
            var surfaceKeys = Set<Int64>()
            var maxYByColumn: [Int64: Float] = [:]
            var minIX = Int.max
            var minIY = Int.max
            var minIZ = Int.max
            var maxIX = Int.min
            var maxIY = Int.min
            var maxIZ = Int.min

            for point in points {
                let ix = Int(floor((point.x - origin.x) / voxelSize))
                let iy = Int(floor((point.y - origin.y) / voxelSize))
                let iz = Int(floor((point.z - origin.z) / voxelSize))
                surfaceKeys.insert(voxelKey(Int64(ix), Int64(iy), Int64(iz)))
                let columnKey = gridKey(Int64(ix), Int64(iz))
                maxYByColumn[columnKey] = max(maxYByColumn[columnKey] ?? point.y, point.y)
                minIX = min(minIX, ix)
                minIY = min(minIY, iy)
                minIZ = min(minIZ, iz)
                maxIX = max(maxIX, ix)
                maxIY = max(maxIY, iy)
                maxIZ = max(maxIZ, iz)
            }

            guard minIX != Int.max else { return nil }
            let projected = points.map { SIMD2<Float>($0.x, $0.z) }
            let footprint = convexHull2D(projected)
            let floorIndex = Int(floor((Float(aabb.minY) - origin.y) / voxelSize))
            var filledKeys = surfaceKeys
            var filledColumnCount = 0

            for (columnKey, topY) in maxYByColumn {
                let ix = (columnKey & 0xFFFFF) - 0x80000
                let iz = ((columnKey >> 20) & 0xFFFFF) - 0x80000
                let topIndex = Int(floor((topY - origin.y) / voxelSize))
                if floorIndex <= topIndex {
                    for iy in floorIndex...topIndex {
                        filledKeys.insert(voxelKey(Int64(ix), Int64(iy), Int64(iz)))
                    }
                }
                filledColumnCount += 1
            }

            if footprint.count >= 3 {
                for ix in minIX...maxIX {
                    for iz in minIZ...maxIZ {
                        let columnKey = gridKey(Int64(ix), Int64(iz))
                        if maxYByColumn[columnKey] != nil { continue }
                        let center = SIMD2<Float>(
                            origin.x + (Float(ix) + 0.5) * voxelSize,
                            origin.z + (Float(iz) + 0.5) * voxelSize
                        )
                        guard pointInsideConvexHull(center, hull: footprint) else { continue }
                        guard let topY = interpolatedColumnHeight(
                            ix: ix,
                            iz: iz,
                            known: maxYByColumn
                        ) else { continue }
                        let topIndex = Int(floor((topY - origin.y) / voxelSize))
                        if floorIndex <= topIndex {
                            for iy in floorIndex...topIndex {
                                filledKeys.insert(voxelKey(Int64(ix), Int64(iy), Int64(iz)))
                            }
                        }
                        filledColumnCount += 1
                    }
                }
            }

            if filledKeys.count <= maxVoxels {
                return VoxelizationData(
                    filledKeys: filledKeys,
                    origin: origin,
                    voxelSize: voxelSize,
                    floorIndex: floorIndex,
                    minIX: minIX,
                    minIY: minIY,
                    minIZ: minIZ,
                    maxIX: maxIX,
                    maxIY: maxIY,
                    maxIZ: maxIZ,
                    knownColumnCount: maxYByColumn.count,
                    filledColumnCount: filledColumnCount
                )
            }
            multiplier *= 1.6
        }
        return nil
    }

    static func voxelReconstruct(
        _ points: [ObjectPoint],
        targetVoxelsPerAxis: Int = 96,
        planes: [ScanPlaneInfo] = []
    ) -> VoxelReconstructionResult {
        guard points.count >= 8 else {
            return VoxelReconstructionResult(failureReason: "目标点过少")
        }
        let aabb = computeAABB(points)
        let maxDim = max(aabb.sizeX, aabb.sizeY, aabb.sizeZ)
        guard maxDim > 1e-6 else {
            return VoxelReconstructionResult(failureReason: "点云范围异常")
        }

        let sqrtCount = sqrt(Double(points.count))
        let target = min(max(Int((sqrtCount * 2).rounded()), 24), targetVoxelsPerAxis)
        let initialVoxelSize = max(Float(maxDim) / Float(target), 0.001)
        guard let voxelization = buildVoxelization(
            points: points,
            aabb: aabb,
            initialVoxelSize: initialVoxelSize,
            maxVoxels: 260_000
        ) else {
            return VoxelReconstructionResult(failureReason: "体素网格过大")
        }
        let origin = voxelization.origin
        let voxelSize = voxelization.voxelSize
        let filledKeys = voxelization.filledKeys
        let floorIndex = voxelization.floorIndex
        let minIX = voxelization.minIX
        let minIY = voxelization.minIY
        let minIZ = voxelization.minIZ
        let maxIX = voxelization.maxIX
        let maxIY = voxelization.maxIY
        let maxIZ = voxelization.maxIZ

        var voxels = VoxelHash<Float>(defaultVoxel: 1.0)
        for key in filledKeys {
            let index = decodeVoxelKey(key)
            voxels.set(VoxelIndex(index.0, index.1, index.2), newValue: -1.0)
        }

        let scale = VoxelScale(origin: origin, cubeSize: voxelSize)
        let renderBounds = VoxelBounds(
            min: VoxelIndex(minIX, minIY, minIZ),
            max: VoxelIndex(maxIX, maxIY, maxIZ)
        ).expand(1)
        let buffer = SurfaceNetRenderer().render(
            voxels,
            scale: scale,
            within: renderBounds
        )
        guard !buffer.positions.isEmpty, buffer.indices.count >= 3 else {
            return VoxelReconstructionResult(failureReason: "Surface Nets 生成失败")
        }

        let vertices = buffer.positions.map {
            HullVector(x: Double($0.x), y: Double($0.y), z: Double($0.z))
        }
        var triangles: [Triangle] = []
        triangles.reserveCapacity(buffer.indices.count / 3)
        var triangleIndex = 0
        while triangleIndex + 2 < buffer.indices.count {
            let a = Int(buffer.indices[triangleIndex])
            let b = Int(buffer.indices[triangleIndex + 1])
            let c = Int(buffer.indices[triangleIndex + 2])
            triangles.append(Triangle(a, b, c))
            triangleIndex += 3
        }
        let meshGL = MeshGL<HullVector>(vertices: vertices, triangles: triangles)
        let voxelVolume = Double(filledKeys.count)
            * Double(voxelSize * voxelSize * voxelSize)
        let rawArea = triangleSurfaceArea(meshGL)
        let knownColumns = Double(voxelization.knownColumnCount)
        let coverage = min(1, knownColumns / Double(max(voxelization.filledColumnCount, 1)))
        let rawContacts = contactAreas(
            from: meshGL,
            aabb: aabb,
            voxelSize: voxelSize,
            planes: planes
        )

        if let manifold = try? Manifold<HullVector>(meshGL) {
            let closedMesh = manifold.meshGL()
            let totalArea = max(0, manifold.surfaceArea)
            let contacts = contactAreas(
                from: closedMesh,
                aabb: aabb,
                voxelSize: voxelSize,
                planes: planes
            )
            let volume = max(0, manifold.volume)
            let excludedArea = max(0, totalArea - contacts.ground - contacts.wall)
            return VoxelReconstructionResult(
                succeeded: true,
                voxelSizeM: Double(voxelSize),
                volumeM3: volume,
                totalSurfaceAreaM2: totalArea,
                contactExcludedSurfaceAreaM2: excludedArea,
                groundContactAreaM2: contacts.ground,
                wallContactAreaM2: contacts.wall,
                coverageEstimate: coverage,
                vertexCount: closedMesh.vertexCount,
                triangleCount: closedMesh.triangleCount,
                usdzData: makeUSDZ(from: closedMesh)
            )
        }

        let excludedArea = max(0, rawArea - rawContacts.ground - rawContacts.wall)
        return VoxelReconstructionResult(
            succeeded: true,
            voxelNote: "网格未闭合，体积/表面积按体素近似",
            voxelSizeM: Double(voxelSize),
            volumeM3: voxelVolume,
            totalSurfaceAreaM2: rawArea,
            contactExcludedSurfaceAreaM2: excludedArea,
            groundContactAreaM2: rawContacts.ground,
            wallContactAreaM2: rawContacts.wall,
            coverageEstimate: coverage,
            vertexCount: meshGL.vertexCount,
            triangleCount: meshGL.triangleCount,
            usdzData: makeUSDZ(from: meshGL)
        )
    }

    private static func triangleSurfaceArea(_ mesh: MeshGL<HullVector>) -> Double {
        let vertices = mesh.vertices
        var total = 0.0
        for triangle in mesh.triangles {
            let a = SIMD3<Double>(
                vertices[triangle.a].x,
                vertices[triangle.a].y,
                vertices[triangle.a].z
            )
            let b = SIMD3<Double>(
                vertices[triangle.b].x,
                vertices[triangle.b].y,
                vertices[triangle.b].z
            )
            let c = SIMD3<Double>(
                vertices[triangle.c].x,
                vertices[triangle.c].y,
                vertices[triangle.c].z
            )
            let u = b - a
            let v = c - a
            total += simd_length(simd_cross(u, v)) * 0.5
        }
        return total
    }

    private static func pointInsideConvexHull(
        _ point: SIMD2<Float>,
        hull: [SIMD2<Float>]
    ) -> Bool {
        guard hull.count >= 3 else { return false }
        var sign: Float = 0
        for index in 0..<hull.count {
            let a = hull[index]
            let b = hull[(index + 1) % hull.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 1e-6 { continue }
            let currentSign: Float = cross > 0 ? 1 : -1
            if sign == 0 {
                sign = currentSign
            } else if sign != currentSign {
                return false
            }
        }
        return true
    }

    private static func interpolatedColumnHeight(
        ix: Int,
        iz: Int,
        known: [Int64: Float]
    ) -> Float? {
        for radius in 1...16 {
            var bestKey: Int64?
            var bestDistance = Float.greatestFiniteMagnitude
            for dx in -radius...radius {
                for dz in -radius...radius {
                    guard abs(dx) == radius || abs(dz) == radius else { continue }
                    let key = gridKey(Int64(ix + dx), Int64(iz + dz))
                    guard known[key] != nil else { continue }
                    let distance = Float(dx * dx + dz * dz)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestKey = key
                    }
                }
            }
            if let bestKey {
                return known[bestKey]
            }
        }
        return nil
    }

    private static func contactAreas(
        from mesh: MeshGL<HullVector>,
        aabb: ObjectScanMetrics.AABB,
        voxelSize: Float,
        planes: [ScanPlaneInfo] = []
    ) -> (ground: Double, wall: Double) {
        let vertices = mesh.vertices
        let tolerance = Double(voxelSize) * 0.75
        let groundY = aabb.minY + Double(voxelSize) * 0.5
        let minXPlane = aabb.minX + Double(voxelSize) * 0.5
        let maxXPlane = aabb.maxX + Double(voxelSize) * 0.5
        let minZPlane = aabb.minZ + Double(voxelSize) * 0.5
        let maxZPlane = aabb.maxZ + Double(voxelSize) * 0.5
        let wallPlanes = planes.filter { abs(Double($0.normalY)) < 0.7 }
        var groundArea = 0.0
        var wallArea = 0.0

        for triangle in mesh.triangles {
            let a = SIMD3<Double>(vertices[triangle.a].x, vertices[triangle.a].y, vertices[triangle.a].z)
            let b = SIMD3<Double>(vertices[triangle.b].x, vertices[triangle.b].y, vertices[triangle.b].z)
            let c = SIMD3<Double>(vertices[triangle.c].x, vertices[triangle.c].y, vertices[triangle.c].z)
            let u = b - a
            let v = c - a
            let normal = simd_normalize(simd_cross(u, v))
            let area = simd_length(simd_cross(u, v)) * 0.5
            let centroid = (a + b + c) / 3

            if abs(centroid.y - groundY) <= tolerance && normal.y < -0.5 {
                groundArea += area
                continue
            }
            if !wallPlanes.isEmpty {
                let wallMatch = wallPlanes.contains { plane in
                    let center = SIMD3<Double>(Double(plane.centerX), Double(plane.centerY), Double(plane.centerZ))
                    var planeNormal = SIMD3<Double>(
                        Double(plane.normalX),
                        Double(plane.normalY),
                        Double(plane.normalZ)
                    )
                    let planeNormalLength = simd_length(planeNormal)
                    guard planeNormalLength > 1e-6 else { return false }
                    planeNormal /= planeNormalLength
                    let distance = abs(simd_dot(centroid - center, planeNormal))
                    let normalAlignment = abs(simd_dot(normal, planeNormal))
                    return distance <= tolerance * 1.5 && normalAlignment > 0.7
                }
                if wallMatch {
                    wallArea += area
                    continue
                }
            }
            guard abs(normal.y) < 0.5 else { continue }
            if abs(centroid.x - maxXPlane) <= tolerance && normal.x > 0.5 {
                wallArea += area
            } else if abs(centroid.x - minXPlane) <= tolerance && normal.x < -0.5 {
                wallArea += area
            } else if abs(centroid.z - maxZPlane) <= tolerance && normal.z > 0.5 {
                wallArea += area
            } else if abs(centroid.z - minZPlane) <= tolerance && normal.z < -0.5 {
                wallArea += area
            }
        }
        return (groundArea, wallArea)
    }

    private static func decodeVoxelKey(_ key: Int64) -> (Int, Int, Int) {
        (
            Int((key & 0xFFFFF) - 0x80000),
            Int(((key >> 20) & 0xFFFFF) - 0x80000),
            Int(((key >> 40) & 0xFFFFF) - 0x80000)
        )
    }

    static func isBackgroundClassification(_ classification: Int?) -> Bool {
        guard let classification else { return false }
        // ARMeshClassification: 1 wall, 2 floor, 3 ceiling, 6 window, 7 door
        return classification == 1
            || classification == 2
            || classification == 3
            || classification == 6
            || classification == 7
    }

    static func voxelDownsample(_ points: [ObjectPoint], voxelSize: Float) -> [ObjectPoint] {
        guard voxelSize > 0, !points.isEmpty else { return points }
        var map: [Int64: VoxelAccumulator] = [:]
        for point in points {
            let key = voxelKey(point.position, voxelSize: voxelSize)
            var acc = map[key] ?? VoxelAccumulator()
            acc.sum += point.position
            acc.sumColor += SIMD3<Float>(point.r, point.g, point.b)
            acc.count += 1
            map[key] = acc
        }
        return map.values.map { acc -> ObjectPoint in
            let inv = 1 / max(acc.count, 1)
            let position = acc.sum * inv
            let color = acc.sumColor * inv
            return ObjectPoint(
                x: position.x,
                y: position.y,
                z: position.z,
                r: color.x,
                g: color.y,
                b: color.z
            )
        }
    }

    static func removeGround(_ points: [ObjectPoint]) -> ([ObjectPoint], Float) {
        guard !points.isEmpty else { return ([], 0) }
        let ys = points.map { $0.y }.sorted()
        let fallbackY = ys[min(ys.count - 1, max(0, ys.count / 25))]
        let threshold: Float = 0.05
        guard points.count >= 32 else {
            return (points.filter { $0.y >= fallbackY + threshold }, fallbackY)
        }
        let lowerLimit = ys[min(ys.count - 1, max(0, ys.count / 4))]
        let lowPoints = points.filter { $0.y <= lowerLimit }
        guard lowPoints.count >= 16 else {
            return (points.filter { $0.y >= fallbackY + threshold }, fallbackY)
        }

        var rng = SystemRandomNumberGenerator()
        var bestNormal = SIMD3<Float>(0, 1, 0)
        var bestPoint = SIMD3<Float>(0, fallbackY, 0)
        var bestInliers = 0

        for _ in 0..<60 {
            var i = Int.random(in: 0..<lowPoints.count, using: &rng)
            var j = Int.random(in: 0..<lowPoints.count, using: &rng)
            var k = Int.random(in: 0..<lowPoints.count, using: &rng)
            while j == i {
                j = Int.random(in: 0..<lowPoints.count, using: &rng)
            }
            while k == i || k == j {
                k = Int.random(in: 0..<lowPoints.count, using: &rng)
            }
            let a = lowPoints[i].position
            let b = lowPoints[j].position
            let c = lowPoints[k].position
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 1e-6 else { continue }
            normal /= length
            guard abs(normal.y) > 0.9 else { continue }

            var inliers = 0
            var index = 0
            while index < points.count {
                if abs(simd_dot(points[index].position - a, normal)) <= threshold {
                    inliers += 1
                }
                index += 4
            }
            let estimated = inliers * 4
            if estimated > bestInliers {
                bestInliers = estimated
                bestNormal = normal
                bestPoint = a
            }
        }

        var fullInliers = 0
        for point in points {
            if abs(simd_dot(point.position - bestPoint, bestNormal)) <= threshold {
                fullInliers += 1
            }
        }
        let minY = points.map { $0.y }.min() ?? fallbackY
        let isLowPlane = abs(bestPoint.y - minY) < 0.15
        guard fullInliers >= max(120, points.count / 20), isLowPlane else {
            return (points.filter { $0.y >= fallbackY + threshold }, fallbackY)
        }
        let kept = points.filter {
            abs(simd_dot($0.position - bestPoint, bestNormal)) > threshold
        }
        return (kept, bestPoint.y)
    }

    private static func removePlanePoints(
        _ points: [ObjectPoint],
        planes: [ScanPlaneInfo],
        distanceThreshold: Float = 0.05
    ) -> ([ObjectPoint], Int) {
        guard !planes.isEmpty else { return (points, 0) }
        let kept = points.filter { point in
            for plane in planes {
                let center = SIMD3<Float>(plane.centerX, plane.centerY, plane.centerZ)
                var normal = SIMD3<Float>(plane.normalX, plane.normalY, plane.normalZ)
                let normalLength = simd_length(normal)
                guard normalLength > 1e-6 else { continue }
                normal /= normalLength
                let distance = abs(simd_dot(point.position - center, normal))
                guard distance <= distanceThreshold else { continue }
                if planeContains(point.position, plane: plane, normal: normal, margin: 0.15) {
                    return false
                }
            }
            return true
        }
        return (kept, points.count - kept.count)
    }

    private static func planeContains(
        _ point: SIMD3<Float>,
        plane: ScanPlaneInfo,
        normal: SIMD3<Float>,
        margin: Float
    ) -> Bool {
        let reference = abs(normal.x) < 0.9
            ? SIMD3<Float>(1, 0, 0)
            : SIMD3<Float>(0, 1, 0)
        var u = simd_cross(normal, reference)
        let uLength = simd_length(u)
        guard uLength > 1e-6 else { return false }
        u /= uLength
        let v = simd_cross(normal, u)
        let center = SIMD3<Float>(plane.centerX, plane.centerY, plane.centerZ)
        let localX = abs(simd_dot(point - center, u))
        let localY = abs(simd_dot(point - center, v))
        return localX <= plane.width * 0.5 + margin
            && localY <= plane.height * 0.5 + margin
    }

    private static func isLikelyBackgroundCluster(
        _ points: [ObjectPoint],
        sceneAABB: ObjectScanMetrics.AABB? = nil
    ) -> Bool {
        guard points.count >= 30 else { return false }
        let aabb = computeAABB(points)
        let dims = [aabb.sizeX, aabb.sizeY, aabb.sizeZ].sorted(by: >)
        let largest = dims[0]
        let smallest = dims[2]
        let planarity = smallest / max(largest, 1e-6)
        if planarity < 0.10 && largest > 0.35 && smallest < 0.18 {
            return true
        }
        if aabb.sizeY < 0.18 && aabb.sizeX > 0.4 && aabb.sizeZ > 0.4 {
            return true
        }
        if let sceneAABB {
            let touchesX = aabb.minX <= sceneAABB.minX + 0.05 || aabb.maxX >= sceneAABB.maxX - 0.05
            let touchesZ = aabb.minZ <= sceneAABB.minZ + 0.05 || aabb.maxZ >= sceneAABB.maxZ - 0.05
            let touchesY = aabb.minY <= sceneAABB.minY + 0.05 || aabb.maxY >= sceneAABB.maxY - 0.05
            let boundaryTouches = [touchesX, touchesY, touchesZ].filter { $0 }.count
            if boundaryTouches >= 2 && planarity < 0.15 && largest > 0.4 {
                return true
            }
        }
        if points.count >= 60 {
            let mean = points.reduce(SIMD3<Float>.zero) { $0 + $1.position }
                / Float(points.count)
            var covariance = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
            for point in points {
                let d = point.position - mean
                for row in 0..<3 {
                    for column in 0..<3 {
                        covariance[row][column] += d[row] * d[column]
                    }
                }
            }
            let axes = jacobiEigenvectors(covariance)
            var extents: [Float] = []
            for axis in axes {
                var minValue = Float.greatestFiniteMagnitude
                var maxValue = -Float.greatestFiniteMagnitude
                for point in points {
                    let projection = simd_dot(point.position - mean, axis)
                    minValue = min(minValue, projection)
                    maxValue = max(maxValue, projection)
                }
                extents.append(max(maxValue - minValue, 0))
            }
            let sorted = extents.sorted(by: >)
            let spread = sorted[2] / max(sorted[0], 1e-6)
            if spread < 0.10 && sorted[0] > 0.4 && sorted[1] > 0.2 {
                return true
            }
        }
        return false
    }

    private static func removeLocalPlaneRegions(
        _ points: [ObjectPoint],
        cellSize: Float = 0.05,
        minAreaM2: Double = 0.5
    ) -> [ObjectPoint] {
        guard cellSize > 0, !points.isEmpty else { return points }
        var cells: [Int64: [ObjectPoint]] = [:]
        for point in points {
            cells[voxelKey(point.position, voxelSize: cellSize), default: []].append(point)
        }
        let cellArea = Double(cellSize * cellSize)
        let minCellCount = max(Int((minAreaM2 / cellArea).rounded()), 20)
        let globalMinY = points.map { $0.y }.min() ?? 0

        var offsets: [SIMD3<Int64>] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    if dx != 0 || dy != 0 || dz != 0 {
                        offsets.append(SIMD3<Int64>(Int64(dx), Int64(dy), Int64(dz)))
                    }
                }
            }
        }

        func neighborKeys(of key: Int64) -> [Int64] {
            let ix = (key & 0xFFFFF) - 0x80000
            let iy = ((key >> 20) & 0xFFFFF) - 0x80000
            let iz = ((key >> 40) & 0xFFFFF) - 0x80000
            return offsets.map { voxelKey(ix + $0.x, iy + $0.y, iz + $0.z) }
        }

        var flatKeys = Set<Int64>()
        for (key, cellPoints) in cells {
            guard cellPoints.count >= 4 else { continue }
            var neighborPoints = cellPoints
            for neighborKey in neighborKeys(of: key) {
                if let neighbor = cells[neighborKey] {
                    neighborPoints.append(contentsOf: neighbor)
                }
            }
            guard neighborPoints.count >= 16 else { continue }

            let mean = neighborPoints.reduce(SIMD3<Float>.zero) { $0 + $1.position }
                / Float(neighborPoints.count)
            let yMin = neighborPoints.map { $0.y }.min() ?? mean.y
            let yMax = neighborPoints.map { $0.y }.max() ?? mean.y
            let ySpread = yMax - yMin
            var covariance = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
            for point in neighborPoints {
                let d = point.position - mean
                for row in 0..<3 {
                    for column in 0..<3 {
                        covariance[row][column] += d[row] * d[column]
                    }
                }
            }
            let axes = jacobiEigenvectors(covariance)
            var extents: [Float] = []
            for axis in axes {
                var minValue = Float.greatestFiniteMagnitude
                var maxValue = -Float.greatestFiniteMagnitude
                for point in neighborPoints {
                    let projection = simd_dot(point.position - mean, axis)
                    minValue = min(minValue, projection)
                    maxValue = max(maxValue, projection)
                }
                extents.append(max(maxValue - minValue, 0))
            }
            let sorted = extents.sorted(by: >)
            let planarity = sorted[2] / max(sorted[0], 1e-6)
            var minExtentIndex = 0
            for index in 1..<extents.count where extents[index] < extents[minExtentIndex] {
                minExtentIndex = index
            }
            let verticalness = abs(axes[minExtentIndex].y)
            let isFloor = verticalness > 0.85 && (mean.y - globalMinY) < 0.15
            let isWall = verticalness < 0.25 && ySpread >= 0.4
            guard planarity < 0.18, isFloor || isWall else { continue }
            flatKeys.insert(key)
        }

        guard !flatKeys.isEmpty else { return points }
        var visited = Set<Int64>()
        var removeKeys = Set<Int64>()
        for key in flatKeys {
            guard !visited.contains(key) else { continue }
            visited.insert(key)
            var stack = [key]
            var region: Set<Int64> = [key]
            while let current = stack.popLast() {
                for neighborKey in neighborKeys(of: current) {
                    if flatKeys.contains(neighborKey) && !visited.contains(neighborKey) {
                        visited.insert(neighborKey)
                        region.insert(neighborKey)
                        stack.append(neighborKey)
                    }
                }
            }
            if Double(region.count) * cellArea >= minAreaM2 {
                removeKeys.formUnion(region)
            }
        }
        guard !removeKeys.isEmpty, removeKeys.count >= minCellCount else {
            return points
        }
        return points.filter {
            !removeKeys.contains(voxelKey($0.position, voxelSize: cellSize))
        }
    }

    static func removeDominantPlanes(
        _ points: [ObjectPoint],
        distanceThreshold: Float = 0.04
    ) -> [ObjectPoint] {
        guard points.count > 400 else { return points }
        var working = points
        for _ in 0..<8 {
            let cleaned = removeLargestPlane(working, distanceThreshold: distanceThreshold)
            if cleaned.count == working.count { break }
            working = cleaned
            if working.count < 100 { break }
        }
        return working
    }

    private static func removeLargestPlane(
        _ points: [ObjectPoint],
        distanceThreshold: Float
    ) -> [ObjectPoint] {
        let count = points.count
        guard count >= 16 else { return points }
        var rng = SystemRandomNumberGenerator()
        let minInliers = max(200, count / 8)
        var bestNormal = SIMD3<Float>(0, 1, 0)
        var bestPoint = SIMD3<Float>.zero
        var bestInliers = 0

        for _ in 0..<120 {
            var i = Int.random(in: 0..<count, using: &rng)
            var j = Int.random(in: 0..<count, using: &rng)
            var k = Int.random(in: 0..<count, using: &rng)
            while j == i {
                j = Int.random(in: 0..<count, using: &rng)
            }
            while k == i || k == j {
                k = Int.random(in: 0..<count, using: &rng)
            }
            let a = points[i].position
            let b = points[j].position
            let c = points[k].position
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 1e-6 else { continue }
            normal /= length

            var inliers = 0
            var index = 0
            while index < count {
                let point = points[index]
                if abs(simd_dot(point.position - a, normal)) <= distanceThreshold {
                    inliers += 1
                }
                index += 4
            }
            let estimated = inliers * 4
            if estimated > bestInliers {
                bestInliers = estimated
                bestNormal = normal
                bestPoint = a
            }
        }

        var fullInliers = 0
        for point in points {
            if abs(simd_dot(point.position - bestPoint, bestNormal)) <= distanceThreshold {
                fullInliers += 1
            }
        }
        guard fullInliers >= minInliers else { return points }
        let minY = points.map { $0.y }.min() ?? 0
        let planeHeight = simd_dot(bestPoint, bestNormal)
        let verticalness = abs(bestNormal.y)
        let isFloor = verticalness > 0.85 && (planeHeight - minY) < 0.15
        let isWall = verticalness < 0.4 && Float(fullInliers) >= Float(count) * 0.08
        guard isFloor || isWall else { return points }

        return points.filter {
            abs(simd_dot($0.position - bestPoint, bestNormal)) > distanceThreshold
        }
    }

    static func connectedClusters(_ points: [ObjectPoint], cellSize: Float = 0.08) -> [[ObjectPoint]] {
        guard cellSize > 0, !points.isEmpty else { return [] }
        var cells: [Int64: [ObjectPoint]] = [:]
        for point in points {
            let ix = Int64(floor(point.x / cellSize))
            let iy = Int64(floor(point.y / cellSize))
            let iz = Int64(floor(point.z / cellSize))
            cells[voxelKey(ix, iy, iz), default: []].append(point)
        }

        var offsets: [SIMD3<Int64>] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    if dx != 0 || dy != 0 || dz != 0 {
                        offsets.append(SIMD3<Int64>(Int64(dx), Int64(dy), Int64(dz)))
                    }
                }
            }
        }

        var visited = Set<Int64>()
        var clusters: [[ObjectPoint]] = []
        for key in cells.keys {
            guard !visited.contains(key) else { continue }
            visited.insert(key)
            var stack = [key]
            var cluster: [ObjectPoint] = []
            while let current = stack.popLast() {
                cluster.append(contentsOf: cells[current] ?? [])
                let ix = (current & 0xFFFFF) - 0x80000
                let iy = ((current >> 20) & 0xFFFFF) - 0x80000
                let iz = ((current >> 40) & 0xFFFFF) - 0x80000
                for offset in offsets {
                    let neighborKey = voxelKey(ix + offset.x, iy + offset.y, iz + offset.z)
                    if cells[neighborKey] != nil && !visited.contains(neighborKey) {
                        visited.insert(neighborKey)
                        stack.append(neighborKey)
                    }
                }
            }
            clusters.append(cluster)
        }
        return clusters
    }

    static func computeAABB(_ points: [ObjectPoint]) -> ObjectScanMetrics.AABB {
        guard !points.isEmpty else {
            return ObjectScanMetrics.AABB(minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 0, maxZ: 0)
        }
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        let zs = points.map { Double($0.z) }
        return ObjectScanMetrics.AABB(
            minX: xs.min() ?? 0,
            minY: ys.min() ?? 0,
            minZ: zs.min() ?? 0,
            maxX: xs.max() ?? 0,
            maxY: ys.max() ?? 0,
            maxZ: zs.max() ?? 0
        )
    }

    static func computeOBB(_ points: [ObjectPoint]) -> OBBResult {
        guard points.count >= 3 else {
            return OBBResult(lengthM: 0, widthM: 0, heightM: 0)
        }
        let mean = points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(points.count)
        var covariance = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        for point in points {
            let d = point.position - mean
            for row in 0..<3 {
                for column in 0..<3 {
                    covariance[row][column] += d[row] * d[column]
                }
            }
        }
        let eigenvectors = jacobiEigenvectors(covariance)
        var extents: [Float] = []
        for axis in eigenvectors {
            var minValue = Float.greatestFiniteMagnitude
            var maxValue = -Float.greatestFiniteMagnitude
            for point in points {
                let projection = simd_dot(point.position - mean, axis)
                minValue = min(minValue, projection)
                maxValue = max(maxValue, projection)
            }
            extents.append(max(maxValue - minValue, 0))
        }
        let sorted = extents.sorted(by: >)
        return OBBResult(
            lengthM: Double(sorted[0]),
            widthM: Double(sorted[1]),
            heightM: Double(sorted[2])
        )
    }

    static func footprintArea(_ points: [ObjectPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        let projected = points.map { SIMD2<Float>($0.x, $0.z) }
        let hull = convexHull2D(projected)
        guard hull.count >= 3 else { return 0 }
        var area: Double = 0
        for index in 0..<hull.count {
            let a = hull[index]
            let b = hull[(index + 1) % hull.count]
            area += Double(a.x * b.y - b.x * a.y)
        }
        return abs(area) * 0.5
    }

    private static func convexHull2D(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let sorted = points.sorted {
            $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y
        }
        guard sorted.count >= 3 else { return sorted }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [SIMD2<Float>] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    static func computeHeightfield(
        _ points: [ObjectPoint],
        groundY: Float,
        gridSize: Float
    ) -> (volumeM3: Double, surfaceAreaM2: Double) {
        guard gridSize > 0, !points.isEmpty else { return (0, 0) }
        var heights: [Int64: Float] = [:]
        for point in points {
            let key = gridKey(point.position, gridSize: gridSize)
            let height = max(0, point.y - groundY)
            if let existing = heights[key] {
                heights[key] = max(existing, height)
            } else {
                heights[key] = height
            }
        }
        let cellArea = Double(gridSize * gridSize)
        var volume = 0.0
        var surfaceArea = 0.0
        let size = Float(gridSize)

        func heightAt(_ ix: Int64, _ iz: Int64) -> Float? {
            heights[gridKey(ix, iz)]
        }

        for key in heights.keys {
            let ix = (key & 0xFFFFF) - 0x80000
            let iz = ((key >> 20) & 0xFFFFF) - 0x80000
            guard let h00 = heightAt(ix, iz) else { continue }
            volume += Double(h00) * cellArea

            let h10 = heightAt(ix + 1, iz) ?? h00
            let h01 = heightAt(ix, iz + 1) ?? h00
            let h11 = heightAt(ix + 1, iz + 1) ?? h10

            let a = SIMD3<Float>(0, 0, 0)
            let b = SIMD3<Float>(size, h10 - h00, 0)
            let c = SIMD3<Float>(0, h01 - h00, size)
            surfaceArea += triangleArea(a, b, c)

            let d = SIMD3<Float>(size, h11 - h00, size)
            surfaceArea += triangleArea(b, d, c)
        }
        return (volume, surfaceArea)
    }

    static func convexHull(
        _ points: [ObjectPoint]
    ) -> (volumeM3: Double, surfaceAreaM2: Double, usdzData: Data?) {
        guard points.count >= 4 else { return (0, 0, nil) }
        let vectors = points.map {
            HullVector(
                x: Double($0.x),
                y: Double($0.y),
                z: Double($0.z)
            )
        }
        let hull = Manifold<HullVector>.hull(vectors)
        let volume = max(0, hull.volume)
        let surfaceArea = max(0, hull.surfaceArea)
        let usdz = makeUSDZ(from: hull.meshGL())
        return (volume, surfaceArea, usdz)
    }

    static func plyData(points: [ObjectPoint]) -> Data {
        var text = """
        ply
        format ascii 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        for point in points {
            text += String(
                format: "%.5f %.5f %.5f %d %d %d\n",
                point.x, point.y, point.z,
                Int32(point.r * 255), Int32(point.g * 255), Int32(point.b * 255)
            )
        }
        return Data(text.utf8)
    }

    private static func makeUSDZ(from mesh: MeshGL<HullVector>) -> Data? {
        let vertices = mesh.vertices.map {
            SCNVector3(Float($0.x), Float($0.y), Float($0.z))
        }
        guard !vertices.isEmpty else { return nil }
        let indices = mesh.triangles.flatMap { [$0.a, $0.b, $0.c] }.map { Int32($0) }
        guard !indices.isEmpty else { return nil }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.75, green: 0.82, blue: 0.9, alpha: 1)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usdz")
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func jacobiEigenvectors(_ matrix: [[Float]]) -> [SIMD3<Float>] {
        var a = matrix
        var v = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        v[0][0] = 1
        v[1][1] = 1
        v[2][2] = 1

        for _ in 0..<64 {
            var p = 0
            var q = 1
            var largest = abs(a[0][1])
            if abs(a[0][2]) > largest {
                p = 0
                q = 2
                largest = abs(a[0][2])
            }
            if abs(a[1][2]) > largest {
                p = 1
                q = 2
                largest = abs(a[1][2])
            }
            if largest < 1e-12 { break }

            let app = a[p][p]
            let aqq = a[q][q]
            let apq = a[p][q]
            let tau = (aqq - app) / (2 * apq)
            let t = tau >= 0
                ? 1 / (tau + sqrt(1 + tau * tau))
                : -1 / (-tau + sqrt(1 + tau * tau))
            let c = 1 / sqrt(1 + t * t)
            let s = t * c

            for k in 0..<3 where k != p && k != q {
                let akp = a[k][p]
                let akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[p][k] = a[k][p]
                a[k][q] = s * akp + c * akq
                a[q][k] = a[k][q]
            }

            let appNew = c * c * app - 2 * s * c * apq + s * s * aqq
            let aqqNew = s * s * app + 2 * s * c * apq + c * c * aqq
            a[p][p] = appNew
            a[q][q] = aqqNew
            a[p][q] = 0
            a[q][p] = 0

            for i in 0..<3 {
                let vip = v[i][p]
                let viq = v[i][q]
                v[i][p] = c * vip - s * viq
                v[i][q] = s * vip + c * viq
            }
        }

        return [
            SIMD3<Float>(v[0][0], v[1][0], v[2][0]),
            SIMD3<Float>(v[0][1], v[1][1], v[2][1]),
            SIMD3<Float>(v[0][2], v[1][2], v[2][2])
        ]
    }

    private static func triangleArea(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Double {
        let ab = b - a
        let ac = c - a
        let cross = SIMD3<Float>(
            ab.y * ac.z - ab.z * ac.y,
            ab.z * ac.x - ab.x * ac.z,
            ab.x * ac.y - ab.y * ac.x
        )
        return Double(simd_length(cross)) * 0.5
    }

    private static func voxelKey(_ p: SIMD3<Float>, voxelSize: Float) -> Int64 {
        let ix = Int64(floor(p.x / voxelSize))
        let iy = Int64(floor(p.y / voxelSize))
        let iz = Int64(floor(p.z / voxelSize))
        return voxelKey(ix, iy, iz)
    }

    private static func voxelKey(_ ix: Int64, _ iy: Int64, _ iz: Int64) -> Int64 {
        ((ix + 0x80000) & 0xFFFFF) | (((iy + 0x80000) & 0xFFFFF) << 20) | (((iz + 0x80000) & 0xFFFFF) << 40)
    }

    private static func gridKey(_ p: SIMD3<Float>, gridSize: Float) -> Int64 {
        gridKey(Int64(floor(p.x / gridSize)), Int64(floor(p.z / gridSize)))
    }

    private static func gridKey(_ ix: Int64, _ iz: Int64) -> Int64 {
        ((ix + 0x80000) & 0xFFFFF) | (((iz + 0x80000) & 0xFFFFF) << 20)
    }
}
