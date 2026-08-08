import ARKit
import RoomPlan
import SceneKit
import simd
import SwiftUI
import UIKit

struct WallDefectPhotoRecognitionResult {
    let result: CrackRecognitionResult
    let annotatedImage: UIImage?
    let arSkeleton: [CrackSkeleton3DPoint]
    let timings: [String: Double]
}

struct WallDefectModelView: View {
    let room: CapturedRoom
    let surfaces: [WallDefectSurface]
    let arSession: ARSession
    let latestRecognition: WallDefectPhotoRecognitionResult?
    let isRecognizing: Bool
    let progressMessage: String
    let onPhoto: ([WallDefectSurfaceAssociation], DefectCameraCapture) -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    @StateObject private var cameraModel = DefectCameraModel()
    @State private var cameraSurfaceID: UUID?
    @State private var photoCount = 0
    @State private var showSaveConfirm = false
    @State private var cameraViewSize = CGSize.zero

    private var cameraSurface: WallDefectSurface? {
        surfaces.first { $0.id == cameraSurfaceID }
    }

    private var captureCenterRatio: CGFloat {
        guard cameraViewSize.width > 0, cameraViewSize.height > 0 else {
            return DefectCameraModel.squareCropCenterYRatio
        }
        let side = min(
            cameraViewSize.width,
            cameraViewSize.height
        ) * DefectCameraModel.squareCropInset
        let centerY = max(
            side / 2 + 72,
            cameraViewSize.height
                * DefectCameraModel.squareCropCenterYRatio
        )
        return min(max(centerY / cameraViewSize.height, 0), 1)
    }

    var body: some View {
        ZStack {
            WallDefectARView(
                surfaces: surfaces,
                arSession: arSession,
                cameraModel: cameraModel,
                latestARSkeleton: latestRecognition?.arSkeleton ?? [],
                cameraSurfaceID: $cameraSurfaceID
            )
            .ignoresSafeArea()

            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                    * DefectCameraModel.squareCropInset
                let centerY = max(
                    side / 2 + 72,
                    geometry.size.height
                        * DefectCameraModel.squareCropCenterYRatio
                )
                ZStack {
                    Color.clear
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(.yellow, lineWidth: 2)
                        .frame(width: side, height: side)
                    Text("将目标放入方框")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .offset(y: -side / 2 - 18)
                }
                .position(x: geometry.size.width / 2, y: centerY)
                .onAppear {
                    cameraViewSize = geometry.size
                }
                .onChange(of: geometry.size) { _, newValue in
                    cameraViewSize = newValue
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    RoomMiniMapView(
                        room: room,
                        surfaces: surfaces
                    )
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)

                    recognitionSummaryPanel
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 8)
                bottomBar
            }
        }
        .alert("保存扫描包？", isPresented: $showSaveConfirm) {
            Button("保存") {
                onSave()
            }
            Button("不保存退出", role: .destructive) {
                onDiscard()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("照片会与墙体 UV 坐标一起归档，后续用于缺陷工程量计算。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(
                systemName: cameraSurface == nil
                    ? "camera.viewfinder"
                    : "checkmark.circle.fill"
            )
            .font(.title3)
            .foregroundStyle(cameraSurface == nil ? .white : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(cameraSurface?.label ?? "对准墙面或地面")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                if let cameraSurface {
                    Text(cameraSurface.uvDescription)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    Text("自动根据相机方向判断贴图位置")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            Spacer()

            Text("已拍 \(photoCount) 张")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let cameraSurface {
                Text("当前目标：\(cameraSurface.label)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            } else if isRecognizing {
                Text("正在识别照片，暂时不能拍照")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Text("未识别到墙面/地面/天面，请对准已建模表面")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.75))
            }
            if let error = cameraModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ZStack {
                HStack {
                    Button {
                        showSaveConfirm = true
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.teal)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }

                Button {
                    let config = CrackRecognitionSettings.load()
                    guard let capture = cameraModel.capture(
                        viewSize: cameraViewSize == .zero
                            ? nil
                            : cameraViewSize,
                        outputSide: CGFloat(config.captureResolution),
                        centerRatio: captureCenterRatio
                    ) else { return }
                    let associations = WallDefectProjection.associations(
                        pose: capture.pose,
                        intrinsics: capture.intrinsics,
                        imageSize: capture.image.size,
                        surfaces: surfaces
                    )
                    guard !associations.isEmpty else {
                        cameraModel.lastError = "未识别到目标表面，请对准墙面/地面/天面"
                        return
                    }
                    photoCount += 1
                    onPhoto(associations, capture)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(.white)
                            .frame(width: 56, height: 56)
                    }
                }
                .disabled(isRecognizing)
                .opacity(isRecognizing ? 0.45 : 1)
            }
        }
        .padding(14)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var recognitionSummaryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("识别简报")
                .font(.caption.bold())
                .foregroundStyle(.white)

            if isRecognizing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("识别中")
                }
                if !progressMessage.isEmpty {
                    Text(progressMessage)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            } else if let latestRecognition {
                let result = latestRecognition.result
                let longest = result.components
                    .map { $0.lengthM ?? 0 }
                    .max() ?? 0
                LabeledContent("裂缝", value: "\(result.components.count) 条")
                LabeledContent(
                    "总长",
                    value: String(format: "%.3f m", result.totalLengthM)
                )
                LabeledContent(
                    "最长",
                    value: String(format: "%.3f m", longest)
                )
                if result.totalAreaM2 > 0 {
                    LabeledContent(
                        "面积",
                        value: String(format: "%.4f m²", result.totalAreaM2)
                    )
                }
                if let total = latestRecognition.timings["总计"] {
                    LabeledContent(
                        "耗时",
                        value: String(format: "%.2fs", total)
                    )
                }
            } else {
                Text("尚未识别")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct WallDefectARView: UIViewRepresentable {
    let surfaces: [WallDefectSurface]
    let arSession: ARSession
    let cameraModel: DefectCameraModel
    let latestARSkeleton: [CrackSkeleton3DPoint]
    @Binding var cameraSurfaceID: UUID?

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = arSession
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        arSession.run(configuration, options: [])

        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.updateARSkeleton(
            latestARSkeleton,
            in: uiView
        )
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            surfaces: surfaces,
            cameraModel: cameraModel,
            cameraSurfaceID: $cameraSurfaceID
        )
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let surfaces: [WallDefectSurface]
        let cameraModel: DefectCameraModel
        var cameraSurfaceID: Binding<UUID?>
        private let skeletonNodeName = "CrackARSkeleton"
        private var lastSkeletonHash = Int.min

        init(
            surfaces: [WallDefectSurface],
            cameraModel: DefectCameraModel,
            cameraSurfaceID: Binding<UUID?>
        ) {
            self.surfaces = surfaces
            self.cameraModel = cameraModel
            self.cameraSurfaceID = cameraSurfaceID
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let pose = flatten(matrix: frame.camera.transform)
            let buffer = frame.capturedImage
            let intrinsics = WallDefectProjection.portraitIntrinsics(
                intrinsics: flatten(matrix: frame.camera.intrinsics),
                rawWidth: CVPixelBufferGetWidth(buffer),
                rawHeight: CVPixelBufferGetHeight(buffer)
            )
            let imageSize = CGSize(
                width: CGFloat(CVPixelBufferGetHeight(buffer)),
                height: CGFloat(CVPixelBufferGetWidth(buffer))
            )
            DispatchQueue.main.async {
                self.cameraModel.update(frame: frame)
                self.updateCameraSurface(
                    pose: pose,
                    intrinsics: intrinsics,
                    imageSize: imageSize
                )
            }
        }

        private func updateCameraSurface(
            pose: [Float],
            intrinsics: [Float],
            imageSize: CGSize
        ) {
            let associations = WallDefectProjection.associations(
                pose: pose,
                intrinsics: intrinsics,
                imageSize: imageSize,
                surfaces: surfaces
            )
            let nextID = associations.first?.surfaceID
            if cameraSurfaceID.wrappedValue != nextID {
                cameraSurfaceID.wrappedValue = nextID
                if nextID != nil {
                    cameraModel.lastError = nil
                }
            }
        }

        func updateARSkeleton(
            _ points: [CrackSkeleton3DPoint],
            in view: ARSCNView
        ) {
            var hash = 0
            for point in points {
                hash = hash &* 31 &+ point.pixel.x
                hash = hash &* 31 &+ point.pixel.y
                hash = hash &* 31 &+ point.surfaceID.hashValue
            }
            guard hash != lastSkeletonHash else { return }
            lastSkeletonHash = hash

            view.scene.rootNode.childNode(
                withName: skeletonNodeName,
                recursively: true
            )?.removeFromParentNode()
            guard !points.isEmpty else { return }

            var vertices: [SCNVector3] = []
            var indices: [Int32] = []
            var indexByPoint: [CrackPoint: Int] = [:]
            for (index, point) in points.enumerated() {
                vertices.append(
                    SCNVector3(
                        point.world.x,
                        point.world.y,
                        point.world.z
                    )
                )
                indexByPoint[point.pixel] = index
            }

            let maxPixel = points
                .map { max($0.pixel.x, $0.pixel.y) }
                .max() ?? 1024
            let neighborRadius = max(2, maxPixel / 160 + 2)
            for (point, index) in indexByPoint {
                for dy in -neighborRadius...neighborRadius {
                    for dx in -neighborRadius...neighborRadius {
                        if dx == 0 && dy == 0 { continue }
                        let neighbor = CrackPoint(
                            x: point.x + dx,
                            y: point.y + dy
                        )
                        if let neighborIndex = indexByPoint[neighbor],
                           index < neighborIndex,
                           points[index].surfaceID
                               == points[neighborIndex].surfaceID {
                            indices.append(Int32(index))
                            indices.append(Int32(neighborIndex))
                        }
                    }
                }
            }
            guard !indices.isEmpty else { return }

            let source = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(
                indices: indices,
                primitiveType: .line
            )
            let geometry = SCNGeometry(
                sources: [source],
                elements: [element]
            )
            geometry.firstMaterial?.diffuse.contents = UIColor.yellow
            geometry.firstMaterial?.emission.contents = UIColor.yellow
            geometry.firstMaterial?.isDoubleSided = true

            let node = SCNNode(geometry: geometry)
            node.name = skeletonNodeName
            node.renderingOrder = 100
            view.scene.rootNode.addChildNode(node)
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
    }
}

private struct RoomMiniMapView: UIViewRepresentable {
    let room: CapturedRoom
    let surfaces: [WallDefectSurface]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X

        let scene = loadScene()
        view.scene = scene

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 60
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        update(camera: camera)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let camera = uiView.pointOfView else { return }
        update(camera: camera)
    }

    private func loadScene() -> SCNScene {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usdz")
        do {
            try room.export(to: tempURL, exportOptions: .model)
            let scene = try SCNScene(url: tempURL, options: [
                .checkConsistency: true
            ])
            try? FileManager.default.removeItem(at: tempURL)
            return scene
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return SCNScene()
        }
    }

    private func update(camera: SCNNode) {
        let center = roomCenter
        let radius = max(roomRadius, 0.5)
        let distance = radius * 2.8
        let elevation = Float.pi / 4.2
        let horizontal = distance * cos(elevation)

        camera.position = SCNVector3(
            center.x + horizontal * 0.8,
            center.y + distance * sin(elevation),
            center.z + horizontal * 0.8
        )
        camera.look(at: SCNVector3(center.x, center.y, center.z))
    }

    private var roomCenter: SCNVector3 {
        var sum = SIMD3<Double>.zero
        var count = 0
        for surface in surfaces {
            let center = WallDefectGeometry.planeOrigin(for: surface)
                + WallDefectGeometry.planeUAxis(for: surface) / 2
                + WallDefectGeometry.planeVAxis(for: surface) / 2
            sum += center
            count += 1
        }
        guard count > 0 else { return SCNVector3Zero }
        return SCNVector3(
            Float(sum.x / Double(count)),
            Float(sum.y / Double(count)),
            Float(sum.z / Double(count))
        )
    }

    private var roomRadius: Float {
        let center = roomCenter
        var maxDistance: Float = 0
        for surface in surfaces {
            let point = WallDefectGeometry.planeOrigin(for: surface)
                + WallDefectGeometry.planeUAxis(for: surface) / 2
                + WallDefectGeometry.planeVAxis(for: surface) / 2
            let distance = simd_distance(
                SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z)),
                SIMD3<Float>(center.x, center.y, center.z)
            )
            maxDistance = max(maxDistance, distance)
        }
        return maxDistance
    }
}

private func surfaceTransform(_ surface: WallDefectSurface) -> simd_float4x4 {
    let origin = WallDefectGeometry.planeOrigin(for: surface)
    let u = WallDefectGeometry.planeUAxis(for: surface)
    let v = WallDefectGeometry.planeVAxis(for: surface)
    let normal = WallDefectGeometry.planeNormal(for: surface)
    let center = origin + u / 2 + v / 2

    var matrix = simd_float4x4()
    matrix.columns.0 = SIMD4<Float>(
        Float(simd_normalize(u).x),
        Float(simd_normalize(u).y),
        Float(simd_normalize(u).z),
        0
    )
    matrix.columns.1 = SIMD4<Float>(
        Float(simd_normalize(v).x),
        Float(simd_normalize(v).y),
        Float(simd_normalize(v).z),
        0
    )
    matrix.columns.2 = SIMD4<Float>(
        Float(simd_normalize(normal).x),
        Float(simd_normalize(normal).y),
        Float(simd_normalize(normal).z),
        0
    )
    matrix.columns.3 = SIMD4<Float>(
        Float(center.x),
        Float(center.y),
        Float(center.z),
        1
    )
    return matrix
}
