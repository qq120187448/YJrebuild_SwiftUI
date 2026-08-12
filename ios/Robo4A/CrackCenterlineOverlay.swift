import Foundation
import UIKit

/// 4A 新层：在 MaciDE mask 输出之上计算裂缝中心线与采样点。
/// mask（MaskPrediction[]）→ 全图 bool 网格 → 稀疏点 → 骨架 → 主中心线 → 等距采样点。
/// 像素行为与 v0.66 的 CrackSkeleton 保持一致；不涉及 ARMesh / RoomPlan / 测量。
enum CrackCenterlineOverlay {

    struct Result {
        var centerline: [CrackPoint]
        var samplePoints: [CrackPoint]
        var maskPixelCount: Int
        var skeletonPointCount: Int
        var sparsePointCount: Int
        var componentCount: Int
        var largestComponentPointCount: Int
        var centerlinePixelLength: Double
    }

    static func compute(
        masks: [MaskPrediction],
        imageSize: CGSize,
        config: CrackRecognitionConfig = .defaultConfig
    ) -> Result {
        let width = max(1, Int(imageSize.width.rounded()))
        let height = max(1, Int(imageSize.height.rounded()))
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

        // 稀疏化：间距随图像尺寸自适应（约 2px/1024 分辨率），保证点数可控且相邻点可连通。
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

        let skeleton = CrackSkeleton.analyzeSparse(
            points: sparse,
            spacing: spacing,
            width: width,
            height: height,
            config: config
        )
        let raw = skeleton.fullSkeletonPoints.isEmpty
            ? skeleton.skeletonPoints
            : skeleton.fullSkeletonPoints
        let groups = CrackSkeleton.componentPointsSparse(raw, spacing: spacing)

        var best: [CrackPoint] = []
        var bestLength = 0.0
        var largestGroupSize = 0
        for group in groups {
            // 稀疏点必须按实际间距排序，再 Douglas-Peucker 简化。
            let ordered = CrackSkeleton.orderedPath(
                from: group,
                spacing: spacing
            )
            let simplified = CrackSkeleton.douglasPeucker(
                ordered,
                epsilon: config.polylineEpsilonPx
            )
            let length = polylineLength(simplified)
            largestGroupSize = max(largestGroupSize, group.count)
            if best.isEmpty || length > bestLength {
                bestLength = length
                best = simplified
            }
        }

        let samples = best.isEmpty
            ? []
            : CrackSamplePoints.evenlySpaced(best, spacingPx: 24, maxPoints: 64)

        return Result(
            centerline: best,
            samplePoints: samples,
            maskPixelCount: maskPixelCount,
            skeletonPointCount: raw.count,
            sparsePointCount: sparse.count,
            componentCount: groups.count,
            largestComponentPointCount: largestGroupSize,
            centerlinePixelLength: bestLength
        )
    }

    /// 有序折线像素长度（直接累加相邻点欧氏距离，不依赖稀疏步长）。
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
        "检测框 \(detectionCount) · mask 像素 \(result.maskPixelCount) · 稀疏点 \(result.sparsePointCount) · 骨架点 \(result.skeletonPointCount) · 分量 \(result.componentCount)（最大 \(result.largestComponentPointCount) 点）· 中心线 \(result.centerline.count) 点 · 采样点 \(result.samplePoints.count) 个 · 像素长度 \(String(format: "%.1f", result.centerlinePixelLength)) px"
    }
}
