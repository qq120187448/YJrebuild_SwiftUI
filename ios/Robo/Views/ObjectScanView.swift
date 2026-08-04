import SwiftUI
import SwiftData
import ARKit
import SceneKit
import simd

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
    @State private var showDiscardConfirm = false

    @State private var cropVolume: ObjectCropVolume?
    @State private var isPlacingCropBox = false
    @State private var boxMetrics: ObjectScanMetrics?
    @State private var isComputingBoxMetrics = false
    @State private var pointSize: Double = ObjectScanSettings.pointSize
    @State private var scanIsPlacingCropBox = false
    @State private var scanCropBoxPlaced = false
    @State private var scanCropBoxSize: Float = 1.0
    @State private var scanClearCropBox = false

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
                tipRow(icon: "point.3.connected.trianglepath.dotted", text: "围绕物体缓慢移动，让 ARKit 网格覆盖全部表面")
                tipRow(icon: "square.dashed", text: "扫描完成后在结果页放置裁剪盒，可一次扫描多次计算")
                tipRow(icon: "hand.tap", text: "拖动红色/绿色/蓝色箭头调整 X/Y/Z 三向尺寸")
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                objectName = ""
                capturedPoints = []
                pointCount = 0
                selectedClusterIndex = 0
                isProcessing = false
                cropVolume = nil
                isPlacingCropBox = false
                boxMetrics = nil
                scanIsPlacingCropBox = false
                scanCropBoxPlaced = false
                scanCropBoxSize = 1.0
                scanClearCropBox = false
                pointSize = ObjectScanSettings.pointSize
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
                pointSize: $pointSize,
                isPlacingCropBox: $scanIsPlacingCropBox,
                cropBoxSize: $scanCropBoxSize,
                clearRequested: $scanClearCropBox,
                onPointCount: { count in
                    pointCount = count
                },
                onPointsCaptured: { points in
                    capturedPoints = points
                    processCapturedPoints()
                },
                onCropBoxPlaced: {
                    scanCropBoxPlaced = true
                    scanIsPlacingCropBox = false
                },
                onCropBoxCleared: {
                    scanCropBoxPlaced = false
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
                    Text(scanCropBoxStatusText)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())

                    HStack(spacing: 10) {
                        Button {
                            scanIsPlacingCropBox = true
                        } label: {
                            Label(
                                scanIsPlacingCropBox
                                    ? "点击物体中心"
                                    : (scanCropBoxPlaced ? "重新放置裁剪盒" : "放置裁剪盒"),
                                systemImage: "square.dashed"
                            )
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(scanIsPlacingCropBox ? Color.orange : Color.accentColor)
                            .clipShape(Capsule())
                        }

                        if scanCropBoxPlaced {
                            VStack(spacing: 4) {
                                Slider(value: $scanCropBoxSize, in: 0.2...10, step: 0.1)
                                    .frame(width: 140)
                                HStack {
                                    Text("\(scanCropBoxSize, specifier: "%.1f") m")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Button {
                                        scanCropBoxPlaced = false
                                        scanIsPlacingCropBox = false
                                        scanClearCropBox = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private var scanCropBoxStatusText: String {
        if scanIsPlacingCropBox {
            return "请点击画面中的物体中心放置裁剪盒"
        }
        if scanCropBoxPlaced {
            return "单指箭头调尺寸 · 单指拖盒子旋转 · 双指移动 · 捏合缩放"
        }
        return "扫描采集全部点云，盒子仅用于预览；结果页可再裁剪计算"
    }

    private func resultsView(_ result: ObjectScanProcessResult) -> some View {
        let current = currentPointsAndMetrics(result)
        return List {
            Section("3D 预览与裁剪") {
                ObjectCropBox3DView(
                    points: sampled(result.allPoints, limit: 80_000),
                    cropVolume: cropVolume,
                    isPlacing: isPlacingCropBox,
                    onCropVolumeChanged: { volume in
                        cropVolume = volume
                        if volume != nil {
                            isPlacingCropBox = false
                        }
                        if volume == nil {
                            boxMetrics = nil
                        }
                    },
                    onCropBoxEditEnded: { volume in
                        recomputeBoxMetrics(for: volume)
                    }
                )
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                HStack(spacing: 10) {
                    Button {
                        isPlacingCropBox = true
                    } label: {
                        Label(
                            isPlacingCropBox
                                ? "点击地面放置"
                                : (cropVolume == nil ? "放置裁剪盒" : "重新放置裁剪盒"),
                            systemImage: "square.dashed"
                        )
                        .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)

                    if cropVolume != nil {
                        Button {
                            cropVolume = nil
                            boxMetrics = nil
                            isPlacingCropBox = false
                        } label: {
                            Label("清除裁剪盒", systemImage: "trash")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                    }

                    if isComputingBoxMetrics {
                        ProgressView()
                    }
                }

                if cropVolume != nil {
                    Text(isPlacingCropBox
                        ? "点击地面重新放置裁剪盒。"
                        : "点选裁剪盒后拖动红/绿/蓝色箭头调整 X/Y/Z 尺寸；未选中时手势控制整个模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if result.clusters.count > 1 && cropVolume == nil {
                Section("目标点簇") {
                    Picker("目标点簇", selection: $selectedClusterIndex) {
                        ForEach(result.clusters.indices, id: \.self) { index in
                            Text("点簇 \(index + 1) · \(result.clusters[index].points.count) 点")
                                .tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("未放置裁剪盒时使用所选点簇计算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("对象") {
                TextField("对象名称", text: $objectName)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("原始点数", value: "\(current.metrics.pointCount)")
                LabeledContent("目标点数", value: "\(current.metrics.targetPointCount ?? current.points.count)")
                LabeledContent("点簇数量", value: "\(current.metrics.clusterCount ?? 1)")
                LabeledContent(
                    "AABB 外包围尺寸",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        current.metrics.aabb.sizeX,
                        current.metrics.aabb.sizeY,
                        current.metrics.aabb.sizeZ
                    )
                )
                LabeledContent(
                    "OBB 长×宽×高",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        current.metrics.obbLengthM ?? 0,
                        current.metrics.obbWidthM ?? 0,
                        current.metrics.obbHeightM ?? 0
                    )
                )
                LabeledContent(
                    "占地面积",
                    value: String(format: "%.2f m²", current.metrics.footprintAreaM2 ?? 0)
                )
            }

            Section("堆体/土方（高度场）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", current.metrics.heightfieldVolumeM3)
                )
                LabeledContent(
                    "表面积",
                    value: String(format: "%.3f m²", current.metrics.heightfieldSurfaceAreaM2)
                )
            }

            Section("设备（凸包）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", current.metrics.convexHullVolumeM3)
                )
                LabeledContent(
                    "表面积",
                    value: String(format: "%.3f m²", current.metrics.convexHullSurfaceAreaM2)
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
                    Label("导出 Excel / PLY / USDZ / JSON", systemImage: "square.and.arrow.up")
                }
                Button("不保存退出", role: .destructive) {
                    showDiscardConfirm = true
                }
            }
        }
        .confirmationDialog("放弃本次扫描？", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("不保存并退出", role: .destructive) {
                dismiss()
            }
            Button("继续", role: .cancel) {}
        } message: {
            Text("当前扫描结果不会保存到历史记录。")
        }
    }

    private func currentPointsAndMetrics(
        _ result: ObjectScanProcessResult
    ) -> (points: [ObjectPoint], metrics: ObjectScanMetrics) {
        if let boxMetrics, let cropVolume {
            let filtered = result.allPoints.filter {
                cropVolume.contains(worldPoint: $0.position)
            }
            return (filtered, boxMetrics)
        }
        let option = selectedOption(result)
        return (option.points, option.metrics)
    }

    private func selectedOption(_ result: ObjectScanProcessResult) -> ObjectScanClusterOption {
        let index = min(max(selectedClusterIndex, 0), result.clusters.count - 1)
        return result.clusters[index]
    }

    private func sampled(_ points: [ObjectPoint], limit: Int) -> [ObjectPoint] {
        guard points.count > limit else { return points }
        let stride = max(points.count / limit, 1)
        var result: [ObjectPoint] = []
        result.reserveCapacity(limit)
        var index = 0
        while index < points.count {
            result.append(points[index])
            index += stride
        }
        return result
    }

    private func recomputeBoxMetrics(for volume: ObjectCropVolume) {
        guard let result else { return }
        isComputingBoxMetrics = true
        let filtered = result.allPoints.filter {
            volume.contains(worldPoint: $0.position)
        }
        Task.detached(priority: .userInitiated) {
            let metrics = ObjectScanProcessor.metrics(for: filtered)
            await MainActor.run {
                self.boxMetrics = metrics
                self.isComputingBoxMetrics = false
            }
        }
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
        let current = currentPointsAndMetrics(result)
        let metrics = current.metrics
        let name = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "物体 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))" : name
        let record = ObjectScanRecord(
            objectName: finalName,
            pointCount: metrics.pointCount,
            processedPointCount: metrics.processedPointCount,
            targetPointCount: metrics.targetPointCount ?? current.points.count,
            clusterCount: metrics.clusterCount ?? 1,
            obbLengthM: metrics.obbLengthM ?? 0,
            obbWidthM: metrics.obbWidthM ?? 0,
            obbHeightM: metrics.obbHeightM ?? 0,
            heightfieldVolumeM3: metrics.heightfieldVolumeM3,
            heightfieldSurfaceAreaM2: metrics.heightfieldSurfaceAreaM2,
            convexHullVolumeM3: metrics.convexHullVolumeM3,
            convexHullSurfaceAreaM2: metrics.convexHullSurfaceAreaM2,
            metricsJSON: (try? JSONEncoder().encode(metrics)) ?? Data(),
            plyData: ObjectScanProcessor.plyData(points: current.points),
            usdzData: cropVolume == nil
                ? selectedOption(result).usdzData
                : ObjectScanProcessor.convexHull(current.points).usdzData,
            pointsJSON: (try? JSONEncoder().encode(current.points)) ?? Data()
        )
        modelContext.insert(record)
        try? modelContext.save()
        dismiss()
    }

    private func exportFiles(_ result: ObjectScanProcessResult) {
        let current = currentPointsAndMetrics(result)
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ObjectScan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = directory.appendingPathComponent("object-scan")
            let plyURL = base.appendingPathExtension("ply")
            let jsonURL = base.appendingPathExtension("json")
            try ObjectScanProcessor.plyData(points: current.points).write(to: plyURL)
            try JSONEncoder().encode(current.metrics).write(to: jsonURL)

            let thumbnail = ObjectPointCloud3DView.thumbnail(points: current.points)
            let excelURL = try ObjectScanExporter.makeExcelFile(
                input: ObjectScanExporter.Input(
                    objectName: objectName.isEmpty ? "物体扫描" : objectName,
                    capturedAt: Date(),
                    metrics: current.metrics,
                    rawPointCount: current.metrics.pointCount,
                    thumbnail: thumbnail
                )
            )

            var urls = [excelURL, plyURL, jsonURL]
            let usdzData = cropVolume == nil
                ? selectedOption(result).usdzData
                : ObjectScanProcessor.convexHull(current.points).usdzData
            if let usdzData {
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
    @Binding var pointSize: Double
    @Binding var isPlacingCropBox: Bool
    @Binding var cropBoxSize: Float
    @Binding var clearRequested: Bool

    let onPointCount: (Int) -> Void
    let onPointsCaptured: ([ObjectPoint]) -> Void
    let onCropBoxPlaced: () -> Void
    let onCropBoxCleared: () -> Void

    func makeUIViewController(context: Context) -> ObjectScanARViewController {
        let controller = ObjectScanARViewController()
        controller.onPointCount = onPointCount
        controller.onPointsCaptured = onPointsCaptured
        controller.pointSize = pointSize
        controller.isPlacingCropBox = isPlacingCropBox
        controller.cropBoxSize = cropBoxSize
        controller.onCropBoxPlaced = onCropBoxPlaced
        controller.onCropBoxCleared = onCropBoxCleared
        if clearRequested {
            controller.clearCropBox()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: ObjectScanARViewController, context: Context) {
        uiViewController.onPointCount = onPointCount
        uiViewController.onPointsCaptured = onPointsCaptured
        uiViewController.pointSize = pointSize
        uiViewController.isPlacingCropBox = isPlacingCropBox
        uiViewController.setCropBoxSize(cropBoxSize)
        uiViewController.onCropBoxPlaced = onCropBoxPlaced
        uiViewController.onCropBoxCleared = onCropBoxCleared
        if clearRequested {
            uiViewController.clearCropBox()
            DispatchQueue.main.async {
                clearRequested = false
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
    var onCropBoxCleared: (() -> Void)?
    var pointSize: Double = 1.5
    var isPlacingCropBox = false
    var cropBoxSize: Float = 1.0

    private let sceneView = ARSCNView()
    private var isCapturing = false
    private var didDeliver = false
    private var frameCount = 0
    private var voxelSize: Float = 0.02
    private let maxVoxels = 200_000
    private var voxelMap: [Int64: VoxelAccumulator] = [:]
    private var cropVolume: ObjectCropVolume?
    private var cropBoxNode: SCNNode?

    private enum DragMode {
        case resize
        case rotate
    }

    private var dragMode: DragMode?
    private var dragAxis: SIMD3<Float>?
    private var dragStartScreen: CGPoint?
    private var dragStartCenter: SIMD3<Float>?
    private var dragStartExtent: SIMD3<Float>?
    private var dragDepth: Float = 0
    private var rotateStartScreen: CGPoint?
    private var rotateStartTransform: simd_float4x4?
    private var moveStartScreen: CGPoint?
    private var moveStartCenter: SIMD3<Float>?
    private var moveStartDepth: Float = 0
    private var scaleStartExtent: SIMD3<Float>?

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
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        sceneView.addGestureRecognizer(pan)

        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        movePan.minimumNumberOfTouches = 2
        movePan.maximumNumberOfTouches = 2
        movePan.cancelsTouchesInView = false
        sceneView.addGestureRecognizer(movePan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        sceneView.addGestureRecognizer(pinch)

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

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard cropVolume != nil, !isPlacingCropBox else { return }
        let location = recognizer.location(in: sceneView)
        switch recognizer.state {
        case .began:
            guard let volume = cropVolume else {
                return
            }
            if let hit = arrowHit(at: location),
               let name = axisName(from: hit),
               let axis = axis(for: name) {
                dragMode = .resize
                dragAxis = axis
                dragStartScreen = location
                dragStartCenter = volume.center
                dragStartExtent = volume.extent
                let cameraPosition = SIMD3<Float>(
                    sceneView.session.currentFrame?.camera.transform.columns.3.x ?? 0,
                    sceneView.session.currentFrame?.camera.transform.columns.3.y ?? 0,
                    sceneView.session.currentFrame?.camera.transform.columns.3.z ?? 0
                )
                dragDepth = max(simd_length(volume.center - cameraPosition), 0.1)
            } else {
                dragMode = .rotate
                rotateStartScreen = location
                rotateStartTransform = volume.transform
            }

        case .changed:
            if dragMode == .resize {
                handleResizeChange(location: location)
            } else if dragMode == .rotate {
                handleRotateChange(location: location)
            }

        case .ended, .cancelled:
            dragMode = nil
            dragAxis = nil
            dragStartScreen = nil
            dragStartCenter = nil
            dragStartExtent = nil
            rotateStartScreen = nil
            rotateStartTransform = nil

        default:
            break
        }
    }

    @objc private func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
        guard cropVolume != nil, !isPlacingCropBox else { return }
        let location = recognizer.location(in: sceneView)
        switch recognizer.state {
        case .began:
            guard let volume = cropVolume,
                  let cameraNode = sceneView.pointOfView else {
                return
            }
            moveStartScreen = location
            moveStartCenter = volume.center
            let cameraPosition = SIMD3<Float>(
                cameraNode.simdTransform.columns.3.x,
                cameraNode.simdTransform.columns.3.y,
                cameraNode.simdTransform.columns.3.z
            )
            moveStartDepth = max(simd_length(volume.center - cameraPosition), 0.1)

        case .changed:
            guard let start = moveStartScreen,
                  let startCenter = moveStartCenter,
                  let cameraNode = sceneView.pointOfView,
                  let volume = cropVolume else {
                return
            }
            let viewport = sceneView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            let dx = Float(location.x - start.x)
            let dy = Float(location.y - start.y)
            let worldDelta = worldDeltaFromScreen(
                dx: dx,
                dy: dy,
                cameraNode: cameraNode,
                center: startCenter,
                viewport: viewport,
                depth: moveStartDepth
            )
            let newCenter = startCenter + worldDelta
            var transform = volume.transform
            transform.columns.3 = SIMD4<Float>(
                newCenter.x,
                newCenter.y,
                newCenter.z,
                1
            )
            cropVolume = ObjectCropVolume(
                center: newCenter,
                extent: volume.extent,
                transform: transform
            )
            updateCropBoxNode()

        case .ended, .cancelled:
            moveStartScreen = nil
            moveStartCenter = nil

        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard cropVolume != nil, !isPlacingCropBox else { return }
        switch recognizer.state {
        case .began:
            scaleStartExtent = cropVolume?.extent
        case .changed:
            guard let startExtent = scaleStartExtent,
                  let volume = cropVolume else {
                return
            }
            let scale = Float(recognizer.scale)
            let newExtent = SIMD3<Float>(
                min(max(startExtent.x * scale, 0.2), 10),
                min(max(startExtent.y * scale, 0.2), 10),
                min(max(startExtent.z * scale, 0.2), 10)
            )
            cropVolume = ObjectCropVolume(
                center: volume.center,
                extent: newExtent,
                transform: volume.transform
            )
            updateCropBoxNode()

        case .ended, .cancelled:
            scaleStartExtent = nil

        default:
            break
        }
    }

    private func handleResizeChange(location: CGPoint) {
        guard let axis = dragAxis,
              let start = dragStartScreen,
              let startCenter = dragStartCenter,
              let startExtent = dragStartExtent,
              let cameraNode = sceneView.pointOfView,
              let volume = cropVolume else {
            return
        }
        let viewport = sceneView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let dx = Float(location.x - start.x)
        let dy = Float(location.y - start.y)
        let worldDelta = worldDeltaFromScreen(
            dx: dx,
            dy: dy,
            cameraNode: cameraNode,
            center: startCenter,
            viewport: viewport,
            depth: dragDepth
        )
        let amount = simd_dot(worldDelta, axis)
        var extent = startExtent
        if axis.x != 0 {
            extent.x = min(max(startExtent.x + amount * 2, 0.2), 10)
        }
        if axis.y != 0 {
            extent.y = min(max(startExtent.y + amount * 2, 0.2), 10)
        }
        if axis.z != 0 {
            extent.z = min(max(startExtent.z + amount * 2, 0.2), 10)
        }
        var transform = volume.transform
        transform.columns.3 = SIMD4<Float>(
            startCenter.x,
            startCenter.y,
            startCenter.z,
            1
        )
        cropVolume = ObjectCropVolume(
            center: startCenter,
            extent: extent,
            transform: transform
        )
        updateCropBoxNode()
    }

    private func handleRotateChange(location: CGPoint) {
        guard let start = rotateStartScreen,
              let startTransform = rotateStartTransform,
              let cameraNode = sceneView.pointOfView,
              let volume = cropVolume else {
            return
        }
        let dx = Float(location.x - start.x)
        let dy = Float(location.y - start.y)
        let yaw = dx * 0.006
        let pitch = dy * 0.006
        let yawQuat = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let cameraRight = SIMD3<Float>(
            cameraNode.simdTransform.columns.0.x,
            cameraNode.simdTransform.columns.0.y,
            cameraNode.simdTransform.columns.0.z
        )
        let pitchQuat = simd_quatf(angle: pitch, axis: cameraRight)
        let rotation = simd_normalize(yawQuat * pitchQuat)
        let newQuat = simd_normalize(rotation * simd_quatf(startTransform))
        var newTransform = simd_float4x4(newQuat)
        newTransform.columns.3 = startTransform.columns.3
        cropVolume = ObjectCropVolume(
            center: volume.center,
            extent: volume.extent,
            transform: newTransform
        )
        updateCropBoxNode()
    }

    private func worldDeltaFromScreen(
        dx: Float,
        dy: Float,
        cameraNode: SCNNode,
        center: SIMD3<Float>,
        viewport: CGSize,
        depth: Float
    ) -> SIMD3<Float> {
        guard viewport.width > 0, viewport.height > 0,
              let camera = cameraNode.camera else {
            return .zero
        }
        let transform = cameraNode.simdTransform
        let cameraPosition = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let forward = simd_normalize(center - cameraPosition)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        let distance = max(depth, 0.1)
        let fovY = Float(camera.fieldOfView) * .pi / 180
        let aspect = Float(viewport.width / max(viewport.height, 1))
        let fovX = 2 * atan(tan(fovY / 2) * aspect)
        let worldPerPixelX = 2 * distance * tan(fovX / 2) / Float(viewport.width)
        let worldPerPixelY = 2 * distance * tan(fovY / 2) / Float(viewport.height)
        return right * dx * worldPerPixelX + up * (-dy) * worldPerPixelY
    }

    private func axisName(from hit: SCNHitTestResult) -> String? {
        if let name = hit.node.name, isAxisName(name) {
            return name
        }
        return hit.node.parent?.name
    }

    private func isAxisName(_ name: String) -> Bool {
        name == "axisX" || name == "axisY" || name == "axisZ"
    }

    private func axis(for name: String) -> SIMD3<Float>? {
        switch name {
        case "axisX": return SIMD3<Float>(1, 0, 0)
        case "axisY": return SIMD3<Float>(0, 1, 0)
        case "axisZ": return SIMD3<Float>(0, 0, 1)
        default: return nil
        }
    }

    private func arrowHit(at location: CGPoint) -> SCNHitTestResult? {
        let results = sceneView.hitTest(location, options: nil)
        return results.first { hit in
            if let name = axisName(from: hit) {
                return axis(for: name) != nil
            }
            return false
        }
    }

    func placeCropBox(at point: CGPoint) {
        guard let query = sceneView.raycastQuery(
            from: point,
            allowing: .estimatedPlane,
            alignment: .horizontal
        ),
        let result = sceneView.session.raycast(query).first else {
            return
        }
        let worldTransform = result.worldTransform
        let hit = SIMD3<Float>(
            worldTransform.columns.3.x,
            worldTransform.columns.3.y,
            worldTransform.columns.3.z
        )
        let up = simd_normalize(SIMD3<Float>(
            worldTransform.columns.1.x,
            worldTransform.columns.1.y,
            worldTransform.columns.1.z
        ))
        let extent = SIMD3<Float>(repeating: cropBoxSize)
        let center = hit + up * (extent.y * 0.5)
        var transform = worldTransform
        transform.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
        cropVolume = ObjectCropVolume(
            center: center,
            extent: extent,
            transform: transform
        )
        voxelMap.removeAll()
        frameCount = 0
        updateCropBoxNode()
        isPlacingCropBox = false
        onCropBoxPlaced?()
    }

    func setCropBoxSize(_ size: Float) {
        let clamped = min(max(size, 0.2), 10)
        guard abs(clamped - cropBoxSize) > 0.001 else { return }
        cropBoxSize = clamped
        guard let volume = cropVolume else { return }
        let extent = SIMD3<Float>(repeating: cropBoxSize)
        cropVolume = ObjectCropVolume(
            center: volume.center,
            extent: extent,
            transform: volume.transform
        )
        updateCropBoxNode()
    }

    func clearCropBox() {
        cropVolume = nil
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
        guard let volume = cropVolume else { return }

        let root = SCNNode()
        root.name = "cropBox"
        root.simdTransform = volume.transform

        let fill = SCNBox(
            width: CGFloat(volume.extent.x),
            height: CGFloat(volume.extent.y),
            length: CGFloat(volume.extent.z),
            chamferRadius: 0
        )
        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.14)
        fillMaterial.emission.contents = UIColor.systemGreen.withAlphaComponent(0.18)
        fillMaterial.isDoubleSided = true
        fill.firstMaterial = fillMaterial
        root.addChildNode(SCNNode(geometry: fill))

        let cameraPosition = cameraPositionOfScene
        addEdges(
            to: root,
            extent: volume.extent,
            cameraPosition: cameraPosition,
            isOccupied: { [weak self] world in
                self?.isOccupied(world) ?? false
            }
        )
        addArrows(to: root, extent: volume.extent)
        sceneView.scene.rootNode.addChildNode(root)
        cropBoxNode = root
    }

    private var cameraPositionOfScene: SIMD3<Float> {
        guard let cameraNode = sceneView.pointOfView else { return .zero }
        let transform = cameraNode.simdTransform
        return SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
    }

    private func isOccupied(_ world: SIMD3<Float>) -> Bool {
        voxelMap[voxelKey(world, size: voxelSize)] != nil
    }

    private func addEdges(
        to root: SCNNode,
        extent: SIMD3<Float>,
        cameraPosition: SIMD3<Float>,
        isOccupied: @escaping (SIMD3<Float>) -> Bool
    ) {
        let half = extent * 0.5
        let solidMaterial = SCNMaterial()
        solidMaterial.lightingModel = .constant
        solidMaterial.diffuse.contents = UIColor.systemGreen
        solidMaterial.emission.contents = UIColor.systemGreen

        let dashedMaterial = SCNMaterial()
        dashedMaterial.lightingModel = .constant
        dashedMaterial.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.55)
        dashedMaterial.emission.contents = UIColor.systemGreen.withAlphaComponent(0.55)

        func addLine(
            axis: SIMD3<Float>,
            length: Float,
            offset: SIMD3<Float>,
            dashed: Bool
        ) {
            let material = dashed ? dashedMaterial : solidMaterial
            if !dashed {
                let box = SCNBox(
                    width: CGFloat(axis.x != 0 ? length : 0.01),
                    height: CGFloat(axis.y != 0 ? length : 0.01),
                    length: CGFloat(axis.z != 0 ? length : 0.01),
                    chamferRadius: 0
                )
                box.firstMaterial = material
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(offset.x, offset.y, offset.z)
                root.addChildNode(node)
                return
            }

            let dashLength: Float = 0.05
            let gapLength: Float = 0.04
            var cursor: Float = 0
            while cursor < length {
                let dash = min(dashLength, length - cursor)
                let box = SCNBox(
                    width: CGFloat(axis.x != 0 ? dash : 0.01),
                    height: CGFloat(axis.y != 0 ? dash : 0.01),
                    length: CGFloat(axis.z != 0 ? dash : 0.01),
                    chamferRadius: 0
                )
                box.firstMaterial = material
                let node = SCNNode(geometry: box)
                let halfLength = length * 0.5
                let centerAlongAxis = -halfLength + cursor + dash * 0.5
                let position = offset + axis * centerAlongAxis
                node.position = SCNVector3(position.x, position.y, position.z)
                root.addChildNode(node)
                cursor += dash + gapLength
            }
        }

        var edges: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float)] = []
        func edgeList(axis: SIMD3<Float>, length: Float, offsets: [SIMD3<Float>]) {
            for offset in offsets {
                edges.append((axis, length, offset, length))
            }
        }

        edgeList(
            axis: SIMD3<Float>(1, 0, 0),
            length: extent.x,
            offsets: [
                SIMD3<Float>(0, -half.y, -half.z),
                SIMD3<Float>(0, -half.y, half.z),
                SIMD3<Float>(0, half.y, -half.z),
                SIMD3<Float>(0, half.y, half.z)
            ]
        )
        edgeList(
            axis: SIMD3<Float>(0, 1, 0),
            length: extent.y,
            offsets: [
                SIMD3<Float>(-half.x, 0, -half.z),
                SIMD3<Float>(-half.x, 0, half.z),
                SIMD3<Float>(half.x, 0, -half.z),
                SIMD3<Float>(half.x, 0, half.z)
            ]
        )
        edgeList(
            axis: SIMD3<Float>(0, 0, 1),
            length: extent.z,
            offsets: [
                SIMD3<Float>(-half.x, -half.y, 0),
                SIMD3<Float>(-half.x, half.y, 0),
                SIMD3<Float>(half.x, -half.y, 0),
                SIMD3<Float>(half.x, half.y, 0)
            ]
        )

        for edge in edges {
            let axis = edge.0
            let length = edge.1
            let offset = edge.2
            let start = offset - axis * length * 0.5
            let end = offset + axis * length * 0.5
            let dashed = edgeOccluded(
                from: start,
                to: end,
                cameraPosition: cameraPosition,
                isOccupied: isOccupied
            )
            addLine(
                axis: axis,
                length: length,
                offset: offset,
                dashed: dashed
            )
        }
    }

    private func edgeOccluded(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        cameraPosition: SIMD3<Float>,
        isOccupied: (SIMD3<Float>) -> Bool
    ) -> Bool {
        let samples = 8
        for index in 0...samples {
            let t = Float(index) / Float(samples)
            let point = start + (end - start) * t
            let toPoint = point - cameraPosition
            let distance = simd_length(toPoint)
            guard distance > 0.05 else { continue }
            let direction = toPoint / distance
            var step: Float = 0.04
            while step < distance - 0.06 {
                let sample = cameraPosition + direction * step
                if isOccupied(sample) {
                    return true
                }
                step += 0.04
            }
        }
        return false
    }

    private func addArrows(to root: SCNNode, extent: SIMD3<Float>) {
        let half = extent * 0.5
        let definitions: [(SIMD3<Float>, UIColor, String)] = [
            (SIMD3<Float>(1, 0, 0), .systemRed, "axisX"),
            (SIMD3<Float>(0, 1, 0), .systemGreen, "axisY"),
            (SIMD3<Float>(0, 0, 1), .systemBlue, "axisZ")
        ]

        for (axis, color, name) in definitions {
            let group = SCNNode()
            group.name = name

            let shaft = SCNBox(
                width: CGFloat(axis.x != 0 ? half.x : 0.018),
                height: CGFloat(axis.y != 0 ? half.y : 0.018),
                length: CGFloat(axis.z != 0 ? half.z : 0.018),
                chamferRadius: 0
            )
            let shaftMaterial = SCNMaterial()
            shaftMaterial.lightingModel = .constant
            shaftMaterial.diffuse.contents = color
            shaftMaterial.emission.contents = color
            shaft.firstMaterial = shaftMaterial
            let shaftNode = SCNNode(geometry: shaft)
            shaftNode.position = SCNVector3(
                axis.x * half.x * 0.5,
                axis.y * half.y * 0.5,
                axis.z * half.z * 0.5
            )
            group.addChildNode(shaftNode)

            let cone = SCNCone(topRadius: 0, bottomRadius: 0.045, height: 0.14)
            let coneMaterial = SCNMaterial()
            coneMaterial.lightingModel = .constant
            coneMaterial.diffuse.contents = color
            coneMaterial.emission.contents = color
            cone.firstMaterial = coneMaterial
            let coneNode = SCNNode(geometry: cone)
            let headPosition = half + axis * 0.07
            coneNode.position = SCNVector3(
                headPosition.x,
                headPosition.y,
                headPosition.z
            )
            coneNode.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: axis
            )
            group.addChildNode(coneNode)
            root.addChildNode(group)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCapturing else { return }
        frameCount += 1
        guard frameCount % 10 == 0 else { return }

        captureMeshPoints(from: frame)
        if voxelMap.count >= maxVoxels {
            compactVoxelMap()
        }
        let snapshot = snapshotPoints()
        DispatchQueue.main.async {
            self.updatePointCloud(snapshot)
            if self.cropVolume != nil {
                self.updateCropBoxNode()
            }
            self.onPointCount?(snapshot.count)
        }
    }

    private func compactVoxelMap() {
        let newSize = voxelSize * 1.5
        var merged: [Int64: VoxelAccumulator] = [:]
        for (_, accumulator) in voxelMap {
            let inv = 1 / max(accumulator.count, 1)
            let position = accumulator.sum * inv
            let key = voxelKey(position, size: newSize)
            var acc = merged[key] ?? VoxelAccumulator()
            acc.sum += accumulator.sum
            acc.sumColor += accumulator.sumColor
            acc.count += accumulator.count
            acc.backgroundCount += accumulator.backgroundCount
            merged[key] = acc
        }
        voxelMap = merged
        voxelSize = newSize
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

    private func sampled(_ points: [ObjectPoint], limit: Int) -> [ObjectPoint] {
        guard points.count > limit else { return points }
        let stride = max(points.count / limit, 1)
        var result: [ObjectPoint] = []
        result.reserveCapacity(limit)
        var index = 0
        while index < points.count {
            result.append(points[index])
            index += stride
        }
        return result
    }

    private func updatePointCloud(_ points: [ObjectPoint]) {
        guard !points.isEmpty else { return }
        let displayPoints = sampled(points, limit: 80_000).map {
            ObjectPoint(x: $0.x, y: $0.y, z: $0.z, r: 1, g: 1, b: 1)
        }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 1, green: 0.08, blue: 0.06, alpha: 1)
        material.emission.contents = UIColor(red: 1, green: 0.08, blue: 0.06, alpha: 1)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        let radius = CGFloat(pointSize)
        let geometry = SCNGeometry.objectPointCloud(
            points: displayPoints,
            worldPointSize: 0.02,
            minScreenRadius: radius,
            maxScreenRadius: radius,
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
        voxelKey(position, size: voxelSize)
    }

    private func voxelKey(_ position: SIMD3<Float>, size: Float) -> Int64 {
        let ix = Int64(floor(position.x / size))
        let iy = Int64(floor(position.y / size))
        let iz = Int64(floor(position.z / size))
        return ((ix + 0x80000) & 0xFFFFF) | (((iy + 0x80000) & 0xFFFFF) << 20) | (((iz + 0x80000) & 0xFFFFF) << 40)
    }
}
