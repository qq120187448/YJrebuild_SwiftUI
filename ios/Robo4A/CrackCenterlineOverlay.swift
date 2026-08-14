import Foundation
import UIKit

/// 4A/4D.1 折线方案（用户定稿）：
/// mask（protos×系数→上采样）→ 框内自适应稀疏化采样（保连通）
/// → 连通域提取 → 轮廓拟合中心线（PCA 主轴 + 分箱中点）→ Douglas-Peucker
/// → 每条裂缝折线强制 ≤7 段（≤8 点）→ 按长度保留最多 7 条主裂缝（≥80px）
/// → 等距采样点（供 4B raycast）。
/// 宽度：沿中心线法向找两侧轮廓最近点，输出平均/最大像素宽。
/// 每条主裂缝只输出一条折线，避免重复计算。
enum CrackCenterlineOverlay {

    struct Result {
        /// 每条主裂缝一条折线（有序 + DP 简化 + ≤7 段）
        var polylines: [[CrackPoint]]
        /// 每条折线的等距采样点（供 4B raycast）
        var samplePointsPerPolyline: [[CrackPoint]]
        /// 全部采样点（按折线顺序拼接）
        var samplePoints: [CrackPoint]
        var maskPixelCount: Int
        var sparsePointCount: Int
        var centerlinePointCount: Int
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
            let centerline = cappedCenterline(
                approximateCenterline(
                    from: component,
                    simplifyEpsilonPx: 1.5
                ),
                maxSegments: 7
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
            centerlinePointCount: polylines.reduce(0) { $0 + $1.count },
            componentCount: components.count,
            totalPixelLength: total,
            longestPixelLength: longest,
            maxWidthPx: widthStats.maxWidthPx,
            averageWidthPx: widthStats.averageWidthPx
        )
    }

    /// 强制每条裂缝折线 ≤ maxSegments 段（≤ maxSegments+1 点）：
    /// 若 DP 结果超限，按弧长均匀重采样（保留首尾）。
    private static func cappedCenterline(
        _ points: [CrackPoint],
        maxSegments: Int
    ) -> [CrackPoint] {
        let maxPoints = maxSegments + 1
        guard points.count > maxPoints, maxSegments > 0 else {
            return points
        }

        var cumulative: [Double] = [0]
        for index in 1..<points.count {
            cumulative.append(
                cumulative[index - 1]
                    + hypot(
                        Double(points[index].x - points[index - 1].x),
                        Double(points[index].y - points[index - 1].y)
                    )
            )
        }
        let total = cumulative.last ?? 0
        guard total > 0 else {
            return Array(points.prefix(maxPoints))
        }

        var result: [CrackPoint] = []
        var targetIndex = 1
        for segmentIndex in 0...maxSegments {
            let target = total * Double(segmentIndex) / Double(maxSegments)
            while targetIndex < cumulative.count - 1,
                  cumulative[targetIndex] < target {
                targetIndex += 1
            }
            let t0 = cumulative[targetIndex - 1]
            let t1 = cumulative[targetIndex]
            let fraction = t1 > t0 ? (target - t0) / (t1 - t0) : 0
            let x = Double(points[targetIndex - 1].x)
                + fraction * Double(points[targetIndex].x - points[targetIndex - 1].x)
            let y = Double(points[targetIndex - 1].y)
                + fraction * Double(points[targetIndex].y - points[targetIndex - 1].y)
            let point = CrackPoint(x: Int(x.rounded()), y: Int(y.rounded()))
            if result.last != point {
                result.append(point)
            }
        }
        return result
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
