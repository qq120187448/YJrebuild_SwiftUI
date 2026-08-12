//
//  CrackPixelPipeline.swift
//  4A 最小接口：照片 → 裂缝像素坐标
//
//  本阶段只实现“像素层”闭环：
//  photo → crack_seg（CoreML）→ mask → 裂缝中心线/采样点
//  不包含 ARMesh、RoomPlan、三级回退、测量。
//  复用 CrackYOLODecoder + CrackSkeleton，像素行为与 v0.66 保持一致。
//

import CoreGraphics
import CoreML
import Foundation
import UIKit

// MARK: - 4A 最小接口（4B/4C/4D 将消费此输出）

protocol CrackPixelDetecting {
    func detect(image: UIImage) throws -> CrackPixelDetection
}

struct CrackPixelDetection {
    /// 分析图像尺寸（像素）
    var width: Int
    var height: Int
    /// 二值掩码，与 width/height 同尺寸，true 表示裂缝像素
    var mask: [Bool]
    /// 主裂缝有序中心线（像素坐标，已剪枝 + Douglas-Peucker 简化）
    var centerline: [CrackPoint]
    /// 供 4B ARView.raycast 的等距采样点（像素坐标）
    var samplePoints: [CrackPoint]
    /// 各连通分量统计
    var components: [CrackComponent]
    /// 主裂缝像素长度
    var totalPixelLength: Double
    /// NMS 后检测框数量（诊断）
    var detectionCount: Int
    /// mask 非零像素数量（诊断）
    var maskPixelCount: Int
    /// 骨架稀疏点数量（诊断）
    var skeletonPointCount: Int
    /// 使用的模型名（crack_seg_n / crack_seg_s）
    var modelName: String
    var timings: [String: Double]
}

enum CrackPixelError: LocalizedError {
    case invalidImage
    case modelNotFound
    case noOutput
    case noCrack

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取照片"
        case .modelNotFound:
            return "未找到 crack_seg 模型（crack_seg_n.mlmodelc）"
        case .noOutput:
            return "CoreML 输出不符合 YOLOv8-seg 格式（boxes[1,4+nc+32,8400] + masks[1,32,H,W]）"
        }
    }
}

// MARK: - 实现：crack_seg（crack-yolo-v8_seg 导出）+ CrackYOLODecoder + CrackSkeleton

final class CrackPixelPipeline: CrackPixelDetecting {

    var config: CrackRecognitionConfig = .defaultConfig

    private struct LoadedModel {
        let mlModel: MLModel
    }

    private struct LetterboxTransform {
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    private var modelCache: [String: LoadedModel] = [:]
    private let inferenceQueue = DispatchQueue(
        label: "com.silv.Robo4A.inference"
    )

    func detect(image: UIImage) throws -> CrackPixelDetection {
        var timings: [String: Double] = [:]
        let overallStart = CFAbsoluteTimeGetCurrent()

        let modelName = config.modelSize == "s" ? "crack_seg_s" : "crack_seg_n"
        let model = try loadModel(named: modelName)
        timings["模型加载"] = CFAbsoluteTimeGetCurrent() - overallStart

        guard let cgImage = image.cgImage else {
            throw CrackPixelError.invalidImage
        }
        let analysisImage = Self.resizedCGImage(
            cgImage,
            maxSide: config.captureResolution
        )
        let width = analysisImage.width
        let height = analysisImage.height
        let inputSize = Self.modelInputSize(model.mlModel)

        let (resized, transform) = Self.letterboxedCGImage(
            analysisImage,
            canvasSize: inputSize
        )

        let inferenceStart = CFAbsoluteTimeGetCurrent()
        let (prediction, protos) = try predict(model: model, cgImage: resized)
        timings["CoreML推理"] = CFAbsoluteTimeGetCurrent() - inferenceStart

        var detections = CrackYOLODecoder.decode(
            prediction: prediction,
            protos: protos,
            confidence: Float(config.confidence)
        )
        detections = CrackYOLODecoder.nms(
            detections,
            iouThreshold: Float(config.iou),
            maxDetections: config.maxDetections
        )

        for index in detections.indices {
            let box = detections[index].box
            detections[index].box = CGRect(
                x: (box.minX - transform.offsetX) / transform.scale,
                y: (box.minY - transform.offsetY) / transform.scale,
                width: box.width / transform.scale,
                height: box.height / transform.scale
            )
            CrackYOLODecoder.decodeMask(
                for: &detections[index],
                protos: protos
            )
            detections[index].tileRect = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        }
        detections = Self.filterEdgeDetections(
            detections,
            width: width,
            height: height
        )

        let sparse = Self.sparseMaskPoints(
            detections: detections,
            width: width,
            height: height
        )
        timings["掩码转稀疏点"] = CFAbsoluteTimeGetCurrent() - inferenceStart

        let skeletonStart = CFAbsoluteTimeGetCurrent()
        let skeleton = CrackSkeleton.analyzeSparse(
            points: sparse.points,
            spacing: sparse.spacing,
            width: width,
            height: height,
            config: config
        )
        let rawPoints = skeleton.fullSkeletonPoints.isEmpty
            ? skeleton.skeletonPoints
            : skeleton.fullSkeletonPoints
        let groups = CrackSkeleton.componentPointsSparse(
            rawPoints,
            spacing: sparse.spacing
        )

        var bestCenterline: [CrackPoint] = []
        var bestLength = 0.0
        for group in groups {
            let simplified = CrackSkeleton.simplifyPolyline(
                group,
                epsilon: config.polylineEpsilonPx
            )
            let length = CrackSkeleton.pixelLength(of: simplified)
            if length > bestLength {
                bestLength = length
                bestCenterline = simplified
            }
        }
        timings["骨架化"] = CFAbsoluteTimeGetCurrent() - skeletonStart

        let samplePoints = CrackSamplePoints.evenlySpaced(
            bestCenterline,
            spacingPx: 24,
            maxPoints: 64
        )

        let mask = Self.mergedMask(
            detections: detections,
            width: width,
            height: height
        )
        timings["总耗时"] = CFAbsoluteTimeGetCurrent() - overallStart

        return CrackPixelDetection(
            width: width,
            height: height,
            mask: mask,
            centerline: bestCenterline,
            samplePoints: samplePoints,
            components: skeleton.components,
            totalPixelLength: bestLength,
            detectionCount: detections.count,
            maskPixelCount: mask.reduce(0) { $0 + ($1 ? 1 : 0) },
            skeletonPointCount: rawPoints.count,
            modelName: modelName,
            timings: timings
        )
    }

    // MARK: - Model

    private func loadModel(named name: String) throws -> LoadedModel {
        if let cached = modelCache[name] {
            return cached
        }
        let configuration = MLModelConfiguration()
        if config.computeMode == "cpu" {
            configuration.computeUnits = .cpuOnly
        } else {
            if #available(iOS 16.0, *) {
                configuration.computeUnits = .cpuAndNeuralEngine
            } else {
                configuration.computeUnits = .all
            }
        }
        let mlModel: MLModel
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlmodelc",
            subdirectory: "Models"
        ) {
            mlModel = try MLModel(contentsOf: url, configuration: configuration)
        } else if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlmodel",
            subdirectory: "Models"
        ) {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled, configuration: configuration)
        } else {
            throw CrackPixelError.modelNotFound
        }
        let loaded = LoadedModel(mlModel: mlModel)
        modelCache[name] = loaded
        return loaded
    }

    private func predict(
        model: LoadedModel,
        cgImage: CGImage
    ) throws -> (prediction: MLMultiArray, protos: MLMultiArray) {
        try inferenceQueue.sync {
            let pixelBuffer = try Self.makePixelBuffer(from: cgImage)
            guard let inputName = model.mlModel.modelDescription
                .inputDescriptionsByName.keys.first else {
                throw CrackPixelError.noOutput
            }
            let inputValue = MLFeatureValue(pixelBuffer: pixelBuffer)
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: inputValue]
            )
            let output = try model.mlModel.prediction(from: provider)
            return try Self.extractOutputs(from: output)
        }
    }

    private static func extractOutputs(
        from output: MLFeatureProvider
    ) throws -> (prediction: MLMultiArray, protos: MLMultiArray) {
        var prediction: MLMultiArray?
        var protos: MLMultiArray?
        for name in output.featureNames {
            guard let value = output.featureValue(for: name),
                  let array = value.multiArrayValue else {
                continue
            }
            if array.shape.count == 3,
               array.shape[1].intValue > 36,
               prediction == nil {
                prediction = array
            } else if array.shape.count == 4,
                      array.shape[1].intValue == 32,
                      protos == nil {
                protos = array
            }
        }
        if let prediction, let protos {
            return (prediction, protos)
        }
        throw CrackPixelError.noOutput
    }

    // MARK: - 预处理（与 v0.66 像素层一致）

    private static func resizedCGImage(
        _ image: CGImage,
        maxSide: Int
    ) -> CGImage {
        let largest = max(image.width, image.height)
        guard largest > maxSide, maxSide > 0 else { return image }
        let scale = CGFloat(maxSide) / CGFloat(largest)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage() ?? image
    }

    private static func makePixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CrackPixelError.invalidImage
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw CrackPixelError.invalidImage
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return pixelBuffer
    }

    private static func letterboxedCGImage(
        _ image: CGImage,
        canvasSize: Int
    ) -> (CGImage, LetterboxTransform) {
        guard image.width > 0, image.height > 0 else {
            return (image, LetterboxTransform(scale: 1, offsetX: 0, offsetY: 0))
        }
        let canvas = CGFloat(canvasSize)
        let scale = min(
            canvas / CGFloat(image.width),
            canvas / CGFloat(image.height)
        )
        let drawWidth = max(1, Int(CGFloat(image.width) * scale))
        let drawHeight = max(1, Int(CGFloat(image.height) * scale))
        let offsetX = (canvasSize - drawWidth) / 2
        let offsetY = (canvasSize - drawHeight) / 2

        guard let context = CGContext(
            data: nil,
            width: canvasSize,
            height: canvasSize,
            bitsPerComponent: 8,
            bytesPerRow: canvasSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (image, LetterboxTransform(scale: 1, offsetX: 0, offsetY: 0))
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(
            CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        )
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: offsetX,
                y: offsetY,
                width: drawWidth,
                height: drawHeight
            )
        )
        let result = context.makeImage() ?? image
        return (
            result,
            LetterboxTransform(
                scale: scale,
                offsetX: CGFloat(offsetX),
                offsetY: CGFloat(offsetY)
            )
        )
    }

    private static func modelInputSize(_ model: MLModel) -> Int {
        for description in model.modelDescription.inputDescriptionsByName.values {
            if let constraint = description.imageConstraint {
                return Int(constraint.pixelsWide)
            }
        }
        return 640
    }

    // MARK: - 后处理（与 v0.66 像素层一致）

    private static func filterEdgeDetections(
        _ detections: [YOLOSegDetection],
        width: Int,
        height: Int
    ) -> [YOLOSegDetection] {
        guard width > 0, height > 0 else { return detections }
        let marginX = CGFloat(width) * 0.015
        let marginY = CGFloat(height) * 0.015
        return detections.filter { detection in
            let rect = detection.box
            return rect.minX >= marginX
                && rect.minY >= marginY
                && rect.maxX <= CGFloat(width) - marginX
                && rect.maxY <= CGFloat(height) - marginY
        }
    }

    private static func sparseMaskPoints(
        detections: [YOLOSegDetection],
        width: Int,
        height: Int
    ) -> (points: Set<CrackPoint>, spacing: Int) {
        guard width > 0, height > 0 else {
            return (points: Set<CrackPoint>(), spacing: 1)
        }
        var points = Set<CrackPoint>()
        var spacing = 1
        for detection in detections {
            guard let values = detection.mask,
                  detection.maskWidth > 0,
                  detection.maskHeight > 0 else {
                continue
            }
            let tile = detection.tileRect
            let originX = Int(tile.minX.rounded())
            let originY = Int(tile.minY.rounded())
            let tileWidth = Int(tile.width.rounded())
            let tileHeight = Int(tile.height.rounded())
            guard tileWidth > 0, tileHeight > 0 else { continue }
            spacing = max(
                spacing,
                max(
                    1,
                    Int(
                        ceil(
                            Double(tileWidth)
                                / Double(detection.maskWidth)
                        )
                    )
                )
            )

            for my in 0..<detection.maskHeight {
                for mx in 0..<detection.maskWidth {
                    guard values[my * detection.maskWidth + mx] > 0.5 else {
                        continue
                    }
                    let localSpacing = max(
                        1,
                        Int(
                            ceil(
                                Double(tileWidth)
                                    / Double(detection.maskWidth)
                            )
                        )
                    )
                    let x = min(originX + mx * localSpacing, width - 1)
                    let y = min(originY + my * localSpacing, height - 1)
                    guard x >= 0, y >= 0, x < width, y < height else {
                        continue
                    }
                    points.insert(CrackPoint(x: x, y: y))
                }
            }
        }
        return (points: points, spacing: spacing)
    }

    private static func mergedMask(
        detections: [YOLOSegDetection],
        width: Int,
        height: Int
    ) -> [Bool] {
        guard width > 0, height > 0 else { return [] }
        var mask = [Bool](repeating: false, count: width * height)
        for detection in detections {
            guard let values = detection.mask,
                  detection.maskWidth > 0,
                  detection.maskHeight > 0 else {
                continue
            }
            let tile = detection.tileRect
            let originX = Int(tile.minX.rounded())
            let originY = Int(tile.minY.rounded())
            let tileWidth = Int(tile.width.rounded())
            let tileHeight = Int(tile.height.rounded())
            for my in 0..<detection.maskHeight {
                for mx in 0..<detection.maskWidth {
                    guard values[my * detection.maskWidth + mx] > 0.5 else {
                        continue
                    }
                    let x0 = Int(
                        CGFloat(mx)
                            * CGFloat(tileWidth)
                            / CGFloat(detection.maskWidth)
                    )
                    let x1 = Int(
                        CGFloat(mx + 1)
                            * CGFloat(tileWidth)
                            / CGFloat(detection.maskWidth)
                    )
                    let y0 = Int(
                        CGFloat(my)
                            * CGFloat(tileHeight)
                            / CGFloat(detection.maskHeight)
                    )
                    let y1 = Int(
                        CGFloat(my + 1)
                            * CGFloat(tileHeight)
                            / CGFloat(detection.maskHeight)
                    )
                    for localY in y0..<max(y0 + 1, y1) {
                        for localX in x0..<max(x0 + 1, x1) {
                            let x = originX + localX
                            let y = originY + localY
                            guard x >= 0, y >= 0, x < width, y < height else {
                                continue
                            }
                            mask[y * width + x] = true
                        }
                    }
                }
            }
        }
        return mask
    }
}
