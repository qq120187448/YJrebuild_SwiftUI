import ARKit
import AVFoundation
import CoreImage
import CoreVideo
import SceneKit
import simd
import SwiftUI
import UIKit

struct DefectCameraCapture {
    let image: UIImage
    let pose: [Float]
    let intrinsics: [Float]
    let depth: Data?
    let depthWidth: Int?
    let depthHeight: Int?
    let depthBytesPerRow: Int?
    let sensorIntrinsics: [Float]
    let depthNormalizedTransform: [Float]
    let fullImageSize: CGSize
    let cropRect: CGRect
    let sensorImageSize: CGSize
    let planeSurface: WallDefectSurface?
}

@MainActor
final class DefectCameraModel: ObservableObject {
    static let squareCropInset: CGFloat = 0.98
    static let squareCropCenterYRatio: CGFloat = 0.5

    private(set) var latestFrame: ARFrame?
    @Published var lastError: String?
    @Published var cameraTransform: simd_float4x4?
    @Published var hitSurfaceLabel: String?
    @Published var hitSurfaceDistanceM: Float?
    @Published var hitSurfaceCoverage: Double?
    @Published var alignedSurfaces: [WallDefectSurface] = []
    @Published var alignmentYawDeg: Double?
    @Published var alignmentResidualM: Double?
    @Published var alignmentSampleCount = 0
    @Published var realignmentRequestedCount = 0
    @Published var planeDistanceM: Float?
    @Published var planeNormalText: String?
    @Published var planeSampleCount = 0
    @Published var planeSource: String?
    @Published var planeResidualM: Float?
    @Published var currentPlaneSurface: WallDefectSurface?

    private let ciContext = CIContext()

    func update(frame: ARFrame) {
        latestFrame = frame
        cameraTransform = frame.camera.transform
    }

    func updateSurfaceDiagnostics(
        label: String?,
        distanceM: Float?,
        coverage: Double?
    ) {
        hitSurfaceLabel = label
        hitSurfaceDistanceM = distanceM
        hitSurfaceCoverage = coverage
    }

    func updateAlignmentSampleCount(_ count: Int) {
        alignmentSampleCount = count
    }

    func updateAlignedSurfaces(
        _ surfaces: [WallDefectSurface],
        transform: simd_float4x4,
        residualM: Double
    ) {
        alignedSurfaces = surfaces
        alignmentYawDeg = WallDefectAligner.yawDegrees(from: transform)
        alignmentResidualM = residualM
    }

    func update(plane: WallDefectPlane?) {
        if let plane {
            let surface = plane.makeSurface()
            let cameraPosition = SIMD3<Float>(
                cameraTransform?.columns.3.x ?? 0,
                cameraTransform?.columns.3.y ?? 0,
                cameraTransform?.columns.3.z ?? 0
            )
            let origin = WallDefectGeometry.planeOrigin(for: surface)
            let normal = WallDefectGeometry.planeNormal(for: surface)
            let length = simd_length(normal)
            let unitNormal = length > 0.0001 ? normal / length : SIMD3<Double>(0, 1, 0)
            let camera = SIMD3<Double>(
                Double(cameraPosition.x),
                Double(cameraPosition.y),
                Double(cameraPosition.z)
            )
            planeDistanceM = Float(abs(simd_dot(camera - origin, unitNormal)))
            planeNormalText = String(
                format: "(%.2f, %.2f, %.2f)",
                unitNormal.x,
                unitNormal.y,
                unitNormal.z
            )
            planeSampleCount = plane.sampleCount
            planeSource = plane.source
            planeResidualM = Float(plane.residualM)
            currentPlaneSurface = surface
        } else {
            planeDistanceM = nil
            planeNormalText = nil
            planeSampleCount = 0
            planeSource = nil
            planeResidualM = nil
            currentPlaneSurface = nil
        }
    }

    func requestRealignment() {
        realignmentRequestedCount += 1
    }

    func poseArray() -> [Float]? {
        guard let frame = latestFrame else { return nil }
        return flatten(matrix: frame.camera.transform)
    }

    func intrinsicsArray() -> [Float]? {
        guard let frame = latestFrame else { return nil }
        let buffer = frame.capturedImage
        return WallDefectProjection.portraitIntrinsics(
            intrinsics: flatten(matrix: frame.camera.intrinsics),
            rawWidth: CVPixelBufferGetWidth(buffer),
            rawHeight: CVPixelBufferGetHeight(buffer)
        )
    }

    func capturedImageSize() -> CGSize? {
        guard let frame = latestFrame else { return nil }
        let buffer = frame.capturedImage
        return CGSize(
            width: CGFloat(CVPixelBufferGetHeight(buffer)),
            height: CGFloat(CVPixelBufferGetWidth(buffer))
        )
    }

    func capture(
        viewSize: CGSize? = nil,
        outputSide: CGFloat = 1024,
        centerRatio: CGFloat = DefectCameraModel.squareCropCenterYRatio
    ) -> DefectCameraCapture? {
        guard let frame = latestFrame else {
            lastError = "尚未获取 ARKit 画面"
            return nil
        }
        guard let fullImage = portraitImage(from: frame) else {
            lastError = "无法读取相机画面"
            return nil
        }
        let buffer = frame.capturedImage
        let sensorSize = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(buffer)),
            height: CGFloat(CVPixelBufferGetHeight(buffer))
        )
        let fullImageSize = CGSize(
            width: CGFloat(fullImage.width),
            height: CGFloat(fullImage.height)
        )
        let targetViewSize = viewSize ?? CGSize(width: 390, height: 844)
        let screenRect = squareScreenRect(
            viewSize: targetViewSize,
            centerRatio: centerRatio
        )
        var cropRect = portraitCropRect(
            screenRect: screenRect,
            imageSize: fullImageSize,
            viewSize: targetViewSize
        )
        if cropRect.width <= 4 || cropRect.height <= 4 {
            let side = min(
                fullImageSize.width,
                fullImageSize.height
            ) * Self.squareCropInset
            cropRect = CGRect(
                x: (fullImageSize.width - side) / 2,
                y: (fullImageSize.height - side) / 2,
                width: side,
                height: side
            )
        }
        guard cropRect.width > 4, cropRect.height > 4,
              let croppedCG = portraitCroppedCG(
                from: frame,
                cropRect: cropRect,
                fullImageSize: fullImageSize
              ) else {
            lastError = "无法裁剪方形识别区域"
            return nil
        }
        let image = resizedSquare(cgImage: croppedCG, side: outputSide)

        let pose = flatten(matrix: frame.camera.transform)
        var intrinsics = WallDefectProjection.portraitIntrinsics(
            intrinsics: flatten(matrix: frame.camera.intrinsics),
            rawWidth: CVPixelBufferGetWidth(buffer),
            rawHeight: CVPixelBufferGetHeight(buffer)
        )
        intrinsics = sensorAdjustedIntrinsics(
            sensorIntrinsics: intrinsics,
            cropRect: cropRect,
            outputSide: image.size.width
        )

        var depth: Data?
        var depthWidth: Int?
        var depthHeight: Int?
        var depthBytesPerRow: Int?
        if let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap {
            let copied = copyDepth(pixelBuffer: depthMap)
            depth = copied.data
            depthWidth = copied.width
            depthHeight = copied.height
            depthBytesPerRow = copied.bytesPerRow
        }
        let sensorIntrinsics = flatten(matrix: frame.camera.intrinsics)
        let depthNormalizedTransform = depthDisplayTransform(
            frame: frame,
            imageSize: fullImageSize,
            viewportSize: targetViewSize
        )

        return DefectCameraCapture(
            image: image,
            pose: pose,
            intrinsics: intrinsics,
            depth: depth,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            depthBytesPerRow: depthBytesPerRow,
            sensorIntrinsics: sensorIntrinsics,
            depthNormalizedTransform: depthNormalizedTransform,
            fullImageSize: fullImageSize,
            cropRect: cropRect,
            sensorImageSize: sensorSize,
            planeSurface: currentPlaneSurface
        )
    }

    private func portraitImage(from frame: ARFrame) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
            .oriented(.right)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    private func squareScreenRect(
        viewSize: CGSize,
        centerRatio: CGFloat
    ) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let side = min(viewSize.width, viewSize.height) * Self.squareCropInset
        let centerY = max(
            side / 2 + 48,
            viewSize.height * centerRatio
        )
        return CGRect(
            x: (viewSize.width - side) / 2,
            y: centerY - side / 2,
            width: side,
            height: side
        )
    }

    private func portraitCropRect(
        screenRect: CGRect,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }
        let scale = max(
            viewSize.width / imageSize.width,
            viewSize.height / imageSize.height
        )
        let drawnWidth = imageSize.width * scale
        let drawnHeight = imageSize.height * scale
        let offsetX = (viewSize.width - drawnWidth) / 2
        let offsetY = (viewSize.height - drawnHeight) / 2
        return CGRect(
            x: (screenRect.minX - offsetX) / scale,
            y: (screenRect.minY - offsetY) / scale,
            width: screenRect.width / scale,
            height: screenRect.height / scale
        )
    }

    private func portraitCroppedCG(
        from frame: ARFrame,
        cropRect: CGRect,
        fullImageSize: CGSize
    ) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
            .oriented(.right)
        let ciRect = CGRect(
            x: cropRect.minX,
            y: fullImageSize.height - cropRect.maxY,
            width: cropRect.width,
            height: cropRect.height
        )
        let cropped = ciImage.cropped(to: ciRect)
        return ciContext.createCGImage(cropped, from: cropped.extent)
    }

    private func resizedSquare(
        cgImage: CGImage,
        side: CGFloat
    ) -> UIImage {
        let side = max(1, Int(side.rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { rendererContext in
                rendererContext.cgContext.interpolationQuality = .high
                // UIImage.draw keeps the CGImage's top-left coordinate space
                // aligned with ARKit's camera image; drawing the CGImage
                // directly would flip it inside the UIKit renderer.
                UIImage(cgImage: cgImage).draw(
                    in: CGRect(origin: .zero, size: size)
                )
            }
    }

    private func sensorAdjustedIntrinsics(
        sensorIntrinsics: [Float],
        cropRect: CGRect,
        outputSide: CGFloat
    ) -> [Float] {
        guard sensorIntrinsics.count == 9,
              cropRect.width > 0,
              cropRect.height > 0 else {
            return sensorIntrinsics
        }
        let scaleX = Float(outputSide / cropRect.width)
        let scaleY = Float(outputSide / cropRect.height)
        return [
            sensorIntrinsics[0] * scaleX, 0,
            (sensorIntrinsics[2] - Float(cropRect.minX)) * scaleX,
            0, sensorIntrinsics[4] * scaleY,
            (sensorIntrinsics[5] - Float(cropRect.minY)) * scaleY,
            0, 0, 1
        ]
    }

    private func depthDisplayTransform(
        frame: ARFrame,
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> [Float] {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return []
        }
        let scale = max(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        let offsetX = (viewportSize.width - imageSize.width * scale) / 2
        let offsetY = (viewportSize.height - imageSize.height * scale) / 2
        let toScreen = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: offsetX,
            ty: offsetY
        )
        let toViewNormalized = toScreen.concatenating(
            CGAffineTransform(
                a: 1 / viewportSize.width,
                b: 0,
                c: 0,
                d: 1 / viewportSize.height,
                tx: 0,
                ty: 0
            )
        )
        let transform = frame.displayTransform(
            for: .portrait,
            viewportSize: viewportSize
        ).inverted()
        let combined = toViewNormalized.concatenating(transform)
        return [
            Float(combined.a),
            Float(combined.b),
            Float(combined.tx),
            Float(combined.c),
            Float(combined.d),
            Float(combined.ty)
        ]
    }

    private func flatten(matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    private func flatten(matrix: simd_float3x3) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z
        ]
    }

    private func copyDepth(
        pixelBuffer: CVPixelBuffer
    ) -> (data: Data?, width: Int?, height: Int?, bytesPerRow: Int?) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (nil, nil, nil, nil)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        return (data, width, height, bytesPerRow)
    }

}

struct ARKitDefectCameraView: UIViewRepresentable {
    let model: DefectCameraModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true

        let configuration = ARWorldTrackingConfiguration()
        if let wideFormat = ARWorldTrackingConfiguration.supportedVideoFormats
            .first(where: {
                $0.captureDevicePosition == .back &&
                $0.captureDeviceType == .builtInWideAngleCamera
            }) {
            configuration.videoFormat = wideFormat
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        view.session.run(configuration)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let model: DefectCameraModel

        init(model: DefectCameraModel) {
            self.model = model
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            DispatchQueue.main.async {
                self.model.update(frame: frame)
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            DispatchQueue.main.async {
                self.model.lastError = error.localizedDescription
            }
        }
    }
}
