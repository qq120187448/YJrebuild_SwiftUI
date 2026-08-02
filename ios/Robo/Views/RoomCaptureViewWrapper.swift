import SwiftUI
import UIKit
import RoomPlan
import ARKit
import CoreImage

struct RoomCaptureViewWrapper: UIViewRepresentable {
    @Binding var stopRequested: Bool
    let onCaptureComplete: (CapturedRoom) -> Void
    let onCaptureError: (Error) -> Void
    var onComponentCaptured: (UIImage, String, String) -> Void = { _, _, _ in }

    func makeUIView(context: Context) -> RoomCaptureView {
        let captureView = RoomCaptureView(frame: .zero)
        captureView.captureSession.delegate = context.coordinator
        captureView.delegate = context.coordinator
        captureView.captureSession.run(configuration: .init())
        return captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        if stopRequested {
            uiView.captureSession.stop()
            DispatchQueue.main.async {
                stopRequested = false
            }
        }
    }

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        uiView.captureSession.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCaptureComplete: onCaptureComplete,
            onCaptureError: onCaptureError,
            onComponentCaptured: onComponentCaptured
        )
    }

    @objc(RoboScanRoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, NSCoding {
        let onCaptureComplete: (CapturedRoom) -> Void
        let onCaptureError: (Error) -> Void
        let onComponentCaptured: (UIImage, String, String) -> Void
        private var seenComponentIDs: Set<String> = []
        private var pendingPhotos: [(id: String, label: String)] = []
        private lazy var ciContext = CIContext()

        init(
            onCaptureComplete: @escaping (CapturedRoom) -> Void,
            onCaptureError: @escaping (Error) -> Void,
            onComponentCaptured: @escaping (UIImage, String, String) -> Void
        ) {
            self.onCaptureComplete = onCaptureComplete
            self.onCaptureError = onCaptureError
            self.onComponentCaptured = onComponentCaptured
            super.init()
        }

        required init?(coder: NSCoder) {
            fatalError("Not implemented")
        }

        func encode(with coder: NSCoder) {}

        func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {}

        func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
            var found: [String: String] = [:]
            for (index, door) in room.doors.enumerated() {
                found[door.identifier.uuidString] = "门\(index + 1)"
            }
            for (index, window) in room.windows.enumerated() {
                found[window.identifier.uuidString] = "窗\(index + 1)"
            }
            for (index, opening) in room.openings.enumerated() {
                found[opening.identifier.uuidString] = "洞口\(index + 1)"
            }
            for (index, object) in room.objects.enumerated() {
                found[object.identifier.uuidString] =
                    "\(QuantityTakeoffExporter.objectCategoryName(object.category))\(index + 1)"
            }

            for (id, label) in found where !seenComponentIDs.contains(id) {
                seenComponentIDs.insert(id)
                pendingPhotos.append((id, label))
            }
            guard !pendingPhotos.isEmpty else { return }
            guard let image = snapshot(from: session) else { return }
            let batch = pendingPhotos
            pendingPhotos.removeAll()

            DispatchQueue.main.async {
                for item in batch {
                    self.onComponentCaptured(image, item.label, item.id)
                }
            }
        }

        private func snapshot(from session: RoomCaptureSession) -> UIImage? {
            guard let frame = session.arSession.currentFrame else { return nil }
            let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

            let raw = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
            let size = raw.size
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            raw.draw(in: CGRect(origin: .zero, size: size))
            let normalized = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return normalized ?? raw
        }

        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
            true
        }

        func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
            if let error {
                onCaptureError(error)
                return
            }
            onCaptureComplete(processedResult)
        }
    }
}
