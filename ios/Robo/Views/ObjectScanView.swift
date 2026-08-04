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
                onPointCount: { count in
                    pointCount = count
                },
                onPointsCaptured: { points in
                    capturedPoints = points
                    processCapturedPoints()
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

                Text("扫描完成后在结果页放置裁剪盒，一次扫描可多次计算")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
            }
        }
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
                            isPlacingCropBox ? "点击地面放置" : "放置裁剪盒",
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
                    Text("拖动红/绿/蓝色箭头调整 X/Y/Z 三向尺寸，只计算盒内点云。")
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

    let onPointCount: (Int) -> Void
    let onPointsCaptured: ([ObjectPoint]) -> Void

    func makeUIViewController(context: Context) -> ObjectScanARViewController {
        let controller = ObjectScanARViewController()
        controller.onPointCount = onPointCount
        controller.onPointsCaptured = onPointsCaptured
        controller.pointSize = pointSize
        return controller
    }

    func updateUIViewController(_ uiViewController: ObjectScanARViewController, context: Context) {
        uiViewController.onPointCount = onPointCount
        uiViewController.onPointsCaptured = onPointsCaptured
        uiViewController.pointSize = pointSize
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
    var pointSize: Double = 1.5

    private let sceneView = ARSCNView()
    private var isCapturing = false
    private var didDeliver = false
    private var frameCount = 0
    private var voxelSize: Float = 0.02
    private let maxVoxels = 200_000
    private var voxelMap: [Int64: VoxelAccumulator] = [:]

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
