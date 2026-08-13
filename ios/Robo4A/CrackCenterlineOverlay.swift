import Foundation
import UIKit

/// 4A 折线方案（用户定稿）：
/// mask（protos×系数→上采样）→ 框内自适应稀疏化采样（保连通）
/// → Zhang-Suen 类骨架化 → 端点回溯剪枝(<30px) → 按长度保留 1~5 条主裂缝(≥80px)
/// → 每分量 BFS 最长路径 → 有序点序列 → Douglas-Peucker(ε=1.5px) → 采样点。
/// 每条主裂缝只输出一条折线，避免重复计算。
enum CrackCenterlineOverlay {

    struct Result {
        /// 每条主裂缝一条折线（有序 + DP 简化）
        var polylines: [[CrackPoint]]
        /// 每条折线的等距采样点（供 4B raycast）
        var samplePointsPerPolyline: [[CrackPoint]]
        /// 全部采样点（按折线顺序拼接）
        var samplePoints: [CrackPoint]
        var maskPixelCount: Int
        var sparsePointCount: Int
        var skeletonPointCount: Int
        var componentCount: Int
        var totalPixelLength: Double
        var longestPixelLength: Double
        var maxWidthPx: Double
        var averageWidthPx: Double
    }

    static func compute(
        masks: [MaskPrediction],
        imageSize: CGSize,
        config: CrackRecognitionConfig = .defaultConfig
    ) -> Result {
        let width = max(1, Int(imageSize.width.rounded()))
        let height = max(1, Int(imageSize.height.rounded()))

        // 1. mask → 全图 bool 网格（每个 mask 单元覆盖整片像素，保证连通）
        var grid = [Bool](repeating: false, count: width * height)
        for prediction in masks {
            let maskWidth = prediction.maskSize.width
            let maskHeight = prediction.maskSize.height
            guard maskWidth > 0, maskHeight > 0,
                  prediction.mask.count >= maskWidth * maskHeight else {
                continue
            }
            let scaleX = CGFloat(width) / CGFloat(maskWidth)
            let scaleY = CGFloat(height) / CGFloat(maskHeight)
            for y in 0..<maskHeight {
                for x in 0..<maskWidth where prediction.mask[y * maskWidth + x] > 0 {
                    let x0 = Int(CGFloat(x) * scaleX)
                    let x1 = Int(CGFloat(x + 1) * scaleX)
                    let y0 = Int(CGFloat(y) * scaleY)
                    let y1 = Int(CGFloat(y + 1) * scaleY)
                    for py in y0..<max(y0 + 1, y1) {
                        for px in x0..<max(x0 + 1, x1) {
                            grid[py * width + px] = true
                        }
                    }
                }
            }
        }

        var maskPixelCount = 0
        for value in grid where value {
            maskPixelCount += 1
        }
        let widthStats = crackWidthStats(
            grid: grid,
            width: width,
            height: height
        )

        // 2. 框内自适应稀疏化采样（保连通）：间距随图像尺寸自适应
        let spacing = max(
            2,
            Int(ceil(Double(max(width, height)) / 1024.0)) * 2
        )
        var sparse = Set<CrackPoint>()
        for y in stride(from: 0, to: height, by: spacing) {
            for x in stride(from: 0, to: width, by: spacing) where grid[y * width + x] {
                sparse.insert(CrackPoint(x: x, y: y))
            }
        }

        // 3. 骨架化：Zhang-Suen 类细化 + 端点回溯剪枝(<30px) + 保留 1~5 条(≥80px)
        var crackConfig = config
        crackConfig.skeletonMode = "main"
        crackConfig.minSpurLength = 30
        crackConfig.minSkeletonLength = 80
        crackConfig.topCracks = 5
        let skeleton = CrackSkeleton.analyzeSparse(
            points: sparse,
            spacing: spacing,
            width: width,
            height: height,
            config: crackConfig
        )
        // skeletonPoints 只含“剪枝后保留的主裂缝”点集
        let groups = CrackSkeleton.componentPointsSparse(
            skeleton.skeletonPoints,
            spacing: spacing
        )

        // 4. 每分量 BFS 最长路径 → DP 简化 → 一条折线
        var polylines: [[CrackPoint]] = []
        var samplesPerPolyline: [[CrackPoint]] = []
        for group in groups {
            let path = longestPath(in: Set(group), spacing: spacing)
            guard path.count >= 2 else { continue }
            let simplified = CrackSkeleton.douglasPeucker(
                path,
                epsilon: 1.5
            )
            let length = polylineLength(simplified)
            guard length >= Double(crackConfig.minSkeletonLength) else {
                continue
            }
            polylines.append(simplified)
            samplesPerPolyline.append(
                CrackSamplePoints.evenlySpaced(
                    simplified,
                    spacingPx: 24,
                    maxPoints: 64
                )
            )
        }

        // 5. 按长度降序，最多 5 条
        let indexed = polylines.indices.sorted {
            polylineLength(polylines[$0]) > polylineLength(polylines[$1])
        }
        let keptIndices = indexed.prefix(5)
        polylines = keptIndices.map { polylines[$0] }
        samplesPerPolyline = keptIndices.map { samplesPerPolyline[$0] }

        let total = polylines.reduce(0.0) { $0 + polylineLength($1) }
        let longest = polylines.map(polylineLength).max() ?? 0
        let flatSamples = samplesPerPolyline.flatMap { $0 }

        return Result(
            polylines: polylines,
            samplePointsPerPolyline: samplesPerPolyline,
            samplePoints: flatSamples,
            maskPixelCount: maskPixelCount,
            sparsePointCount: sparse.count,
            skeletonPointCount: skeleton.skeletonPoints.count,
            componentCount: groups.count,
            totalPixelLength: total,
            longestPixelLength: longest,
            maxWidthPx: widthStats.maxWidthPx,
            averageWidthPx: widthStats.averageWidthPx
        )
    }

    /// 用二值掩码到背景的 8 邻域距离场估算裂缝宽度：
    /// 每个前景点到最近背景的距离视为“半宽”，宽度=2×半宽。
    /// 返回最大宽度与平均宽度（像素）。
    private static func crackWidthStats(
        grid: [Bool],
        width: Int,
        height: Int
    ) -> (maxWidthPx: Double, averageWidthPx: Double) {
        guard width > 0, height > 0, grid.count == width * height else {
            return (0, 0)
        }
        let infinity = Int.max
        var distance = [Int](repeating: infinity, count: grid.count)
        var queue: [Int] = []
        queue.reserveCapacity(grid.count)

        for index in 0..<grid.count where !grid[index] {
            distance[index] = 0
            queue.append(index)
        }

        let directions = [
            (1, 0), (-1, 0), (0, 1), (0, -1),
            (1, 1), (1, -1), (-1, 1), (-1, -1)
        ]
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            let nextDistance = distance[index] + 1
            for (dx, dy) in directions {
                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else {
                    continue
                }
                let neighbor = ny * width + nx
                if distance[neighbor] > nextDistance {
                    distance[neighbor] = nextDistance
                    queue.append(neighbor)
                }
            }
        }

        var sum = 0.0
        var count = 0
        var maxDistance = 0
        for index in 0..<grid.count where grid[index] {
            let value = distance[index]
            guard value != infinity else { continue }
            sum += Double(value)
            count += 1
            if value > maxDistance {
                maxDistance = value
            }
        }
        guard count > 0 else { return (0, 0) }
        return (
            maxWidthPx: Double(maxDistance) * 2,
            averageWidthPx: (sum / Double(count)) * 2
        )
    }

    /// 骨架图上 BFS 求直径（两次 BFS），返回从一端到另一端的有序路径。
    private static func longestPath(
        in points: Set<CrackPoint>,
        spacing: Int
    ) -> [CrackPoint] {
        guard let start = points.first else { return [] }
        let step = max(1, spacing)

        func bfs(
            from source: CrackPoint
        ) -> (CrackPoint, [CrackPoint: CrackPoint]) {
            var visited = Set<CrackPoint>([source])
            var parent: [CrackPoint: CrackPoint] = [:]
            var queue = [source]
            var queueIndex = 0
            var last = source
            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1
                last = current
                for dy in -step...step where dy % step == 0 {
                    for dx in -step...step where dx % step == 0 {
                        if dy == 0 && dx == 0 { continue }
                        let next = CrackPoint(
                            x: current.x + dx,
                            y: current.y + dy
                        )
                        if points.contains(next), !visited.contains(next) {
                            visited.insert(next)
                            parent[next] = current
                            queue.append(next)
                        }
                    }
                }
            }
            return (last, parent)
        }

        let (farEnd, _) = bfs(from: start)
        let (otherEnd, parent) = bfs(from: farEnd)

        var path: [CrackPoint] = []
        var current: CrackPoint? = otherEnd
        while let point = current {
            path.append(point)
            current = parent[point]
        }
        return path.reversed()
    }

    /// 有序折线像素长度（直接累加相邻点欧氏距离）。
    private static func polylineLength(_ points: [CrackPoint]) -> Double {
        var total = 0.0
        for index in 1..<points.count {
            total += hypot(
                Double(points[index].x - points[index - 1].x),
                Double(points[index].y - points[index - 1].y)
            )
        }
        return total
    }

    static func statsText(detectionCount: Int, result: Result) -> String {
        "主裂缝 \(result.polylines.count) 条 · mask 像素 \(result.maskPixelCount) · 平均宽 \(String(format: "%.1f", result.averageWidthPx)) px · 最大宽 \(String(format: "%.1f", result.maxWidthPx)) px · 总长 \(String(format: "%.1f", result.totalPixelLength)) px · 最长 \(String(format: "%.1f", result.longestPixelLength)) px · 采样点 \(result.samplePoints.count) 个"
    }
}
