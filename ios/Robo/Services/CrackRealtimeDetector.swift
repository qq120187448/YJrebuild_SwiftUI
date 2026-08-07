import ARKit
import Combine
import CoreImage
import CoreGraphics
import Foundation
import UIKit
import Vision

final class CrackRealtimeDetector: ObservableObject {
    @Published var normalizedPoints: [CGPoint] = []
    @Published var normalizedBoxes: [CGRect] = []
    @Published var detectionCount = 0
    @Published var isAvailable = false
    @Published var statusMessage = ""

    private let queue = DispatchQueue(label: "crack.realtime.queue", qos: .userInteractive)
    private let ciContext = CIContext()
    private var model: VNCoreMLModel?
    private var lastRunAt: TimeInterval = 0

    func prepare(config: CrackRecognitionConfig) {
        guard model == nil else { return }
        do {
            model = try CrackRecognitionEngine.makeVisionModel(size: config.modelSize)
            isAvailable = true
            statusMessage = "实时识别已就绪"
        } catch {
            isAvailable = false
            statusMessage = "未找到 CoreML 模型"
        }
    }

    func process(frame: ARFrame, config: CrackRecognitionConfig) {
        guard model != nil else { return }
        let now = frame.timestamp
        guard now - lastRunAt >= 2.0 else { return }
        lastRunAt = now
        guard let image = snapshot(from: frame),
              let cgImage = image.cgImage else {
            return
        }
        guard let model else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let mask = try CrackRecognitionEngine.realtimeMaskPoints(
                    cgImage: cgImage,
                    model: model,
                    config: config
                )
                DispatchQueue.main.async {
                    self.normalizedPoints = mask.points
                    self.normalizedBoxes = mask.boxes
                    self.detectionCount = mask.detectionCount
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.statusMessage = "识别出错：\(message)"
                }
            }
        }
    }

    private func snapshot(from frame: ARFrame) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let oriented = ciImage.oriented(.right)
        guard let cgImage = ciContext.createCGImage(
            oriented,
            from: oriented.extent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
