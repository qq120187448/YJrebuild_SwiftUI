//
//  ContentViewModel.swift
//  YOLOv8-seg-iOS
//
//  Created by Marcel Opitz on 18.05.23.
//

import Combine
import CoreML
import PhotosUI
import SwiftUI
import Vision

enum Status {
    case preProcessing
    case postProcessing
    case inferencing
    case parsingBoxPredictions
    case performingNMS
    case parsingMaskProtos
    case generateMasksFromProtos
}

extension Status {
    var message: String {
        switch self {
        case .preProcessing:
            return "Preprocessing..."
        case .postProcessing:
            return "Postprocessing..."
        case .inferencing:
            return "Inferencing..."
        case .parsingBoxPredictions:
            return "Parsing box predictions..."
        case .performingNMS:
            return "Performing nms..."
        case .parsingMaskProtos:
            return "Parsing mask protos..."
        case .generateMasksFromProtos:
            return "Generate masks from protos..."
        }
    }
}

// MARK: ContentViewModel
class ContentViewModel: ObservableObject {
    
    var cancellables = Set<AnyCancellable>()
    
    @Published var imageSelection: PhotosPickerItem?
    @Published var uiImage: UIImage?
    
    @Published var confidenceThreshold: Float = 0.3
    @Published var iouThreshold: Float = 0.6
    @Published var maskThreshold: Float = 0.5
    
    @MainActor @Published var processing: Bool = false
    
    @MainActor @Published var predictions: [Prediction] = []
    @Published var maskPredictions: [MaskPrediction] = []
    
    @Published var combinedMaskImage: UIImage?
    @Published var modelSize: String = "n"
    @Published var modelNote: String = ""
    @Published var centerlineResult: CrackCenterlineOverlay.Result?
    @Published var centerlineStats: String = ""
    @Published var inferenceHardware = ""
    @Published var stageTimings: [String: Double] = [:]

    private static let modelCacheLock = NSLock()
    private static var cachedModelName: String?
    private static var cachedMLModel: MLModel?
    private static var cachedVisionModel: VNCoreMLModel?
    
    @MainActor @Published var status: Status? = nil
    
    init() {
        setupBindings()
    }
        
    private func setupBindings() {
        $imageSelection.sink { [weak self] item in
            guard let item else { return }
            
            Task { [weak self] in
                
                if let data = try? await item.loadTransferable(type: Data.self) {
                    if let uiImage = UIImage(data: data) {
                        await MainActor.run { [weak self] in
                            self?.predictions = []
                            self?.maskPredictions = []
                            self?.combinedMaskImage = nil
                            self?.uiImage = uiImage
                        }
                        return
                    }
                }
            }
            
        }.store(in: &cancellables)
        
        $maskPredictions.sink { [weak self] predictions in
            guard !predictions.isEmpty else { return }
            
            self?.combinedMaskImage = predictions.combineToSingleImage()
        }.store(in: &cancellables)
    }
    
    func runInference() async {
        await MainActor.run { [weak self] in
            self?.processing = true
        }
        await runVisionInference()
    }
}

// MARK: Vision Inference
extension ContentViewModel {
    private func runVisionInference() async {
        @Sendable func handleResults(
            _ results: [VNObservation],
            inputSize: MLImageConstraint,
            originalImgSize: CGSize,
            processOnlyTopScoringBox: Bool? = nil
        ) async {
            NSLog(#function)
            defer {
                Task {
                    await MainActor.run { [weak self] in
                        self?.processing = false
                    }
                    await setStatus(to: nil)
                }
            }
          
            guard let boxesOutput = results.first(where: { ($0 as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue?.shape.count == 3 }) as? VNCoreMLFeatureValueObservation,
                  let masksOutput = results.first(where: { ($0 as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue?.shape.count == 4}) as? VNCoreMLFeatureValueObservation
            else { return }
            
            guard let boxes = boxesOutput.featureValue.multiArrayValue else {
                return
            }
          
            let numSegmentationMasks = 32
            let numClasses = Int(truncating: boxes.shape[1]) - 4 - numSegmentationMasks
            
            NSLog("Model has \(numClasses) classes")
            
            await setStatus(to: .parsingBoxPredictions)
            let predictions = getPredictionsFromOutput(
                output: boxes,
                rows: Int(truncating: boxes.shape[1]),
                columns: Int(truncating: boxes.shape[2]),
                numberOfClasses: numClasses,
                inputImgSize: CGSize(width: inputSize.pixelsWide, height: inputSize.pixelsHigh),
                confidenceThreshold: confidenceThreshold
            )
            
            NSLog("Got \(predictions.count) predicted boxes")
            
            await setStatus(to: .performingNMS)
            
            guard !predictions.isEmpty else { return }
            
            NSLog("Perform non maximum suppression")
            
            let groupedPredictions = Dictionary(grouping: predictions) { prediction in
                prediction.classIndex
            }
            
            var nmsPredictions: [Prediction] = []
            let _ = groupedPredictions.mapValues { predictions in
                nmsPredictions.append(
                    contentsOf: nonMaximumSuppression(
                        predictions: predictions,
                        iouThreshold: iouThreshold,
                        limit: 100))
            }
            
            NSLog("\(nmsPredictions.count) boxes left after performing nms with iou threshold of 0.6")
            
            guard !nmsPredictions.isEmpty else {
                await MainActor.run { [weak self] in
                    self?.centerlineResult = nil
                    self?.predictions = []
                    self?.centerlineStats = "未检测到裂缝（检测框 0）"
                }
                return
            }
            
            await MainActor.run { [weak self, nmsPredictions] in
                self?.predictions = nmsPredictions
            }
            
            guard let masks = masksOutput.featureValue.multiArrayValue else {
                print("No masks output")
                return
            }
            
            let maskDecodeStart = CFAbsoluteTimeGetCurrent()
            await setStatus(to: .parsingMaskProtos)
            let maskProtos = getMaskProtosFromOutput(
                output: masks,
                rows: Int(truncating: masks.shape[2]),
                columns: Int(truncating: masks.shape[3]),
                tubes: Int(truncating: masks.shape[1])
            )

            NSLog("Got \(maskProtos.count) mask protos")

            await setStatus(to: .generateMasksFromProtos)
            let maskPredictions = masksFromProtos(
                boxPredictions: nmsPredictions,
                maskProtos: maskProtos,
                maskSize: (
                    width: Int(truncating: masks.shape[3]),
                    height: Int(truncating: masks.shape[2])
                ),
                originalImgSize: originalImgSize
            )
            let maskDecodeDuration =
                (CFAbsoluteTimeGetCurrent() - maskDecodeStart) * 1000
          
            NSLog("Set maskpredictions")
            await MainActor.run { [weak self, maskPredictions] in
                guard let self else { return }
                self.maskPredictions = maskPredictions
                self.processing = false
                if let uiImage = self.uiImage {
                    let skeletonStart = CFAbsoluteTimeGetCurrent()
                    let result = CrackCenterlineOverlay.compute(
                        masks: maskPredictions,
                        imageSize: uiImage.size
                    )
                    let skeletonDuration =
                        (CFAbsoluteTimeGetCurrent() - skeletonStart) * 1000
                    self.centerlineResult = result
                    self.centerlineStats = CrackCenterlineOverlay.statsText(
                        detectionCount: maskPredictions.count,
                        result: result
                    )
                    self.stageTimings["maskDecode"] = maskDecodeDuration
                    self.stageTimings["centerline"] = skeletonDuration
                }
            }
            await setStatus(to: nil)
        }
        
        guard let uiImage else {
            await MainActor.run { [weak self] in
                self?.processing = false
            }
            return
        }
        
        await setStatus(to: .preProcessing)
        
        NSLog("Start inference using Vision")
        
        var requests = [VNRequest]()
        var handleTask: Task<Void, Never>?
        do {
            let config = MLModelConfiguration()
            let requestSetupStart = CFAbsoluteTimeGetCurrent()
            await MainActor.run { [weak self] in
                self?.inferenceHardware = "computeUnitsPolicy = .all"
            }
            
            let requestedName = modelSize == "s" ? "crack_seg_s" : "crack_seg_n"
            var modelName = requestedName
            Self.modelCacheLock.lock()
            let cacheHit: (MLModel, VNCoreMLModel)?
            if Self.cachedModelName == modelName,
               let cachedML = Self.cachedMLModel,
               let cachedVision = Self.cachedVisionModel {
                cacheHit = (cachedML, cachedVision)
            } else {
                cacheHit = nil
            }
            Self.modelCacheLock.unlock()

            if let cacheHit {
                let cachedMLModel = cacheHit.0
                let cachedVisionModel = cacheHit.1
                let inputDesc = cachedMLModel.modelDescription.inputDescriptionsByName
                guard let imgInputDesc = inputDesc["image"],
                      let imgsz = imgInputDesc.imageConstraint else {
                    return
                }
                let segmentationRequest = VNCoreMLRequest(
                    model: cachedVisionModel,
                    completionHandler: { (request, error) in
                        if let error = error {
                            print("VNCoreMLRequest complete with error: \(error)")
                        }
                        if let results = request.results {
                            handleTask = Task {
                                await self.setStatus(to: .postProcessing)
                                await handleResults(
                                    results,
                                    inputSize: imgsz,
                                    originalImgSize: uiImage.size
                                )
                            }
                        }
                    })
                segmentationRequest.preferBackgroundProcessing = false
                segmentationRequest.imageCropAndScaleOption = .scaleFill
                requests = [segmentationRequest]
            } else {
            var modelURL = Bundle.main.url(
                forResource: modelName,
                withExtension: "mlmodelc",
                subdirectory: "Models"
            )
            if modelURL == nil, requestedName == "crack_seg_s" {
                // s 模型暂未打包：回退 n，接口保留
                modelName = "crack_seg_n"
                modelURL = Bundle.main.url(
                    forResource: modelName,
                    withExtension: "mlmodelc",
                    subdirectory: "Models"
                )
                await MainActor.run { [weak self] in
                    self?.modelNote = "crack_seg_s 未打包，已回退 crack_seg_n"
                }
            }
            guard let modelURL else {
                print("failed to find crack model: \(modelName)")
                return
            }
            guard let mlModel = try? MLModel(contentsOf: modelURL, configuration: config),
                  let visionModel = try? VNCoreMLModel(for: mlModel) else {
                print("failed to init crack model: \(modelName)")
                return
            }
            Self.modelCacheLock.lock()
            Self.cachedModelName = modelName
            Self.cachedMLModel = mlModel
            Self.cachedVisionModel = visionModel
            Self.modelCacheLock.unlock()
            
            let inputDesc = mlModel.modelDescription.inputDescriptionsByName
            guard let imgInputDesc = inputDesc["image"],
                  let imgsz = imgInputDesc.imageConstraint
            else { return }
            
            let segmentationRequest = VNCoreMLRequest(
                model: visionModel,
                completionHandler: { (request, error) in
                    if let error = error {
                        print("VNCoreMLRequest complete with error: \(error)")
                    }
                    
                    if let results = request.results {
                        handleTask = Task {
                            await self.setStatus(to: .postProcessing)
                            await handleResults(results, inputSize: imgsz, originalImgSize: uiImage.size)
                        }
                    }
                })
            segmentationRequest.preferBackgroundProcessing = false
            segmentationRequest.imageCropAndScaleOption = .scaleFill
            
            requests = [segmentationRequest]
            }
            let requestSetupDuration =
                (CFAbsoluteTimeGetCurrent() - requestSetupStart) * 1000
            await MainActor.run { [weak self] in
                self?.stageTimings["requestSetup"] = requestSetupDuration
            }
        } catch let error as NSError {
            print("Model loading went wrong: \(error)")
        }
        
        guard let cgImage = uiImage.cgImage else { return }
        
        let imageRequestHandler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: uiImage.imageOrientation.toCGImagePropertyOrientation() ?? .up
        )
        do {
            await setStatus(to: .inferencing)
            NSLog("Perform inference")
            let coreMLStart = CFAbsoluteTimeGetCurrent()
            try imageRequestHandler.perform(requests)
            let coreMLDuration =
                (CFAbsoluteTimeGetCurrent() - coreMLStart) * 1000
            await MainActor.run { [weak self] in
                self?.stageTimings["coreML"] = coreMLDuration
            }
        } catch {
            print(error)
        }
        if let handleTask {
            await handleTask.value
        }
    }
}

// MARK: Outputs to predictions
extension ContentViewModel {
    func getPredictionsFromOutput(
        output: MLMultiArray,
        rows: Int,
        columns: Int,
        numberOfClasses: Int,
        inputImgSize: CGSize,
        confidenceThreshold: Float
    ) -> [Prediction] {
        NSLog(#function)
        guard output.count != 0 else { return [] }

        let strides = output.strides.map { $0.intValue }

        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)

        @inline(__always)
        func getIndex(_ channel: Int, _ i: Int) -> Int {
            return channel * strides[1] + i * strides[2]
        }
      
        let resultsQueue = DispatchQueue(label: "resultsQueue", attributes: .concurrent)

        var predictions = [Prediction]()
        DispatchQueue.concurrentPerform(iterations: columns) { i in
            let centerX = pointer[getIndex(0, i)]
            let centerY = pointer[getIndex(1, i)]
            let width   = pointer[getIndex(2, i)]
            let height  = pointer[getIndex(3, i)]

            var classScores = [Float](repeating: 0, count: numberOfClasses)
            for j in 0..<numberOfClasses {
                let classIdx = getIndex(4 + j, i)
                classScores[j] = pointer[classIdx]
            }

            var highestScore: Float = 0
            var classIndex: vDSP_Length = 0
            vDSP_maxvi(classScores, 1, &highestScore, &classIndex, vDSP_Length(numberOfClasses))

            if highestScore >= confidenceThreshold {
                var maskCoefficients = [Float](repeating: 0, count: 32)
                for k in 0..<32 {
                    let maskIdx = getIndex(4 + numberOfClasses + k, i)
                    if maskIdx >= output.count { break }
                    maskCoefficients[k] = pointer[maskIdx]
                }
              
                // Convert box from xywh to xyxy format
                let left = centerX - width * 0.5
                let top = centerY - height * 0.5
                let right = centerX + width * 0.5
                let bottom = centerY + height * 0.5

                let prediction = Prediction(
                    classIndex: Int(classIndex),
                    score: highestScore,
                    xyxy: .init(x1: left, y1: top, x2: right, y2: bottom),
                    maskCoefficients: maskCoefficients,
                    inputImgSize: inputImgSize
                )

                resultsQueue.async(flags: .barrier) {
                    predictions.append(prediction)
                }
            }
        }
        
        resultsQueue.sync(flags: .barrier) {}
        
        return predictions
    }
  
    func getMaskProtosFromOutput(
        output: MLMultiArray,
        rows: Int,
        columns: Int,
        tubes: Int
    ) -> [[Float]] {
        NSLog(#function)
        let strides = output.strides.map { $0.intValue }
        let strideTube = strides[1]
        let strideRow = strides[2]
        let strideCol = strides[3]
        
        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
        let maskSize = rows * columns

        var masks = Array(repeating: [Float](repeating: 0, count: maskSize), count: tubes)

        masks.withUnsafeMutableBufferPointer { maskBuffer in
            DispatchQueue.concurrentPerform(iterations: tubes) { tube in
                let destPointer = maskBuffer[tube].withUnsafeMutableBufferPointer { $0.baseAddress! }

                for row in 0..<rows {
                    let rowOffset = row * columns
                    for col in 0..<columns {
                        let index = tube * strideTube + row * strideRow + col * strideCol
                        destPointer[rowOffset + col] = pointer[index]
                    }
                }
            }
        }

        return masks
    }
}

import Accelerate

extension ContentViewModel {
    func masksFromProtos(
        boxPredictions: [Prediction],
        maskProtos: [[Float]],
        maskSize: (width: Int, height: Int),
        originalImgSize: CGSize
    ) -> [MaskPrediction] {
        NSLog(#function)
        var maskPredictions: [MaskPrediction] = []
        // 0.742B：ROI 批量上采样——先收集所有实例，一次 Metal 批处理。
        var batchItems: [(
            input: [Float],
            initialSize: (width: Int, height: Int),
            targetSize: (width: Int, height: Int)
        )] = []
        var batchMeta: [(
            classIndex: Int,
            targetSize: (width: Int, height: Int),
            origin: (x: Int, y: Int)
        )] = []
        for prediction in boxPredictions {
            
            let maskCoefficients = prediction.maskCoefficients

            var finalMask = [Float](repeating: 0, count: maskSize.width * maskSize.height)
            NSLog("Perform matrix multiplication to create finalMask")
            finalMask.withUnsafeMutableBufferPointer { finalMaskBuffer in
                for (index, maskProto) in maskProtos.enumerated() {
                    var coeff = maskCoefficients[index]
                  
                    maskProto.withUnsafeBufferPointer { protoBuffer in
                        guard let protoBase = protoBuffer.baseAddress,
                              let finalBase = finalMaskBuffer.baseAddress
                        else { return }

                        vDSP_vsma(protoBase, 1, &coeff, finalBase, 1, finalBase, 1, vDSP_Length(maskSize.width * maskSize.height))
                    }
                }
            }

            NSLog("Apply sigmoid")
            let count = finalMask.count
            var negated = [Float](repeating: 0, count: count)
            var expResult = [Float](repeating: 0, count: count)
            var one = Float(1.0)

            vDSP_vneg(finalMask, 1, &negated, 1, vDSP_Length(count))
          
            vvexpf(&expResult, negated, [Int32(count)])

            vDSP_vsadd(expResult, 1, &one, &expResult, 1, vDSP_Length(count))
            vDSP_svdiv(&one, expResult, 1, &finalMask, 1, vDSP_Length(count))

            // ROI：只保留检测框区域（160 网格），返回压缩尺寸 + 原点。
            let roi = cropROI(
                mask: finalMask,
                maskSize: maskSize,
                box: .init(
                  x1: prediction.xyxy.x1 / 4,
                  y1: prediction.xyxy.y1 / 4,
                  x2: prediction.xyxy.x2 / 4,
                  y2: prediction.xyxy.y2 / 4
                ))

            // 目标尺寸：检测框在原图中的尺寸（上限 1280 长边）
            let xScale = originalImgSize.width / CGFloat(maskSize.width)
            let yScale = originalImgSize.height / CGFloat(maskSize.height)
            var targetW = Int(CGFloat(roi.roiSize.width) * xScale)
            var targetH = Int(CGFloat(roi.roiSize.height) * yScale)
            let maxSide = max(targetW, targetH)
            if maxSide > 1280 {
                let s = CGFloat(1280) / CGFloat(maxSide)
                targetW = max(1, Int(CGFloat(targetW) * s))
                targetH = max(1, Int(CGFloat(targetH) * s))
            }

            batchItems.append(
                (
                    roi.values,
                    roi.roiSize,
                    (width: targetW, height: targetH)
                )
            )
            batchMeta.append(
                (
                    prediction.classIndex,
                    (width: targetW, height: targetH),
                    roi.origin
                )
            )
        }

        let batchResults = [Float].upsampleBatch(
            items: batchItems,
            maskThreshold: maskThreshold
        )
        for (index, mask) in batchResults.enumerated() {
            guard index < batchMeta.count else { continue }
            maskPredictions.append(
                MaskPrediction(
                    classIndex: batchMeta[index].classIndex,
                    mask: mask,
                    maskSize: batchMeta[index].targetSize,
                    bboxOrigin: batchMeta[index].origin
                )
            )
        }
        return maskPredictions
    }

    /// ROI 裁剪：返回检测框区域的压缩数组（非整张补零），并给出 roi 尺寸与原点（160 网格）。
    private func cropROI(
        mask: [Float],
        maskSize: (width: Int, height: Int),
        box: XYXY
    ) -> (values: [Float], roiSize: (width: Int, height: Int), origin: (x: Int, y: Int)) {
        let columns = maskSize.width
        let rows = maskSize.height
        let x1 = max(0, Int(box.x1))
        let y1 = max(0, Int(box.y1))
        let x2 = min(columns - 1, Int(box.x2))
        let y2 = min(rows - 1, Int(box.y2))
        let roiW = max(1, x2 - x1 + 1)
        let roiH = max(1, y2 - y1 + 1)
        var cropped = [Float](repeating: 0, count: roiW * roiH)
        for row in 0..<roiH {
            let srcStart = (y1 + row) * columns + x1
            let dstStart = row * roiW
            cropped.replaceSubrange(
                dstStart..<(dstStart + roiW),
                with: mask[srcStart..<(srcStart + roiW)]
            )
        }
        return (cropped, (roiW, roiH), (x1, y1))
    }
    
    private func crop(
        mask: [Float],
        maskSize: (width: Int, height: Int),
        box: XYXY
    ) -> [Float] {
        let rows = maskSize.height
        let columns = maskSize.width
        
        let x1 = max(0, Int(box.x1))
        let y1 = max(0, Int(box.y1))
        let x2 = min(columns - 1, Int(box.x2))
        let y2 = min(rows - 1, Int(box.y2))

        var croppedArr = [Float](repeating: 0, count: rows * columns)

        croppedArr.withUnsafeMutableBufferPointer { buffer in
            mask.withUnsafeBufferPointer { sourceBuffer in
                for row in y1...y2 {
                    let srcStartIdx = row * columns + x1
                    let dstStartIdx = row * columns + x1
                    let count = x2 - x1 + 1
                    buffer.baseAddress!.advanced(by: dstStartIdx)
                      .update(from: sourceBuffer.baseAddress!.advanced(by: srcStartIdx), count: count)
                }
            }
        }

        return croppedArr
    }
  
    private func crop(
        mask: [UInt8],
        maskSize: (width: Int, height: Int),
        box: XYXY
    ) -> [UInt8] {
        let rows = maskSize.height
        let columns = maskSize.width
        
        let x1 = max(0, Int(box.x1))
        let y1 = max(0, Int(box.y1))
        let x2 = min(columns - 1, Int(box.x2))
        let y2 = min(rows - 1, Int(box.y2))

        var croppedArr = [UInt8](repeating: 0, count: rows * columns)

        croppedArr.withUnsafeMutableBufferPointer { buffer in
            mask.withUnsafeBufferPointer { sourceBuffer in
                for row in y1...y2 {
                    let srcStartIdx = row * columns + x1
                    let dstStartIdx = row * columns + x1
                    let count = x2 - x1 + 1
                    buffer.baseAddress!.advanced(by: dstStartIdx)
                      .update(from: sourceBuffer.baseAddress!.advanced(by: srcStartIdx), count: count)
                }
            }
        }

        return croppedArr
    }
}

// MARK: Non-Maximum-Suppression
extension ContentViewModel {
    func nonMaximumSuppression(
        predictions: [Prediction],
        iouThreshold: Float,
        limit: Int
    ) -> [Prediction] {
        guard !predictions.isEmpty else { return [] }

        // Sort by confidence score in descending order
        var sortedPredictions = predictions.sorted(by: { $0.score > $1.score })
        var selected: [Prediction] = []
        selected.reserveCapacity(limit)

        while !sortedPredictions.isEmpty {
            let best = sortedPredictions.removeFirst()
            selected.append(best)

            if selected.count >= limit { break }

            sortedPredictions.removeAll { IOU(a: best.xyxy, b: $0.xyxy) > iouThreshold }
        }
        
        return selected
    }
    
    private func IOU(a: XYXY, b: XYXY) -> Float {
        let x1 = max(a.x1, b.x1)
        let y1 = max(a.y1, b.y1)
        let x2 = min(a.x2, b.x2)
        let y2 = min(a.y2, b.y2)

        let intersection = max(x2 - x1, 0) * max(y2 - y1, 0)

        let area1 = (a.x2 - a.x1) * (a.y2 - a.y1)
        let area2 = (b.x2 - b.x1) * (b.y2 - b.y1)
        let union = area1 + area2 - intersection

        return intersection / union
    }
}

extension ContentViewModel {
    @MainActor
    fileprivate func setStatus(to status: Status?) {
        self.status = status
    }
}
