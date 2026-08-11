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
    let pointCloud: [DefectPointCloudPoint]
    let depth: Data?
    let depthWidth: Int?
    let depthHeight: Int?
    let depthBytesPerRow: Int?
    let sensorIntrinsics: [Float]
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
    @Published var currentViewSize: CGSize?

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
        return flatten(matrix: frame.camera.intrinsics)
    }

    func capturedImageSize() -> CGSize? {
        guard let frame = latestFrame else { return nil }
        let buffer = frame.capturedImage
        return CGSize(
            width: CGFloat(CVPixelBufferGetWidth(buffer)),
            height: CGFloat(CVPixelBufferGetHeight(buffer))
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
        let buffer = frame.capturedImage
        let sensorSize = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(buffer)),
            height: CGFloat(CVPixelBufferGetHeight(buffer))
        )
        let targetViewSize = currentViewSize
            ?? viewSize
            ?? CGSize(width: 390, height: 844)
        let screenRect = squareScreenRect(
            viewSize: targetViewSize,
            centerRatio: centerRatio
        )
        var cropRect = sensorCropRect(
            screenRect: screenRect,
            transform: frame.displayTransform(
                for: .portrait,
                viewportSize: targetViewSize
            ).inverted(),
            sensorSize: sensorSize
        )
        if cropRect.width <= 4 || cropRect.height <= 4
            || cropRect.maxX > sensorSize.width
            || cropRect.maxY > sensorSize.height {
            let side = min(
                sensorSize.width,
                sensorSize.height
            ) * Self.squareCropInset
            cropRect = CGRect(
                x: (sensorSize.width - side) / 2,
                y: (sensorSize.height - side) / 2,
                width: side,
                height: side
            )
        }
        guard cropRect.width > 4, cropRect.height > 4,
              let croppedCG = sensorCroppedCG(
                from: frame,
                cropRect: cropRect
              ) else {
            lastError = "无法裁剪方形识别区域"
            return nil
        }
        let image = resizedSquare(cgImage: croppedCG, side: outputSide)

        let pose = flatten(matrix: frame.camera.transform)
        let intrinsics = flatten(matrix: frame.camera.intrinsics)
        var pointCloud: [DefectPointCloudPoint] = []

        var depth: Data?
        var depthWidth: Int?
        var depthHeight: Int?
        var depthBytesPerRow: Int?
        if let depthMap = frame.sceneDepth?.depthMap {
            pointCloud = WallDefectProjection.makePointCloud(
                frame: frame,
                depthMap: depthMap,
                sampleStep: 1
            )
            let copied = copyDepth(pixelBuffer: depthMap)
            depth = copied.data
            depthWidth = copied.width
            depthHeight = copied.height
            depthBytesPerRow = copied.bytesPerRow
        }
        let sensorIntrinsics = flatten(matrix: frame.camera.intrinsics)

        return DefectCameraCapture(
            image: image,
            pose: pose,
            intrinsics: intrinsics,
            pointCloud: pointCloud,
            depth: depth,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            depthBytesPerRow: depthBytesPerRow,
            sensorIntrinsics: sensorIntrinsics,
            cropRect: cropRect,
            sensorImageSize: sensorSize,
            planeSurface: currentPlaneSurface
        )
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

    private func sensorCropRect(
        screenRect: CGRect,
        transform: CGAffineTransform,
        sensorSize: CGSize
    ) -> CGRect {
        guard sensorSize.width > 0, sensorSize.height > 0 else {
            return .zero
        }
        let topLeft = CGPoint(
            x: screenRect.minX,
            y: screenRect.minY
        ).applying(transform)
        let bottomRight = CGPoint(
            x: screenRect.maxX,
            y: screenRect.maxY
        ).applying(transform)
        let rect = CGRect(
            x: min(topLeft.x, bottomRight.x) * sensorSize.width,
            y: min(topLeft.y, bottomRight.y) * sensorSize.height,
            width: abs(topLeft.x - bottomRight.x) * sensorSize.width,
            height: abs(topLeft.y - bottomRight.y) * sensorSize.height
        )
        return rect.intersection(
            CGRect(origin: .zero, size: sensorSize)
        )
    }

    private func sensorCroppedCG(
        from frame: ARFrame,
        cropRect: CGRect
    ) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let sensorSize = CGSize(
            width: CGFloat(ciImage.extent.width),
            height: CGFloat(ciImage.extent.height)
        )
        let ciRect = CGRect(
            x: cropRect.minX,
            y: sensorSize.height - cropRect.maxY,
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
