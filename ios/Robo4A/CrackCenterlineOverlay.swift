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
                    let px = min(width - 1, Int((CGFloat(x) + 0.5) * scaleX))
                    let py = min(height - 1, Int((CGFloat(y) + 0.5) * scaleY))
                    grid[py * width + px] = true
                }
            }
        }

        var maskPixelCount = 0
        for value in grid where value {
            maskPixelCount += 1
        }

        // 稀疏化：每 2px 取一个点（与 v0.66 稀疏骨架同一思路）
        let spacing = 2
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
        for group in groups {
            let simplified = CrackSkeleton.simplifyPolyline(
                group,
                epsilon: config.polylineEpsilonPx
            )
            let length = CrackSkeleton.pixelLength(of: simplified)
            if length > bestLength {
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
            centerlinePixelLength: bestLength
        )
    }

    static func statsText(detectionCount: Int, result: Result) -> String {
        "检测框 \(detectionCount) · mask 像素 \(result.maskPixelCount) · 骨架点 \(result.skeletonPointCount) · 中心线 \(result.centerline.count) 点 · 采样点 \(result.samplePoints.count) 个 · 像素长度 \(String(format: "%.1f", result.centerlinePixelLength)) px"
    }
}
