import ARKit
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
}

@MainActor
final class DefectCameraModel: ObservableObject {
    @Published var latestFrame: ARFrame?
    @Published var lastError: String?

    private let ciContext = CIContext()

    func update(frame: ARFrame) {
        latestFrame = frame
    }

    func capture() -> DefectCameraCapture? {
        guard let frame = latestFrame else {
            lastError = "尚未获取 ARKit 画面"
            return nil
        }
        guard let image = snapshot(from: frame) else {
            lastError = "无法读取相机画面"
            return nil
        }

        let pose = flatten(matrix: frame.camera.transform)
        let intrinsics = flatten(matrix: frame.camera.intrinsics)

        var depth: Data?
        var depthWidth: Int?
        var depthHeight: Int?
        if let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap {
            let copied = copyDepth(pixelBuffer: depthMap)
            depth = copied.data
            depthWidth = copied.width
            depthHeight = copied.height
        }

        return DefectCameraCapture(
            image: image,
            pose: pose,
            intrinsics: intrinsics,
            depth: depth,
            depthWidth: depthWidth,
            depthHeight: depthHeight
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
    ) -> (data: Data?, width: Int?, height: Int?) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (nil, nil, nil)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        return (data, width, height)
    }
}

struct ARKitDefectCameraView: UIViewRepresentable {
    let model: DefectCameraModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true

        let configuration = ARWorldTrackingConfiguration()
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
