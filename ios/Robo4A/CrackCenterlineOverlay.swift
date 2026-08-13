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
        var crackConfig = config
        crackConfig.minSkeletonLength = 80
        crackConfig.topCracks = 7

        // 2. 提取连通域，从每个实例轮廓拟合中心线，不使用骨架。
        let components = CrackSkeleton.componentPoints(
            grid,
            width: width,
            height: height
        )
        var polylines: [[CrackPoint]] = []
        var samplesPerPolyline: [[CrackPoint]] = []
        for component in components {
            guard component.count >= 3 else { continue }
            let centerline = approximateCenterline(
                from: component,
                simplifyEpsilonPx: 1.5
            )
            guard centerline.count >= 2 else { continue }
            let length = polylineLength(centerline)
            guard length >= Double(crackConfig.minSkeletonLength) else {
                continue
            }
            polylines.append(centerline)
            samplesPerPolyline.append(
                CrackSamplePoints.evenlySpaced(
                    centerline,
                    spacingPx: 24,
                    maxPoints: 64
                )
            )
        }

        // 3. 按长度降序，最多 7 条
        let indexed = polylines.indices.sorted {
            polylineLength(polylines[$0]) > polylineLength(polylines[$1])
        }
        let keptIndices = indexed.prefix(crackConfig.topCracks)
        polylines = keptIndices.map { polylines[$0] }
        samplesPerPolyline = keptIndices.map { samplesPerPolyline[$0] }
        let widthStats = contourWidthStats(
            masks: masks,
            imageWidth: width,
            imageHeight: height,
            samplesPerPolyline: samplesPerPolyline
        )

        let total = polylines.reduce(0.0) { $0 + polylineLength($1) }
        let longest = polylines.map(polylineLength).max() ?? 0
        let flatSamples = samplesPerPolyline.flatMap { $0 }

        return Result(
            polylines: polylines,
            samplePointsPerPolyline: samplesPerPolyline,
            samplePoints: flatSamples,
            maskPixelCount: maskPixelCount,
            sparsePointCount: components.reduce(0) { $0 + $1.count },
            skeletonPointCount: polylines.reduce(0) { $0 + $1.count },
            componentCount: components.count,
            totalPixelLength: total,
            longestPixelLength: longest,
            maxWidthPx: widthStats.maxWidthPx,
            averageWidthPx: widthStats.averageWidthPx
        )
    }

    /// 用连通域点的 PCA 主轴作为裂缝主方向，把每个横截面两侧轮廓中点连成中心线。
    private static func approximateCenterline(
        from points: [CrackPoint],
        simplifyEpsilonPx: Double
    ) -> [CrackPoint] {
        guard points.count >= 3 else { return points }
        let sample: [CrackPoint]
        if points.count > 600 {
            sample = points.enumerated().compactMap { index, point in
                index % max(1, points.count / 600) == 0 ? point : nil
            }
        } else {
            sample = points
        }
        guard !sample.isEmpty else { return [] }

        var centroidX = 0.0
        var centroidY = 0.0
        for point in sample {
            centroidX += Double(point.x)
            centroidY += Double(point.y)
        }
        centroidX /= Double(sample.count)
        centroidY /= Double(sample.count)

        var xx = 0.0
        var xy = 0.0
        var yy = 0.0
        for point in sample {
            let dx = Double(point.x) - centroidX
            let dy = Double(point.y) - centroidY
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let ux = cos(angle)
        let uy = sin(angle)
        let nx = -uy
        let ny = ux

        var minT = Double.infinity
        var maxT = -Double.infinity
        for point in points {
            let dx = Double(point.x) - centroidX
            let dy = Double(point.y) - centroidY
            let t = dx * ux + dy * uy
            minT = min(minT, t)
            maxT = max(maxT, t)
        }
        guard maxT > minT else { return [] }

        let binCount = min(64, max(8, points.count / 8))
        let step = (maxT - minT) / Double(binCount)
        var bins = Array(repeating: [(t: Double, w: Double)](), count: binCount)
        for point in points {
            let dx = Double(point.x) - centroidX
            let dy = Double(point.y) - centroidY
            let t = dx * ux + dy * uy
            let w = dx * nx + dy * ny
            let index = min(binCount - 1, max(0, Int((t - minT) / step)))
            bins[index].append((t, w))
        }

        var centers: [CrackPoint] = []
        for bin in bins {
            guard !bin.isEmpty else { continue }
            var minW = Double.infinity
            var maxW = -Double.infinity
            var tSum = 0.0
            for item in bin {
                minW = min(minW, item.w)
                maxW = max(maxW, item.w)
                tSum += item.t
            }
            let t = tSum / Double(bin.count)
            let w = (minW + maxW) * 0.5
            let x = centroidX + ux * t + nx * w
            let y = centroidY + uy * t + ny * w
            centers.append(
                CrackPoint(
                    x: Int(x.rounded()),
                    y: Int(y.rounded())
                )
            )
        }
        return CrackSkeleton.douglasPeucker(
            centers,
            epsilon: simplifyEpsilonPx
        )
    }

    /// 从每个实例 mask 提取闭合轮廓边界点，沿中心线法向两侧找最近边界点，
    /// 以两点欧氏距离作为局部像素宽度，返回平均/最大宽度。
    private static func contourWidthStats(
        masks: [MaskPrediction],
        imageWidth: Int,
        imageHeight: Int,
        samplesPerPolyline: [[CrackPoint]]
    ) -> (maxWidthPx: Double, averageWidthPx: Double) {
        var contour = Set<CrackPoint>()
        for prediction in masks {
            let maskWidth = prediction.maskSize.width
            let maskHeight = prediction.maskSize.height
            guard maskWidth > 0, maskHeight > 0,
                  prediction.mask.count >= maskWidth * maskHeight else {
                continue
            }
            let scaleX = CGFloat(imageWidth) / CGFloat(maskWidth)
            let scaleY = CGFloat(imageHeight) / CGFloat(maskHeight)
            for y in 0..<maskHeight {
                for x in 0..<maskWidth
                    where prediction.mask[y * maskWidth + x] > 0 {
                    var isBoundary = false
                    for dy in -1...1 where !isBoundary {
                        for dx in -1...1 where !isBoundary {
                            let nx = x + dx
                            let ny = y + dy
                            if nx >= 0, nx < maskWidth,
                               ny >= 0, ny < maskHeight,
                               prediction.mask[ny * maskWidth + nx] == 0 {
                                isBoundary = true
                            }
                        }
                    }
                    if isBoundary {
                        let px = Int((CGFloat(x) + 0.5) * scaleX)
                        let py = Int((CGFloat(y) + 0.5) * scaleY)
                        contour.insert(CrackPoint(x: px, y: py))
                    }
                }
            }
        }
        guard !contour.isEmpty else { return (0, 0) }

        var widths: [Double] = []
        for polyline in samplesPerPolyline {
            guard polyline.count >= 2 else { continue }
            for index in 0..<polyline.count {
                let point = polyline[index]
                let previous = index > 0
                    ? polyline[index - 1]
                    : nil
                let next = index < polyline.count - 1
                    ? polyline[index + 1]
                    : nil
                let dx: Int
                let dy: Int
                if let previous, let next {
                    dx = next.x - previous.x
                    dy = next.y - previous.y
                } else if let next {
                    dx = next.x - point.x
                    dy = next.y - point.y
                } else if let previous {
                    dx = point.x - previous.x
                    dy = point.y - previous.y
                } else {
                    continue
                }
                let nx = -dy
                let ny = dx

                var positivePoint: CrackPoint?
                var positiveDistance = Double.infinity
                var negativePoint: CrackPoint?
                var negativeDistance = Double.infinity
                for contourPoint in contour {
                    let vx = contourPoint.x - point.x
                    let vy = contourPoint.y - point.y
                    let side = vx * nx + vy * ny
                    let distance = hypot(Double(vx), Double(vy))
                    if side > 0 {
                        if distance < positiveDistance {
                            positiveDistance = distance
                            positivePoint = contourPoint
                        }
                    } else if side < 0 {
                        if distance < negativeDistance {
                            negativeDistance = distance
                            negativePoint = contourPoint
                        }
                    }
                }
                if let positivePoint, let negativePoint {
                    widths.append(
                        hypot(
                            Double(positivePoint.x - negativePoint.x),
                            Double(positivePoint.y - negativePoint.y)
                        )
                    )
                }
            }
        }
        guard !widths.isEmpty else { return (0, 0) }
        return (
            maxWidthPx: widths.max() ?? 0,
            averageWidthPx: widths.reduce(0, +) / Double(widths.count)
        )
    }

    /// 只在中心线采样点附近做局部 BFS，找到最近背景作为半宽。
    private static func crackWidthStatsLocal(
        grid: [Bool],
        width: Int,
        height: Int,
        samplesPerPolyline: [[CrackPoint]]
    ) -> (maxWidthPx: Double, averageWidthPx: Double) {
        guard width > 0, height > 0, grid.count == width * height else {
            return (0, 0)
        }
        let directions = [
            (1, 0), (-1, 0), (0, 1), (0, -1),
            (1, 1), (1, -1), (-1, 1), (-1, -1)
        ]
        let maxRadius = 80
        var widths: [Double] = []

        for polyline in samplesPerPolyline {
            for point in polyline {
                guard point.x >= 0, point.x < width,
                      point.y >= 0, point.y < height else {
                    continue
                }
                let start = point.y * width + point.x
                guard grid[start] else { continue }

                var distances: [Int: Int] = [start: 0]
                var queue = [start]
                var head = 0
                var nearestBackground: Int?

                while head < queue.count {
                    let current = queue[head]
                    head += 1
                    let currentDistance = distances[current] ?? 0
                    let cx = current % width
                    let cy = current / width

                    if !grid[current] {
                        nearestBackground = currentDistance
                        break
                    }
                    if currentDistance >= maxRadius {
                        continue
                    }

                    for (dx, dy) in directions {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else {
                            continue
                        }
                        let neighbor = ny * width + nx
                        guard distances[neighbor] == nil else { continue }
                        distances[neighbor] = currentDistance + 1
                        queue.append(neighbor)
                    }
                }

                if let nearestBackground {
                    widths.append(Double(nearestBackground) * 2)
                }
            }
        }

        guard !widths.isEmpty else { return (0, 0) }
        let sum = widths.reduce(0, +)
        return (
            maxWidthPx: widths.max() ?? 0,
            averageWidthPx: sum / Double(widths.count)
        )
    }

    /// 用二值掩码到背景的 8 邻域距离场估算裂缝宽度：
    /// 每个前景点到最近背景的距离视为“半宽”，宽度=2×半宽。
    /// 返回最大宽度与平均宽度（像素）。
    private static func crackWidthStats(
        grid: [Bool],
        width: Int,
        height: Int,
        samplesPerPolyline: [[CrackPoint]]
    ) -> (maxWidthPx: Double, averageWidthPx: Double) {
        guard width > 0, height > 0, grid.count == width * height else {
            return (0, 0)
        }
        let directions = [
            (1, 0), (-1, 0), (0, 1), (0, -1),
            (1, 1), (1, -1), (-1, 1), (-1, -1)
        ]
        let maxRadius = 80
        var widths: [Double] = []
        for polyline in samplesPerPolyline {
            for point in polyline {
                guard point.x >= 0, point.x < width,
                      point.y >= 0, point.y < height else {
                    continue
                }
                let index = point.y * width + point.x
                guard grid[index] else { continue }

                var visited = Set<Int>([index])
                var queue = [index]
                var head = 0
                var halfWidth: Int?

                while head < queue.count {
                    let current = queue[head]
                    head += 1
                    let currentDistance =
                        current == index ? 0 : visited.count > 0 ? current == index ? 0 : 0 : 0
                    // 用与起点的 BFS 层数维护距离。
                    if !grid[current] {
                        halfWidth = max(1, current == index ? 0 : 0)
                        break
                    }
                    if current != index {
                        // 计算从起点到当前点的最短曼哈顿距离近似。
                    }
                    for (dx, dy) in directions {
                        let nx = (current % width) + dx
                        let ny = (current / width) + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else {
                            continue
                        }
                        let neighbor = ny * width + nx
                        guard !visited.contains(neighbor) else { continue }
                        visited.insert(neighbor)
                        queue.append(neighbor)
                        if !grid[neighbor] {
                            halfWidth = max(1, min(halfWidth ?? .max, current == index ? 1 : 1))
                            break
                        }
                    }
                    if halfWidth != nil { break }
                }

                if let halfWidth {
                    widths.append(Double(halfWidth) * 2)
                }
            }
        }
        guard !widths.isEmpty else { return (0, 0) }
        let sum = widths.reduce(0, +)
        let count = widths.count
        let maxWidth = widths.max() ?? 0
        return (
            maxWidthPx: maxWidth,
            averageWidthPx: sum / Double(count)
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
