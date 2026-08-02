import SwiftUI
import UIKit
import RoomPlan
import ARKit
import CoreImage
import CoreVideo
import simd

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
        private var pendingComponents: [String: PendingComponent] = [:]
        private lazy var ciContext = CIContext()

        private struct PendingComponent {
            let label: String
            var candidates: [(image: UIImage, score: Double)] = []
            var lastCaptureTime: TimeInterval?
        }

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

        func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
            flushPendingPhotos()
        }

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
                pendingComponents[id] = PendingComponent(label: label)
            }
            guard !pendingComponents.isEmpty, let frame = session.arSession.currentFrame else { return }

            var captureScores: [String: Double] = [:]
            var removals: [String] = []
            for id in Array(pendingComponents.keys) {
                guard let pending = pendingComponents[id] else { continue }
                guard let geometry = componentGeometry(in: room, id: id) else {
                    if !pending.candidates.isEmpty {
                        deliverBest(id: id, pending: pending)
                    }
                    removals.append(id)
                    continue
                }
                if pending.candidates.count >= 5 {
                    deliverBest(id: id, pending: pending)
                    removals.append(id)
                    continue
                }
                if let score = projectionScore(geometry: geometry, frame: frame) {
                    captureScores[id] = score
                }
            }
            for id in removals {
                pendingComponents.removeValue(forKey: id)
            }
            guard !captureScores.isEmpty, let image = snapshot(from: frame) else { return }

            for (id, score) in captureScores {
                guard var pending = pendingComponents[id] else { continue }
                let shouldCapture = pending.lastCaptureTime == nil
                    || frame.timestamp - (pending.lastCaptureTime ?? 0) >= 0.25
                if shouldCapture {
                    pending.candidates.append((image, score))
                    pending.lastCaptureTime = frame.timestamp
                    pendingComponents[id] = pending
                }
            }
        }

        private func deliverBest(id: String, pending: PendingComponent) {
            guard let best = pending.candidates.max(by: { $0.score < $1.score }) else { return }
            DispatchQueue.main.async {
                self.onComponentCaptured(best.image, pending.label, id)
            }
        }

        private func flushPendingPhotos() {
            for (id, pending) in pendingComponents {
                if !pending.candidates.isEmpty {
                    deliverBest(id: id, pending: pending)
                }
            }
            pendingComponents.removeAll()
        }

        private func componentGeometry(in room: CapturedRoom, id: String) -> (simd_float4x4, simd_float3)? {
            if let door = room.doors.first(where: { $0.identifier.uuidString == id }) {
                return (door.transform, door.dimensions)
            }
            if let window = room.windows.first(where: { $0.identifier.uuidString == id }) {
                return (window.transform, window.dimensions)
            }
            if let opening = room.openings.first(where: { $0.identifier.uuidString == id }) {
                return (opening.transform, opening.dimensions)
            }
            if let object = room.objects.first(where: { $0.identifier.uuidString == id }) {
                return (object.transform, object.dimensions)
            }
            return nil
        }

        private func projectionScore(geometry: (simd_float4x4, simd_float3), frame: ARFrame) -> Double? {
            let buffer = frame.capturedImage
            let viewport = CGSize(
                width: CGFloat(CVPixelBufferGetHeight(buffer)),
                height: CGFloat(CVPixelBufferGetWidth(buffer))
            )
            let half = SIMD3<Float>(geometry.1.x / 2, geometry.1.y / 2, geometry.1.z / 2)
            let localCorners: [SIMD3<Float>] = [
                SIMD3(-half.x, -half.y, -half.z),
                SIMD3(half.x, -half.y, -half.z),
                SIMD3(-half.x, half.y, -half.z),
                SIMD3(half.x, half.y, -half.z),
                SIMD3(-half.x, -half.y, half.z),
                SIMD3(half.x, -half.y, half.z),
                SIMD3(-half.x, half.y, half.z),
                SIMD3(half.x, half.y, half.z)
            ]
            let margin: CGFloat = 20
            var points: [CGPoint] = []
            for corner in localCorners {
                let world = geometry.0 * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
                let projected = frame.camera.projectPoint(
                    SIMD3<Float>(world.x, world.y, world.z),
                    orientation: .portrait,
                    viewportSize: viewport
                )
                guard projected.x >= margin,
                      projected.y >= margin,
                      projected.x <= viewport.width - margin,
                      projected.y <= viewport.height - margin else {
                    return nil
                }
                points.append(projected)
            }
            let xs = points.map { $0.x }
            let ys = points.map { $0.y }
            let width = max(0, (xs.max() ?? 0) - (xs.min() ?? 0))
            let height = max(0, (ys.max() ?? 0) - (ys.min() ?? 0))
            return Double(width * height)
        }

        private func snapshot(from frame: ARFrame) -> UIImage? {
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
            flushPendingPhotos()
            if let error {
                onCaptureError(error)
                return
            }
            onCaptureComplete(processedResult)
        }
    }
}
