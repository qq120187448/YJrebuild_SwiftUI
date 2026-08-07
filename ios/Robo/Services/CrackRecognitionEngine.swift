import CoreGraphics
import CoreML
import Foundation
import UIKit
import Vision

struct CrackRealtimeMask {
    let points: [CGPoint]
    let detectionCount: Int
}

struct CrackRecognitionOutput {
    let result: CrackRecognitionResult
    let annotatedImage: UIImage
}

enum CrackRecognitionError: LocalizedError {
    case modelNotFound
    case invalidImage
    case noModelOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "未找到 CoreML 模型，请在 Mac 上导出 crack_seg_n/s 并加入工程资源"
        case .invalidImage:
            return "无法读取识别图片"
        case .noModelOutput:
            return "模型输出格式不符合 YOLOv8-seg"
        }
    }
}

enum CrackRecognitionEngine {

    private struct LoadedModel {
        let mlModel: MLModel
        let visionModel: VNCoreMLModel
    }

    static func makeVisionModel(size: String) throws -> VNCoreMLModel {
        try loadModel(size: size).visionModel
    }

    static func analyze(
        image: UIImage,
        pose: [Float],
        intrinsics: [Float],
        surfaces: [WallDefectSurface],
        config: CrackRecognitionConfig
    ) throws -> CrackRecognitionOutput {
        let model = try loadModel(size: config.modelSize)
        let analysisImage = resizedUIImage(
            image,
            maxSide: config.mode == "hairline" ? 4096 : 2048
        )
        guard let cgImage = analysisImage.cgImage else {
            throw CrackRecognitionError.invalidImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let ratio = CGFloat(width) / max(image.size.width, 1)
        let scaledIntrinsics = scaleIntrinsics(intrinsics, ratio: ratio)
        let detections = try runDetections(
            cgImage: cgImage,
            model: model,
            config: config
        )
        let merged = mergedMask(
            detections: detections,
            width: width,
            height: height
        )
        let skeleton = CrackSkeleton.analyze(
            mask: merged,
            width: width,
            height: height,
            config: config
        )
        let skeletonMask = skeleton.mask ?? merged
        let measurements = surfaceMeasurements(
            skeletonMask: skeletonMask,
            width: width,
            height: height,
            pose: pose,
            intrinsics: scaledIntrinsics,
            surfaces: surfaces,
            config: config
        )

        let confidence = detections.map(\.score).max() ?? 0
        let totalMM: Double?
        if measurements.totalLengthM > 0 {
            totalMM = measurements.totalLengthM * 1000
        } else if config.lengthUnit == "known", config.mmPerPixel > 0 {
            totalMM = skeleton.totalPixelLength * config.mmPerPixel
        } else {
            totalMM = nil
        }

        let result = CrackRecognitionResult(
            detectedClass: detections.isEmpty ? "无裂缝" : "裂缝",
            confidence: Double(confidence),
            totalPixelLength: skeleton.totalPixelLength,
            totalMMLength: totalMM,
            totalLengthM: measurements.totalLengthM,
            totalAreaM2: measurements.totalAreaM2,
            components: measurements.components,
            surfaceSummaries: measurements.summaries,
            mode: config.mode,
            modelSize: config.modelSize,
            engine: config.engine
        )
        let annotated = annotatedImage(
            from: analysisImage,
            mask: skeletonMask,
            width: width,
            height: height
        )
        return CrackRecognitionOutput(result: result, annotatedImage: annotated)
    }

    static func realtimeMaskPoints(
        cgImage: CGImage,
        model: VNCoreMLModel,
        config: CrackRecognitionConfig
    ) throws -> CrackRealtimeMask {
        let inputSize = 640
        let resized = resizedCGImage(
            cgImage,
            width: inputSize,
            height: inputSize
        )
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        request.usesCPUOnly = false
        try VNImageRequestHandler(cgImage: resized, orientation: .up)
            .perform([request])

        guard let (prediction, protos) = featureArrays(from: request.results) else {
            throw CrackRecognitionError.noModelOutput
        }
        var detections = CrackYOLODecoder.decode(
            prediction: prediction,
            protos: protos,
            confidence: Float(config.confidence)
        )
        detections = CrackYOLODecoder.nms(
            detections,
            iouThreshold: Float(config.iou)
        )
        for index in detections.indices {
            CrackYOLODecoder.decodeMask(for: &detections[index], protos: protos)
            detections[index].tileRect = CGRect(
                x: 0,
                y: 0,
                width: inputSize,
                height: inputSize
            )
        }

        let mask = mergedMask(
            detections: detections,
            width: inputSize,
            height: inputSize
        )
        var points: [CGPoint] = []
        points.reserveCapacity(1200)
        for y in stride(from: 0, to: inputSize, by: 2) {
            for x in stride(from: 0, to: inputSize, by: 2) {
                if mask[y * inputSize + x] {
                    points.append(
                        CGPoint(
                            x: CGFloat(x) / CGFloat(inputSize),
                            y: CGFloat(y) / CGFloat(inputSize)
                        )
                    )
                }
            }
        }
        return CrackRealtimeMask(
            points: points,
            detectionCount: detections.count
        )
    }

    private static func loadModel(size: String) throws -> LoadedModel {
        let name = size == "n" ? "crack_seg_n" : "crack_seg_s"
        let mlModel: MLModel
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlmodelc",
            subdirectory: "Models"
        ) {
            mlModel = try MLModel(contentsOf: url)
        } else if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlpackage",
            subdirectory: "Models"
        ) {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled)
        } else if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlmodel",
            subdirectory: "Models"
        ) {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled)
        } else if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            mlModel = try MLModel(contentsOf: url)
        } else if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled)
        } else if let url = Bundle.main.url(forResource: name, withExtension: "mlmodel") {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled)
        } else {
            throw CrackRecognitionError.modelNotFound
        }
        return LoadedModel(
            mlModel: mlModel,
            visionModel: try VNCoreMLModel(for: mlModel)
        )
    }

    private static func runDetections(
        cgImage: CGImage,
        model: LoadedModel,
        config: CrackRecognitionConfig
    ) throws -> [YOLOSegDetection] {
        let width = cgImage.width
        let height = cgImage.height
        let inputSize = modelInputSize(model.mlModel)

        if config.mode == "hairline",
           width > config.tileSize || height > config.tileSize {
            let step = max(64, config.tileSize - config.tileOverlap)
            var all: [YOLOSegDetection] = []
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let tileWidth = min(config.tileSize, width - x)
                    let tileHeight = min(config.tileSize, height - y)
                    guard let tile = cgImage.cropping(
                        to: CGRect(
                            x: x,
                            y: y,
                            width: tileWidth,
                            height: tileHeight
                        )
                    ) else {
                        continue
                    }
                    let decoded = try runSingleDetection(
                        cgImage: tile,
                        model: model,
                        inputSize: inputSize,
                        offset: CGPoint(x: x, y: y),
                        tileSize: CGSize(width: tileWidth, height: tileHeight),
                        config: config
                    )
                    all.append(contentsOf: decoded)
                }
            }
            return CrackYOLODecoder.nms(
                all,
                iouThreshold: Float(config.iou)
            )
        }

        return try runSingleDetection(
            cgImage: cgImage,
            model: model,
            inputSize: inputSize,
            offset: .zero,
            tileSize: CGSize(width: width, height: height),
            config: config
        )
    }

    private static func runSingleDetection(
        cgImage: CGImage,
        model: LoadedModel,
        inputSize: Int,
        offset: CGPoint,
        tileSize: CGSize,
        config: CrackRecognitionConfig
    ) throws -> [YOLOSegDetection] {
        let resized = resizedCGImage(
            cgImage,
            width: inputSize,
            height: inputSize
        )
        let request = VNCoreMLRequest(model: model.visionModel)
        request.imageCropAndScaleOption = .scaleFill
        request.usesCPUOnly = false
        try VNImageRequestHandler(cgImage: resized, orientation: .up)
            .perform([request])

        guard let (prediction, protos) = featureArrays(from: request.results) else {
            throw CrackRecognitionError.noModelOutput
        }
        var detections = CrackYOLODecoder.decode(
            prediction: prediction,
            protos: protos,
            confidence: Float(config.confidence)
        )
        detections = CrackYOLODecoder.nms(
            detections,
            iouThreshold: Float(config.iou)
        )

        let scaleX = tileSize.width / CGFloat(inputSize)
        let scaleY = tileSize.height / CGFloat(inputSize)
        for index in detections.indices {
            detections[index].box = CGRect(
                x: offset.x + detections[index].box.minX * scaleX,
                y: offset.y + detections[index].box.minY * scaleY,
                width: detections[index].box.width * scaleX,
                height: detections[index].box.height * scaleY
            )
            detections[index].tileRect = CGRect(
                origin: offset,
                size: tileSize
            )
            CrackYOLODecoder.decodeMask(
                for: &detections[index],
                protos: protos
            )
        }
        return detections
    }

    private static func featureArrays(
        from results: [VNObservation]?
    ) -> (prediction: MLMultiArray, protos: MLMultiArray)? {
        guard let observations = results as? [VNCoreMLFeatureValueObservation] else {
            return nil
        }
        var prediction: MLMultiArray?
        var protos: MLMultiArray?
        for observation in observations {
            guard let array = observation.featureValue.multiArrayValue else {
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
        return nil
    }

    private static func modelInputSize(_ model: MLModel) -> Int {
        for description in model.modelDescription.inputDescriptionsByName.values {
            if let constraint = description.imageConstraint {
                return Int(constraint.pixelsWide)
            }
        }
        return 640
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

    private static func surfaceMeasurements(
        skeletonMask: [Bool],
        width: Int,
        height: Int,
        pose: [Float],
        intrinsics: [Float],
        surfaces: [WallDefectSurface],
        config: CrackRecognitionConfig
    ) -> (
        summaries: [CrackSurfaceSummary],
        components: [CrackComponentMeasurement],
        totalLengthM: Double,
        totalAreaM2: Double
    ) {
        guard !surfaces.isEmpty else {
            return ([], [], 0, 0)
        }
        let splits = WallDefectProjection.splitMaskBySurfaces(
            mask: skeletonMask,
            width: width,
            height: height,
            pose: pose,
            intrinsics: intrinsics,
            surfaces: surfaces
        )
        var summaries: [CrackSurfaceSummary] = []
        var components: [CrackComponentMeasurement] = []
        var totalLength = 0.0
        var totalArea = 0.0

        for split in splits {
            guard let surface = surfaces.first(where: { $0.id == split.surfaceID }) else {
                continue
            }
            let analysis = CrackSkeleton.analyze(
                mask: split.mask,
                width: width,
                height: height,
                config: config
            )
            let groups = CrackSkeleton.componentPoints(
                analysis.mask ?? split.mask,
                width: width,
                height: height
            )
            var splitLength = 0.0
            var longest = 0.0
            for (index, group) in groups.enumerated() {
                var uvByPoint: [CrackPoint: SIMD2<Double>] = [:]
                for point in group {
                    let pixelIndex = point.y * width + point.x
                    if let uv = split.uvByIndex[pixelIndex] {
                        uvByPoint[point] = uv
                    }
                }
                let physical = CrackSkeleton.physicalGraphLength(
                    group,
                    uvByPoint: uvByPoint
                )
                let pixelLength = CrackSkeleton.pixelLength(of: group)
                let lengthM = physical ?? 0
                let mm: Double?
                if let physical {
                    mm = physical * 1000
                } else if config.lengthUnit == "known", config.mmPerPixel > 0 {
                    mm = pixelLength * config.mmPerPixel
                } else {
                    mm = nil
                }
                components.append(
                    CrackComponentMeasurement(
                        id: components.count + 1,
                        pixelLength: pixelLength,
                        mmLength: mm,
                        lengthM: lengthM > 0 ? lengthM : nil
                    )
                )
                splitLength += lengthM
                longest = max(longest, lengthM)
            }

            let area = estimatedAreaM2(
                split: split,
                surface: surface,
                width: width,
                height: height
            )
            summaries.append(
                CrackSurfaceSummary(
                    surfaceID: surface.id,
                    label: surface.label,
                    pixelArea: split.pixelCount,
                    areaM2: area,
                    totalLengthM: splitLength,
                    longestLengthM: longest,
                    componentCount: groups.count,
                    uvPolygon: uvPolygon(for: split)
                )
            )
            totalLength += splitLength
            totalArea += area
        }
        return (summaries, components, totalLength, totalArea)
    }

    private static func estimatedAreaM2(
        split: SurfaceMaskSplit,
        surface: WallDefectSurface,
        width: Int,
        height: Int
    ) -> Double {
        var cellSum = 0.0
        var samples = 0
        for (index, uv) in split.uvByIndex {
            let x = index % width
            let y = index / width
            guard let right = split.uvByIndex[y * width + min(x + 1, width - 1)],
                  let down = split.uvByIndex[min(y + 1, height - 1) * width + x] else {
                continue
            }
            let du = right - uv
            let dv = down - uv
            cellSum += abs(du.x * dv.y - du.y * dv.x)
            samples += 1
        }
        let averageCell = samples > 0 ? cellSum / Double(samples) : 0
        return averageCell * Double(split.pixelCount)
    }

    private static func uvPolygon(for split: SurfaceMaskSplit) -> [[Double]] {
        let values = Array(split.uvByIndex.values)
        guard !values.isEmpty else { return [] }
        var minU = Double.infinity
        var maxU = -Double.infinity
        var minV = Double.infinity
        var maxV = -Double.infinity
        for value in values {
            minU = min(minU, value.x)
            maxU = max(maxU, value.x)
            minV = min(minV, value.y)
            maxV = max(maxV, value.y)
        }
        return [
            [minU, minV],
            [maxU, minV],
            [maxU, maxV],
            [minU, maxV]
        ]
    }

    private static func resizedUIImage(
        _ image: UIImage,
        maxSide: CGFloat
    ) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > 0 else { return image }
        let scale = min(1, maxSide / largest)
        let width = max(1, Int(image.size.width * scale))
        let height = max(1, Int(image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { rendererContext in
                rendererContext.cgContext.interpolationQuality = .high
                image.draw(in: CGRect(origin: .zero, size: size))
            }
    }

    private static func resizedCGImage(
        _ image: CGImage,
        width: Int,
        height: Int
    ) -> CGImage {
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

    private static func scaleIntrinsics(
        _ intrinsics: [Float],
        ratio: CGFloat
    ) -> [Float] {
        guard intrinsics.count == 9 else { return intrinsics }
        var scaled = intrinsics
        let value = Float(ratio)
        scaled[0] *= value
        scaled[4] *= value
        scaled[2] *= value
        scaled[5] *= value
        return scaled
    }

    private static func annotatedImage(
        from image: UIImage,
        mask: [Bool],
        width: Int,
        height: Int
    ) -> UIImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<mask.count where mask[index] {
            rgba[index * 4] = 255
            rgba[index * 4 + 1] = 40
            rgba[index * 4 + 2] = 40
            rgba[index * 4 + 3] = 160
        }
        var overlay: CGImage?
        if let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            overlay = context.makeImage()
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { rendererContext in
                image.draw(in: CGRect(origin: .zero, size: size))
                if let overlay {
                    rendererContext.cgContext.draw(
                        overlay,
                        in: CGRect(origin: .zero, size: size)
                    )
                }
            }
    }
}
