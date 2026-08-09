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
    var onPendingUpdate: ([String]) -> Void = { _ in }
    var onLiveRoomUpdate: ((CapturedRoom) -> Void) = { _ in }
    var initialWorldMap: ARWorldMap? = nil
    var onARSessionReady: ((ARSession) -> Void)? = { _ in }
    var keepARSessionAlive = false

    func makeUIView(context: Context) -> RoomCaptureView {
        let arSession = ARSession()
        let captureView = RoomCaptureView(frame: .zero, arSession: arSession)
        captureView.captureSession.delegate = context.coordinator
        captureView.delegate = context.coordinator
        captureView.captureSession.run(configuration: .init())

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak arSession] in
            guard let arSession else { return }
            onARSessionReady?(arSession)
        }
        return captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        if stopRequested {
            if keepARSessionAlive, #available(iOS 17.0, *) {
                uiView.captureSession.stop(pauseARSession: false)
            } else {
                uiView.captureSession.stop()
            }
            DispatchQueue.main.async {
                stopRequested = false
            }
        }
    }

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        if coordinator.keepARSessionAlive, #available(iOS 17.0, *) {
            uiView.captureSession.stop(pauseARSession: false)
        } else {
            uiView.captureSession.stop()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCaptureComplete: onCaptureComplete,
            onCaptureError: onCaptureError,
            onComponentCaptured: onComponentCaptured,
            onStatusUpdate: onStatusUpdate,
            onPendingUpdate: onPendingUpdate,
            onLiveRoomUpdate: onLiveRoomUpdate,
            keepARSessionAlive: keepARSessionAlive
        )
    }

    @objc(RoboScanRoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, NSCoding {
        let onCaptureComplete: (CapturedRoom) -> Void
        let onCaptureError: (Error) -> Void
        let onComponentCaptured: (UIImage, String, String) -> Void
        let onStatusUpdate: (Int, Int) -> Void
        let onPendingUpdate: ([String]) -> Void
        let onLiveRoomUpdate: (CapturedRoom) -> Void
        let keepARSessionAlive: Bool
        private var seenComponentIDs: Set<String> = []
        private var deliveredComponentIDs: Set<String> = []
        private var pendingComponents: [String: PendingComponent] = [:]
        private var liveComponents: [String: LiveComponentInfo] = [:]
        private var capturedPhotosByLiveID: [String: CapturedPhoto] = [:]
        private var pendingOrder: [String] = []
        private lazy var ciContext = CIContext()

        private let maxCandidates = 5
        private let goodScoreThreshold = 0.09
        private let matchDistanceThreshold: Float = 0.6

        private enum ComponentKind: Hashable {
            case door
            case window
            case opening
            case object(String)
        }

        private struct Candidate {
            let image: UIImage
            let score: Double
            let center: SIMD3<Float>
            let dimensions: SIMD3<Float>
        }

        private struct PendingComponent {
            let label: String
            let kind: ComponentKind
            var candidates: [Candidate] = []
            var lastCaptureTime: TimeInterval?
        }

        private struct LiveComponentInfo {
            let kind: ComponentKind
            let center: SIMD3<Float>
            let dimensions: SIMD3<Float>
        }

        private struct CapturedPhoto {
            let image: UIImage
            let label: String
            let kind: ComponentKind
            let center: SIMD3<Float>
            let dimensions: SIMD3<Float>
        }

        init(
            onCaptureComplete: @escaping (CapturedRoom) -> Void,
            onCaptureError: @escaping (Error) -> Void,
            onComponentCaptured: @escaping (UIImage, String, String) -> Void,
            onStatusUpdate: @escaping (Int, Int) -> Void,
            onPendingUpdate: @escaping ([String]) -> Void = { _ in },
            onLiveRoomUpdate: @escaping (CapturedRoom) -> Void = { _ in },
            keepARSessionAlive: Bool = false
        ) {
            self.onCaptureComplete = onCaptureComplete
            self.onCaptureError = onCaptureError
            self.onComponentCaptured = onComponentCaptured
            self.onStatusUpdate = onStatusUpdate
            self.onPendingUpdate = onPendingUpdate
            self.onLiveRoomUpdate = onLiveRoomUpdate
            self.keepARSessionAlive = keepARSessionAlive
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
            DispatchQueue.main.async {
                self.onLiveRoomUpdate(room)
            }
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
                if !hasZeroDimensions(in: room, id: id),
                   let kind = componentInfo(in: room, id: id)?.kind {
                    pendingComponents[id] = PendingComponent(label: label, kind: kind)
                    pendingOrder.append(id)
                }
            }
            for (id, _) in found {
                if let info = componentInfo(in: room, id: id) {
                    liveComponents[id] = info
                }
            }
            guard !pendingComponents.isEmpty, let frame = session.arSession.currentFrame else { return }
            guard let snapshot = snapshot(from: frame) else { return }

            for id in Array(pendingComponents.keys) {
                guard let pending = pendingComponents[id] else { continue }
                guard pending.candidates.count < maxCandidates else {
                    deliverBest(id: id, pending: pending)
                    pendingComponents.removeValue(forKey: id)
                    continue
                }
                guard let geometry = componentGeometry(in: room, id: id) else {
                    deliverFallback(id: id, pending: pending)
                    deliveredComponentIDs.insert(id)
                    pendingComponents.removeValue(forKey: id)
                    continue
                }
                guard let projection = projectionInfo(geometry: geometry, frame: frame) else { continue }
                if let lastTime = pending.lastCaptureTime,
                   frame.timestamp - lastTime < 0.3 {
                    continue
                }
                var updated = pending
                let cropped = croppedImage(
                    from: snapshot,
                    rect: projection.rect,
                    viewport: projection.viewport
                )
                updated.candidates.append(Candidate(
                    image: cropped,
                    score: projection.score,
                    center: center(of: geometry.0),
                    dimensions: geometry.1
                ))
                updated.lastCaptureTime = frame.timestamp
                pendingComponents[id] = updated
                if updated.candidates.count >= maxCandidates || projection.score >= goodScoreThreshold {
                    deliverBest(id: id, pending: updated)
                    deliveredComponentIDs.insert(id)
                    pendingComponents.removeValue(forKey: id)
                }
            }
            DispatchQueue.main.async {
                self.onStatusUpdate(self.deliveredComponentIDs.count, self.seenComponentIDs.count)
                self.onPendingUpdate(self.pendingLabels)
            }
        }

        private var pendingLabels: [String] {
            pendingOrder.compactMap { pendingComponents[$0]?.label }
        }

        private func deliverBest(id: String, pending: PendingComponent) {
            guard let best = pending.candidates.max(by: { $0.score < $1.score }) else { return }
            let kind = liveComponents[id]?.kind ?? pending.kind
            let resized = ImageResizer.resized(best.image, maxDimension: 1024)
            capturedPhotosByLiveID[id] = CapturedPhoto(
                image: resized,
                label: pending.label,
                kind: kind,
                center: best.center,
                dimensions: best.dimensions
            )
            deliveredComponentIDs.insert(id)
        }

        private func deliverFallback(id: String, pending: PendingComponent) {
            if let best = pending.candidates.max(by: { $0.score < $1.score }) {
                let kind = liveComponents[id]?.kind ?? pending.kind
                let resized = ImageResizer.resized(best.image, maxDimension: 1024)
                capturedPhotosByLiveID[id] = CapturedPhoto(
                    image: resized,
                    label: pending.label,
                    kind: kind,
                    center: best.center,
                    dimensions: best.dimensions
                )
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
                deliverFallback(id: id, pending: pending)
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

        private struct ProjectionInfo {
            let score: Double
            let rect: CGRect
            let viewport: CGSize
        }

        private func projectionInfo(
            geometry: (simd_float4x4, simd_float3),
            frame: ARFrame
        ) -> ProjectionInfo? {
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
            guard width > 0, height > 0 else { return nil }
            let rect = CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: width,
                height: height
            )
            let visibleFraction = Double(insideCount) / Double(localCorners.count)
            let score = visibleFraction * Double(width * height) / Double(viewport.width * viewport.height)
            return ProjectionInfo(score: score, rect: rect, viewport: viewport)
        }

        private func croppedImage(
            from image: UIImage,
            rect: CGRect,
            viewport: CGSize
        ) -> UIImage {
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0,
                  rect.width > 4, rect.height > 4,
                  viewport.width > 0, viewport.height > 0 else {
                return image
            }
            let scaleX = imageSize.width / viewport.width
            let scaleY = imageSize.height / viewport.height
            var crop = CGRect(
                x: rect.minX * scaleX,
                y: rect.minY * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )
            let padX = crop.width * 0.12
            let padY = crop.height * 0.12
            crop = crop
                .insetBy(dx: -padX, dy: -padY)
                .intersection(CGRect(origin: .zero, size: imageSize))
            guard crop.width >= 4, crop.height >= 4,
                  let cgImage = image.cgImage,
                  let croppedCG = cgImage.cropping(to: crop) else {
                return image
            }
            return UIImage(
                cgImage: croppedCG,
                scale: image.scale,
                orientation: image.imageOrientation
            )
        }

        private func snapshot(from frame: ARFrame) -> UIImage? {
            let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
            let oriented = ciImage.oriented(.right)
            guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
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
            deliverMatchedFinalPhotos(processedResult)
            onCaptureComplete(processedResult)
        }

        private func deliverMatchedFinalPhotos(_ room: CapturedRoom) {
            var finalComponents: [(id: UUID, label: String, kind: ComponentKind, center: SIMD3<Float>)] = []
            for (index, door) in room.doors.enumerated() {
                finalComponents.append((
                    door.identifier,
                    "门\(index + 1)",
                    .door,
                    center(of: door.transform)
                ))
            }
            for (index, window) in room.windows.enumerated() {
                finalComponents.append((
                    window.identifier,
                    "窗\(index + 1)",
                    .window,
                    center(of: window.transform)
                ))
            }
            for (index, opening) in room.openings.enumerated() {
                finalComponents.append((
                    opening.identifier,
                    "洞口\(index + 1)",
                    .opening,
                    center(of: opening.transform)
                ))
            }
            for (index, object) in room.objects.enumerated() {
                let label = "\(QuantityTakeoffExporter.objectCategoryName(object.category))\(index + 1)"
                finalComponents.append((
                    object.identifier,
                    label,
                    .object(QuantityTakeoffExporter.objectCategoryName(object.category)),
                    center(of: object.transform)
                ))
            }

            var usedFinalIndexes = Set<Int>()
            var usedLiveIDs = Set<String>()
            var assignment: [Int: String] = [:]

            var pairs: [(distance: Float, finalIndex: Int, liveID: String)] = []
            for (finalIndex, component) in finalComponents.enumerated() {
                for (liveID, photo) in capturedPhotosByLiveID where photo.kind == component.kind {
                    pairs.append((
                        simd_distance(photo.center, component.center),
                        finalIndex,
                        liveID
                    ))
                }
            }
            pairs.sort { $0.distance < $1.distance }
            for pair in pairs
            where !usedFinalIndexes.contains(pair.finalIndex) && !usedLiveIDs.contains(pair.liveID) {
                guard pair.distance <= matchDistanceThreshold else { continue }
                assignment[pair.finalIndex] = pair.liveID
                usedFinalIndexes.insert(pair.finalIndex)
                usedLiveIDs.insert(pair.liveID)
            }

            for (finalIndex, component) in finalComponents.enumerated()
            where !usedFinalIndexes.contains(finalIndex) {
                for (liveID, photo) in capturedPhotosByLiveID
                where !usedLiveIDs.contains(liveID)
                    && photo.kind == component.kind
                    && photo.label == component.label {
                    assignment[finalIndex] = liveID
                    usedFinalIndexes.insert(finalIndex)
                    usedLiveIDs.insert(liveID)
                    break
                }
            }

            var matchedCount = 0
            for (index, component) in finalComponents.enumerated() {
                let idString = component.id.uuidString
                guard let liveID = assignment[index],
                      let photo = capturedPhotosByLiveID[liveID] else {
                    continue
                }
                deliver(image: photo.image, label: component.label, id: idString)
                deliveredComponentIDs.insert(idString)
                matchedCount += 1
            }
            DispatchQueue.main.async {
                self.onStatusUpdate(matchedCount, finalComponents.count)
                self.onPendingUpdate([])
            }
        }

        private func componentInfo(
            in room: CapturedRoom,
            id: String
        ) -> LiveComponentInfo? {
            if let door = room.doors.first(where: { $0.identifier.uuidString == id }) {
                return LiveComponentInfo(
                    kind: .door,
                    center: center(of: door.transform),
                    dimensions: door.dimensions
                )
            }
            if let window = room.windows.first(where: { $0.identifier.uuidString == id }) {
                return LiveComponentInfo(
                    kind: .window,
                    center: center(of: window.transform),
                    dimensions: window.dimensions
                )
            }
            if let opening = room.openings.first(where: { $0.identifier.uuidString == id }) {
                return LiveComponentInfo(
                    kind: .opening,
                    center: center(of: opening.transform),
                    dimensions: opening.dimensions
                )
            }
            if let object = room.objects.first(where: { $0.identifier.uuidString == id }) {
                return LiveComponentInfo(
                    kind: .object(QuantityTakeoffExporter.objectCategoryName(object.category)),
                    center: center(of: object.transform),
                    dimensions: object.dimensions
                )
            }
            return nil
        }

        private func center(of transform: simd_float4x4) -> SIMD3<Float> {
            SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
        }
    }
}
