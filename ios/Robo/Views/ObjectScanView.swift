import SwiftUI
import SwiftData
import ARKit
import CoreVideo
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
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var shareURLs: [URL] = []

    var body: some View {
        NavigationStack {
            Group {
                if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
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
                tipRow(icon: "figure.walk", text: "围绕物体缓慢移动，让 LiDAR 扫到全部表面")
                tipRow(icon: "move.3d", text: "尽量保持物体完整出现在画面中")
                tipRow(icon: "clock", text: "扫描越完整，体积和表面积越准确")
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                objectName = ""
                capturedPoints = []
                pointCount = 0
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
            }
        }
    }

    private func resultsView(_ result: ObjectScanProcessResult) -> some View {
        List {
            Section("对象") {
                TextField("对象名称", text: $objectName)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("原始点数", value: "\(result.metrics.pointCount)")
                LabeledContent("处理点数", value: "\(result.metrics.processedPointCount)")
                LabeledContent(
                    "外包围尺寸",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        result.metrics.aabb.sizeX,
                        result.metrics.aabb.sizeY,
                        result.metrics.aabb.sizeZ
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
            heightfieldVolumeM3: result.metrics.heightfieldVolumeM3,
            heightfieldSurfaceAreaM2: result.metrics.heightfieldSurfaceAreaM2,
            convexHullVolumeM3: result.metrics.convexHullVolumeM3,
            convexHullSurfaceAreaM2: result.metrics.convexHullSurfaceAreaM2,
            metricsJSON: result.metricsJSON,
            plyData: result.plyData,
            usdzData: result.usdzData
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

private struct ObjectScanARView: UIViewControllerRepresentable {
    @Binding var isCapturing: Bool
    let onPointCount: (Int) -> Void
    let onPointsCaptured: ([ObjectPoint]) -> Void

    func makeUIViewController(context: Context) -> ObjectScanARViewController {
        let controller = ObjectScanARViewController()
        controller.onPointCount = onPointCount
        controller.onPointsCaptured = onPointsCaptured
        return controller
    }

    func updateUIViewController(_ uiViewController: ObjectScanARViewController, context: Context) {
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

    private let sceneView = ARSCNView()
    private var isCapturing = false
    private var didDeliver = false
    private var frameCount = 0
    private let voxelSize: Float = 0.02
    private let maxVoxels = 400_000
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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
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
        let points = voxelMap.values.map { accumulator -> ObjectPoint in
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
        DispatchQueue.main.async {
            self.onPointCount?(points.count)
            self.onPointsCaptured?(points)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCapturing else { return }
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0,
              let depthBase = CVPixelBufferGetBaseAddress(depthMap)?
                .assumingMemoryBound(to: Float32.self) else {
            return
        }
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride

        var colorBase: UnsafeMutablePointer<UInt8>?
        var colorWidth = 0
        var colorHeight = 0
        var colorRow = 0
        CVPixelBufferLockBaseAddress(frame.capturedImage, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.capturedImage, .readOnly) }
        if let base = CVPixelBufferGetBaseAddressOfPlane(frame.capturedImage, 0)?
            .assumingMemoryBound(to: UInt8.self) {
            colorBase = base
            colorWidth = CVPixelBufferGetWidth(frame.capturedImage)
            colorHeight = CVPixelBufferGetHeight(frame.capturedImage)
            colorRow = CVPixelBufferGetBytesPerRowOfPlane(frame.capturedImage, 0)
        }

        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        let step = 2
        for y in stride(from: 0, to: depthHeight, by: step) {
            for x in stride(from: 0, to: depthWidth, by: step) {
                let depth = depthBase[y * depthRow + x]
                guard depth > 0.2, depth < 8 else { continue }
                let local = SIMD3<Float>(
                    (Float(x) - cx) / fx * depth,
                    (Float(y) - cy) / fy * depth,
                    -depth
                )
                let world = cameraTransform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let position = SIMD3<Float>(world.x, world.y, world.z)
                let key = voxelKey(position)
                if voxelMap[key] == nil && voxelMap.count >= maxVoxels { continue }

                var accumulator = voxelMap[key] ?? VoxelAccumulator()
                accumulator.sum += position
                var gray: Float = 0.65
                if let colorBase, colorWidth > 0, colorHeight > 0 {
                    let sx = min(colorWidth - 1, Int((Double(x) * Double(colorWidth) / Double(depthWidth)).rounded()))
                    let sy = min(colorHeight - 1, Int((Double(y) * Double(colorHeight) / Double(depthHeight)).rounded()))
                    gray = Float(colorBase[sy * colorRow + sx]) / 255
                }
                accumulator.sumColor += SIMD3<Float>(gray * 0.7, gray * 0.8, 1.0)
                accumulator.count += 1
                voxelMap[key] = accumulator
            }
        }

        frameCount += 1
        if frameCount % 15 == 0 {
            let snapshot = voxelMap.values.map { accumulator -> ObjectPoint in
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
            DispatchQueue.main.async {
                self.updatePointCloud(snapshot)
                self.onPointCount?(snapshot.count)
            }
        }
    }

    private func updatePointCloud(_ points: [ObjectPoint]) {
        guard !points.isEmpty else { return }
        let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        let source = SCNGeometrySource(vertices: vertices)
        let indices = (0..<Int32(points.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.shaderModifiers = [
            .geometry: "#pragma body\n_geometry.pointSize = 6.0;"
        ]
        geometry.materials = [material]

        sceneView.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        sceneView.scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    }

    private func voxelKey(_ position: SIMD3<Float>) -> Int64 {
        let ix = Int64(floor(position.x / voxelSize)) + 0x80000
        let iy = Int64(floor(position.y / voxelSize)) + 0x80000
        let iz = Int64(floor(position.z / voxelSize)) + 0x80000
        return (ix & 0xFFFFF) | ((iy & 0xFFFFF) << 20) | ((iz & 0xFFFFF) << 40)
    }
}
