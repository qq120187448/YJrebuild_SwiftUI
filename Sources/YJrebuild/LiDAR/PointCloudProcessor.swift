import Foundation
import SceneKit

/// 点云处理算法集合
class PointCloudProcessor {
    typealias Point3D = SIMD3<Float>

    /// Voxel grid downsampling
    static func downsample(_ points: [Point3D], voxelSize: Float) -> [Point3D] {
        var grid: [String: Point3D] = [:]
        for p in points {
            let key = "\(Int(p.x / voxelSize)),\(Int(p.y / voxelSize)),\(Int(p.z / voxelSize))"
            grid[key] = p
        }
        return Array(grid.values)
    }

    /// Statistical outlier removal
    static func removeOutliers(_ points: [Point3D], k: Int = 10, threshold: Float = 1.0) -> [Point3D] {
        guard points.count > k else { return points }
        var result: [Point3D] = []
        for (i, p) in points.enumerated() {
            let neighbors = points.enumerated()
                .filter { $0.offset != i }
                .map { ($0.element, distance($0.element, p)) }
                .sorted { $0.1 < $1.1 }
                .prefix(k)
            let meanDist = neighbors.map { $0.1 }.reduce(0, +) / Float(k)
            if meanDist < threshold { result.append(p) }
        }
        return result
    }

    /// Laplacian smoothing
    static func smooth(_ points: [Point3D], iterations: Int = 3) -> [Point3D] {
        guard points.count > 10, iterations > 0 else { return points }
        var result = points
        for _ in 0..<iterations {
            var smoothed = result
            for (i, p) in result.enumerated() {
                let neighbors = result.enumerated()
                    .filter { $0.offset != i }
                    .sorted { distance($0.element, p) < distance($1.element, p) }
                    .prefix(8)
                    .map { $0.element }
                guard !neighbors.isEmpty else { continue }
                let avg = Point3D(
                    neighbors.map { $0.x }.reduce(0, +) / Float(neighbors.count),
                    neighbors.map { $0.y }.reduce(0, +) / Float(neighbors.count),
                    neighbors.map { $0.z }.reduce(0, +) / Float(neighbors.count)
                )
                smoothed[i] = Point3D(p.x * 0.5 + avg.x * 0.5, p.y * 0.5 + avg.y * 0.5, p.z * 0.5 + avg.z * 0.5)
            }
            result = smoothed
        }
        return result
    }

    /// Decimate by ratio
    static func simplify(_ points: [Point3D], ratio: Float) -> [Point3D] {
        let target = max(Int(Float(points.count) * ratio), 10)
        let step = max(points.count / target, 1)
        var result: [Point3D] = []
        for i in stride(from: 0, to: points.count, by: step) {
            result.append(points[i])
        }
        return result
    }

    private static func distance(_ a: Point3D, _ b: Point3D) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}
