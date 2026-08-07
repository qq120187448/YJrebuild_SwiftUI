import ARKit
import SceneKit
import simd
import SwiftUI
import UIKit

struct WallDefectModelView: View {
    let surfaces: [WallDefectSurface]
    let arSession: ARSession
    let onPhoto: (UUID, DefectCameraCapture) -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    @StateObject private var cameraModel = DefectCameraModel()
    @State private var selectedSurfaceID: UUID?
    @State private var photoCount = 0
    @State private var showSaveConfirm = false

    private var selectedSurface: WallDefectSurface? {
        surfaces.first { $0.id == selectedSurfaceID }
    }

    var body: some View {
        ZStack {
            WallDefectARView(
                surfaces: surfaces,
                arSession: arSession,
                cameraModel: cameraModel,
                selectedSurfaceID: $selectedSurfaceID
            )
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
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
                systemName: selectedSurface == nil
                    ? "hand.tap"
                    : "checkmark.circle.fill"
            )
            .font(.title3)
            .foregroundStyle(selectedSurface == nil ? .white : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSurface?.label ?? "点击墙面选择")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                if let selectedSurface {
                    Text(selectedSurface.uvDescription)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    Text("直接点选模型上的墙或地面")
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
            if let selectedSurface {
                Text("已选：\(selectedSurface.label)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }

            HStack(spacing: 14) {
                Button {
                    guard let selectedSurfaceID,
                          let capture = cameraModel.capture() else { return }
                    photoCount += 1
                    onPhoto(selectedSurfaceID, capture)
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
                .disabled(selectedSurface == nil)
                .opacity(selectedSurface == nil ? 0.45 : 1)

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
    @Binding var selectedSurfaceID: UUID?

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

        addNodes(to: view.scene.rootNode)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.updateSelection(
            in: uiView.scene.rootNode,
            selectedID: selectedSurfaceID
        )
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            cameraModel: cameraModel,
            selectedSurfaceID: $selectedSurfaceID
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
            node.transform = SCNMatrix4(transform(for: surface))
            root.addChildNode(node)
        }
    }

    private func transform(for surface: WallDefectSurface) -> simd_float4x4 {
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

    final class Coordinator: NSObject, ARSessionDelegate {
        let cameraModel: DefectCameraModel
        var selectedSurfaceID: Binding<UUID?>

        init(
            cameraModel: DefectCameraModel,
            selectedSurfaceID: Binding<UUID?>
        ) {
            self.cameraModel = cameraModel
            self.selectedSurfaceID = selectedSurfaceID
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            DispatchQueue.main.async {
                self.cameraModel.update(frame: frame)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ARSCNView else { return }
            let location = gesture.location(in: view)
            let results = view.hitTest(
                location,
                options: [.rootNode: view.scene.rootNode]
            )
            guard let node = results.first?.node,
                  let name = node.name,
                  let id = UUID(uuidString: name) else {
                return
            }
            DispatchQueue.main.async {
                self.selectedSurfaceID.wrappedValue = id
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
