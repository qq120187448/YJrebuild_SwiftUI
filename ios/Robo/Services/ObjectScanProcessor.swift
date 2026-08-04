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

    init(x: Float, y: Float, z: Float, r: Float = 0.7, g: Float = 0.8, b: Float = 1.0) {
        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.g = g
        self.b = b
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
    var groundY: Double
    var aabb: AABB
    var heightfieldVolumeM3: Double
    var heightfieldSurfaceAreaM2: Double
    var convexHullVolumeM3: Double
    var convexHullSurfaceAreaM2: Double
}

struct ObjectScanProcessResult: Sendable {
    var metrics: ObjectScanMetrics
    var metricsJSON: Data
    var plyData: Data
    var usdzData: Data?
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
        let downsampled = voxelDownsample(points, voxelSize: voxelSize)
        let (keptPoints, groundY) = removeGround(downsampled)
        let aabb = computeAABB(keptPoints)
        let heightfield = computeHeightfield(keptPoints, groundY: groundY, gridSize: gridSize)
        let hull = convexHull(keptPoints)

        let metrics = ObjectScanMetrics(
            pointCount: points.count,
            processedPointCount: keptPoints.count,
            groundY: Double(groundY),
            aabb: aabb,
            heightfieldVolumeM3: heightfield.volumeM3,
            heightfieldSurfaceAreaM2: heightfield.surfaceAreaM2,
            convexHullVolumeM3: hull.volumeM3,
            convexHullSurfaceAreaM2: hull.surfaceAreaM2
        )
        let metricsJSON = try JSONEncoder().encode(metrics)
        let ply = plyData(points: downsampled)
        return ObjectScanProcessResult(
            metrics: metrics,
            metricsJSON: metricsJSON,
            plyData: ply,
            usdzData: hull.usdzData
        )
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
        let g = Double(gridSize)
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
        let ix = Int64(floor(p.x / voxelSize)) + 0x80000
        let iy = Int64(floor(p.y / voxelSize)) + 0x80000
        let iz = Int64(floor(p.z / voxelSize)) + 0x80000
        return (ix & 0xFFFFF) | ((iy & 0xFFFFF) << 20) | ((iz & 0xFFFFF) << 40)
    }

    private static func gridKey(_ p: SIMD3<Float>, gridSize: Float) -> Int64 {
        gridKey(Int64(floor(p.x / gridSize)), Int64(floor(p.z / gridSize)))
    }

    private static func gridKey(_ ix: Int64, _ iz: Int64) -> Int64 {
        ((ix + 0x80000) & 0xFFFFF) | (((iz + 0x80000) & 0xFFFFF) << 20)
    }
}
