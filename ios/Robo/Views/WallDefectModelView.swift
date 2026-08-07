import ARKit
import SceneKit
import simd
import SwiftUI
import UIKit

struct WallDefectModelView: View {
    let surfaces: [WallDefectSurface]
    let arSession: ARSession
    let onPhoto: ([WallDefectSurfaceAssociation], DefectCameraCapture) -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    @StateObject private var cameraModel = DefectCameraModel()
    @StateObject private var realtimeDetector = CrackRealtimeDetector()
    @State private var cameraSurfaceID: UUID?
    @State private var photoCount = 0
    @State private var showSaveConfirm = false

    private var cameraSurface: WallDefectSurface? {
        surfaces.first { $0.id == cameraSurfaceID }
    }

    var body: some View {
        ZStack {
            WallDefectARView(
                surfaces: surfaces,
                arSession: arSession,
                cameraModel: cameraModel,
                realtimeDetector: realtimeDetector,
                cameraSurfaceID: $cameraSurfaceID
            )
            .ignoresSafeArea()

            if realtimeDetector.isAvailable,
               !realtimeDetector.normalizedPoints.isEmpty {
                Canvas { context, size in
                    for point in realtimeDetector.normalizedPoints {
                        let rect = CGRect(
                            x: point.x * size.width - 2,
                            y: point.y * size.height - 2,
                            width: 4,
                            height: 4
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(.red.opacity(0.85))
                        )
                    }
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                RoomMiniMapView(
                    surfaces: surfaces,
                    yaw: cameraModel.yaw,
                    selectedSurfaceID: cameraSurfaceID
                )
                .frame(height: 180)
                .padding(.horizontal, 10)
                bottomBar
            }
        }
        .onAppear {
            realtimeDetector.prepare(config: CrackRecognitionSettings.load())
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
            } else {
                Text("把相机对准墙或地面，自动识别目标")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 14) {
                Button {
                    guard let capture = cameraModel.capture() else { return }
                    let associations = WallDefectProjection.associations(
                        pose: capture.pose,
                        intrinsics: capture.intrinsics,
                        imageSize: capture.image.size,
                        surfaces: surfaces
                    )
                    guard !associations.isEmpty else { return }
                    photoCount += 1
                    onPhoto(associations, capture)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 68, height: 68)
                        Circle()
                            .fill(.white)
                            .frame(width: 52, height: 52)
                    }
                }
                .disabled(cameraSurface == nil)
                .opacity(cameraSurface == nil ? 0.45 : 1)

                Button {
                    showSaveConfirm = true
                } label: {
                    Label("保存扫描包", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.teal)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

private struct WallDefectARView: UIViewRepresentable {
    let surfaces: [WallDefectSurface]
    let arSession: ARSession
    let cameraModel: DefectCameraModel
    let realtimeDetector: CrackRealtimeDetector
    @Binding var cameraSurfaceID: UUID?

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = arSession
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        context.coordinator.sceneView = view

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        arSession.run(configuration, options: [])

        addNodes(to: view.scene.rootNode)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.updateSelection(
            in: uiView.scene.rootNode,
            selectedID: cameraSurfaceID
        )
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            cameraModel: cameraModel,
            cameraSurfaceID: $cameraSurfaceID,
            realtimeDetector: realtimeDetector
        )
    }

    private func addNodes(to root: SCNNode) {
        for surface in surfaces {
            let plane = SCNPlane(width: surface.width, height: surface.height)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.cyan.withAlphaComponent(0.32)
            material.isDoubleSided = true
            plane.firstMaterial = material

            let node = SCNNode(geometry: plane)
            node.name = surface.id.uuidString
            node.transform = SCNMatrix4(surfaceTransform(surface))
            root.addChildNode(node)
        }
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let cameraModel: DefectCameraModel
        let realtimeDetector: CrackRealtimeDetector
        private let realtimeConfig: CrackRecognitionConfig
        var cameraSurfaceID: Binding<UUID?>
        weak var sceneView: ARSCNView?

        init(
            cameraModel: DefectCameraModel,
            cameraSurfaceID: Binding<UUID?>,
            realtimeDetector: CrackRealtimeDetector
        ) {
            self.cameraModel = cameraModel
            self.cameraSurfaceID = cameraSurfaceID
            self.realtimeDetector = realtimeDetector
            self.realtimeConfig = CrackRecognitionSettings.load()
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            DispatchQueue.main.async {
                self.cameraModel.update(frame: frame)
                self.realtimeDetector.process(
                    frame: frame,
                    config: self.realtimeConfig
                )
                self.updateCameraSurface()
            }
        }

        private func updateCameraSurface() {
            guard let view = sceneView else { return }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let results = view.hitTest(
                center,
                options: [.rootNode: view.scene.rootNode]
            )
            var nextID: UUID?
            if let name = results.first?.node.name {
                nextID = UUID(uuidString: name)
            }
            if cameraSurfaceID.wrappedValue != nextID {
                cameraSurfaceID.wrappedValue = nextID
            }
        }

        func updateSelection(in root: SCNNode, selectedID: UUID?) {
            for node in root.childNodes {
                guard let name = node.name,
                      let id = UUID(uuidString: name) else {
                    continue
                }
                let selected = id == selectedID
                let color = selected
                    ? UIColor.orange.withAlphaComponent(0.58)
                    : UIColor.cyan.withAlphaComponent(0.32)
                node.geometry?.firstMaterial?.diffuse.contents = color
            }
        }
    }
}

private struct RoomMiniMapView: UIViewRepresentable {
    let surfaces: [WallDefectSurface]
    let yaw: Float
    let selectedSurfaceID: UUID?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0, alpha: 0.42)
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        view.scene = scene
        addNodes(to: scene.rootNode)

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
        updateSelection(in: uiView.scene?.rootNode)
    }

    private func addNodes(to root: SCNNode) {
        for surface in surfaces {
            let plane = SCNPlane(width: surface.width, height: surface.height)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.cyan.withAlphaComponent(0.55)
            material.isDoubleSided = true
            plane.firstMaterial = material

            let node = SCNNode(geometry: plane)
            node.name = surface.id.uuidString
            node.transform = SCNMatrix4(surfaceTransform(surface))
            root.addChildNode(node)
        }
    }

    private func update(camera: SCNNode) {
        let center = roomCenter
        let radius = max(roomRadius, 0.5)
        let elevation = Float.pi / 4
        let distance = radius * 3.4
        let horizontal = distance * cos(elevation)

        camera.position = SCNVector3(
            center.x + horizontal * sin(yaw),
            center.y + distance * sin(elevation),
            center.z + horizontal * cos(yaw)
        )
        camera.look(at: SCNVector3(center.x, center.y, center.z))
    }

    private func updateSelection(in root: SCNNode?) {
        guard let root else { return }
        for node in root.childNodes {
            guard let name = node.name,
                  let id = UUID(uuidString: name) else {
                continue
            }
            let selected = id == selectedSurfaceID
            let color = selected
                ? UIColor.orange.withAlphaComponent(0.85)
                : UIColor.cyan.withAlphaComponent(0.55)
            node.geometry?.firstMaterial?.diffuse.contents = color
        }
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
