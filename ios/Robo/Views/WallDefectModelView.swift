import ARKit
import CoreVideo
import SceneKit
import simd
import SwiftUI
import UIKit

struct WallDefectPhotoRecognitionResult {
    let result: CrackRecognitionResult
    let annotatedImage: UIImage?
    let arSkeleton: [CrackSkeleton3DPoint]
    let timings: [String: Double]
    let rawDetectionCount: Int
    let skeletonComponentCount: Int
    let projectedComponentCount: Int
    let pixelLengthReported: Double
    let maskPointCount: Int
    let preFilterComponentCount: Int
    let filteredReason: String?
}

struct WallDefectModelView: View {
    let arSession: ARSession
    let latestRecognition: WallDefectPhotoRecognitionResult?
    let isRecognizing: Bool
    let progressMessage: String
    let onPhoto: (DefectCameraCapture, WallDefectSurface?) -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    @StateObject private var cameraModel = DefectCameraModel()
    @State private var cameraViewSize = CGSize.zero
    @State private var showSaveConfirm = false
    @State private var showRecognitionPanel = false
    @State private var recognitionConfig = CrackRecognitionSettings.load()

    private var captureCenterRatio: CGFloat {
        guard cameraViewSize.width > 0, cameraViewSize.height > 0 else {
            return DefectCameraModel.squareCropCenterYRatio
        }
        let side = min(
            cameraViewSize.width,
            cameraViewSize.height
        ) * DefectCameraModel.squareCropInset
        let centerY = max(
            side / 2 + 48,
            cameraViewSize.height
                * DefectCameraModel.squareCropCenterYRatio
        )
        return min(max(centerY / cameraViewSize.height, 0), 1)
    }

    private var planeResidualText: String {
        guard let residual = cameraModel.planeResidualM,
              residual.isFinite,
              residual < 1 else {
            return "残差 -"
        }
        return String(format: "残差 %.1f cm", residual * 100)
    }

    var body: some View {
        ZStack {
            WallDefectARView(
                arSession: arSession,
                cameraModel: cameraModel,
                latestARSkeleton: latestRecognition?.arSkeleton ?? []
            )
            .ignoresSafeArea()

            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                    * DefectCameraModel.squareCropInset
                let centerY = max(
                    side / 2 + 48,
                    geometry.size.height
                        * DefectCameraModel.squareCropCenterYRatio
                )
                ZStack {
                    Color.clear
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(.yellow, lineWidth: 2)
                        .frame(width: side, height: side)
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
                Spacer(minLength: 0)
                if let tap = cameraModel.tapWorldPoint {
                    Text(
                        String(
                            format: "点云命中 (%.3f, %.3f, %.3f)",
                            tap.x,
                            tap.y,
                            tap.z
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
                }
                planeStatusPanel
                if showRecognitionPanel {
                    recognitionPanel
                }
                recognitionSummaryPanel
                bottomBar
            }
        }
        .onChange(of: recognitionConfig) { _, newValue in
            CrackRecognitionSettings.save(newValue)
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
            Text("照片会与墙面平面、裂缝长度一起归档，用于缺陷工程量计算。")
        }
    }

    private var planeStatusPanel: some View {
        HStack(spacing: 10) {
            if let source = cameraModel.planeSource,
               let distance = cameraModel.planeDistanceM {
                Image(systemName: "square.dashed")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        String(
                            format: "墙面平面 %@ · 距离 %.2f m",
                            source == "raycast" ? "射线检测" : "深度拟合",
                            distance
                        )
                    )
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    Text(
                        "法向 \(cameraModel.planeNormalText ?? "-") · 采样 \(cameraModel.planeSampleCount) · \(planeResidualText)"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
            } else {
                Image(systemName: "viewfinder")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("未检测到墙面平面，请将取景框对准墙面或地面")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Spacer()
            }
        }
        .padding(10)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if isRecognizing {
                Text(progressMessage.isEmpty ? "正在识别照片" : progressMessage)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
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
                    Button {
                        showRecognitionPanel.toggle()
                    } label: {
                        Label(
                            showRecognitionPanel ? "收起" : "识别参数",
                            systemImage: "slider.horizontal.3"
                        )
                        .font(.subheadline.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                }

                Button {
                    guard let capture = cameraModel.capture(
                        viewSize: cameraViewSize == .zero
                            ? nil
                            : cameraViewSize,
                        outputSide: CGFloat(recognitionConfig.captureResolution),
                        centerRatio: captureCenterRatio
                    ) else { return }
                    onPhoto(capture, cameraModel.currentPlaneSurface)
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
        .padding(12)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var recognitionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("识别参数")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button("恢复默认") {
                    recognitionConfig = .defaultConfig
                    CrackRecognitionSettings.save(recognitionConfig)
                }
                .font(.caption.bold())
                .foregroundStyle(.orange)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        parameterPicker(
                            title: "模式",
                            selection: Binding(
                                get: { recognitionConfig.mode },
                                set: { recognitionConfig.mode = $0 }
                            ),
                            options: [
                                ("常规", "normal"),
                                ("发丝级", "hairline")
                            ]
                        )
                        parameterPicker(
                            title: "模型",
                            selection: Binding(
                                get: { recognitionConfig.modelSize },
                                set: { recognitionConfig.modelSize = $0 }
                            ),
                            options: [
                                ("n", "n"),
                                ("s", "s")
                            ]
                        )
                    }
                    parameterSlider(
                        title: "置信度",
                        value: Binding(
                            get: { recognitionConfig.confidence },
                            set: { recognitionConfig.confidence = $0 }
                        ),
                        range: 0.1...0.9,
                        step: 0.05,
                        format: "%.2f"
                    )
                    parameterSlider(
                        title: "IoU",
                        value: Binding(
                            get: { recognitionConfig.iou },
                            set: { recognitionConfig.iou = $0 }
                        ),
                        range: 0.1...0.9,
                        step: 0.05,
                        format: "%.2f"
                    )
                    parameterStepper(
                        title: "候选框上限",
                        value: Binding(
                            get: { recognitionConfig.maxDetections },
                            set: { recognitionConfig.maxDetections = $0 }
                        ),
                        range: 1...25
                    )
                    parameterStepper(
                        title: "裁剪分辨率",
                        value: Binding(
                            get: { recognitionConfig.captureResolution },
                            set: { recognitionConfig.captureResolution = $0 }
                        ),
                        range: 512...2048,
                        step: 128
                    )
                    HStack(spacing: 8) {
                        parameterPicker(
                            title: "骨架",
                            selection: Binding(
                                get: { recognitionConfig.skeletonMode },
                                set: { recognitionConfig.skeletonMode = $0 }
                            ),
                            options: [
                                ("全部", "all"),
                                ("主裂缝", "main")
                            ]
                        )
                        parameterPicker(
                            title: "长度单位",
                            selection: Binding(
                                get: { recognitionConfig.lengthUnit },
                                set: { recognitionConfig.lengthUnit = $0 }
                            ),
                            options: [
                                ("像素", "pixel"),
                                ("已知mm", "known")
                            ]
                        )
                    }
                    parameterStepper(
                        title: "最短骨架长度",
                        value: Binding(
                            get: { recognitionConfig.minSkeletonLength },
                            set: { recognitionConfig.minSkeletonLength = $0 }
                        ),
                        range: 20...500,
                        step: 20
                    )
                    parameterStepper(
                        title: "最小物理长度(mm)",
                        value: Binding(
                            get: { Int(recognitionConfig.minPhysicalLengthMM) },
                            set: {
                                recognitionConfig.minPhysicalLengthMM = Double($0)
                            }
                        ),
                        range: 1...100
                    )
                    parameterStepper(
                        title: "去重距离(mm)",
                        value: Binding(
                            get: { Int(recognitionConfig.dedupDistanceMM) },
                            set: {
                                recognitionConfig.dedupDistanceMM = Double($0)
                            }
                        ),
                        range: 1...100
                    )
                }
            }
            .frame(maxHeight: 210)
        }
        .padding(10)
        .background(.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private func parameterPicker(
        title: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.7))
            Picker(title, selection: selection) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index].0).tag(options[index].1)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity)
    }

    private func parameterSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(value: value, in: range, step: step)
                .tint(.cyan)
        }
    }

    private func parameterStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1
    ) -> some View {
        Stepper(
            "\(title)：\(value.wrappedValue)",
            value: value,
            in: range,
            step: step
        )
        .font(.caption2)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var recognitionSummaryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("识别简报")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Spacer()
            }

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
                if result.isEmpty {
                    Text(
                        latestRecognition.rawDetectionCount > 0
                            ? "未形成有效裂缝"
                            : "未识别到裂缝"
                    )
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    if latestRecognition.pixelLengthReported > 0 {
                        Text(
                            String(
                                format: "像素长度 %.0f px",
                                latestRecognition.pixelLengthReported
                            )
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                    }
                    Text(
                        "检测 \(latestRecognition.rawDetectionCount) 处 · 掩码 \(latestRecognition.maskPointCount) 点 · 骨架 \(latestRecognition.preFilterComponentCount) 组"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    if let reason = latestRecognition.filteredReason {
                        Text(reason)
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                } else {
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
                    if let total = latestRecognition.timings["总计"] {
                        LabeledContent(
                            "耗时",
                            value: String(format: "%.2fs", total)
                        )
                    }
                }
                Text(
                    "YOLO \(latestRecognition.rawDetectionCount)处 · 骨架 \(latestRecognition.skeletonComponentCount)条 · 墙面投影 \(latestRecognition.projectedComponentCount)条"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            } else {
                Text("尚未识别，对准裂缝后点击拍照")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }
}

private struct WallDefectARView: UIViewRepresentable {
    let arSession: ARSession
    let cameraModel: DefectCameraModel
    let latestARSkeleton: [CrackSkeleton3DPoint]

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = arSession
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        context.coordinator.sceneView = view
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
        Coordinator(cameraModel: cameraModel)
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let cameraModel: DefectCameraModel
        weak var sceneView: ARSCNView?
        private let skeletonNodeName = "CrackARSkeleton"
        private let centerNodeName = "DepthCenterVerificationBox"
        private let raycastNodeName = "RaycastVerificationBox"
        private let pointCloudNodeName = "DefectDepthPointCloud"
        private let tapMarkerNodeName = "TapWorldPointMarker"
        private var latestPointCloud: [DefectPointCloudPoint] = []
        private var lastSkeletonHash = Int.min
        private var lastPlaneEstimateTime: TimeInterval = -1
        private var lastCenterUpdateTime: TimeInterval = -1
        private var lastPointCloudUpdateTime: TimeInterval = -1

        init(cameraModel: DefectCameraModel) {
            self.cameraModel = cameraModel
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            DispatchQueue.main.async {
                self.cameraModel.update(frame: frame)
                if frame.timestamp - self.lastPlaneEstimateTime >= 0.2 {
                    self.lastPlaneEstimateTime = frame.timestamp
                    let cropCenter = self.cropCenter(in: self.sceneView)
                    let plane = WallDefectPlaneEstimator.estimate(
                        frame: frame,
                        view: self.sceneView,
                        center: cropCenter
                    )
                    self.cameraModel.update(plane: plane)
                }
                if frame.timestamp - self.lastCenterUpdateTime >= 0.1 {
                    self.lastCenterUpdateTime = frame.timestamp
                    self.updateCenterMarker(
                        frame: frame,
                        view: self.sceneView
                    )
                }
                if frame.timestamp - self.lastPointCloudUpdateTime >= 0.15 {
                    self.lastPointCloudUpdateTime = frame.timestamp
                    self.updateDepthPointCloud(
                        frame: frame,
                        view: self.sceneView
                    )
                }
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let location = recognizer.location(in: sceneView)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let view = self.sceneView else {
                    return
                }
                guard let world = self.screenWorldPoint(
                    view: view,
                    screenPoint: location
                ) else {
                    self.cameraModel.tapWorldPoint = nil
                    return
                }
                self.cameraModel.tapWorldPoint = world
                let marker = self.verificationNode(
                    named: self.tapMarkerNodeName,
                    color: .white,
                    in: view
                )
                marker.isHidden = false
                marker.position = SCNVector3(world.x, world.y, world.z)
            }
        }

        private func cropCenter(in view: ARSCNView?) -> CGPoint? {
            guard let view, view.bounds.width > 0, view.bounds.height > 0 else {
                return nil
            }
            let side = min(
                view.bounds.width,
                view.bounds.height
            ) * DefectCameraModel.squareCropInset
            let centerY = max(
                side / 2 + 48,
                view.bounds.height * DefectCameraModel.squareCropCenterYRatio
            )
            return CGPoint(x: view.bounds.midX, y: centerY)
        }

        private func updateCenterMarker(
            frame: ARFrame,
            view: ARSCNView?
        ) {
            guard let view else { return }
            let depthNode = verificationNode(
                named: centerNodeName,
                color: .cyan,
                in: view
            )
            let raycastNode = verificationNode(
                named: raycastNodeName,
                color: .green,
                in: view
            )
            guard let center = cropCenter(in: view) else {
                depthNode.isHidden = true
                raycastNode.isHidden = true
                return
            }
            if let world = screenWorldPoint(
                view: view,
                screenPoint: center
            ) {
                depthNode.isHidden = false
                depthNode.position = SCNVector3(world.x, world.y, world.z)
            } else {
                depthNode.isHidden = true
            }
            if let world = raycastWorldPoint(
                frame: frame,
                view: view,
                screenPoint: center
            ) {
                raycastNode.isHidden = false
                raycastNode.position = SCNVector3(world.x, world.y, world.z)
            } else {
                raycastNode.isHidden = true
            }
        }

        private func screenWorldPoint(
            view: ARSCNView,
            screenPoint: CGPoint
        ) -> SIMD3<Float>? {
            nearestCloudWorldPoint(
                toScreen: screenPoint,
                in: view
            )
        }

        private func nearestCloudWorldPoint(
            toScreen screenPoint: CGPoint,
            in view: ARSCNView
        ) -> SIMD3<Float>? {
            guard !latestPointCloud.isEmpty else {
                return nil
            }
            var best: DefectPointCloudPoint?
            var bestDistance = CGFloat.infinity
            for point in latestPointCloud {
                let projected = view.projectPoint(
                    SCNVector3(
                        point.world.x,
                        point.world.y,
                        point.world.z
                    )
                )
                let projectedPoint = CGPoint(
                    x: CGFloat(projected.x),
                    y: CGFloat(projected.y)
                )
                let dx = projectedPoint.x - screenPoint.x
                let dy = projectedPoint.y - screenPoint.y
                let distance = dx * dx + dy * dy
                if distance < bestDistance {
                    bestDistance = distance
                    best = point
                }
            }
            return best?.world
        }

        private func updateDepthPointCloud(
            frame: ARFrame,
            view: ARSCNView?
        ) {
            guard let view,
                  let depthMap = frame.sceneDepth?.depthMap else {
                return
            }
            let points = WallDefectProjection.makePointCloud(
                frame: frame,
                depthMap: depthMap,
                sampleStep: 4
            )
            latestPointCloud = points
            let node = SCNNode()
            node.name = pointCloudNodeName
            if !points.isEmpty {
                let vertices = points.map {
                    SCNVector3($0.world.x, $0.world.y, $0.world.z)
                }
                let source = SCNGeometrySource(vertices: vertices)
                let indices = (0..<Int32(points.count)).map { $0 }
                let element = SCNGeometryElement(
                    indices: indices,
                    primitiveType: .point
                )
                element.pointSize = 2
                element.minimumPointScreenSpaceRadius = 1
                element.maximumPointScreenSpaceRadius = 3
                let geometry = SCNGeometry(
                    sources: [source],
                    elements: [element]
                )
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = UIColor.cyan
                material.emission.contents = UIColor.cyan
                material.blendMode = .alpha
                geometry.materials = [material]
                node.geometry = geometry
            }
            view.scene.rootNode.childNode(
                withName: pointCloudNodeName,
                recursively: true
            )?.removeFromParentNode()
            view.scene.rootNode.addChildNode(node)
        }

        private func raycastWorldPoint(
            frame: ARFrame,
            view: ARSCNView,
            screenPoint: CGPoint
        ) -> SIMD3<Float>? {
            let targets: [ARRaycastQuery.Target] = [
                .existingPlaneGeometry,
                .estimatedPlane
            ]
            for target in targets {
                guard let query = view.raycastQuery(
                    from: screenPoint,
                    allowing: target,
                    alignment: .any
                ), let result = view.session.raycast(query).first else {
                    continue
                }
                let transform = result.worldTransform
                return SIMD3<Float>(
                    transform.columns.3.x,
                    transform.columns.3.y,
                    transform.columns.3.z
                )
            }
            return nil
        }

        private func verificationNode(
            named name: String,
            color: UIColor,
            in view: ARSCNView
        ) -> SCNNode {
            if let existing = view.scene.rootNode.childNode(
                withName: name,
                recursively: true
            ) {
                return existing
            }
            let box = SCNBox(
                width: 0.05,
                height: 0.05,
                length: 0.05,
                chamferRadius: 0
            )
            box.firstMaterial?.diffuse.contents = color
            box.firstMaterial?.emission.contents = color
            let node = SCNNode(geometry: box)
            node.name = name
            node.renderingOrder = 200
            view.scene.rootNode.addChildNode(node)
            return node
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
                           index < neighborIndex {
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
    }
}
