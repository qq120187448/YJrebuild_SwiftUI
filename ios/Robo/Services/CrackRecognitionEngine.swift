import CoreGraphics
import CoreVideo
import CoreML
import Foundation
import simd
import UIKit
import Vision

struct CrackSkeleton3DPoint {
    let surfaceID: UUID
    let pixel: CrackPoint
    let world: SIMD3<Float>
}

struct CrackRecognitionOutput {
    let result: CrackRecognitionResult
    let annotatedImage: UIImage?
    let arSkeleton: [CrackSkeleton3DPoint]
    let timings: [String: Double]
    let rawDetectionCount: Int
    let skeletonComponentCount: Int
    let projectedComponentCount: Int
    let pixelLengthReported: Double
    let maskPointCount: Int
    let preFilterComponentCount: Int
    let filteredReason: String?
    /// P0 测量诊断：mesh / depth / plane 命中与未命中统计。
    let meshHitCount: Int
    let depthHitCount: Int
    let planeHitCount: Int
    let missCount: Int
    /// 屏幕重投影误差（像素），闭环测试用；nil 表示未计算。
    let reprojectionErrorPx: Double?
    let meshAnchorCount: Int
    let meshVertexCount: Int
    let meshFaceCount: Int
}

/// 稀疏骨架测量结果（含 P0 诊断统计）。meshuv 与 legacy 两种引擎共用。
private struct SparseMeasurementResult {
    let summaries: [CrackSurfaceSummary]
    let components: [CrackComponentMeasurement]
    let totalLengthM: Double
    let totalAreaM2: Double
    let arPoints: [CrackSkeleton3DPoint]
    let meshHitCount: Int
    let depthHitCount: Int
    let planeHitCount: Int
    let missCount: Int
    let reprojectionErrorPx: Double?
}

struct CrackResolutionValidationResult: Identifiable {
    let id: Int
    let resolution: Int
    let detectionCount: Int
    let skeletonComponentCount: Int
    let totalPixelLength: Double
    let longestPixelLength: Double
    let confidence: Double
    let maskPixelCount: Int
    let annotatedImage: UIImage?
    let errorMessage: String?

    init(
        id: Int,
        resolution: Int,
        detectionCount: Int,
        skeletonComponentCount: Int,
        totalPixelLength: Double,
        longestPixelLength: Double,
        confidence: Double,
        maskPixelCount: Int,
        annotatedImage: UIImage?,
        errorMessage: String?
    ) {
        self.id = id
        self.resolution = resolution
        self.detectionCount = detectionCount
        self.skeletonComponentCount = skeletonComponentCount
        self.totalPixelLength = totalPixelLength
        self.longestPixelLength = longestPixelLength
        self.confidence = confidence
        self.maskPixelCount = maskPixelCount
        self.annotatedImage = annotatedImage
        self.errorMessage = errorMessage
    }
}

private struct LetterboxTransform {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
}

enum CrackRecognitionError: LocalizedError {
    case modelNotFound
    case invalidImage
    case noModelOutput
    case visionModelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "未找到 CoreML 模型，请在 Mac 上导出 crack_seg_n/s 并加入工程资源"
        case .invalidImage:
            return "无法读取识别图片"
        case .noModelOutput:
            return "模型输出格式不符合 YOLOv8-seg"
        case .visionModelUnavailable:
            return "无法创建 Vision CoreML 请求"
        }
    }
}

enum CrackRecognitionEngine {

    private struct LoadedModel {
        let mlModel: MLModel
        let visionRequest: VNCoreMLRequest?
    }

    private static var modelCache: [String: LoadedModel] = [:]
    private static let modelLock = NSLock()
    private static let inferenceQueue = DispatchQueue(
        label: "com.silv.RoboScan.crackInference",
        qos: .userInitiated
    )

    static func analyze(
        image: UIImage,
        pose: [Float],
        intrinsics: [Float],
        surfaces: [WallDefectSurface],
        config: CrackRecognitionConfig,
        progress: ((String, Double?) -> Void)? = nil,
        depthContext: CrackDepthContext? = nil,
        meshContext: CrackMeshContext? = nil
    ) throws -> CrackRecognitionOutput {
        var timings: [String: Double] = [:]
        let overallStart = CFAbsoluteTimeGetCurrent()
        let modelStart = CFAbsoluteTimeGetCurrent()
        progress?("正在加载模型", nil)
        let model = try loadModel(size: config.modelSize, config: config)
        timings["模型加载"] = CFAbsoluteTimeGetCurrent() - modelStart

        let prepareStart = CFAbsoluteTimeGetCurrent()
        progress?("正在预处理照片", timings["模型加载"])
        let analysisImage = resizedUIImage(
            image,
            maxSide: CGFloat(config.captureResolution)
        )
        guard let cgImage = analysisImage.cgImage else {
            throw CrackRecognitionError.invalidImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let ratio = CGFloat(width) / max(image.size.width, 1)
        let scaledIntrinsics = scaleIntrinsics(intrinsics, ratio: ratio)
        timings["预处理"] = CFAbsoluteTimeGetCurrent() - prepareStart

        let inferenceStart = CFAbsoluteTimeGetCurrent()
        progress?("正在 CoreML 推理", timings["预处理"])
        var detections = try runDetections(
            cgImage: cgImage,
            model: model,
            config: config,
            progress: { stage in
                progress?(stage, CFAbsoluteTimeGetCurrent() - overallStart)
            }
        )
        detections = filterEdgeDetections(
            detections,
            width: width,
            height: height
        )
        timings["CoreML识别"] = CFAbsoluteTimeGetCurrent() - inferenceStart

        let sparseStart = CFAbsoluteTimeGetCurrent()
        progress?("正在转换稀疏掩码", timings["CoreML识别"])
        let sparse = sparseMaskPoints(
            detections: detections,
            width: width,
            height: height
        )
        timings["掩码转稀疏点"] = CFAbsoluteTimeGetCurrent() - sparseStart

        let skeletonStart = CFAbsoluteTimeGetCurrent()
        progress?("正在提取裂缝骨架", timings["掩码转稀疏点"])
        let skeleton = CrackSkeleton.analyzeSparse(
            points: sparse.points,
            spacing: sparse.spacing,
            width: width,
            height: height,
            config: config
        )
        timings["骨架化"] = CFAbsoluteTimeGetCurrent() - skeletonStart

        let measureStart = CFAbsoluteTimeGetCurrent()
        progress?("正在墙面投射并计算长度", timings["骨架化"])
        let measurePoints = skeleton.fullSkeletonPoints.isEmpty
            ? skeleton.skeletonPoints
            : skeleton.fullSkeletonPoints
        let measurements: SparseMeasurementResult
        if config.measurementEngine == "meshuv" {
            measurements = measureSparseSkeletonMeshUV(
                points: measurePoints,
                spacing: sparse.spacing,
                width: width,
                height: height,
                pose: pose,
                intrinsics: scaledIntrinsics,
                sensorIntrinsics: intrinsics,
                surfaces: surfaces,
                config: config,
                depthContext: depthContext,
                meshContext: meshContext
            )
        } else {
            let legacy = measureSparseSkeleton(
                points: measurePoints,
                spacing: sparse.spacing,
                width: width,
                height: height,
                pose: pose,
                intrinsics: scaledIntrinsics,
                surfaces: surfaces,
                config: config,
                depthContext: depthContext
            )
            measurements = SparseMeasurementResult(
                summaries: legacy.summaries,
                components: legacy.components,
                totalLengthM: legacy.totalLengthM,
                totalAreaM2: legacy.totalAreaM2,
                arPoints: legacy.arPoints,
                meshHitCount: 0,
                depthHitCount: 0,
                planeHitCount: 0,
                missCount: 0,
                reprojectionErrorPx: nil
            )
        }
        timings["墙面投射与长度"] = CFAbsoluteTimeGetCurrent() - measureStart

        let confidence = detections.map(\.score).max() ?? 0
        let fallbackComponents = skeleton.components.map { component in
            let lengthM = component.mmLength.map { $0 / 1000 }
            return CrackComponentMeasurement(
                id: component.id,
                pixelLength: component.pixelLength,
                mmLength: component.mmLength,
                lengthM: lengthM,
                uvPolyline: nil,
                measurementVersion: MeasurementEngineVersion.legacy
            )
        }
        let finalComponents: [CrackComponentMeasurement]
        if !measurements.components.isEmpty {
            finalComponents = measurements.components
        } else if surfaces.isEmpty, !fallbackComponents.isEmpty {
            finalComponents = fallbackComponents
        } else {
            finalComponents = []
        }
        let fallbackTotalM = finalComponents.reduce(0) {
            $0 + ($1.lengthM ?? 0)
        }
        let finalTotalM = measurements.totalLengthM > 0
            ? measurements.totalLengthM
            : fallbackTotalM
        let totalMM: Double?
        if finalTotalM > 0 {
            totalMM = finalTotalM * 1000
        } else if config.lengthUnit == "known", config.mmPerPixel > 0 {
            totalMM = skeleton.totalPixelLength * config.mmPerPixel
        } else {
            totalMM = nil
        }
        let pixelLengthReported: Double
        if skeleton.totalPixelLength > 0 {
            pixelLengthReported = skeleton.totalPixelLength
        } else if !sparse.points.isEmpty {
            pixelLengthReported = Double(sparse.points.count)
        } else {
            pixelLengthReported = 0
        }

        let filteredReason: String?
        if finalComponents.isEmpty {
            if sparse.points.isEmpty {
                filteredReason = "掩码为空"
            } else if skeleton.fullComponentCount == 0 {
                filteredReason = "骨架提取为空"
            } else if !surfaces.isEmpty {
                filteredReason = measurements.arPoints.isEmpty
                    ? "墙面投影失败，请对准墙面重新拍摄"
                    : "投影后物理长度不足 \(Int(config.minPhysicalLengthMM)) mm"
            } else {
                filteredReason = "像素长度不足 \(config.minSkeletonLength) px"
            }
        } else {
            filteredReason = nil
        }

        let result = CrackRecognitionResult(
            detectedClass: detections.isEmpty ? "无裂缝" : "裂缝",
            confidence: Double(confidence),
            totalPixelLength: skeleton.totalPixelLength,
            totalMMLength: totalMM,
            totalLengthM: finalTotalM,
            totalAreaM2: measurements.totalAreaM2,
            components: finalComponents,
            surfaceSummaries: measurements.summaries,
            mode: config.mode,
            modelSize: config.modelSize,
            engine: config.engine,
            measurementVersion: config.measurementEngine == "meshuv"
                ? MeasurementEngineVersion.current
                : MeasurementEngineVersion.legacy,
            measurementEngine: config.measurementEngine
        )
        timings["总计"] = CFAbsoluteTimeGetCurrent() - overallStart
        progress?("识别完成", timings["总计"])
        return CrackRecognitionOutput(
            result: result,
            annotatedImage: nil,
            arSkeleton: measurements.arPoints,
            timings: timings,
            rawDetectionCount: detections.count,
            skeletonComponentCount: skeleton.components.count,
            projectedComponentCount: measurements.components.count,
            pixelLengthReported: pixelLengthReported,
            maskPointCount: sparse.points.count,
            preFilterComponentCount: skeleton.fullComponentCount,
            filteredReason: filteredReason,
            meshHitCount: measurements.meshHitCount,
            depthHitCount: measurements.depthHitCount,
            planeHitCount: measurements.planeHitCount,
            missCount: measurements.missCount,
            reprojectionErrorPx: measurements.reprojectionErrorPx,
            meshAnchorCount: meshContext?.anchorCount ?? 0,
            meshVertexCount: meshContext?.vertexCount ?? 0,
            meshFaceCount: meshContext?.faceCount ?? 0
        )
    }

    static func checkModelLoad() -> String {
        do {
            _ = try loadModel(
                named: "crack_seg_n",
                config: CrackRecognitionSettings.load()
            )
            return "模型加载成功"
        } catch {
            return "模型加载失败：\(error.localizedDescription)"
        }
    }

    static func validateResolutions(
        image: UIImage,
        resolutions: [Int] = [640, 1280, 1920, 2240, 3200, 4096],
        progress: ((String, [CrackResolutionValidationResult]) -> Void)? = nil
    ) -> [CrackResolutionValidationResult] {
        let analysisImage = resizedUIImage(image, maxSide: 4096)
        guard let cgImage = analysisImage.cgImage else {
            let results = resolutions.enumerated().map { index, resolution in
                CrackResolutionValidationResult(
                    id: index,
                    resolution: resolution,
                    detectionCount: 0,
                    skeletonComponentCount: 0,
                    totalPixelLength: 0,
                    longestPixelLength: 0,
                    confidence: 0,
                    maskPixelCount: 0,
                    annotatedImage: nil,
                    errorMessage: CrackRecognitionError.invalidImage.localizedDescription
                )
            }
            progress?("图片读取失败", results)
            return results
        }

        let config = CrackRecognitionSettings.load()

        let model: LoadedModel
        do {
            progress?("正在加载 \(config.modelSize) 模型", [])
            model = try loadModel(size: config.modelSize, config: config)
            progress?("模型加载成功，等待推理", [])
        } catch {
            let errorMessage = error.localizedDescription
            let results = resolutions.enumerated().map { index, resolution in
                CrackResolutionValidationResult(
                    id: index,
                    resolution: resolution,
                    detectionCount: 0,
                    skeletonComponentCount: 0,
                    totalPixelLength: 0,
                    longestPixelLength: 0,
                    confidence: 0,
                    maskPixelCount: 0,
                    annotatedImage: nil,
                    errorMessage: errorMessage
                )
            }
            progress?("模型加载失败：\(errorMessage)", results)
            return results
        }

        var results: [CrackResolutionValidationResult] = []
        for (index, resolution) in resolutions.enumerated() {
            let backendLabel = config.inferenceBackend == "vision"
                ? "Vision"
                : "CoreML"
            do {
                progress?("正在准备 \(resolution)×\(resolution) 输入", results)
                let canvas = letterboxedCGImage(
                    cgImage,
                    canvasSize: resolution
                ).0
                let canvasWidth = canvas.width
                let canvasHeight = canvas.height
                progress?(
                    "\(resolution) 输入图已生成，进入 \(backendLabel) 推理队列",
                    results
                )
                let detections = try runSingleDetection(
                    cgImage: canvas,
                    model: model,
                    inputSize: 640,
                    offset: .zero,
                    tileSize: CGSize(width: canvasWidth, height: canvasHeight),
                    config: config,
                    progress: { stage in
                        progress?("\(resolution) \(stage)", results)
                    }
                )
                progress?("\(resolution) 生成标注图", results)
                let mask = mergedMask(
                    detections: detections,
                    width: canvasWidth,
                    height: canvasHeight
                )
                let sparse = sparseMaskPoints(
                    detections: detections,
                    width: canvasWidth,
                    height: canvasHeight
                )
                let skeleton = CrackSkeleton.analyzeSparse(
                    points: sparse.points,
                    spacing: sparse.spacing,
                    width: canvasWidth,
                    height: canvasHeight,
                    config: config
                )
                let annotated = annotatedImageWithBoxes(
                    from: UIImage(cgImage: canvas),
                    mask: mask,
                    boxes: detections.map(\.box),
                    skeletonPoints: skeleton.skeletonPoints,
                    width: canvasWidth,
                    height: canvasHeight
                )
                let result = CrackResolutionValidationResult(
                    id: index,
                    resolution: resolution,
                    detectionCount: detections.count,
                    skeletonComponentCount: skeleton.components.count,
                    totalPixelLength: skeleton.totalPixelLength,
                    longestPixelLength: skeleton.longestPixelLength,
                    confidence: Double(detections.map(\.score).max() ?? 0),
                    maskPixelCount: mask.filter { $0 }.count,
                    annotatedImage: resizedUIImage(annotated, maxSide: 1600),
                    errorMessage: nil
                )
                results.append(result)
                progress?("\(resolution) 完成，检测到 \(detections.count) 处裂缝", results)
            } catch {
                let result = CrackResolutionValidationResult(
                    id: index,
                    resolution: resolution,
                    detectionCount: 0,
                    skeletonComponentCount: 0,
                    totalPixelLength: 0,
                    longestPixelLength: 0,
                    confidence: 0,
                    maskPixelCount: 0,
                    annotatedImage: nil,
                    errorMessage: error.localizedDescription
                )
                results.append(result)
                progress?("\(resolution) 出错：\(error.localizedDescription)", results)
            }
        }
        return results
    }

    private static func loadModel(
        size: String,
        config: CrackRecognitionConfig
    ) throws -> LoadedModel {
        let name = size == "n" ? "crack_seg_n" : "crack_seg_s"
        return try loadModel(named: name, config: config)
    }

    private static func loadModel(
        named name: String,
        config: CrackRecognitionConfig
    ) throws -> LoadedModel {
        let cacheKey = "\(name)|\(config.computeMode)"
        modelLock.lock()
        if let cached = modelCache[cacheKey] {
            modelLock.unlock()
            return cached
        }
        modelLock.unlock()

        let loaded = try makeModel(name: name, config: config)
        modelLock.lock()
        modelCache[cacheKey] = loaded
        modelLock.unlock()
        return loaded
    }

    private static func makeModel(
        name: String,
        config: CrackRecognitionConfig
    ) throws -> LoadedModel {
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
        if #available(iOS 17.0, *) {
            configuration.setValue(1, forKey: "experimentalMLE5EngineUsage")
        }
        print(
            "[CrackCoreML] loading \(name) computeMode=\(config.computeMode) mle5Compat=1"
        )
        let mlModel: MLModel
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlmodelc",
            subdirectory: "Models"
        ) {
            mlModel = try MLModel(contentsOf: url, configuration: configuration)
        } else if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlpackage",
            subdirectory: "Models"
        ) {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled, configuration: configuration)
        } else if let url = Bundle.main.url(
            forResource: name,
            withExtension: "mlmodel",
            subdirectory: "Models"
        ) {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled, configuration: configuration)
        } else if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            mlModel = try MLModel(contentsOf: url, configuration: configuration)
        } else if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled, configuration: configuration)
        } else if let url = Bundle.main.url(forResource: name, withExtension: "mlmodel") {
            let compiled = try MLModel.compileModel(at: url)
            mlModel = try MLModel(contentsOf: compiled, configuration: configuration)
        } else {
            throw CrackRecognitionError.modelNotFound
        }
        let visionModel = try? VNCoreMLModel(for: mlModel)
        var visionRequest: VNCoreMLRequest?
        if let visionModel {
            let request = VNCoreMLRequest(model: visionModel)
            request.imageCropAndScaleOption = .scaleFit
            visionRequest = request
        }
        return LoadedModel(
            mlModel: mlModel,
            visionRequest: visionRequest
        )
    }

    private static func runDetections(
        cgImage: CGImage,
        model: LoadedModel,
        config: CrackRecognitionConfig,
        progress: ((String) -> Void)? = nil
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
                        config: config,
                        progress: progress
                    )
                    all.append(contentsOf: decoded)
                }
            }
            return CrackYOLODecoder.nms(
                all,
                iouThreshold: Float(config.iou),
                maxDetections: config.maxDetections
            )
        }

        return try runSingleDetection(
            cgImage: cgImage,
            model: model,
            inputSize: inputSize,
            offset: .zero,
            tileSize: CGSize(width: width, height: height),
            config: config,
            progress: progress
        )
    }

    private static func runSingleDetection(
        cgImage: CGImage,
        model: LoadedModel,
        inputSize: Int,
        offset: CGPoint,
        tileSize: CGSize,
        config: CrackRecognitionConfig,
        progress: ((String) -> Void)? = nil
    ) throws -> [YOLOSegDetection] {
        progress?("letterbox 完成，进入推理队列")
        let (resized, transform) = letterboxedCGImage(
            cgImage,
            canvasSize: inputSize
        )
        print(
            "[CrackCoreML] letterbox complete \(resized.width)x\(resized.height)"
        )
        progress?("推理队列开始")
        let (prediction, protos) = try predict(
            model: model,
            cgImage: resized,
            config: config
        )
        print("[CrackCoreML] prediction returned, starting decode")
        progress?("CoreML 推理返回，开始解析检测")
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
        progress?("检测解析完成，生成掩码")

        for index in detections.indices {
            let box = detections[index].box
            detections[index].box = CGRect(
                x: offset.x + (box.minX - transform.offsetX) / transform.scale,
                y: offset.y + (box.minY - transform.offsetY) / transform.scale,
                width: box.width / transform.scale,
                height: box.height / transform.scale
            )
            CrackYOLODecoder.decodeMask(
                for: &detections[index],
                protos: protos
            )
            detections[index].tileRect = CGRect(
                origin: offset,
                size: tileSize
            )
        }
        progress?("掩码生成完成")
        return detections
    }

    private static func predict(
        model: LoadedModel,
        cgImage: CGImage,
        config: CrackRecognitionConfig
    ) throws -> (prediction: MLMultiArray, protos: MLMultiArray) {
        print("[CrackCoreML] entering serial inference queue")
        let result = try inferenceQueue.sync {
            if config.inferenceBackend == "vision" {
                return try predictWithVision(
                    model: model,
                    cgImage: cgImage
                )
            }
            return try predictDirect(model: model, cgImage: cgImage)
        }
        print("[CrackCoreML] leaving serial inference queue")
        return result
    }

    private static func predictDirect(
        model: LoadedModel,
        cgImage: CGImage
    ) throws -> (prediction: MLMultiArray, protos: MLMultiArray) {
        let pixelBuffer = try makePixelBuffer(from: cgImage)
        guard let inputName = model.mlModel.modelDescription
            .inputDescriptionsByName.keys.first else {
            throw CrackRecognitionError.noModelOutput
        }
        let inputValue = MLFeatureValue(pixelBuffer: pixelBuffer)
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputName: inputValue]
        )
        print(
            "[CrackCoreML] direct prediction start \(cgImage.width)x\(cgImage.height)"
        )
        let started = CFAbsoluteTimeGetCurrent()
        let output = try model.mlModel.prediction(from: provider)
        print(
            String(
                format: "[CrackCoreML] direct prediction done %.3f s",
                CFAbsoluteTimeGetCurrent() - started
            )
        )
        return try extractOutputs(from: output)
    }

    private static func predictWithVision(
        model: LoadedModel,
        cgImage: CGImage
    ) throws -> (prediction: MLMultiArray, protos: MLMultiArray) {
        guard let request = model.visionRequest else {
            throw CrackRecognitionError.visionModelUnavailable
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        print(
            "[CrackCoreML] vision prediction start \(cgImage.width)x\(cgImage.height)"
        )
        let started = CFAbsoluteTimeGetCurrent()
        try handler.perform([request])
        print(
            String(
                format: "[CrackCoreML] vision prediction done %.3f s",
                CFAbsoluteTimeGetCurrent() - started
            )
        )
        guard let observations = request.results
                as? [VNCoreMLFeatureValueObservation] else {
            throw CrackRecognitionError.noModelOutput
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
        throw CrackRecognitionError.noModelOutput
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
        throw CrackRecognitionError.noModelOutput
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
            throw CrackRecognitionError.invalidImage
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
            throw CrackRecognitionError.invalidImage
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return pixelBuffer
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

    /// P0/P1 新测量路径：
    /// YOLO skeleton -> Camera Ray -> ARMesh 交点 -> World -> Surface UV。
    /// 三级回退：ARMesh -> sceneDepth/Depth Cloud -> RoomPlan/拟合平面。
    /// 裂缝长度：骨架 -> 剪枝(上游) -> Douglas-Peucker -> UV 折线 -> 米制长度。
    private static func measureSparseSkeletonMeshUV(
        points: Set<CrackPoint>,
        spacing: Int,
        width: Int,
        height: Int,
        pose: [Float],
        intrinsics: [Float],
        sensorIntrinsics: [Float],
        surfaces: [WallDefectSurface],
        config: CrackRecognitionConfig,
        depthContext: CrackDepthContext? = nil,
        meshContext: CrackMeshContext? = nil
    ) -> SparseMeasurementResult {
        guard !points.isEmpty else {
            return SparseMeasurementResult(
                summaries: [],
                components: [],
                totalLengthM: 0,
                totalAreaM2: 0,
                arPoints: [],
                meshHitCount: 0,
                depthHitCount: 0,
                planeHitCount: 0,
                missCount: 0,
                reprojectionErrorPx: nil
            )
        }
        let analysisSize = CGSize(width: width, height: height)
        let projections = WallDefectProjection.projectSparsePoints(
            points: points,
            pose: pose,
            intrinsics: intrinsics,
            surfaces: surfaces
        )

        // 优先 1：ARMesh 交点（最终表面几何）。
        var meshWorldByPoint: [CrackPoint: SIMD3<Float>] = [:]
        var reprojectionSum = 0.0
        var reprojectionCount = 0
        if let meshContext, !meshContext.anchors.isEmpty {
            for point in points {
                let pixel = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                guard let world = WallDefectProjection.meshWorldPoint(
                    pixel: pixel,
                    analysisSize: analysisSize,
                    context: meshContext,
                    pose: pose,
                    intrinsics: sensorIntrinsics,
                    maxDistance: Float(config.meshRayMaxDistanceM)
                ) else {
                    continue
                }
                meshWorldByPoint[point] = world
                // 闭环：world 反投影回 sensor 像素，与原始像素比较。
                if let original = WallDefectProjection.sensorPoint(
                    for: pixel,
                    analysisSize: analysisSize,
                    context: meshContext
                ), let projected = WallDefectProjection.projectToScreen(
                    world: world,
                    pose: pose,
                    intrinsics: sensorIntrinsics
                ) {
                    reprojectionSum += hypot(
                        Double(projected.x - original.x),
                        Double(projected.y - original.y)
                    )
                    reprojectionCount += 1
                }
            }
        }

        // 优先 2：sceneDepth / Depth Cloud（沿用原最近邻，职责改为快速对应与回退）。
        var depthWorldByPoint: [CrackPoint: SIMD3<Float>] = [:]
        if let depthContext {
            for point in points {
                if let world = WallDefectProjection.depthWorldPoint(
                    pixel: CGPoint(
                        x: CGFloat(point.x),
                        y: CGFloat(point.y)
                    ),
                    analysisSize: analysisSize,
                    context: depthContext
                ) {
                    depthWorldByPoint[point] = world
                }
            }
            if !depthWorldByPoint.isEmpty,
               let plane = WallDefectProjection.fitPlane(
                points: depthContext.pointCloud,
                cropRect: depthContext.cropRect
               ) {
                for key in depthWorldByPoint.keys {
                    if let world = depthWorldByPoint[key] {
                        depthWorldByPoint[key] =
                            WallDefectProjection.projectToPlane(
                                point: world,
                                plane: plane
                            )
                    }
                }
            }
        }

        // 优先 3：RoomPlan / 拟合平面射线求交（projections 已含 ray-plane world）。
        var planeWorldByPoint: [CrackPoint: SIMD3<Float>] = [:]
        for (_, projected) in projections {
            for item in projected where planeWorldByPoint[item.point] == nil {
                planeWorldByPoint[item.point] = item.world
            }
        }

        // 汇总每点最终世界坐标与命中层级。
        var worldByPoint: [CrackPoint: SIMD3<Float>] = [:]
        var hitLevelByPoint: [CrackPoint: String] = [:]
        var missCount = 0
        for point in points {
            if let world = meshWorldByPoint[point] {
                worldByPoint[point] = world
                hitLevelByPoint[point] = "mesh"
            } else if let world = depthWorldByPoint[point] {
                worldByPoint[point] = world
                hitLevelByPoint[point] = "depth"
            } else if let world = planeWorldByPoint[point] {
                worldByPoint[point] = world
                hitLevelByPoint[point] = "plane"
            } else {
                missCount += 1
            }
        }
        let meshHitCount = hitLevelByPoint.values.filter { $0 == "mesh" }.count
        let depthHitCount = hitLevelByPoint.values.filter { $0 == "depth" }.count
        let planeHitCount = hitLevelByPoint.values.filter { $0 == "plane" }.count

        var uvByPoint: [CrackPoint: SIMD2<Double>] = [:]
        var surfaceIDByPoint: [CrackPoint: UUID] = [:]
        for (surfaceID, projected) in projections {
            for item in projected {
                uvByPoint[item.point] = item.uv
                surfaceIDByPoint[item.point] = surfaceID
            }
        }

        var summaries: [CrackSurfaceSummary] = []
        var components: [CrackComponentMeasurement] = []
        var totalLength = 0.0
        var totalArea = 0.0
        let minPhysicalM = config.minPhysicalLengthMM / 1000
        let groups = CrackSkeleton.componentPointsSparse(
            points,
            spacing: spacing
        )
        let measurementVersion = MeasurementEngineVersion.current

        for group in groups {
            var worldByGroup: [CrackPoint: SIMD3<Float>] = [:]
            var uvByGroup: [CrackPoint: SIMD2<Double>] = [:]
            var dominantSurfaceID: UUID?
            for point in group {
                if let world = worldByPoint[point] {
                    worldByGroup[point] = world
                }
                if let uv = uvByPoint[point] {
                    uvByGroup[point] = uv
                    if dominantSurfaceID == nil {
                        dominantSurfaceID = surfaceIDByPoint[point]
                    }
                }
            }
            let depthPhysical = CrackSkeleton.worldGraphLength(
                group,
                worldByPoint: worldByGroup,
                spacing: spacing
            )
            let uvPhysical = CrackSkeleton.physicalGraphLength(
                group,
                uvByPoint: uvByGroup,
                spacing: spacing
            )
            let pixelLength = CrackSkeleton.pixelLength(
                of: group,
                spacing: spacing
            )
            // 新：骨架 -> 有序折线 -> Douglas-Peucker -> UV 折线（米）。
            let uvPolyline = CrackSkeleton.uvPolyline(
                from: group,
                uvByPoint: uvByGroup,
                simplifyEpsilonPx: config.polylineEpsilonPx
            )
            let uvPolylineM = WallDefectProjection.uvPolylineLength(
                uvPolyline
            )
            let physical = uvPolylineM > 0
                ? uvPolylineM
                : (uvPhysical ?? depthPhysical)
            let lengthM = physical ?? 0
            let keep: Bool
            if let physical {
                keep = physical >= minPhysicalM
            } else {
                keep = pixelLength >= Double(config.minSkeletonLength)
            }
            guard keep else { continue }

            let mm: Double?
            if let physical {
                mm = physical * 1000
            } else if config.lengthUnit == "known",
                      config.mmPerPixel > 0 {
                mm = pixelLength * config.mmPerPixel
            } else {
                mm = nil
            }
            components.append(
                CrackComponentMeasurement(
                    id: components.count + 1,
                    pixelLength: pixelLength,
                    mmLength: mm,
                    lengthM: lengthM > 0 ? lengthM : nil,
                    uvPolyline: uvPolyline.isEmpty
                        ? nil
                        : uvPolyline.map { [$0.x, $0.y] },
                    measurementVersion: measurementVersion,
                    surfaceID: dominantSurfaceID
                )
            )
            totalLength += lengthM
            totalArea += 0

            var pointsBySurface: [UUID: [CrackPoint]] = [:]
            for point in group {
                if let surfaceID = surfaceIDByPoint[point] {
                    pointsBySurface[surfaceID, default: []].append(point)
                }
            }
            for (surfaceID, surfacePoints) in pointsBySurface {
                guard let surface = surfaces.first(
                    where: { $0.id == surfaceID }
                ) else {
                    continue
                }
                var surfaceUV: [CrackPoint: SIMD2<Double>] = [:]
                for point in surfacePoints {
                    if let uv = uvByPoint[point] {
                        surfaceUV[point] = uv
                    }
                }
                let surfaceUVPolyline = CrackSkeleton.uvPolyline(
                    from: surfacePoints,
                    uvByPoint: surfaceUV,
                    simplifyEpsilonPx: config.polylineEpsilonPx
                )
                let surfaceLength = WallDefectProjection.uvPolylineLength(
                    surfaceUVPolyline
                )
                if let index = summaries.firstIndex(
                    where: { $0.surfaceID == surfaceID }
                ) {
                    let old = summaries[index]
                    summaries[index] = CrackSurfaceSummary(
                        surfaceID: surfaceID,
                        label: surface.label,
                        pixelArea: old.pixelArea + surfacePoints.count,
                        areaM2: old.areaM2,
                        totalLengthM: old.totalLengthM + surfaceLength,
                        longestLengthM: max(
                            old.longestLengthM,
                            surfaceLength
                        ),
                        componentCount: old.componentCount + 1,
                        uvPolygon: old.uvPolygon
                    )
                } else {
                    summaries.append(
                        CrackSurfaceSummary(
                            surfaceID: surfaceID,
                            label: surface.label,
                            pixelArea: surfacePoints.count,
                            areaM2: 0,
                            totalLengthM: surfaceLength,
                            longestLengthM: surfaceLength,
                            componentCount: 1,
                            uvPolygon: uvPolygonSparse(
                                projections[surfaceID] ?? []
                            )
                        )
                    )
                }
            }
        }

        var arPoints: [CrackSkeleton3DPoint] = []
        var arPointSet = Set<CrackPoint>()
        for point in points where !arPointSet.contains(point) {
            let surfaceID = surfaceIDByPoint[point] ?? UUID()
            if let world = worldByPoint[point] {
                arPoints.append(
                    CrackSkeleton3DPoint(
                        surfaceID: surfaceID,
                        pixel: point,
                        world: world
                    )
                )
                arPointSet.insert(point)
            } else if let projectedSurfaceID = surfaceIDByPoint[point],
                      let projected = projections[projectedSurfaceID]?.first(
                        where: { $0.point == point }
                      ) {
                arPoints.append(
                    CrackSkeleton3DPoint(
                        surfaceID: projectedSurfaceID,
                        pixel: point,
                        world: projected.world
                    )
                )
                arPointSet.insert(point)
            }
        }

        let reprojectionErrorPx = reprojectionCount > 0
            ? reprojectionSum / Double(reprojectionCount)
            : nil
        return SparseMeasurementResult(
            summaries: summaries,
            components: components,
            totalLengthM: totalLength,
            totalAreaM2: totalArea,
            arPoints: arPoints,
            meshHitCount: meshHitCount,
            depthHitCount: depthHitCount,
            planeHitCount: planeHitCount,
            missCount: missCount,
            reprojectionErrorPx: reprojectionErrorPx
        )
    }

    private static func measureSparseSkeleton(
        points: Set<CrackPoint>,
        spacing: Int,
        width: Int,
        height: Int,
        pose: [Float],
        intrinsics: [Float],
        surfaces: [WallDefectSurface],
        config: CrackRecognitionConfig,
        depthContext: CrackDepthContext? = nil
    ) -> (
        summaries: [CrackSurfaceSummary],
        components: [CrackComponentMeasurement],
        totalLengthM: Double,
        totalAreaM2: Double,
        arPoints: [CrackSkeleton3DPoint]
    ) {
        guard !points.isEmpty else {
            return ([], [], 0, 0, [])
        }
        let projections = WallDefectProjection.projectSparsePoints(
            points: points,
            pose: pose,
            intrinsics: intrinsics,
            surfaces: surfaces
        )

        var depthWorldByPoint: [CrackPoint: SIMD3<Float>] = [:]
        if let depthContext {
            let analysisSize = CGSize(width: width, height: height)
            for point in points {
                if let world = WallDefectProjection.depthWorldPoint(
                    pixel: CGPoint(
                        x: CGFloat(point.x),
                        y: CGFloat(point.y)
                    ),
                    analysisSize: analysisSize,
                    context: depthContext
                ) {
                    depthWorldByPoint[point] = world
                }
            }
            if !depthWorldByPoint.isEmpty,
               let plane = WallDefectProjection.fitPlane(
                points: depthContext.pointCloud,
                cropRect: depthContext.cropRect
               ) {
                for key in depthWorldByPoint.keys {
                    if let world = depthWorldByPoint[key] {
                        depthWorldByPoint[key] =
                            WallDefectProjection.projectToPlane(
                                point: world,
                                plane: plane
                            )
                    }
                }
            }
        }

        var uvByPoint: [CrackPoint: SIMD2<Double>] = [:]
        var surfaceIDByPoint: [CrackPoint: UUID] = [:]
        for (surfaceID, projected) in projections {
            for item in projected {
                uvByPoint[item.point] = item.uv
                surfaceIDByPoint[item.point] = surfaceID
            }
        }

        var summaries: [CrackSurfaceSummary] = []
        var components: [CrackComponentMeasurement] = []
        var totalLength = 0.0
        var totalArea = 0.0
        let minPhysicalM = config.minPhysicalLengthMM / 1000
        let groups = CrackSkeleton.componentPointsSparse(
            points,
            spacing: spacing
        )

        for group in groups {
            var worldByGroup: [CrackPoint: SIMD3<Float>] = [:]
            var uvByGroup: [CrackPoint: SIMD2<Double>] = [:]
            for point in group {
                if let world = depthWorldByPoint[point] {
                    worldByGroup[point] = world
                }
                if let uv = uvByPoint[point] {
                    uvByGroup[point] = uv
                }
            }
            let depthPhysical = CrackSkeleton.worldGraphLength(
                group,
                worldByPoint: worldByGroup,
                spacing: spacing
            )
            let uvPhysical = CrackSkeleton.physicalGraphLength(
                group,
                uvByPoint: uvByGroup,
                spacing: spacing
            )
            let physical = depthPhysical ?? uvPhysical
            let pixelLength = CrackSkeleton.pixelLength(
                of: group,
                spacing: spacing
            )
            let lengthM = physical ?? 0
            let keep: Bool
            if let physical {
                keep = physical >= minPhysicalM
            } else {
                keep = pixelLength >= Double(config.minSkeletonLength)
            }
            guard keep else { continue }

            let mm: Double?
            if let physical {
                mm = physical * 1000
            } else if config.lengthUnit == "known",
                      config.mmPerPixel > 0 {
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
            totalLength += lengthM
            totalArea += 0

            var pointsBySurface: [UUID: [CrackPoint]] = [:]
            for point in group {
                if let surfaceID = surfaceIDByPoint[point] {
                    pointsBySurface[surfaceID, default: []].append(point)
                }
            }
            for (surfaceID, surfacePoints) in pointsBySurface {
                guard let surface = surfaces.first(
                    where: { $0.id == surfaceID }
                ) else {
                    continue
                }
                var surfaceUV: [CrackPoint: SIMD2<Double>] = [:]
                for point in surfacePoints {
                    if let uv = uvByPoint[point] {
                        surfaceUV[point] = uv
                    }
                }
                let surfaceLength = CrackSkeleton.physicalGraphLength(
                    surfacePoints,
                    uvByPoint: surfaceUV,
                    spacing: spacing
                ) ?? 0
                if let index = summaries.firstIndex(
                    where: { $0.surfaceID == surfaceID }
                ) {
                    let old = summaries[index]
                    summaries[index] = CrackSurfaceSummary(
                        surfaceID: surfaceID,
                        label: surface.label,
                        pixelArea: old.pixelArea + surfacePoints.count,
                        areaM2: old.areaM2,
                        totalLengthM: old.totalLengthM + surfaceLength,
                        longestLengthM: max(
                            old.longestLengthM,
                            surfaceLength
                        ),
                        componentCount: old.componentCount + 1,
                        uvPolygon: old.uvPolygon
                    )
                } else {
                    summaries.append(
                        CrackSurfaceSummary(
                            surfaceID: surfaceID,
                            label: surface.label,
                            pixelArea: surfacePoints.count,
                            areaM2: 0,
                            totalLengthM: surfaceLength,
                            longestLengthM: surfaceLength,
                            componentCount: 1,
                            uvPolygon: uvPolygonSparse(
                                projections[surfaceID] ?? []
                            )
                        )
                    )
                }
            }
        }

        var arPoints: [CrackSkeleton3DPoint] = []
        var arPointSet = Set<CrackPoint>()
        for point in points where !arPointSet.contains(point) {
            if let world = depthWorldByPoint[point] {
                let surfaceID = surfaceIDByPoint[point] ?? UUID()
                arPoints.append(
                    CrackSkeleton3DPoint(
                        surfaceID: surfaceID,
                        pixel: point,
                        world: world
                    )
                )
                arPointSet.insert(point)
            } else if let surfaceID = surfaceIDByPoint[point],
                      let projected = projections[surfaceID]?.first(
                        where: { $0.point == point }
                      ) {
                arPoints.append(
                    CrackSkeleton3DPoint(
                        surfaceID: surfaceID,
                        pixel: point,
                        world: projected.world
                    )
                )
                arPointSet.insert(point)
            }
        }
        return (summaries, components, totalLength, totalArea, arPoints)
    }

    private static func uvPolygonSparse(
        _ projected: [SparseSurfaceProjection]
    ) -> [[Double]] {
        guard !projected.isEmpty else { return [] }
        var minU = Double.infinity
        var maxU = -Double.infinity
        var minV = Double.infinity
        var maxV = -Double.infinity
        for item in projected {
            minU = min(minU, item.uv.x)
            maxU = max(maxU, item.uv.x)
            minV = min(minV, item.uv.y)
            maxV = max(maxV, item.uv.y)
        }
        return [
            [minU, minV],
            [maxU, minV],
            [maxU, maxV],
            [minU, maxV]
        ]
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

    private static func annotatedImageWithBoxes(
        from image: UIImage,
        mask: [Bool],
        boxes: [CGRect],
        skeletonPoints: Set<CrackPoint>,
        width: Int,
        height: Int
    ) -> UIImage {
        let base = annotatedImage(
            from: image,
            mask: mask,
            width: width,
            height: height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { rendererContext in
                base.draw(in: CGRect(origin: .zero, size: size))
                rendererContext.cgContext.setStrokeColor(
                    UIColor.systemYellow.cgColor
                )
                rendererContext.cgContext.setLineWidth(2)
                for box in boxes {
                    rendererContext.cgContext.stroke(box)
                }
                rendererContext.cgContext.setFillColor(
                    UIColor.systemGreen.cgColor
                )
                for point in skeletonPoints {
                    rendererContext.cgContext.fill(
                        CGRect(
                            x: point.x,
                            y: point.y,
                            width: 2,
                            height: 2
                        )
                    )
                }
            }
    }
}
