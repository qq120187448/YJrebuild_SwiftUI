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
    var onStatusUpdate: (Int, Int) -> Void = { _, _ in }

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
            onComponentCaptured: onComponentCaptured,
            onStatusUpdate: onStatusUpdate
        )
    }

    @objc(RoboScanRoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, NSCoding {
        let onCaptureComplete: (CapturedRoom) -> Void
        let onCaptureError: (Error) -> Void
        let onComponentCaptured: (UIImage, String, String) -> Void
        let onStatusUpdate: (Int, Int) -> Void
        private var seenComponentIDs: Set<String> = []
        private var deliveredComponentIDs: Set<String> = []
        private var pendingComponents: [String: PendingComponent] = [:]
        private var bestFrameSnapshot: UIImage?
        private lazy var ciContext = CIContext()

        private let maxCandidates = 5
        private let goodScoreThreshold = 0.09

        private struct PendingComponent {
            let label: String
            var candidates: [(image: UIImage, score: Double)] = []
            var lastCaptureTime: TimeInterval?
        }

        init(
            onCaptureComplete: @escaping (CapturedRoom) -> Void,
            onCaptureError: @escaping (Error) -> Void,
            onComponentCaptured: @escaping (UIImage, String, String) -> Void,
            onStatusUpdate: @escaping (Int, Int) -> Void
        ) {
            self.onCaptureComplete = onCaptureComplete
            self.onCaptureError = onCaptureError
            self.onComponentCaptured = onComponentCaptured
            self.onStatusUpdate = onStatusUpdate
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

            for (id, label) in found
            where !seenComponentIDs.contains(id) && !deliveredComponentIDs.contains(id) {
                seenComponentIDs.insert(id)
                if !hasZeroDimensions(in: room, id: id) {
                    pendingComponents[id] = PendingComponent(label: label)
                }
            }
            guard !pendingComponents.isEmpty, let frame = session.arSession.currentFrame else { return }
            guard let snapshot = snapshot(from: frame) else { return }
            bestFrameSnapshot = snapshot

            for id in Array(pendingComponents.keys) {
                guard let pending = pendingComponents[id] else { continue }
                guard pending.candidates.count < maxCandidates else {
                    deliverBest(id: id, pending: pending)
                    pendingComponents.removeValue(forKey: id)
                    continue
                }
                guard let geometry = componentGeometry(in: room, id: id) else {
                    deliverFallback(id: id, pending: pending, snapshot: snapshot)
                    deliveredComponentIDs.insert(id)
                    pendingComponents.removeValue(forKey: id)
                    continue
                }
                guard let score = projectionScore(geometry: geometry, frame: frame) else { continue }
                if let lastTime = pending.lastCaptureTime,
                   frame.timestamp - lastTime < 0.3 {
                    continue
                }
                var updated = pending
                updated.candidates.append((snapshot, score))
                updated.lastCaptureTime = frame.timestamp
                pendingComponents[id] = updated
                if updated.candidates.count >= maxCandidates || score >= goodScoreThreshold {
                    deliverBest(id: id, pending: updated)
                    deliveredComponentIDs.insert(id)
                    pendingComponents.removeValue(forKey: id)
                }
            }
            DispatchQueue.main.async {
                self.onStatusUpdate(self.deliveredComponentIDs.count, self.seenComponentIDs.count)
            }
        }

        private func deliverBest(id: String, pending: PendingComponent) {
            guard let best = pending.candidates.max(by: { $0.score < $1.score }) else { return }
            deliver(image: best.image, label: pending.label, id: id)
            deliveredComponentIDs.insert(id)
        }

        private func deliverFallback(id: String, pending: PendingComponent, snapshot: UIImage?) {
            if let best = pending.candidates.max(by: { $0.score < $1.score }) {
                deliver(image: best.image, label: pending.label, id: id)
            } else if let snapshot {
                deliver(image: snapshot, label: pending.label, id: id)
            }
            deliveredComponentIDs.insert(id)
        }

        private func deliver(image: UIImage, label: String, id: String) {
            let resized = ImageResizer.resized(image, maxDimension: 1024)
            DispatchQueue.main.async {
                self.onComponentCaptured(resized, label, id)
            }
        }

        private func flushPendingPhotos() {
            for (id, pending) in pendingComponents {
                deliverFallback(id: id, pending: pending, snapshot: bestFrameSnapshot)
            }
            pendingComponents.removeAll()
        }

        private func hasZeroDimensions(in room: CapturedRoom, id: String) -> Bool {
            if let door = room.doors.first(where: { $0.identifier.uuidString == id }) {
                return door.dimensions.x <= 0.001 && door.dimensions.y <= 0.001 && door.dimensions.z <= 0.001
            }
            if let window = room.windows.first(where: { $0.identifier.uuidString == id }) {
                return window.dimensions.x <= 0.001 && window.dimensions.y <= 0.001 && window.dimensions.z <= 0.001
            }
            if let opening = room.openings.first(where: { $0.identifier.uuidString == id }) {
                return opening.dimensions.x <= 0.001 && opening.dimensions.y <= 0.001 && opening.dimensions.z <= 0.001
            }
            if let object = room.objects.first(where: { $0.identifier.uuidString == id }) {
                return object.dimensions.x <= 0.001 && object.dimensions.y <= 0.001 && object.dimensions.z <= 0.001
            }
            return false
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
            guard viewport.width > 0, viewport.height > 0 else { return nil }
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
            var points: [CGPoint] = []
            var insideCount = 0
            for corner in localCorners {
                let world = geometry.0 * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
                let projected = frame.camera.projectPoint(
                    SIMD3<Float>(world.x, world.y, world.z),
                    orientation: .portrait,
                    viewportSize: viewport
                )
                points.append(projected)
                if projected.x >= 0, projected.y >= 0,
                   projected.x <= viewport.width, projected.y <= viewport.height {
                    insideCount += 1
                }
            }
            let center = frame.camera.projectPoint(
                SIMD3<Float>(geometry.0.columns.3.x, geometry.0.columns.3.y, geometry.0.columns.3.z),
                orientation: .portrait,
                viewportSize: viewport
            )
            guard center.x >= 0, center.y >= 0,
                  center.x <= viewport.width, center.y <= viewport.height else {
                return nil
            }
            guard insideCount >= 2 else { return nil }
            let xs = points.map { $0.x }
            let ys = points.map { $0.y }
            let width = max(0, (xs.max() ?? 0) - (xs.min() ?? 0))
            let height = max(0, (ys.max() ?? 0) - (ys.min() ?? 0))
            let visibleFraction = Double(insideCount) / Double(localCorners.count)
            return visibleFraction * Double(width * height) / Double(viewport.width * viewport.height)
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
            ensureFinalRoomPhotos(processedResult)
            onCaptureComplete(processedResult)
        }

        private func ensureFinalRoomPhotos(_ room: CapturedRoom) {
            var components: [(id: UUID, label: String)] = []
            for (index, door) in room.doors.enumerated() {
                components.append((door.identifier, "门\(index + 1)"))
            }
            for (index, window) in room.windows.enumerated() {
                components.append((window.identifier, "窗\(index + 1)"))
            }
            for (index, opening) in room.openings.enumerated() {
                components.append((opening.identifier, "洞口\(index + 1)"))
            }
            for (index, object) in room.objects.enumerated() {
                components.append((
                    object.identifier,
                    "\(QuantityTakeoffExporter.objectCategoryName(object.category))\(index + 1)"
                ))
            }
            for component in components {
                let idString = component.id.uuidString
                guard !deliveredComponentIDs.contains(idString) else { continue }
                if let snapshot = bestFrameSnapshot {
                    deliver(image: snapshot, label: component.label, id: idString)
                    deliveredComponentIDs.insert(idString)
                }
            }
            DispatchQueue.main.async {
                self.onStatusUpdate(self.deliveredComponentIDs.count, components.count)
            }
        }
    }
}
