import Vision
import UIKit

/// OCR text recognition service using Vision framework
class OCRService: ObservableObject {
    @Published var recognizedText: String = ""
    @Published var isProcessing = false

    func recognizeText(in image: UIImage) {
        isProcessing = true
        recognizedText = ""

        guard let cgImage = image.cgImage else {
            isProcessing = false
            return
        }

        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                DispatchQueue.main.async { self?.isProcessing = false }
                return
            }
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async {
                self?.recognizedText = text
                self?.isProcessing = false
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    func recognizeText(from fileURL: URL) {
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return }
        recognizeText(in: image)
    }
}
