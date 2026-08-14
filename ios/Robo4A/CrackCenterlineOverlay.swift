import Foundation
import UIKit

/// 4A/4D.1 折线方案（用户定稿）：
/// mask（protos×系数→上采样）→ 框内自适应稀疏化采样（保连通）
/// → 连通域提取 → 轮廓拟合中心线（PCA 主轴 + 分箱中点）→ SwiftSimplify（MIT，Douglas-Peucker）
/// → 每条裂缝折线强制 ≤6 段（≤7 点，对齐 PC max_pts=7）→ 按长度保留最多 7 条主裂缝（≥80px）
/// → 等距采样点（供 4B raycast）。
/// 宽度：沿中心线法向找两侧轮廓最近点，输出 min/avg/max、P10/P50/P90、10 段剖面与 widthQuality。
/// 长度一致性：同时输出 dense（简化前）/ simplified（简化后）长度与 loss%。
/// 合规：Zhang-Suen / EDT / DP 不手写；DP 使用 SwiftSimplify（MIT），主 App 旧骨架管线原样保留。
/// 每条主裂缝只输出一条折线，避免重复计算。
struct CrackWidthStats {
    /// widthQuality：<2px 低分辨率 / 2–4px 受限 / >4px 正常。
    enum Quality: String, CaseIterable {
        case lowResolution
        case limited
        case normal

        var label: String {
            switch self {
            case .lowResolution: return "低分辨率(<2px)"
            case .limited: return "受限(2-4px)"
            case .normal: return "正常(>4px)"
            }
        }
    }

    var minPx: Double = 0
    var averagePx: Double = 0
    var maxPx: Double = 0
    var p10Px: Double = 0
    var p50Px: Double = 0
    var p90Px: Double = 0
    /// 10 段剖面：沿每条折线弧长归一化到 10 段，各段跨裂缝平均宽度（px）。
    var profile10Px: [Double] = []
    var quality: Quality = .normal
}

/// CrackPoint 适配 SwiftSimplify（MIT）的 Point2DRepresentable 协议。
extension CrackPoint: Point2DRepresentable {
    var xValue: Float { Float(x) }
    var yValue: Float { Float(y) }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum CrackCenterlineOverlay {

    struct Result {
        /// 每条主裂缝一条折线（有序 + SwiftSimplify DP 简化 + ≤6 段）
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
        /// 简化前（分箱中点折线）总像素长度。
        var denseTotalPixelLength: Double
        /// 简化后（SwiftSimplify + ≤6 段）总像素长度。
        var simplifiedTotalPixelLength: Double
        /// 长度一致性损失：(dense - simplified) / dense × 100。
        var lengthLossPercent: Double
        var widthStats: CrackWidthStats

        var maxWidthPx: Double { widthStats.maxPx }
        var averageWidthPx: Double { widthStats.averagePx }
    }

    static func compute(
        masks: [MaskPrediction],
        imageSize: CGSize,
        config: CrackRecognitionConfig = .defaultConfig,
        includeWidthStats: Bool = true
    ) -> Result {
        let width = max(1, Int(imageSize.width.rounded()))
        let height = max(1, Int(imageSize.height.rounded()))

        // 1. mask → 全图 bool 网格（每个 mask 单元覆盖整片像素，保证连通）
        let grid = mergedGrid(
            masks: masks,
            imageWidth: width,
            imageHeight: height
        )

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
        var denseTotalPixelLength = 0.0
        for component in components {
            guard component.count >= 3 else { continue }
            let fitted = approximateCenterline(
                from: component,
                simplifyEpsilonPx: 1.5
            )
            let centerline = cappedCenterline(
                fitted.simplified,
                maxSegments: 6
            )
            guard centerline.count >= 2 else { continue }
            let length = polylineLength(centerline)
            guard length >= Double(crackConfig.minSkeletonLength) else {
                continue
            }
            denseTotalPixelLength += polylineLength(fitted.dense)
            polylines.append(centerline)
            samplesPerPolyline.append(
                CrackSamplePoints.evenlySpaced(
                    centerline,
                    spacingPx: 24,
                    maxPoints: 32
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
        // 宽度统计可延迟（先出折线/采样点，宽度由调用方后台异步补充）。
        let widthStats = includeWidthStats
            ? widthStatsViaNormalScan(
                masks: masks,
                imageWidth: width,
                imageHeight: height,
                polylines: polylines
            )
            : CrackWidthStats()

        let total = polylines.reduce(0.0) { $0 + polylineLength($1) }
        let longest = polylines.map(polylineLength).max() ?? 0
        let flatSamples = samplesPerPolyline.flatMap { $0 }
        let lengthLossPercent = denseTotalPixelLength > 0
            ? (denseTotalPixelLength - total) / denseTotalPixelLength * 100
            : 0

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
            denseTotalPixelLength: denseTotalPixelLength,
            simplifiedTotalPixelLength: total,
            lengthLossPercent: lengthLossPercent,
            widthStats: widthStats
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

    /// 用连通域点的 PCA 主轴作为裂缝主方向，把每个横截面两侧轮廓中点连成中心线，
    /// 再用 SwiftSimplify（MIT，Douglas-Peucker）简化。返回 dense（简化前）与 simplified 两版，
    /// 供长度一致性诊断（denseLength / simplifiedLength / loss%）。
    private static func approximateCenterline(
        from points: [CrackPoint],
        simplifyEpsilonPx: Double
    ) -> (dense: [CrackPoint], simplified: [CrackPoint]) {
        guard points.count >= 3 else {
            return (dense: points, simplified: points)
        }
        let sample: [CrackPoint]
        if points.count > 600 {
            sample = points.enumerated().compactMap { index, point in
                index % max(1, points.count / 600) == 0 ? point : nil
            }
        } else {
            sample = points
        }
        guard !sample.isEmpty else {
            return (dense: [], simplified: [])
        }

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
        guard maxT > minT else {
            return (dense: [], simplified: [])
        }

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
        let simplified = SwiftSimplify.simplify(
            centers,
            tolerance: Float(simplifyEpsilonPx),
            highestQuality: true
        )
        return (dense: centers, simplified: simplified)
    }

    /// 从每个实例 mask 提取闭合轮廓边界点，沿中心线法向两侧找最近边界点，
    /// 以两点欧氏距离作为局部像素宽度，返回 min/avg/max、P10/P50/P90、10 段剖面与质量分级。
    /// 后台异步补充宽度统计的入口（先出折线/长度，宽度后补）。
    static func computeWidthStats(
        masks: [MaskPrediction],
        imageSize: CGSize,
        samplesPerPolyline: [[CrackPoint]]
    ) -> CrackWidthStats {
        widthStatsViaNormalScan(
            masks: masks,
            imageWidth: max(1, Int(imageSize.width.rounded())),
            imageHeight: max(1, Int(imageSize.height.rounded())),
            polylines: samplesPerPolyline
        )
    }

    /// New fast width stats: per crack, 50 arc-length samples; for each sample,
    /// walk both normal directions on the merged binary mask. O(50 x width)
    /// instead of the old O(samples x contour) nearest-boundary search.
    /// Output keeps min/avg/max, P10/P50/P90, 10-segment profile and quality.
    private static func widthStatsViaNormalScan(
        masks: [MaskPrediction],
        imageWidth: Int,
        imageHeight: Int,
        polylines: [[CrackPoint]]
    ) -> CrackWidthStats {
        guard imageWidth > 0, imageHeight > 0 else { return CrackWidthStats() }
        let grid = mergedGrid(
            masks: masks,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        let sampleCount = 50
        let maxScanRadius = 400.0
        var perPolylineWidths: [[Double]] = []
        for polyline in polylines {
            guard polyline.count >= 2 else { continue }
            let samples = resampleArcLength(polyline, count: sampleCount)
            var polylineWidths: [Double] = []
            for index in 0..<samples.count {
                let point = samples[index]
                let previous = index > 0 ? samples[index - 1] : nil
                let next = index < samples.count - 1 ? samples[index + 1] : nil
                var dirX = 0.0
                var dirY = 0.0
                if let previous, let next {
                    dirX = next.x - previous.x
                    dirY = next.y - previous.y
                } else if let next {
                    dirX = next.x - point.x
                    dirY = next.y - point.y
                } else if let previous {
                    dirX = point.x - previous.x
                    dirY = point.y - previous.y
                } else {
                    continue
                }
                let directionLength = hypot(dirX, dirY)
                guard directionLength > 1e-6 else { continue }
                let normalX = -dirY / directionLength
                let normalY = dirX / directionLength
                let width = scanMaskWidth(
                    at: point,
                    normalX: normalX,
                    normalY: normalY,
                    grid: grid,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight,
                    maxRadius: maxScanRadius
                )
                if width > 0 {
                    polylineWidths.append(width)
                }
            }
            if !polylineWidths.isEmpty {
                perPolylineWidths.append(polylineWidths)
            }
        }
        let widths = perPolylineWidths.flatMap { $0 }
        guard !widths.isEmpty else { return CrackWidthStats() }
        let sorted = widths.sorted()
        let average = widths.reduce(0, +) / Double(widths.count)
        var stats = CrackWidthStats()
        stats.minPx = sorted.first ?? 0
        stats.averagePx = average
        stats.maxPx = sorted.last ?? 0
        stats.p10Px = percentile(sorted, 10)
        stats.p50Px = percentile(sorted, 50)
        stats.p90Px = percentile(sorted, 90)
        stats.profile10Px = profile10(perPolylineWidths)
        if average < 2 {
            stats.quality = .lowResolution
        } else if average <= 4 {
            stats.quality = .limited
        } else {
            stats.quality = .normal
        }
        return stats
    }

    /// Merge all instance masks into one full-image bool grid.
    private static func mergedGrid(
        masks: [MaskPrediction],
        imageWidth: Int,
        imageHeight: Int
    ) -> [Bool] {
        var grid = [Bool](repeating: false, count: imageWidth * imageHeight)
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
                for x in 0..<maskWidth where prediction.mask[y * maskWidth + x] > 0 {
                    let x0 = Int(CGFloat(x) * scaleX)
                    let x1 = Int(CGFloat(x + 1) * scaleX)
                    let y0 = Int(CGFloat(y) * scaleY)
                    let y1 = Int(CGFloat(y + 1) * scaleY)
                    for py in y0..<max(y0 + 1, y1) {
                        for px in x0..<max(x0 + 1, x1) {
                            grid[py * imageWidth + px] = true
                        }
                    }
                }
            }
        }
        return grid
    }

    /// Arc-length uniform resampling, keeps both endpoints.
    private static func resampleArcLength(
        _ points: [CrackPoint],
        count: Int
    ) -> [(x: Double, y: Double)] {
        guard points.count >= 2, count >= 2 else {
            return points.map { (x: Double($0.x), y: Double($0.y)) }
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
        guard total > 1e-6 else {
            return points.map { (x: Double($0.x), y: Double($0.y)) }
        }
        var result: [(x: Double, y: Double)] = []
        result.reserveCapacity(count)
        var targetIndex = 1
        for sampleIndex in 0..<count {
            let target = total * Double(sampleIndex) / Double(count - 1)
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
            result.append((x: x, y: y))
        }
        return result
    }

    /// Walk both normal directions on the merged grid.
    /// Width = distance of last mask pixel on each side + 1px.
    private static func scanMaskWidth(
        at point: (x: Double, y: Double),
        normalX: Double,
        normalY: Double,
        grid: [Bool],
        imageWidth: Int,
        imageHeight: Int,
        maxRadius: Double
    ) -> Double {
        func isMask(_ x: Double, _ y: Double) -> Bool {
            let px = Int(x.rounded())
            let py = Int(y.rounded())
            guard px >= 0, px < imageWidth, py >= 0, py < imageHeight else {
                return false
            }
            return grid[py * imageWidth + px]
        }
        guard isMask(point.x, point.y) else { return 0 }

        var tPositive = 0.0
        var t = 0.0
        while t <= maxRadius {
            if !isMask(point.x + t * normalX, point.y + t * normalY) { break }
            tPositive = t
            t += 1.0
        }
        var tNegative = 0.0
        t = 0.0
        while t <= maxRadius {
            if !isMask(point.x - t * normalX, point.y - t * normalY) { break }
            tNegative = t
            t += 1.0
        }
        return tPositive + tNegative + 1
    }

    // NOTE: contourWidthStats below is superseded by widthStatsViaNormalScan.
    // It is kept only as reference; it is no longer called anywhere.
    private static func contourWidthStats(
        masks: [MaskPrediction],
        imageWidth: Int,
        imageHeight: Int,
        samplesPerPolyline: [[CrackPoint]]
    ) -> CrackWidthStats {
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
            // 性能：边界检测 stride=2 降采样，计算量降约 4 倍。
            let samplingStep = 2
            for y in stride(from: 0, to: maskHeight, by: samplingStep) {
                for x in stride(from: 0, to: maskWidth, by: samplingStep)
                    where prediction.mask[y * maskWidth + x] > 0 {
                    var isBoundary = false
                    for dy in -samplingStep...samplingStep where !isBoundary {
                        for dx in -samplingStep...samplingStep where !isBoundary {
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
                        let px = Int(
                            (CGFloat(x) + CGFloat(samplingStep) * 0.5)
                                * scaleX
                        )
                        let py = Int(
                            (CGFloat(y) + CGFloat(samplingStep) * 0.5)
                                * scaleY
                        )
                        contour.insert(CrackPoint(x: px, y: py))
                    }
                }
            }
        }
        guard !contour.isEmpty else { return CrackWidthStats() }

        var perPolylineWidths: [[Double]] = []
        for polyline in samplesPerPolyline {
            guard polyline.count >= 2 else { continue }
            var polylineWidths: [Double] = []
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
                    polylineWidths.append(
                        hypot(
                            Double(positivePoint.x - negativePoint.x),
                            Double(positivePoint.y - negativePoint.y)
                        )
                    )
                }
            }
            if !polylineWidths.isEmpty {
                perPolylineWidths.append(polylineWidths)
            }
        }
        let widths = perPolylineWidths.flatMap { $0 }
        guard !widths.isEmpty else { return CrackWidthStats() }
        let sorted = widths.sorted()
        let average = widths.reduce(0, +) / Double(widths.count)
        var stats = CrackWidthStats()
        stats.minPx = sorted.first ?? 0
        stats.averagePx = average
        stats.maxPx = sorted.last ?? 0
        stats.p10Px = percentile(sorted, 10)
        stats.p50Px = percentile(sorted, 50)
        stats.p90Px = percentile(sorted, 90)
        stats.profile10Px = profile10(perPolylineWidths)
        if average < 2 {
            stats.quality = .lowResolution
        } else if average <= 4 {
            stats.quality = .limited
        } else {
            stats.quality = .normal
        }
        return stats
    }

    /// 线性插值百分位。
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = Double(sorted.count - 1) * p / 100.0
        let lower = Int(floor(rank))
        let upper = min(sorted.count - 1, Int(ceil(rank)))
        let fraction = rank - Double(lower)
        if lower == upper { return sorted[lower] }
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// 10 段剖面：每条折线采样点按弧长归一化（等距采样下索引比例≈弧长比例），
    /// 分入 10 个桶取平均，再跨裂缝对同段求平均；空桶补 0。
    private static func profile10(_ perPolylineWidths: [[Double]]) -> [Double] {
        var buckets = Array(repeating: [Double](), count: 10)
        for widths in perPolylineWidths {
            guard widths.count >= 2 else { continue }
            for (index, width) in widths.enumerated() {
                let t = Double(index) / Double(widths.count - 1)
                let bucket = min(9, max(0, Int(t * 10)))
                buckets[bucket].append(width)
            }
        }
        return buckets.map { bucket in
            bucket.isEmpty ? 0 : bucket.reduce(0, +) / Double(bucket.count)
        }
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
        let w = result.widthStats
        let profile = w.profile10Px.enumerated()
            .map { "\($0.offset + 1):\(String(format: "%.1f", $0.element))px" }
            .joined(separator: " ")
        return "主裂缝 \(result.polylines.count) 条 · mask 像素 \(result.maskPixelCount) · 宽度 min/avg/max \(String(format: "%.1f", w.minPx))/\(String(format: "%.1f", w.averagePx))/\(String(format: "%.1f", w.maxPx)) px · P10/P50/P90 \(String(format: "%.1f", w.p10Px))/\(String(format: "%.1f", w.p50Px))/\(String(format: "%.1f", w.p90Px)) px · 质量 \(w.quality.label) · 10段剖面 \(profile) · 长度 dense→simplified \(String(format: "%.1f", result.denseTotalPixelLength))→\(String(format: "%.1f", result.simplifiedTotalPixelLength)) px (loss \(String(format: "%.2f", result.lengthLossPercent))%) · 最长 \(String(format: "%.1f", result.longestPixelLength)) px · 采样点 \(result.samplePoints.count) 个"
    }
}
