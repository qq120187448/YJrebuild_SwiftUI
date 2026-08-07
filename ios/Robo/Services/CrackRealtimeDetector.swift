import ARKit
import Combine
import CoreImage
import CoreGraphics
import Foundation
import UIKit
import Vision

final class CrackRealtimeDetector: ObservableObject {
    @Published var normalizedPoints: [CGPoint] = []
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
        guard now - lastRunAt >= 0.8 else { return }
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
                    self.detectionCount = mask.detectionCount
                }
            } catch {
                // 实时识别失败时静默降级，不打断扫描
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
