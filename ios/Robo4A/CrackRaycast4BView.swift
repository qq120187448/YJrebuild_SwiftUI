import ARKit
import RealityKit
import simd
import SwiftUI
import UIKit

/// 4B：4A 采样点 → ARView.raycast → ARWorld 3D → 反投影 → 重投影误差。
struct CrackRaycast4BView: View {

    @StateObject private var viewModel = ContentViewModel()
    @State private var scenario = CrackRaycast4B.scenarios[0]
    @State private var statusText = "对准墙面，点击“拍照并 4B 测量”"
    @State private var isRunning = false
    @State private var report: Raycast4BReport?
    @State private var history: [Raycast4BReport] = []
    @State private var arViewReference: ARView?
    @State private var worldAnchors: [AnchorEntity] = []
    /// 0.742B 任务4：后台/息屏时保存 WorldMap，回前台复用坐标。
    @State private var savedWorldMap: ARWorldMap?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            ARViewContainer { arView in
                arViewReference = arView
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            Picker("场景", selection: $scenario) {
                ForEach(CrackRaycast4B.scenarios, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.orange)
            Text("红色球/线 = raycast 命中的世界点，应贴合墙面裂缝")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    measure()
                } label: {
                    Label("拍照并 4B 测量", systemImage: "camera.viewfinder")
                }
                .disabled(isRunning || arViewReference == nil)

                if let report {
                    Button {
                        UIPasteboard.general.string = report.text()
                    } label: {
                        Label("复制本组", systemImage: "doc.on.doc")
                    }
                }

                if !history.isEmpty {
                    Button {
                        UIPasteboard.general.string = history
                            .map { $0.text() }
                            .joined(separator: "\n\n")
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc.fill")
                    }
                }

                Button {
                    clearWorldVisualization()
                } label: {
                    Label("清除投影", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.borderedProminent)

            ScrollView {
                if let report {
                    Text(report.text())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("测量后此处显示 4B 基线报告（区域固定，取景框比例不变）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 170)
            .padding(.horizontal)
        }
        .navigationTitle("4B Raycast")
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
    }

    private func measure() {
        guard let arView = arViewReference else { return }
        isRunning = true
        statusText = "拍照中…"
        // 0.742B 任务3：按下拍照瞬间捕获帧，用于最终 AR 投影定位（识别期间移动不漂移）。
        let captureFrame = arView.session.currentFrame

        arView.snapshot(saveToHDR: false) { image in
            Task { @MainActor in
                guard let image else {
                    statusText = "拍照失败"
                    isRunning = false
                    return
                }
                statusText = "4A 识别裂缝中…"
                viewModel.centerlineResult = nil
                viewModel.centerlineStats = ""
                // 0.742B：拍照后图像统一转长边 1024，喂给 1024 输入模型，后续坐标按 1024。
                let analysisImage = Self.resizedImage(image, maxSide: 1024)
                viewModel.uiImage = analysisImage
                await viewModel.runInference()

                guard let samples = viewModel.centerlineResult?.samplePointsPerPolyline,
                      !samples.isEmpty else {
                    statusText = "未识别到裂缝，无法 4B"
                    isRunning = false
                    return
                }

                let scale: CGFloat
                if analysisImage.size.width > 0 {
                    scale = arView.bounds.width / analysisImage.size.width
                } else {
                    scale = 1
                }

                statusText = "raycast + 反投影中…"
                let measured = CrackRaycast4B.measure(
                    arView: arView,
                    scenario: scenario,
                    samplePointsPerPolyline: samples,
                    imageToViewScale: scale
                )
                // AR 投影位置按"按下拍照时刻"锁定（帧锁定），替代识别后当前帧 raycast 点。
                let displayWorldPoints = frameLockedWorldPoints(
                    captureFrame: captureFrame,
                    samplePointsPerPolyline: samples,
                    imageToViewScale: scale,
                    arView: arView
                )
                addWorldVisualization(
                    arView: arView,
                    worldPoints: displayWorldPoints
                )
                report = measured
                history.append(measured)
                statusText = String(
                    format: "命中率 %.1f%% · 平均重投影 %.2f px · P95 %.2f px",
                    measured.hitRate * 100,
                    measured.avgError,
                    measured.p95Error
                )
                isRunning = false
            }
        }
    }

    // MARK: - AR 世界点可视化（红球 + 相邻点连线）

    private func addWorldVisualization(
        arView: ARView,
        worldPoints: [SIMD3<Float>]
    ) {
        clearWorldVisualization()
        var previousWorld: SIMD3<Float>?
        for world in worldPoints {
            let anchor = AnchorEntity(world: world)
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.004),
                materials: [SimpleMaterial(color: .red, isMetallic: false)]
            )
            anchor.addChild(sphere)
            arView.scene.addAnchor(anchor)
            worldAnchors.append(anchor)

            if let previous = previousWorld {
                if let line = Self.lineEntity(
                    from: previous,
                    to: world,
                    color: .red
                ) {
                    let midpoint = (previous + world) * 0.5
                    let lineAnchor = AnchorEntity(world: midpoint)
                    lineAnchor.addChild(line)
                    arView.scene.addAnchor(lineAnchor)
                    worldAnchors.append(lineAnchor)
                }
            }
            previousWorld = world
        }
    }

    private func clearWorldVisualization() {
        for anchor in worldAnchors {
            anchor.removeFromParent()
        }
        worldAnchors.removeAll()
    }

    // MARK: - 0.742B 任务3：按下拍照时刻帧锁定投影

    /// 拍照帧锁定：像素 → 拍照帧相机射线 → 拍照帧 ARPlaneAnchor 求交 → world 投影点。
    /// 识别期间手机移动不影响投影位置（AR 红线锚定在按下瞬间）。
    @MainActor
    private func frameLockedWorldPoints(
        captureFrame: ARFrame?,
        samplePointsPerPolyline: [[CrackPoint]],
        imageToViewScale: CGFloat,
        arView: ARView
    ) -> [SIMD3<Float>] {
        guard let captureFrame else { return [] }
        let planes = captureFrame.anchors.compactMap {
            $0 as? ARPlaneAnchor
        }
        guard !planes.isEmpty else { return [] }
        let orientation =
            arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let displayTransform = captureFrame.displayTransform(
            for: orientation,
            viewportSize: arView.bounds.size
        )
        let intrinsics = captureFrame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let cameraTransform = captureFrame.camera.transform
        let rotation = simd_float3x3(columns: (
            SIMD3<Float>(
                cameraTransform.columns.0.x,
                cameraTransform.columns.0.y,
                cameraTransform.columns.0.z
            ),
            SIMD3<Float>(
                cameraTransform.columns.1.x,
                cameraTransform.columns.1.y,
                cameraTransform.columns.1.z
            ),
            SIMD3<Float>(
                cameraTransform.columns.2.x,
                cameraTransform.columns.2.y,
                cameraTransform.columns.2.z
            )
        ))
        let origin = cameraTransform.position
        let imageW = captureFrame.camera.imageResolution.width
        let imageH = captureFrame.camera.imageResolution.height

        var points: [SIMD3<Float>] = []
        for polyline in samplePointsPerPolyline {
            for point in polyline {
                let viewPoint = CGPoint(
                    x: CGFloat(point.x) * imageToViewScale,
                    y: CGFloat(point.y) * imageToViewScale
                )
                let sensor = CaptureFrameSurfaceMapper.sensorPoint(
                    viewPoint: viewPoint,
                    displayTransform: displayTransform,
                    viewportSize: arView.bounds.size,
                    imageWidth: imageW,
                    imageHeight: imageH
                )
                let localDirection = SIMD3<Float>(
                    (sensor.x - cx) / fx,
                    -(sensor.y - cy) / fy,
                    -1
                )
                let worldDirection = simd_normalize(
                    rotation * localDirection
                )
                var bestWorld: SIMD3<Float>?
                var bestDistance = Float.greatestFiniteMagnitude
                for plane in planes {
                    let inverse = plane.transform.inverse
                    let localOrigin4 = inverse
                        * SIMD4<Float>(origin.x, origin.y, origin.z, 1)
                    let localDir4 = inverse
                        * SIMD4<Float>(
                            worldDirection.x,
                            worldDirection.y,
                            worldDirection.z,
                            0
                        )
                    let localOrigin = SIMD3<Float>(
                        localOrigin4.x,
                        localOrigin4.y,
                        localOrigin4.z
                    )
                    let localDir = SIMD3<Float>(
                        localDir4.x,
                        localDir4.y,
                        localDir4.z
                    )
                    guard abs(localDir.z) > 0.0001 else { continue }
                    let t = -localOrigin.z / localDir.z
                    guard t > 0 else { continue }
                    let localHit = localOrigin + localDir * t
                    let halfX = plane.planeExtent.width * 0.5 + 0.02
                    let halfY = plane.planeExtent.height * 0.5 + 0.02
                    guard abs(localHit.x) <= halfX,
                          abs(localHit.y) <= halfY,
                          abs(localHit.z) <= 0.02 else {
                        continue
                    }
                    let world4 = plane.transform
                        * SIMD4<Float>(
                            localHit.x,
                            localHit.y,
                            localHit.z,
                            1
                        )
                    let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                    let distance = simd_distance(world, origin)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestWorld = world
                    }
                }
                if let bestWorld {
                    points.append(bestWorld)
                }
            }
        }
        return points
    }

    // MARK: - 0.742B 任务4：息屏/后台 WorldMap 坐标复用

    private func handleScenePhase(_ phase: ScenePhase) {
        guard let arView = arViewReference else { return }
        switch phase {
        case .background:
            saveWorldMapForResume(arView: arView)
        case .active:
            if savedWorldMap != nil {
                resumeWithWorldMap(arView: arView)
            }
        default:
            break
        }
    }

    private func saveWorldMapForResume(arView: ARView) {
        guard let frame = arView.session.currentFrame,
              frame.worldMappingStatus == .mapped else { return }
        arView.session.getCurrentWorldMap { map, _ in
            if let map {
                savedWorldMap = map
            }
        }
    }

    private func resumeWithWorldMap(arView: ARView) {
        guard let savedWorldMap else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = savedWorldMap
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(
            .meshWithClassification
        ) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.environmentTexturing = .automatic
        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
    }

    private static func lineEntity(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        color: UIColor
    ) -> ModelEntity? {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 0.001 else { return nil }
        let direction = delta / length
        let entity = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(0.003, 0.003, length),
                cornerRadius: 0.0015
            ),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        entity.orientation = simd_quatf(
            from: SIMD3<Float>(0, 0, 1),
            to: direction
        )
        return entity
    }

    /// 等比压缩长边到 maxSide（0.742B：统一 1024）。
    private static func resizedImage(
        _ image: UIImage,
        maxSide: CGFloat
    ) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxSide, largest > 0 else { return image }
        let scale = maxSide / largest
        let size = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
    }
}

struct ARViewContainer: UIViewRepresentable {
    var onReady: (ARView) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)

        onReady(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
