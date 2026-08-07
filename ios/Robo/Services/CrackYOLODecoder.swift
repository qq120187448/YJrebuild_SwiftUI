import CoreGraphics
import CoreML
import Foundation

struct YOLOSegDetection {
    var box: CGRect
    let score: Float
    let classIndex: Int
    let maskCoefficients: [Float]
    var tileRect: CGRect
    var mask: [Float]?
    var maskWidth: Int = 0
    var maskHeight: Int = 0
}

enum CrackYOLODecoder {

    static func decode(
        prediction: MLMultiArray,
        protos: MLMultiArray,
        confidence: Float
    ) -> [YOLOSegDetection] {
        guard prediction.shape.count == 3,
              prediction.shape[1].intValue > 36,
              protos.shape.count == 4,
              protos.shape[1].intValue == 32 else {
            return []
        }

        let channelCount = prediction.shape[1].intValue
        let anchorCount = prediction.shape[2].intValue
        let classCount = channelCount - 36
        let maskStart = 4 + classCount
        let stride1 = prediction.strides[1].intValue
        let stride2 = prediction.strides[2].intValue
        let values = rawValues(prediction)

        var detections: [YOLOSegDetection] = []
        detections.reserveCapacity(32)

        for anchor in 0..<anchorCount {
            let base = anchor * stride2
            let cx = values[base]
            let cy = values[1 * stride1 + base]
            let width = values[2 * stride1 + base]
            let height = values[3 * stride1 + base]

            var bestRaw: Float = -Float.greatestFiniteMagnitude
            var bestClass = 0
            for classIndex in 0..<classCount {
                let raw = values[(4 + classIndex) * stride1 + base]
                if raw > bestRaw {
                    bestRaw = raw
                    bestClass = classIndex
                }
            }
            let score = sigmoid(bestRaw)
            guard score >= confidence,
                  width > 0, height > 0,
                  width.isFinite, height.isFinite else {
                continue
            }

            var coefficients: [Float] = []
            coefficients.reserveCapacity(32)
            for maskIndex in 0..<32 {
                coefficients.append(
                    values[(maskStart + maskIndex) * stride1 + base]
                )
            }

            detections.append(
                YOLOSegDetection(
                    box: CGRect(
                        x: CGFloat(cx - width / 2),
                        y: CGFloat(cy - height / 2),
                        width: CGFloat(width),
                        height: CGFloat(height)
                    ),
                    score: score,
                    classIndex: bestClass,
                    maskCoefficients: coefficients,
                    tileRect: .zero
                )
            )
        }
        return detections
    }

    static func nms(
        _ detections: [YOLOSegDetection],
        iouThreshold: Float
    ) -> [YOLOSegDetection] {
        let sorted = detections.sorted { $0.score > $1.score }
        var kept: [YOLOSegDetection] = []
        for detection in sorted {
            var overlaps = false
            for item in kept {
                if iou(detection.box, item.box) >= iouThreshold {
                    overlaps = true
                    break
                }
            }
            if !overlaps {
                kept.append(detection)
            }
        }
        return kept
    }

    static func decodeMask(
        for detection: inout YOLOSegDetection,
        protos: MLMultiArray
    ) {
        guard protos.shape.count == 4,
              protos.shape[1].intValue == 32 else {
            return
        }
        let height = protos.shape[2].intValue
        let width = protos.shape[3].intValue
        guard width > 0, height > 0 else { return }

        let stride1 = protos.strides[1].intValue
        let stride2 = protos.strides[2].intValue
        let stride3 = protos.strides[3].intValue
        let values = rawValues(protos)
        var mask = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in 0..<32 {
                    sum += detection.maskCoefficients[k]
                        * values[k * stride1 + y * stride2 + x * stride3]
                }
                mask[y * width + x] = sigmoid(sum)
            }
        }

        detection.mask = mask
        detection.maskWidth = width
        detection.maskHeight = height
    }

    private static func rawValues(_ array: MLMultiArray) -> UnsafeMutablePointer<Float> {
        array.dataPointer.assumingMemoryBound(to: Float.self)
    }

    private static func sigmoid(_ value: Float) -> Float {
        1 / (1 + exp(-value))
    }

    private static func iou(_ lhs: CGRect, _ rhs: CGRect) -> Float {
        let intersection = lhs.intersection(rhs)
        guard intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Float(intersectionArea / unionArea)
    }
}
