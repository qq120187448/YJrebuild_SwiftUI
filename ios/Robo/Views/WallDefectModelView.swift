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
    let meshHitCount: Int
    let depthHitCount: Int
    let planeHitCount: Int
    let missCount: Int
    let reprojectionErrorPx: Double?
    let meshAnchorCount: Int
    let meshVertexCount: Int
    let meshFaceCount: Int
    let measurementEngine: String?
    let measurementVersion: String?
}

struct WallDefectModelView: View {
    let arSession: ARSession
    let latestRecognition: WallDefectPhotoRecognitionResult?
    let arSkeletonGroups: [[CrackSkeleton3DPoint]]
    let cumulativeCrackCount: Int
    let cumulativeLengthM: Double
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
    @State private var calibrationKnownMM = 1000
    @State private var calibrationCount = 0
    @State private var lastCalibrationText: String?

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
                skeletonGroups: arSkeletonGroups,
                lineWidth: recognitionConfig.arLineWidth,
                meshMaxDistance: recognitionConfig.meshRayMaxDistanceM
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
        .onAppear {
            calibrationCount = WallDefectStore.calibrationCount()
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

    private func recordCalibration() {
        guard let recognition = latestRecognition else { return }
        let result = recognition.result
        let measuredMM = result.totalLengthM * 1000
        let record = CalibrationRecord(
            knownLengthMM: Double(calibrationKnownMM),
            measuredLengthMM: measuredMM,
            measurementEngine: recognition.measurementEngine ?? "unknown",
            measurementVersion: recognition.measurementVersion,
            pixelLength: result.totalPixelLength,
            confidence: result.confidence,
            createdAt: Date()
        )
        do {
            try WallDefectStore.saveCalibration(record)
            calibrationCount += 1
            lastCalibrationText = String(
                format: "已知 %.0fmm → 实测 %.1fmm（误差 %.1fmm）",
                record.knownLengthMM,
                record.measuredLengthMM,
                record.measuredLengthMM - record.knownLengthMM
            )
        } catch {
            lastCalibrationText = "记录失败：\(error.localizedDescription)"
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
                    if let reprojection = cameraModel.reprojectionDetail {
                        Text(reprojection)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.mint)
                    }
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
                        range: 1...10
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
                    }
                    parameterSlider(
                        title: "AR投影宽度",
                        value: Binding(
                            get: { recognitionConfig.arLineWidth },
                            set: { recognitionConfig.arLineWidth = $0 }
                        ),
                        range: 0.1...5,
                        step: 0.1,
                        format: "%.1f"
                    )
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
                    HStack(spacing: 8) {
                        parameterPicker(
                            title: "测量引擎",
                            selection: Binding(
                                get: { recognitionConfig.measurementEngine },
                                set: {
                                    recognitionConfig.measurementEngine = $0
                                }
                            ),
                            options: [
                                ("ARMesh+UV", "meshuv"),
                                ("LiDAR最近邻", "nearest")
                            ]
                        )
                    }
                    parameterSlider(
                        title: "折线简化阈值(px)",
                        value: Binding(
                            get: { recognitionConfig.polylineEpsilonPx },
                            set: { recognitionConfig.polylineEpsilonPx = $0 }
                        ),
                        range: 0.1...5,
                        step: 0.1,
                        format: "%.1f"
                    )
                    parameterSlider(
                        title: "Mesh求交距离上限(m)",
                        value: Binding(
                            get: { recognitionConfig.meshRayMaxDistanceM },
                            set: { recognitionConfig.meshRayMaxDistanceM = $0 }
                        ),
                        range: 0.5...8,
                        step: 0.5,
                        format: "%.1f"
                    )
                }
            }
            .frame(maxHeight: 210)

            Divider()
                .overlay(.white.opacity(0.25))
            HStack(spacing: 8) {
                Text("标定长度")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.7))
                Picker("标定长度", selection: $calibrationKnownMM) {
                    Text("500mm").tag(500)
                    Text("1000mm").tag(1000)
                    Text("2000mm").tag(2000)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(spacing: 8) {
                Button {
                    recordCalibration()
                } label: {
                    Label("记录本次测量", systemImage: "ruler")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.teal)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .disabled(latestRecognition == nil)
                Spacer()
                Text("已记录 \(calibrationCount) 条")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let text = lastCalibrationText {
                Text(text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
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
                    LabeledContent(
                        "本次裂缝",
                        value: "\(result.components.count) 条"
                    )
                    LabeledContent(
                        "本次增加",
                        value: String(format: "%.3f m", result.totalLengthM)
                    )
                    LabeledContent(
                        "累计数量",
                        value: "\(cumulativeCrackCount) 条"
                    )
                    LabeledContent(
                        "累计长度",
                        value: String(format: "%.3f m", cumulativeLengthM)
                    )
                }
                Text(
                    "YOLO \(latestRecognition.rawDetectionCount)处 · 骨架 \(latestRecognition.skeletonComponentCount)条 · 墙面投影 \(latestRecognition.projectedComponentCount)条"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                if let engine = latestRecognition.measurementEngine {
                    Text(
                        String(
                            format: "测量 %@ · mesh %d / depth %d / plane %d / miss %d · 重投影 %.1fpx · mesh面 %d",
                            engine == "meshuv" ? "ARMesh+UV" : "LiDAR最近邻",
                            latestRecognition.meshHitCount,
                            latestRecognition.depthHitCount,
                            latestRecognition.planeHitCount,
                            latestRecognition.missCount,
                            latestRecognition.reprojectionErrorPx ?? -1,
                            latestRecognition.meshFaceCount
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    if let version = latestRecognition.measurementVersion {
                        Text("算法版本 \(version)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
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
    let skeletonGroups: [[CrackSkeleton3DPoint]]
    let lineWidth: Double
    let meshMaxDistance: Double

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = arSession
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        context.coordinator.sceneView = view
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleReprojectionTap(_:))
        )
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.updateARSkeleton(
            skeletonGroups,
            lineWidth: lineWidth,
            in: uiView
        )
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            cameraModel: cameraModel,
            meshMaxDistance: meshMaxDistance
        )
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let cameraModel: DefectCameraModel
        let meshMaxDistance: Double
        weak var sceneView: ARSCNView?
        private let skeletonNodeName = "CrackARSkeleton"
        private let pointCloudNodeName = "DefectDepthPointCloud"
        private var lastSkeletonHash = Int.min
        private var lastPlaneEstimateTime: TimeInterval = -1
        private var lastPointCloudUpdateTime: TimeInterval = -1

        init(cameraModel: DefectCameraModel, meshMaxDistance: Double) {
            self.cameraModel = cameraModel
            self.meshMaxDistance = meshMaxDistance
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            DispatchQueue.main.async {
                self.cameraModel.update(frame: frame)
                if let view = self.sceneView,
                   view.bounds.width > 0,
                   view.bounds.height > 0 {
                    self.cameraModel.currentViewSize = view.bounds.size
                }
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
                if frame.timestamp - self.lastPointCloudUpdateTime >= 0.15 {
                    self.lastPointCloudUpdateTime = frame.timestamp
                    self.updateDepthPointCloud(
                        frame: frame,
                        view: self.sceneView
                    )
                }
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

        func updateARSkeleton(
            _ groups: [[CrackSkeleton3DPoint]],
            lineWidth: Double,
            in view: ARSCNView
        ) {
            var hash = 0
            for group in groups {
                for point in group {
                    hash = hash &* 31 &+ point.pixel.x
                    hash = hash &* 31 &+ point.pixel.y
                    hash = hash &* 31 &+ point.surfaceID.hashValue
                }
            }
            hash = hash &* 31 &+ Int(lineWidth * 10)
            guard hash != lastSkeletonHash else { return }
            lastSkeletonHash = hash

            view.scene.rootNode.childNode(
                withName: skeletonNodeName,
                recursively: true
            )?.removeFromParentNode()
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.red
            material.emission.contents = UIColor.red
            material.isDoubleSided = true
            let radius = CGFloat(max(0.1, min(lineWidth, 5))) * 0.0012
            let rootNode = SCNNode()
            rootNode.name = skeletonNodeName
            rootNode.renderingOrder = 100

            for group in groups where group.count >= 2 {
                var vertices: [SCNVector3] = []
                var indexByPoint: [CrackPoint: Int] = [:]
                for (index, point) in group.enumerated() {
                    vertices.append(
                        SCNVector3(
                            point.world.x,
                            point.world.y,
                            point.world.z
                        )
                    )
                    indexByPoint[point.pixel] = index
                }
                let maxPixel = group
                    .map { max($0.pixel.x, $0.pixel.y) }
                    .max() ?? 1024
                let neighborRadius = max(2, maxPixel / 160 + 2)
                var seenEdges = Set<Int>()
                for (point, index) in indexByPoint {
                    for dy in -neighborRadius...neighborRadius {
                        for dx in -neighborRadius...neighborRadius {
                            if dx == 0 && dy == 0 { continue }
                            let neighbor = CrackPoint(
                                x: point.x + dx,
                                y: point.y + dy
                            )
                            guard let neighborIndex = indexByPoint[neighbor] else {
                                continue
                            }
                            let edgeKey = index < neighborIndex
                                ? index * 100000 + neighborIndex
                                : neighborIndex * 100000 + index
                            guard !seenEdges.contains(edgeKey) else { continue }
                            seenEdges.insert(edgeKey)
                            let startVector = vertices[index]
                            let endVector = vertices[neighborIndex]
                            let start = SIMD3<Float>(
                                startVector.x,
                                startVector.y,
                                startVector.z
                            )
                            let end = SIMD3<Float>(
                                endVector.x,
                                endVector.y,
                                endVector.z
                            )
                            let delta = end - start
                            let length = simd_length(delta)
                            guard length > 0.0001 else { continue }
                            let cylinder = SCNCylinder(
                                radius: radius,
                                height: CGFloat(length)
                            )
                            cylinder.materials = [material]
                            let node = SCNNode(geometry: cylinder)
                            node.position = SCNVector3(
                                (start.x + end.x) / 2,
                                (start.y + end.y) / 2,
                                (start.z + end.z) / 2
                            )
                            let direction = delta / length
                            node.simdOrientation = simd_quatf(
                                from: SIMD3<Float>(0, 1, 0),
                                to: direction
                            )
                            rootNode.addChildNode(node)
                        }
                    }
                }
            }
            view.scene.rootNode.addChildNode(rootNode)
        }

        // MARK: - P0 闭环测试（screen -> world -> screen）

        @objc func handleReprojectionTap(
            _ recognizer: UITapGestureRecognizer
        ) {
            DispatchQueue.main.async {
                self.runReprojectionTest(recognizer: recognizer)
            }
        }

        private func runReprojectionTest(
            recognizer: UITapGestureRecognizer
        ) {
            guard let view = sceneView,
                  let frame = view.session.currentFrame,
                  view.bounds.width > 0,
                  view.bounds.height > 0 else {
                DispatchQueue.main.async {
                    self.cameraModel.updateReprojection(
                        errorPx: nil,
                        detail: "无 AR 帧"
                    )
                }
                return
            }
            let location = recognizer.location(in: view)
            let pose = flatten4(frame.camera.transform)
            let intrinsics = flatten3(frame.camera.intrinsics)
            let transform = frame.displayTransform(
                for: .portrait,
                viewportSize: view.bounds.size
            ).inverted()
            let normalized = CGPoint(
                x: location.x,
                y: location.y
            ).applying(transform)
            let sensorSize = CGSize(
                width: CGFloat(
                    CVPixelBufferGetWidth(frame.capturedImage)
                ),
                height: CGFloat(
                    CVPixelBufferGetHeight(frame.capturedImage)
                )
            )
            let sensorPixel = CGPoint(
                x: normalized.x * sensorSize.width,
                y: normalized.y * sensorSize.height
            )
            guard let ray = WallDefectProjection.cameraRay(
                pixel: sensorPixel,
                pose: pose,
                intrinsics: intrinsics
            ) else {
                DispatchQueue.main.async {
                    self.cameraModel.updateReprojection(
                        errorPx: nil,
                        detail: "相机射线失败"
                    )
                }
                return
            }
            let anchors = frame.anchors.compactMap {
                $0 as? ARMeshAnchor
            }
            guard let world = WallDefectProjection.rayMeshIntersection(
                rayOrigin: ray.origin,
                rayDirection: ray.direction,
                anchors: anchors,
                maxDistance: Float(meshMaxDistance)
            ) else {
                DispatchQueue.main.async {
                    self.cameraModel.updateReprojection(
                        errorPx: nil,
                        detail: "mesh 未命中（anchor \(self.anchorsCount(anchors))）"
                    )
                }
                return
            }
            guard let projected = WallDefectProjection.projectToScreen(
                world: world,
                pose: pose,
                intrinsics: intrinsics
            ) else {
                DispatchQueue.main.async {
                    self.cameraModel.updateReprojection(
                        errorPx: nil,
                        detail: "反投影失败"
                    )
                }
                return
            }
            let error = hypot(
                Double(projected.x - sensorPixel.x),
                Double(projected.y - sensorPixel.y)
            )
            let faceCount = anchors.reduce(0) {
                $0 + $1.geometry.faces.count
            }
            DispatchQueue.main.async {
                self.cameraModel.updateReprojection(
                    errorPx: error,
                    detail: String(
                        format: "screen→world→screen · mesh %d面 · 误差 %.1f px",
                        faceCount,
                        error
                    )
                )
            }
        }

        private func anchorsCount(_ anchors: [ARMeshAnchor]) -> Int {
            anchors.count
        }

        private func flatten4(_ matrix: simd_float4x4) -> [Float] {
            [
                matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
                matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
                matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
                matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
            ]
        }

        private func flatten3(_ matrix: simd_float3x3) -> [Float] {
            [
                matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z,
                matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z,
                matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z
            ]
        }
    }
}
