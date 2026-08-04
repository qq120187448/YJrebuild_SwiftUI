import SwiftUI
import SwiftData
import ARKit
import SceneKit
import simd

private enum CropBoxCommand: Equatable {
    case none
    case increase
    case decrease
    case clear
}

struct ObjectScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case instructions
        case scanning
        case results
    }

    @State private var phase: Phase = .instructions
    @State private var isCapturing = false
    @State private var pointCount = 0
    @State private var capturedPoints: [ObjectPoint] = []
    @State private var objectName = ""
    @State private var result: ObjectScanProcessResult?
    @State private var selectedClusterIndex = 0
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var shareURLs: [URL] = []

    @State private var isPlacingCropBox = false
    @State private var cropBoxPlaced = false
    @State private var cropBoxSize: Float = 1.0
    @State private var cropBoxCommand: CropBoxCommand = .none

    var body: some View {
        NavigationStack {
            Group {
                if !ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                    ContentUnavailableView(
                        "需要 LiDAR",
                        systemImage: "camera.metering.unknown",
                        description: Text("物体工程扫描需要带 LiDAR 的 iPhone Pro 或 iPad Pro。")
                    )
                } else {
                    switch phase {
                    case .instructions:
                        instructionsView
                    case .scanning:
                        scanningView
                    case .results:
                        if let result {
                            resultsView(result)
                        } else {
                            ProgressView("正在计算")
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .instructions {
                        Button("取消") { dismiss() }
                    } else if phase == .scanning {
                        Button("结束") { finishScan() }
                    }
                }
            }
            .alert("扫描出错", isPresented: .constant(errorMessage != nil)) {
                Button("好") {
                    errorMessage = nil
                    phase = .instructions
                }
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
            .sheet(isPresented: Binding(
                get: { !shareURLs.isEmpty },
                set: { if !$0 { shareURLs = [] } }
            )) {
                ActivityView(activityItems: shareURLs)
            }
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .instructions: return "物体工程扫描"
        case .scanning: return "扫描中"
        case .results: return "扫描结果"
        }
    }

    private var instructionsView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "cube.transparent")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            Text("物体工程扫描")
                .font(.title.bold())
            Text("扫描堆体、土方、中大型设备，在本机计算体积、表面积和外包围尺寸。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(alignment: .leading, spacing: 12) {
                tipRow(icon: "square.dashed", text: "先点击“放置裁剪盒”，再点击物体中心框选目标")
                tipRow(icon: "point.3.connected.trianglepath.dotted", text: "扫描中红色点云为实时覆盖示意")
                tipRow(icon: "hand.tap", text: "完成后自动剔除墙面地面，可在结果页选择目标点簇")
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                objectName = ""
                capturedPoints = []
                pointCount = 0
                selectedClusterIndex = 0
                isProcessing = false
                isPlacingCropBox = false
                cropBoxPlaced = false
                cropBoxSize = 1.0
                cropBoxCommand = .none
                isCapturing = true
                phase = .scanning
            } label: {
                Label("开始扫描", systemImage: "camera.metering.spot")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }

    private var scanningView: some View {
        ZStack {
            ObjectScanARView(
                isCapturing: $isCapturing,
                isPlacingCropBox: $isPlacingCropBox,
                cropBoxCommand: $cropBoxCommand,
                onPointCount: { count in
                    pointCount = count
                },
                onPointsCaptured: { points in
                    capturedPoints = points
                    processCapturedPoints()
                },
                onCropBoxPlaced: {
                    cropBoxPlaced = true
                    isPlacingCropBox = false
                },
                onCropBoxSizeChanged: { size in
                    cropBoxSize = size
                },
                onCropBoxCleared: {
                    cropBoxPlaced = false
                }
            )
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.white)
                    Text("点云 \(pointCount)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    if isProcessing {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(.top, 8)
                .padding(.horizontal, 16)

                Spacer()

                VStack(spacing: 10) {
                    Text(cropBoxStatusText)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())

                    HStack(spacing: 10) {
                        Button {
                            isPlacingCropBox = true
                        } label: {
                            Label(
                                isPlacingCropBox ? "点击物体中心" : "放置裁剪盒",
                                systemImage: "square.dashed"
                            )
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(isPlacingCropBox ? Color.orange : Color.accentColor)
                            .clipShape(Capsule())
                        }

                        if cropBoxPlaced {
                            Button {
                                cropBoxCommand = .decrease
                            } label: {
                                Image(systemName: "minus")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.accentColor)
                                    .clipShape(Circle())
                            }

                            Text("\(cropBoxSize, specifier: "%.1f") m")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)

                            Button {
                                cropBoxCommand = .increase
                            } label: {
                                Image(systemName: "plus")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.accentColor)
                                    .clipShape(Circle())
                            }

                            Button {
                                cropBoxCommand = .clear
                            } label: {
                                Image(systemName: "trash")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                        }
                    }
                }
                .padding(12)
                .background(.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 20)
            }
        }
    }

    private var cropBoxStatusText: String {
        if isPlacingCropBox {
            return "请点击画面中的物体中心，放置裁剪盒"
        }
        if cropBoxPlaced {
            return "拖动红/绿/蓝色球沿 X/Y/Z 移动裁剪盒，只计算盒内点云"
        }
        return "建议先放置裁剪盒，再围绕物体扫描"
    }

    private func resultsView(_ result: ObjectScanProcessResult) -> some View {
        let selected = selectedOption(result)
        return List {
            Section("3D 预览") {
                ObjectPointCloud3DView(points: selected.points)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if result.clusters.count > 1 {
                Section("目标点簇") {
                    Picker("目标点簇", selection: $selectedClusterIndex) {
                        ForEach(result.clusters.indices, id: \.self) { index in
                            Text("点簇 \(index + 1) · \(result.clusters[index].points.count) 点")
                                .tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("已自动剔除墙面、地面、天花板、门窗，选择要计算的目标点簇。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("对象") {
                TextField("对象名称", text: $objectName)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("原始点数", value: "\(selected.metrics.pointCount)")
                LabeledContent("处理点数", value: "\(selected.metrics.processedPointCount)")
                LabeledContent("目标点数", value: "\(selected.metrics.targetPointCount ?? selected.points.count)")
                LabeledContent("点簇数量", value: "\(selected.metrics.clusterCount ?? 1)")
                LabeledContent(
                    "AABB 外包围尺寸",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        selected.metrics.aabb.sizeX,
                        selected.metrics.aabb.sizeY,
                        selected.metrics.aabb.sizeZ
                    )
                )
                LabeledContent(
                    "OBB 长×宽×高",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        selected.metrics.obbLengthM ?? 0,
                        selected.metrics.obbWidthM ?? 0,
                        selected.metrics.obbHeightM ?? 0
                    )
                )
            }

            Section("堆体/土方（高度场）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", selected.metrics.heightfieldVolumeM3)
                )
                LabeledContent(
                    "表面积",
                    value: String(format: "%.3f m²", selected.metrics.heightfieldSurfaceAreaM2)
                )
            }

            Section("设备（凸包）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", selected.metrics.convexHullVolumeM3)
                )
                LabeledContent(
                    "表面积",
                    value: String(format: "%.3f m²", selected.metrics.convexHullSurfaceAreaM2)
                )
            }

            Section {
                Button {
                    saveRecord(result)
                } label: {
                    Label("保存记录", systemImage: "square.and.arrow.down")
                }
                Button {
                    exportFiles(result)
                } label: {
                    Label("导出 PLY / USDZ / JSON", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func selectedOption(_ result: ObjectScanProcessResult) -> ObjectScanClusterOption {
        let index = min(max(selectedClusterIndex, 0), result.clusters.count - 1)
        return result.clusters[index]
    }

    private func processCapturedPoints() {
        guard !capturedPoints.isEmpty else {
            errorMessage = "没有采集到有效点云，请重新扫描"
            phase = .instructions
            return
        }
        isProcessing = true
        selectedClusterIndex = 0
        let points = capturedPoints
        Task.detached(priority: .userInitiated) {
            do {
                let processed = try ObjectScanProcessor.process(points: points)
                await MainActor.run {
                    self.result = processed
                    self.isProcessing = false
                    self.phase = .results
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                    self.phase = .instructions
                }
            }
        }
    }

    private func finishScan() {
        isCapturing = false
        isProcessing = true
    }

    private func saveRecord(_ result: ObjectScanProcessResult) {
        let option = selectedOption(result)
        let metrics = option.metrics
        let name = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "物体 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))" : name
        let record = ObjectScanRecord(
            objectName: finalName,
            pointCount: metrics.pointCount,
            processedPointCount: metrics.processedPointCount,
            targetPointCount: metrics.targetPointCount ?? option.points.count,
            clusterCount: metrics.clusterCount ?? 1,
            obbLengthM: metrics.obbLengthM ?? 0,
            obbWidthM: metrics.obbWidthM ?? 0,
            obbHeightM: metrics.obbHeightM ?? 0,
            heightfieldVolumeM3: metrics.heightfieldVolumeM3,
            heightfieldSurfaceAreaM2: metrics.heightfieldSurfaceAreaM2,
            convexHullVolumeM3: metrics.convexHullVolumeM3,
            convexHullSurfaceAreaM2: metrics.convexHullSurfaceAreaM2,
            metricsJSON: (try? JSONEncoder().encode(metrics)) ?? Data(),
            plyData: ObjectScanProcessor.plyData(points: option.points),
            usdzData: option.usdzData,
            pointsJSON: (try? JSONEncoder().encode(option.points)) ?? Data()
        )
        modelContext.insert(record)
        try? modelContext.save()
        dismiss()
    }

    private func exportFiles(_ result: ObjectScanProcessResult) {
        let option = selectedOption(result)
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ObjectScan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = directory.appendingPathComponent("object-scan")
            let plyURL = base.appendingPathExtension("ply")
            let jsonURL = base.appendingPathExtension("json")
            try ObjectScanProcessor.plyData(points: option.points).write(to: plyURL)
            try JSONEncoder().encode(option.metrics).write(to: jsonURL)
            var urls = [plyURL, jsonURL]
            if let usdzData = option.usdzData {
                let usdzURL = base.appendingPathExtension("usdz")
                try usdzData.write(to: usdzURL)
                urls.append(usdzURL)
            }
            shareURLs = urls
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ObjectScanARView: UIViewControllerRepresentable {
    @Binding var isCapturing: Bool
    @Binding var isPlacingCropBox: Bool
    @Binding var cropBoxCommand: CropBoxCommand

    let onPointCount: (Int) -> Void
    let onPointsCaptured: ([ObjectPoint]) -> Void
    let onCropBoxPlaced: () -> Void
    let onCropBoxSizeChanged: (Float) -> Void
    let onCropBoxCleared: () -> Void

    func makeUIViewController(context: Context) -> ObjectScanARViewController {
        let controller = ObjectScanARViewController()
        controller.onPointCount = onPointCount
        controller.onPointsCaptured = onPointsCaptured
        controller.onCropBoxPlaced = onCropBoxPlaced
        controller.onCropBoxSizeChanged = onCropBoxSizeChanged
        controller.onCropBoxCleared = onCropBoxCleared
        return controller
    }

    func updateUIViewController(_ uiViewController: ObjectScanARViewController, context: Context) {
        uiViewController.isPlacingCropBox = isPlacingCropBox
        uiViewController.onPointCount = onPointCount
        uiViewController.onPointsCaptured = onPointsCaptured
        uiViewController.onCropBoxPlaced = onCropBoxPlaced
        uiViewController.onCropBoxSizeChanged = onCropBoxSizeChanged
        uiViewController.onCropBoxCleared = onCropBoxCleared

        switch cropBoxCommand {
        case .none:
            break
        case .increase:
            uiViewController.adjustCropBoxSize(delta: 0.2)
        case .decrease:
            uiViewController.adjustCropBoxSize(delta: -0.2)
        case .clear:
            uiViewController.clearCropBox()
        }
        if cropBoxCommand != .none {
            DispatchQueue.main.async {
                cropBoxCommand = .none
            }
        }

        if isCapturing {
            uiViewController.startCapturing()
        } else {
            uiViewController.stopCapturing()
        }
    }
}

private final class ObjectScanARViewController: UIViewController, ARSessionDelegate {
    var onPointCount: ((Int) -> Void)?
    var onPointsCaptured: (([ObjectPoint]) -> Void)?
    var onCropBoxPlaced: (() -> Void)?
    var onCropBoxSizeChanged: ((Float) -> Void)?
    var onCropBoxCleared: (() -> Void)?

    var isPlacingCropBox = false

    private let sceneView = ARSCNView()
    private var isCapturing = false
    private var didDeliver = false
    private var frameCount = 0
    private let voxelSize: Float = 0.02
    private let maxVoxels = 600_000
    private var voxelMap: [Int64: VoxelAccumulator] = [:]
    private var cropBoxSize: Float = 1.0
    private var cropBoxCenter: SIMD3<Float>?
    private var cropBoxNode: SCNNode?

    private struct VoxelAccumulator {
        var sum = SIMD3<Float>.zero
        var sumColor = SIMD3<Float>.zero
        var count: Float = 0
        var backgroundCount: Float = 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(sceneView)
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session.delegate = self
        sceneView.rendersContinuously = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        sceneView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        sceneView.addGestureRecognizer(pan)

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        sceneView.session.run(configuration)
    }

    func startCapturing() {
        if didDeliver {
            voxelMap.removeAll()
            frameCount = 0
            didDeliver = false
        }
        isCapturing = true
    }

    func stopCapturing() {
        guard isCapturing else { return }
        isCapturing = false
        deliverPoints()
    }

    private func deliverPoints() {
        guard !didDeliver else { return }
        didDeliver = true
        let points = snapshotPoints()
        DispatchQueue.main.async {
            self.onPointCount?(points.count)
            self.onPointsCaptured?(points)
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard isPlacingCropBox, recognizer.state == .ended else { return }
        placeCropBox(at: recognizer.location(in: sceneView))
    }

    private var dragAxis: SIMD3<Float>?
    private var dragStartCenter: SIMD3<Float>?
    private var dragStartScreen: CGPoint?
    private var dragDepth: Float = 0

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: sceneView)
        switch recognizer.state {
        case .began:
            guard let hit = sceneView.hitTest(
                location,
                options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]
            ).first, let name = hit.node.name else {
                return
            }
            let axis: SIMD3<Float>?
            switch name {
            case "axisX": axis = SIMD3<Float>(1, 0, 0)
            case "axisY": axis = SIMD3<Float>(0, 1, 0)
            case "axisZ": axis = SIMD3<Float>(0, 0, 1)
            default: axis = nil
            }
            guard let axis,
                  let center = cropBoxCenter,
                  let frame = sceneView.session.currentFrame else {
                return
            }
            dragAxis = axis
            dragStartCenter = center
            dragStartScreen = location
            let cameraPosition = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            dragDepth = max(simd_length(center - cameraPosition), 0.1)

        case .changed:
            guard let axis = dragAxis,
                  let startCenter = dragStartCenter,
                  let start = dragStartScreen,
                  let frame = sceneView.session.currentFrame else {
                return
            }
            let viewport = sceneView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            let dx = Float(location.x - start.x)
            let dy = Float(location.y - start.y)
            let imageWidth = Float(frame.camera.imageResolution.width)
            let imageHeight = Float(frame.camera.imageResolution.height)
            let fx = frame.camera.intrinsics.columns.0.x * Float(viewport.width) / imageWidth
            let fy = frame.camera.intrinsics.columns.1.y * Float(viewport.height) / imageHeight
            let localDelta = SIMD3<Float>(
                dx * dragDepth / fx,
                -dy * dragDepth / fy,
                0
            )
            let worldDelta4 = frame.camera.transform * SIMD4<Float>(
                localDelta.x,
                localDelta.y,
                localDelta.z,
                0
            )
            let worldDelta = SIMD3<Float>(worldDelta4.x, worldDelta4.y, worldDelta4.z)
            let amount = simd_dot(worldDelta, axis)
            cropBoxCenter = startCenter + axis * amount
            updateCropBoxNode()

        case .ended, .cancelled:
            if dragAxis != nil {
                filterVoxelMapToCropBox()
            }
            dragAxis = nil
            dragStartCenter = nil
            dragStartScreen = nil

        default:
            break
        }
    }

    func placeCropBox(at point: CGPoint) {
        guard let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .horizontal),
              let result = sceneView.session.raycast(query).first else {
            return
        }
        let transform = result.worldTransform
        let hit = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        cropBoxCenter = hit + SIMD3<Float>(0, cropBoxSize * 0.5, 0)
        voxelMap.removeAll()
        frameCount = 0
        updateCropBoxNode()
        isPlacingCropBox = false
        onCropBoxPlaced?()
        onCropBoxSizeChanged?(cropBoxSize)
    }

    func adjustCropBoxSize(delta: Float) {
        cropBoxSize = min(max(cropBoxSize + delta, 0.4), 5.0)
        updateCropBoxNode()
        onCropBoxSizeChanged?(cropBoxSize)
    }

    func clearCropBox() {
        cropBoxCenter = nil
        cropBoxNode?.removeFromParentNode()
        cropBoxNode = nil
        voxelMap.removeAll()
        frameCount = 0
        sceneView.scene.rootNode.childNodes
            .filter { $0.name == "scanPoints" }
            .forEach { $0.removeFromParentNode() }
        onCropBoxCleared?()
    }

    private func updateCropBoxNode() {
        cropBoxNode?.removeFromParentNode()
        cropBoxNode = nil
        guard let center = cropBoxCenter else { return }
        let size = CGFloat(cropBoxSize)
        let half = cropBoxSize * 0.5

        let root = SCNNode()
        root.name = "cropBox"
        root.position = SCNVector3(center.x, center.y, center.z)

        let fill = SCNBox(width: size, height: size, length: size, chamferRadius: 0)
        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.16)
        fillMaterial.emission.contents = UIColor.systemGreen.withAlphaComponent(0.22)
        fillMaterial.isDoubleSided = true
        fill.firstMaterial = fillMaterial
        root.addChildNode(SCNNode(geometry: fill))

        let wire = SCNBox(width: size, height: size, length: size, chamferRadius: 0)
        let wireMaterial = SCNMaterial()
        wireMaterial.lightingModel = .constant
        wireMaterial.diffuse.contents = UIColor.systemGreen
        wireMaterial.emission.contents = UIColor.systemGreen
        wireMaterial.fillMode = .lines
        wire.firstMaterial = wireMaterial
        root.addChildNode(SCNNode(geometry: wire))

        addAxisHandles(to: root, half: half)
        sceneView.scene.rootNode.addChildNode(root)
        cropBoxNode = root
    }

    private func addAxisHandles(to root: SCNNode, half: Float) {
        let axes: [(SIMD3<Float>, UIColor, String)] = [
            (SIMD3<Float>(1, 0, 0), .systemRed, "axisX"),
            (SIMD3<Float>(0, 1, 0), .systemGreen, "axisY"),
            (SIMD3<Float>(0, 0, 1), .systemBlue, "axisZ")
        ]
        for (axis, color, name) in axes {
            let sphere = SCNSphere(radius: 0.04)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.emission.contents = color
            sphere.firstMaterial = material
            let handle = SCNNode(geometry: sphere)
            handle.name = name
            handle.position = SCNVector3(axis.x * half, axis.y * half, axis.z * half)
            root.addChildNode(handle)

            let line = SCNBox(
                width: CGFloat(axis.x != 0 ? half : 0.008),
                height: CGFloat(axis.y != 0 ? half : 0.008),
                length: CGFloat(axis.z != 0 ? half : 0.008),
                chamferRadius: 0
            )
            let lineMaterial = SCNMaterial()
            lineMaterial.lightingModel = .constant
            lineMaterial.diffuse.contents = color.withAlphaComponent(0.9)
            lineMaterial.emission.contents = color.withAlphaComponent(0.9)
            line.firstMaterial = lineMaterial
            let lineNode = SCNNode(geometry: line)
            lineNode.position = SCNVector3(
                axis.x * half * 0.5,
                axis.y * half * 0.5,
                axis.z * half * 0.5
            )
            root.addChildNode(lineNode)
        }
    }

    private func filterVoxelMapToCropBox() {
        guard let center = cropBoxCenter else { return }
        let half = cropBoxSize * 0.5
        var filtered: [Int64: VoxelAccumulator] = [:]
        for (key, accumulator) in voxelMap {
            let inv = 1 / max(accumulator.count, 1)
            let position = accumulator.sum * inv
            if abs(position.x - center.x) <= half
                && abs(position.y - center.y) <= half
                && abs(position.z - center.z) <= half {
                filtered[key] = accumulator
            }
        }
        voxelMap = filtered
    }

    private func pointInsideCropBox(_ world: SIMD3<Float>) -> Bool {
        guard let center = cropBoxCenter else { return true }
        let half = cropBoxSize * 0.5
        return abs(world.x - center.x) <= half
            && abs(world.y - center.y) <= half
            && abs(world.z - center.z) <= half
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCapturing else { return }
        frameCount += 1
        guard frameCount % 10 == 0 else { return }

        captureMeshPoints(from: frame)
        let snapshot = snapshotPoints()
        DispatchQueue.main.async {
            self.updatePointCloud(snapshot)
            self.onPointCount?(snapshot.count)
        }
    }

    private func captureMeshPoints(from frame: ARFrame) {
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let geometry = mesh.geometry
            let vertexSource = geometry.vertices
            let vertexCount = vertexSource.count
            guard vertexCount > 0 else { continue }

            let base = vertexSource.buffer.contents()
            let stride = vertexSource.stride
            let offset = vertexSource.offset

            var classificationBuffer: UnsafeRawPointer?
            var classificationStride = 0
            var classificationOffset = 0
            if let classificationSource = geometry.classification {
                classificationBuffer = UnsafeRawPointer(classificationSource.buffer.contents())
                classificationStride = classificationSource.stride
                classificationOffset = classificationSource.offset
            }

            for i in 0..<vertexCount {
                let local = (base + offset + i * stride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world4 = mesh.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                guard pointInsideCropBox(world) else { continue }

                let key = voxelKey(world)
                if voxelMap[key] == nil && voxelMap.count >= maxVoxels { continue }

                var classification: Int?
                var color = SIMD3<Float>(0.95, 0.55, 0.2)
                if let classificationBuffer {
                    let raw = classificationBuffer.load(
                        fromByteOffset: classificationOffset + i * classificationStride,
                        as: UInt8.self
                    )
                    classification = Int(raw)
                    color = classificationColor(ARMeshClassification(rawValue: Int(raw)))
                }

                var accumulator = voxelMap[key] ?? VoxelAccumulator()
                accumulator.sum += world
                accumulator.sumColor += color
                if let classification, ObjectScanProcessor.isBackgroundClassification(classification) {
                    accumulator.backgroundCount += 1
                }
                accumulator.count += 1
                voxelMap[key] = accumulator
            }
        }
    }

    private func classificationColor(_ classification: ARMeshClassification?) -> SIMD3<Float> {
        switch classification {
        case .floor: return SIMD3<Float>(0.55, 0.55, 0.55)
        case .wall: return SIMD3<Float>(0.35, 0.55, 0.85)
        case .ceiling: return SIMD3<Float>(0.88, 0.9, 0.93)
        case .table: return SIMD3<Float>(0.72, 0.5, 0.3)
        case .seat: return SIMD3<Float>(0.3, 0.72, 0.48)
        case .window: return SIMD3<Float>(0.35, 0.78, 0.9)
        case .door: return SIMD3<Float>(0.8, 0.5, 0.25)
        default: return SIMD3<Float>(0.95, 0.55, 0.2)
        }
    }

    private func snapshotPoints() -> [ObjectPoint] {
        voxelMap.values.map { accumulator -> ObjectPoint in
            let inv = 1 / max(accumulator.count, 1)
            let position = accumulator.sum * inv
            let color = accumulator.sumColor * inv
            let isBackground = accumulator.backgroundCount >= accumulator.count
            return ObjectPoint(
                x: position.x,
                y: position.y,
                z: position.z,
                r: color.x,
                g: color.y,
                b: color.z,
                classification: isBackground ? 2 : nil
            )
        }
    }

    private func updatePointCloud(_ points: [ObjectPoint]) {
        guard !points.isEmpty else { return }
        let displayPoints = points.map {
            ObjectPoint(x: $0.x, y: $0.y, z: $0.z, r: 1, g: 1, b: 1)
        }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 1, green: 0.08, blue: 0.06, alpha: 1)
        material.emission.contents = UIColor(red: 1, green: 0.08, blue: 0.06, alpha: 1)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        let geometry = SCNGeometry.objectPointCloud(
            points: displayPoints,
            worldPointSize: 0.03,
            minScreenRadius: 12,
            maxScreenRadius: 48,
            material: material
        )
        let node = SCNNode(geometry: geometry)
        node.name = "scanPoints"
        sceneView.scene.rootNode.childNodes
            .filter { $0.name == "scanPoints" }
            .forEach { $0.removeFromParentNode() }
        sceneView.scene.rootNode.addChildNode(node)
    }

    private func voxelKey(_ position: SIMD3<Float>) -> Int64 {
        let ix = Int64(floor(position.x / voxelSize))
        let iy = Int64(floor(position.y / voxelSize))
        let iz = Int64(floor(position.z / voxelSize))
        return ((ix + 0x80000) & 0xFFFFF) | (((iy + 0x80000) & 0xFFFFF) << 20) | (((iz + 0x80000) & 0xFFFFF) << 40)
    }
}
