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
    @State private var coverageRatio: Float = 0
    @State private var suggestedAngle: Float?
    @State private var capturedPoints: [ObjectPoint] = []
    @State private var objectName = ""
    @State private var result: ObjectScanProcessResult?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var shareURLs: [URL] = []

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
                tipRow(icon: "figure.walk", text: "围绕物体缓慢移动，让 ARKit 网格覆盖全部表面")
                tipRow(icon: "move.3d", text: "尽量保持物体完整出现在画面中")
                tipRow(icon: "scope", text: "按提示移动到未覆盖方向，环绕覆盖率会实时更新")
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                objectName = ""
                capturedPoints = []
                pointCount = 0
                coverageRatio = 0
                suggestedAngle = nil
                isProcessing = false
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
                onPointCount: { count in
                    pointCount = count
                },
                onPointsCaptured: { points in
                    capturedPoints = points
                    processCapturedPoints()
                },
                onCoverageUpdate: { ratio, angle in
                    coverageRatio = ratio
                    suggestedAngle = angle
                }
            )
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.white)
                    Text("点云 \(pointCount) · 覆盖 \(Int(coverageRatio * 100))%")
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

                if coverageRatio < 0.15 && suggestedAngle == nil {
                    Text("请围绕物体缓慢移动，让 ARKit 扫到全部表面")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(.bottom, 10)
                }

                HStack(spacing: 16) {
                    CoverageRingView(ratio: Double(coverageRatio), suggestedAngle: suggestedAngle)
                        .frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已覆盖 \(Int(coverageRatio * 100))%")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(directionText)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
                .padding(12)
                .background(.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 24)
            }
        }
    }

    private var directionText: String {
        guard let angle = suggestedAngle else {
            return coverageRatio < 0.15 ? "请围绕物体缓慢移动" : "继续环绕扫描，补全未覆盖区域"
        }
        let normalized = ((Int(angle) % 360) + 360) % 360
        let names = ["正前方", "右前方", "右侧", "右后方", "正后方", "左后方", "左侧", "左前方"]
        let index = (normalized + 22) / 45 % 8
        return "建议向\(names[index])移动"
    }

    private func resultsView(_ result: ObjectScanProcessResult) -> some View {
        List {
            Section("3D 预览") {
                ObjectPointCloud3DView(points: result.points)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            Section("对象") {
                TextField("对象名称", text: $objectName)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("原始点数", value: "\(result.metrics.pointCount)")
                LabeledContent("处理点数", value: "\(result.metrics.processedPointCount)")
                LabeledContent("目标点数", value: "\(result.metrics.targetPointCount ?? result.metrics.processedPointCount)")
                LabeledContent("点簇数量", value: "\(result.metrics.clusterCount ?? 1)")
                LabeledContent(
                    "AABB 外包围尺寸",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        result.metrics.aabb.sizeX,
                        result.metrics.aabb.sizeY,
                        result.metrics.aabb.sizeZ
                    )
                )
                LabeledContent(
                    "OBB 长×宽×高",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        result.metrics.obbLengthM ?? 0,
                        result.metrics.obbWidthM ?? 0,
                        result.metrics.obbHeightM ?? 0
                    )
                )
            }

            Section("堆体/土方（高度场）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", result.metrics.heightfieldVolumeM3)
                )
                LabeledContent(
                    "表面积",
                    value: String(format: "%.3f m²", result.metrics.heightfieldSurfaceAreaM2)
                )
            }

            Section("设备（凸包）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", result.metrics.convexHullVolumeM3)
                )
                LabeledContent(
                    "表面积",
                    value: String(format: "%.3f m²", result.metrics.convexHullSurfaceAreaM2)
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

    private func processCapturedPoints() {
        guard !capturedPoints.isEmpty else {
            errorMessage = "没有采集到有效点云，请重新扫描"
            phase = .instructions
            return
        }
        isProcessing = true
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
        let name = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "物体 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))" : name
        let record = ObjectScanRecord(
            objectName: finalName,
            pointCount: result.metrics.pointCount,
            processedPointCount: result.metrics.processedPointCount,
            targetPointCount: result.metrics.targetPointCount ?? result.metrics.processedPointCount,
            clusterCount: result.metrics.clusterCount ?? 1,
            obbLengthM: result.metrics.obbLengthM ?? 0,
            obbWidthM: result.metrics.obbWidthM ?? 0,
            obbHeightM: result.metrics.obbHeightM ?? 0,
            heightfieldVolumeM3: result.metrics.heightfieldVolumeM3,
            heightfieldSurfaceAreaM2: result.metrics.heightfieldSurfaceAreaM2,
            convexHullVolumeM3: result.metrics.convexHullVolumeM3,
            convexHullSurfaceAreaM2: result.metrics.convexHullSurfaceAreaM2,
            metricsJSON: result.metricsJSON,
            plyData: result.plyData,
            usdzData: result.usdzData,
            pointsJSON: (try? JSONEncoder().encode(result.points)) ?? Data()
        )
        modelContext.insert(record)
        try? modelContext.save()
        dismiss()
    }

    private func exportFiles(_ result: ObjectScanProcessResult) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ObjectScan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = directory.appendingPathComponent("object-scan")
            let plyURL = base.appendingPathExtension("ply")
            let jsonURL = base.appendingPathExtension("json")
            try result.plyData.write(to: plyURL)
            try result.metricsJSON.write(to: jsonURL)
            var urls = [plyURL, jsonURL]
            if let usdzData = result.usdzData {
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

private struct CoverageRingView: View {
    let ratio: Double
    let suggestedAngle: Float?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, ratio)))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let suggestedAngle {
                Image(systemName: "location.north.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                    .rotationEffect(.degrees(Double(suggestedAngle)))
            }
            VStack(spacing: 2) {
                Text("\(Int(ratio * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                Text("覆盖率")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(12)
        .background(.black.opacity(0.5))
        .clipShape(Circle())
    }
}

private struct ObjectScanARView: UIViewControllerRepresentable {
    @Binding var isCapturing: Bool
    let onPointCount: (Int) -> Void
    let onPointsCaptured: ([ObjectPoint]) -> Void
    let onCoverageUpdate: ((Float, Float?) -> Void)?

    func makeUIViewController(context: Context) -> ObjectScanARViewController {
        let controller = ObjectScanARViewController()
        controller.onPointCount = onPointCount
        controller.onPointsCaptured = onPointsCaptured
        controller.onCoverageUpdate = onCoverageUpdate
        return controller
    }

    func updateUIViewController(_ uiViewController: ObjectScanARViewController, context: Context) {
        uiViewController.onCoverageUpdate = onCoverageUpdate
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
    var onCoverageUpdate: ((Float, Float?) -> Void)?

    private let sceneView = ARSCNView()
    private var isCapturing = false
    private var didDeliver = false
    private var frameCount = 0
    private let voxelSize: Float = 0.02
    private let maxVoxels = 600_000
    private var voxelMap: [Int64: VoxelAccumulator] = [:]

    private struct VoxelAccumulator {
        var sum = SIMD3<Float>.zero
        var sumColor = SIMD3<Float>.zero
        var count: Float = 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(sceneView)
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session.delegate = self

        let configuration = ARWorldTrackingConfiguration()
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
        let snapshot = snapshotPoints()
        let coverage = coverageInfo(from: snapshot, cameraTransform: frame.camera.transform)
        DispatchQueue.main.async {
            self.updatePointCloud(snapshot)
            self.onPointCount?(snapshot.count)
            self.onCoverageUpdate?(coverage.ratio, coverage.direction)
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
                let key = voxelKey(world)
                if voxelMap[key] == nil && voxelMap.count >= maxVoxels { continue }

                var color = SIMD3<Float>(0.95, 0.55, 0.2)
                if let classificationBuffer {
                    let raw = classificationBuffer.load(
                        fromByteOffset: classificationOffset + i * classificationStride,
                        as: UInt8.self
                    )
                    color = classificationColor(ARMeshClassification(rawValue: Int(raw)))
                }

                var accumulator = voxelMap[key] ?? VoxelAccumulator()
                accumulator.sum += world
                accumulator.sumColor += color
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
            return ObjectPoint(
                x: position.x,
                y: position.y,
                z: position.z,
                r: color.x,
                g: color.y,
                b: color.z
            )
        }
    }

    private func coverageInfo(
        from points: [ObjectPoint],
        cameraTransform: simd_float4x4
    ) -> (ratio: Float, direction: Float?) {
        guard points.count > 20 else { return (0, nil) }
        var sum = SIMD3<Float>.zero
        for point in points {
            sum += point.position
        }
        let center = sum / Float(points.count)
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let sectorCount = 36
        var occupied = Set<Int>()

        func binFor(dx: Float, dz: Float) -> Int {
            let angle = atan2(dx, dz)
            var bin = Int(((angle + .pi) / (2 * .pi)) * Float(sectorCount))
            bin = ((bin % sectorCount) + sectorCount) % sectorCount
            return bin
        }

        occupied.insert(binFor(dx: cameraPosition.x - center.x, dz: cameraPosition.z - center.z))
        for point in points {
            occupied.insert(binFor(dx: point.x - center.x, dz: point.z - center.z))
        }

        let ratio = Float(occupied.count) / Float(sectorCount)

        var bestStart = 0
        var bestLength = 0
        var currentStart = -1
        var currentLength = 0
        for i in 0..<(sectorCount * 2) {
            let bin = i % sectorCount
            if occupied.contains(bin) {
                currentStart = -1
                currentLength = 0
            } else {
                if currentStart < 0 {
                    currentStart = i
                }
                currentLength += 1
                if currentLength > bestLength {
                    bestLength = currentLength
                    bestStart = currentStart
                }
            }
        }
        guard bestLength > 0 else { return (ratio, nil) }

        let midIndex = bestStart + bestLength / 2
        let midBin = midIndex % sectorCount
        let worldAngle = -Float.pi + (Float(midBin) + 0.5) * (2 * Float.pi / Float(sectorCount))
        let forward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            0,
            -cameraTransform.columns.2.z
        )
        let cameraYaw = atan2(forward.x, -forward.z)
        var relative = (worldAngle - cameraYaw) * 180 / .pi
        relative = ((relative.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        return (ratio, relative)
    }

    private func updatePointCloud(_ points: [ObjectPoint]) {
        guard !points.isEmpty else { return }
        let geometry = SCNGeometry.objectPointCloud(points: points, pointSize: 6)
        sceneView.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        sceneView.scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    }

    private func voxelKey(_ position: SIMD3<Float>) -> Int64 {
        let ix = Int64(floor(position.x / voxelSize))
        let iy = Int64(floor(position.y / voxelSize))
        let iz = Int64(floor(position.z / voxelSize))
        return ((ix + 0x80000) & 0xFFFFF) | (((iy + 0x80000) & 0xFFFFF) << 20) | (((iz + 0x80000) & 0xFFFFF) << 40)
    }
}
