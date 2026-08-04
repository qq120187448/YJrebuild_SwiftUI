import Foundation
import UIKit
import SceneKit
import simd
import Manifold3D

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

struct ObjectPoint: Codable, Sendable {
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

enum ObjectScanProcessor {
    private struct VoxelAccumulator {
        var sum = SIMD3<Float>.zero
        var sumColor = SIMD3<Float>.zero
        var count: Float = 0
    }

    static func process(
        points: [ObjectPoint],
        voxelSize: Float = 0.02,
        gridSize: Float = 0.05
    ) throws -> ObjectScanProcessResult {
        let nonBackground = points.filter { !isBackgroundClassification($0.classification) }
        let source = nonBackground.isEmpty ? points : nonBackground
        let downsampled = voxelDownsample(source, voxelSize: voxelSize)
        let (keptPoints, groundY) = removeGround(downsampled)
        let planeCleaned = removeDominantPlanes(keptPoints)
        let allClusters = connectedClusters(planeCleaned, cellSize: 0.08)
        let candidateClusters = allClusters
            .filter { $0.count >= 20 }
            .sorted { $0.count > $1.count }
        let totalClusterCount = allClusters.count
        let candidates = candidateClusters.isEmpty ? [keptPoints] : Array(candidateClusters.prefix(6))

        var options: [ObjectScanClusterOption] = []
        for cluster in candidates {
            let aabb = computeAABB(cluster)
            let obb = computeOBB(cluster)
            let heightfield = computeHeightfield(cluster, groundY: groundY, gridSize: gridSize)
            let hull = convexHull(cluster)
            let footprint = footprintArea(cluster)
            let metrics = ObjectScanMetrics(
                pointCount: points.count,
                processedPointCount: keptPoints.count,
                targetPointCount: cluster.count,
                clusterCount: totalClusterCount,
                groundY: Double(groundY),
                aabb: aabb,
                obbLengthM: obb.lengthM,
                obbWidthM: obb.widthM,
                obbHeightM: obb.heightM,
                heightfieldVolumeM3: heightfield.volumeM3,
                heightfieldSurfaceAreaM2: heightfield.surfaceAreaM2,
                convexHullVolumeM3: hull.volumeM3,
                convexHullSurfaceAreaM2: hull.surfaceAreaM2,
                footprintAreaM2: footprint,
                groundContactAreaM2: footprint,
                wallContactAreaM2: 0
            )
            options.append(
                ObjectScanClusterOption(
                    points: cluster,
                    metrics: metrics,
                    usdzData: hull.usdzData
                )
            )
        }

        let primary = options[0]
        let metricsJSON = try JSONEncoder().encode(primary.metrics)
        let ply = plyData(points: primary.points)
        return ObjectScanProcessResult(
            clusters: options,
            allPoints: planeCleaned,
            points: primary.points,
            metrics: primary.metrics,
            metricsJSON: metricsJSON,
            plyData: ply,
            usdzData: primary.usdzData
        )
    }

    static func metrics(for points: [ObjectPoint]) -> ObjectScanMetrics {
        guard !points.isEmpty else {
            return ObjectScanMetrics(
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
            )
        }
        let groundY = points.map { $0.y }.min() ?? 0
        let aabb = computeAABB(points)
        let obb = computeOBB(points)
        let heightfield = computeHeightfield(points, groundY: groundY, gridSize: 0.05)
        let hull = convexHull(points)
        let footprint = footprintArea(points)
        return ObjectScanMetrics(
            pointCount: points.count,
            processedPointCount: points.count,
            targetPointCount: points.count,
            clusterCount: 1,
            groundY: Double(groundY),
            aabb: aabb,
            obbLengthM: obb.lengthM,
            obbWidthM: obb.widthM,
            obbHeightM: obb.heightM,
            heightfieldVolumeM3: heightfield.volumeM3,
            heightfieldSurfaceAreaM2: heightfield.surfaceAreaM2,
            convexHullVolumeM3: hull.volumeM3,
            convexHullSurfaceAreaM2: hull.surfaceAreaM2,
            footprintAreaM2: footprint,
            groundContactAreaM2: footprint,
            wallContactAreaM2: 0
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
        let index = min(ys.count - 1, max(0, ys.count / 50))
        let groundY = ys[index]
        let threshold = groundY + 0.01
        return (points.filter { $0.y >= threshold }, groundY)
    }

    static func removeDominantPlanes(
        _ points: [ObjectPoint],
        distanceThreshold: Float = 0.03
    ) -> [ObjectPoint] {
        guard points.count > 800 else { return points }
        var working = points
        for _ in 0..<3 {
            let cleaned = removeLargestPlane(working, distanceThreshold: distanceThreshold)
            if cleaned.count == working.count { break }
            working = cleaned
            if working.count < 200 { break }
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
        let minInliers = max(400, count / 8)
        var bestNormal = SIMD3<Float>(0, 1, 0)
        var bestPoint = SIMD3<Float>.zero
        var bestInliers = 0

        for _ in 0..<80 {
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
        let isFloor = verticalness > 0.85 && (planeHeight - minY) < 0.12
        let isWall = verticalness < 0.3 && Float(fullInliers) >= Float(count) * 0.18
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
