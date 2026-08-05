import SwiftUI
import SwiftData
import ARKit
import CoreVideo
import SceneKit
import simd

enum AxisMoveCommand: Equatable {
    case none
    case xMinus
    case xPlus
    case yMinus
    case yPlus
    case zMinus
    case zPlus
}

enum ObjectPreviewMode: String, CaseIterable, Identifiable {
    case all
    case highlightTarget
    case targetOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部点云"
        case .highlightTarget: return "高亮目标"
        case .targetOnly: return "仅显示目标"
        }
    }
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
    @State private var capturedPlanes: [ScanPlaneInfo] = []
    @State private var objectName = ""
    @State private var result: ObjectScanProcessResult?
    @State private var selectedClusterIndex = 0
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var shareURLs: [URL] = []
    @State private var showDiscardConfirm = false

    @State private var cropVolume: ObjectCropVolume?
    @State private var placeCropBoxRequested = false
    @State private var axisMoveCommand: AxisMoveCommand = .none
    @State private var boxMetrics: ObjectScanMetrics?
    @State private var boxUSDZData: Data?
    @State private var previewMode: ObjectPreviewMode = .all
    @State private var isComputingBoxMetrics = false
    @State private var pointSize: Double = ObjectScanSettings.pointSize
    @State private var scanPlaceRequested = false
    @State private var scanAxisMoveCommand: AxisMoveCommand = .none
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
                tipRow(icon: "hand.tap", text: "盒子自动贴合地面/墙面，按钮微调 X/Y/Z")
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                objectName = ""
                capturedPoints = []
                capturedPlanes = []
                pointCount = 0
                selectedClusterIndex = 0
                isProcessing = false
                cropVolume = nil
                placeCropBoxRequested = false
                axisMoveCommand = .none
                boxMetrics = nil
                scanPlaceRequested = false
                scanAxisMoveCommand = .none
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
                placeRequested: $scanPlaceRequested,
                axisMoveCommand: $scanAxisMoveCommand,
                cropBoxSize: $scanCropBoxSize,
                clearRequested: $scanClearCropBox,
                onPointCount: { count in
                    pointCount = count
                },
                onPointsCaptured: { points, planes in
                    capturedPoints = points
                    capturedPlanes = planes
                    processCapturedPoints()
                },
                onCropBoxPlaced: {
                    scanCropBoxPlaced = true
                },
                onCropBoxCleared: {
                    scanCropBoxPlaced = false
                },
                onCommandHandled: {
                    scanPlaceRequested = false
                    scanAxisMoveCommand = .none
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
                            scanPlaceRequested = true
                        } label: {
                            Label(
                                scanCropBoxPlaced ? "重新贴合" : "放置裁剪盒",
                                systemImage: "square.dashed"
                            )
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                        }

                        if scanCropBoxPlaced {
                            VStack(spacing: 4) {
                                axisButtons(command: $scanAxisMoveCommand)
                                Slider(value: $scanCropBoxSize, in: 0.2...10, step: 0.1)
                                    .frame(width: 140)
                                HStack {
                                    Text("\(scanCropBoxSize, specifier: "%.1f") m")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Button {
                                        scanCropBoxPlaced = false
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
        if scanCropBoxPlaced {
            return "自动贴合 · 单指移动 · 双指缩放 · 按钮微调"
        }
        return "点“放置裁剪盒”自动贴合地面/墙面；扫描采集全部点云"
    }

    private func axisButtons(command: Binding<AxisMoveCommand>) -> some View {
        let buttons: [(String, AxisMoveCommand)] = [
            ("X-", .xMinus), ("X+", .xPlus),
            ("Y-", .yMinus), ("Y+", .yPlus),
            ("Z-", .zMinus), ("Z+", .zPlus)
        ]
        return HStack(spacing: 6) {
            ForEach(buttons, id: \.0) { label, commandValue in
                Button {
                    command.wrappedValue = commandValue
                } label: {
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 26)
                        .background(Color.accentColor.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func resultsView(_ result: ObjectScanProcessResult) -> some View {
        let current = currentPointsAndMetrics(result)
        let voxelOK = current.metrics.voxelReconstructionSucceeded
            ?? (current.metrics.voxelMeshVolumeM3 != nil)
        return List {
            Section("3D 预览与裁剪") {
                Picker("预览模式", selection: $previewMode) {
                    ForEach(ObjectPreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ObjectCropBox3DView(
                    points: sampled(
                        result.allPoints,
                        limit: ObjectScanSettings.previewPointLimit
                    ),
                    targetPoints: current.points,
                    previewMode: previewMode,
                    cropVolume: cropVolume,
                    placeRequested: placeCropBoxRequested,
                    axisMoveCommand: axisMoveCommand,
                    onCropVolumeChanged: { volume in
                        cropVolume = volume
                        if volume == nil {
                            boxMetrics = nil
                            boxUSDZData = nil
                        }
                    },
                    onCropBoxEditEnded: { volume in
                        recomputeBoxMetrics(for: volume)
                    },
                    onCommandHandled: {
                        placeCropBoxRequested = false
                        axisMoveCommand = .none
                    }
                )
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                HStack(spacing: 10) {
                    Button {
                        placeCropBoxRequested = true
                    } label: {
                        Label(
                            cropVolume == nil ? "放置裁剪盒" : "重新贴合",
                            systemImage: "square.dashed"
                        )
                        .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)

                    if cropVolume != nil {
                        axisButtons(command: $axisMoveCommand)
                        Button {
                            cropVolume = nil
                            boxMetrics = nil
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
                    Text("盒子自动贴合地面；单指移动、双指缩放，按钮微调 X/Y/Z。")
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
                if let removedCount = current.metrics.backgroundRemovedCount,
                   let ratio = current.metrics.backgroundRemovedRatio {
                    LabeledContent(
                        "已剔除背景点",
                        value: "\(removedCount)（\(String(format: "%.1f%%", ratio * 100))）"
                    )
                }
                if let value = current.metrics.classificationRemovedCount {
                    LabeledContent("分类剔除", value: "\(value)")
                }
                if let value = current.metrics.planeAnchorRemovedCount {
                    LabeledContent("AR 平面剔除", value: "\(value)")
                }
                if let value = current.metrics.groundRemovedCount {
                    LabeledContent("地面剔除", value: "\(value)")
                }
                if let value = current.metrics.ransacRemovedCount {
                    LabeledContent("RANSAC 平面剔除", value: "\(value)")
                }
                if let value = current.metrics.localPlaneRemovedCount {
                    LabeledContent("局部平面剔除", value: "\(value)")
                }
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

            Section("体素表面重建（Surface Nets）") {
                if voxelOK {
                    LabeledContent(
                        "体积（闭合封口）",
                        value: String(
                            format: "%.3f m³",
                            current.metrics.voxelMeshVolumeM3 ?? current.metrics.heightfieldVolumeM3
                        )
                    )
                    LabeledContent(
                        "不规则物体表面积（不含地面/墙面接触）",
                        value: String(
                            format: "%.3f m²",
                            current.metrics.voxelMeshSurfaceAreaM2 ?? current.metrics.heightfieldSurfaceAreaM2
                        )
                    )
                    LabeledContent(
                        "网格总表面积",
                        value: String(
                            format: "%.3f m²",
                            current.metrics.voxelMeshTotalSurfaceAreaM2 ?? current.metrics.heightfieldSurfaceAreaM2
                        )
                    )
                    if let voxelSize = current.metrics.voxelSizeM {
                        LabeledContent(
                            "体素尺寸",
                            value: String(format: "%.4f m", voxelSize)
                        )
                    }
                    if let coverage = current.metrics.voxelCoverageEstimate {
                        LabeledContent(
                            "点云覆盖率",
                            value: String(format: "%.0f%%", coverage * 100)
                        )
                    }
                    if let vertexCount = current.metrics.voxelMeshVertexCount,
                       let triangleCount = current.metrics.voxelMeshTriangleCount {
                        LabeledContent(
                            "网格顶点/三角面",
                            value: "\(vertexCount) / \(triangleCount)"
                        )
                    }
                } else {
                    LabeledContent(
                        "体素重建状态",
                        value: current.metrics.voxelFailureReason ?? "未生成"
                    )
                    Text("请参考高度场或凸包结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("堆体/土方（高度场，参考）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", current.metrics.heightfieldVolumeM3)
                )
                LabeledContent(
                    "高度场表面积（参考）",
                    value: String(format: "%.3f m²", current.metrics.heightfieldSurfaceAreaM2)
                )
                LabeledContent(
                    "地面接触面积",
                    value: String(format: "%.2f m²", current.metrics.groundContactAreaM2 ?? current.metrics.footprintAreaM2 ?? 0)
                )
                LabeledContent(
                    "靠墙接触面积",
                    value: String(format: "%.2f m²", current.metrics.wallContactAreaM2 ?? 0)
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
            let pair = ObjectScanProcessor.metricsAndUSDZ(for: filtered)
            await MainActor.run {
                self.boxMetrics = pair.metrics
                self.boxUSDZData = pair.voxelUSDZData
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
        let planes = capturedPlanes
        Task.detached(priority: .userInitiated) {
            do {
                let processed = try ObjectScanProcessor.process(
                    points: points,
                    planes: planes
                )
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
                : (boxUSDZData ?? ObjectScanProcessor.voxelReconstruct(current.points).usdzData),
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
                : (boxUSDZData ?? ObjectScanProcessor.voxelReconstruct(current.points).usdzData)
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
    @Binding var placeRequested: Bool
    @Binding var axisMoveCommand: AxisMoveCommand
    @Binding var cropBoxSize: Float
    @Binding var clearRequested: Bool

    let onPointCount: (Int) -> Void
    let onPointsCaptured: ([ObjectPoint], [ScanPlaneInfo]) -> Void
    let onCropBoxPlaced: () -> Void
    let onCropBoxCleared: () -> Void
    let onCommandHandled: () -> Void

    func makeUIViewController(context: Context) -> ObjectScanARViewController {
        let controller = ObjectScanARViewController()
        controller.onPointCount = onPointCount
        controller.onPointsCaptured = onPointsCaptured
        controller.pointSize = pointSize
        controller.cropBoxSize = cropBoxSize
        controller.onCropBoxPlaced = onCropBoxPlaced
        controller.onCropBoxCleared = onCropBoxCleared
        return controller
    }

    func updateUIViewController(_ uiViewController: ObjectScanARViewController, context: Context) {
        uiViewController.onPointCount = onPointCount
        uiViewController.onPointsCaptured = onPointsCaptured
        uiViewController.pointSize = pointSize
        uiViewController.setCropBoxSize(cropBoxSize)
        uiViewController.onCropBoxPlaced = onCropBoxPlaced
        uiViewController.onCropBoxCleared = onCropBoxCleared
        if placeRequested {
            uiViewController.placeCropBoxAutomatically()
            onCommandHandled()
        }
        switch axisMoveCommand {
        case .none:
            break
        case .xMinus:
            uiViewController.moveCropBox(axis: SIMD3<Float>(-1, 0, 0))
            onCommandHandled()
        case .xPlus:
            uiViewController.moveCropBox(axis: SIMD3<Float>(1, 0, 0))
            onCommandHandled()
        case .yMinus:
            uiViewController.moveCropBox(axis: SIMD3<Float>(0, -1, 0))
            onCommandHandled()
        case .yPlus:
            uiViewController.moveCropBox(axis: SIMD3<Float>(0, 1, 0))
            onCommandHandled()
        case .zMinus:
            uiViewController.moveCropBox(axis: SIMD3<Float>(0, 0, -1))
            onCommandHandled()
        case .zPlus:
            uiViewController.moveCropBox(axis: SIMD3<Float>(0, 0, 1))
            onCommandHandled()
        }
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
    var onPointsCaptured: (([ObjectPoint], [ScanPlaneInfo]) -> Void)?
    var onCropBoxPlaced: (() -> Void)?
    var onCropBoxCleared: (() -> Void)?
    var pointSize: Double = 1.5
    var cropBoxSize: Float = 1.0

    private let sceneView = ARSCNView()
    private var isCapturing = false
    private var didDeliver = false
    private var frameCount = 0
    private var voxelSize: Float = 0.02
    private let maxVoxels = 200_000
    private var voxelMap: [Int64: VoxelAccumulator] = [:]
    private var lastPlaneInfos: [ScanPlaneInfo] = []
    private var cropVolume: ObjectCropVolume?
    private var cropBoxNode: SCNNode?
    private var meshOcclusionNodes: [UUID: SCNNode] = [:]

    private var moveStartScreen: CGPoint?
    private var moveStartCenter: SIMD3<Float>?
    private var moveStartDepth: Float = 0
    private var rotateStartTransform: simd_float4x4?
    private var scaleStartExtent: SIMD3<Float>?
    private var isMoving = false
    private var isScaling = false

    private let lineColor = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1)

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
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
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
        let planes = lastPlaneInfos
        DispatchQueue.main.async {
            self.onPointCount?(points.count)
            self.onPointsCaptured?(points, planes)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard cropVolume != nil else { return }
        let location = recognizer.location(in: sceneView)
        switch recognizer.state {
        case .began:
            guard let volume = cropVolume,
                  let frame = sceneView.session.currentFrame else {
                return
            }
            isMoving = true
            moveStartScreen = location
            moveStartCenter = volume.center
            rotateStartTransform = volume.transform
            let cameraPosition = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            moveStartDepth = max(simd_length(volume.center - cameraPosition), 0.1)

        case .changed:
            guard isMoving,
                  let start = moveStartScreen,
                  let startCenter = moveStartCenter,
                  let cameraNode = sceneView.pointOfView,
                  let startTransform = rotateStartTransform,
                  let volume = cropVolume else {
                return
            }
            let viewport = sceneView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            let dx = Float(location.x - start.x)
            let dy = Float(location.y - start.y)
            let yaw = dx * 0.006
            let yawQuat = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            let newQuat = simd_normalize(yawQuat * simd_quatf(startTransform))
            var newTransform = simd_float4x4(newQuat)

            let verticalDelta = worldDeltaFromScreen(
                dx: 0,
                dy: dy,
                cameraNode: cameraNode,
                center: startCenter,
                viewport: viewport,
                depth: moveStartDepth
            )
            let newCenter = SIMD3<Float>(
                startCenter.x,
                startCenter.y + verticalDelta.y,
                startCenter.z
            )
            newTransform.columns.3 = SIMD4<Float>(
                newCenter.x,
                newCenter.y,
                newCenter.z,
                1
            )
            cropVolume = ObjectCropVolume(
                center: newCenter,
                extent: volume.extent,
                transform: newTransform
            )
            updateCropBoxNode()

        case .ended, .cancelled:
            isMoving = false
            moveStartScreen = nil
            moveStartCenter = nil
            rotateStartTransform = nil
            snapCropBoxToPlanes()

        default:
            break
        }
    }

    @objc private func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
        guard cropVolume != nil else { return }
        let location = recognizer.location(in: sceneView)
        switch recognizer.state {
        case .began:
            guard let volume = cropVolume,
                  let cameraNode = sceneView.pointOfView else {
                return
            }
            isMoving = true
            moveStartScreen = location
            moveStartCenter = volume.center
            moveStartDepth = max(
                simd_length(volume.center - cameraPosition(of: cameraNode)),
                0.1
            )

        case .changed:
            guard isMoving,
                  let start = moveStartScreen,
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
            let horizontalDelta = SIMD3<Float>(worldDelta.x, 0, worldDelta.z)
            let newCenter = startCenter + horizontalDelta
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
            isMoving = false
            moveStartScreen = nil
            moveStartCenter = nil
            snapCropBoxToPlanes()

        default:
            break
        }
    }

    private func cameraPosition(of cameraNode: SCNNode) -> SIMD3<Float> {
        let transform = cameraNode.simdTransform
        return SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
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

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard cropVolume != nil else { return }
        switch recognizer.state {
        case .began:
            isScaling = true
            scaleStartExtent = cropVolume?.extent
        case .changed:
            guard isScaling,
                  let startExtent = scaleStartExtent,
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
            isScaling = false
            scaleStartExtent = nil
            snapCropBoxToPlanes()

        default:
            break
        }
    }

    func placeCropBoxAutomatically() {
        let extent = SIMD3<Float>(repeating: cropBoxSize)
        let screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let query = sceneView.raycastQuery(
            from: screenCenter,
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        let result = query.flatMap { sceneView.session.raycast($0).first }

        let center: SIMD3<Float>
        if let result {
            let transform = result.worldTransform
            let hit = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
            center = hit + SIMD3<Float>(0, extent.y * 0.5, 0)
        } else {
            let cameraTransform = sceneView.session.currentFrame?.camera.transform
                ?? matrix_identity_float4x4
            let forward = SIMD3<Float>(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            )
            let cameraPosition = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )
            var fallback = cameraPosition + forward * 1.2
            fallback.y = max(fallback.y, cameraPosition.y - 1.0)
            center = fallback + SIMD3<Float>(0, extent.y * 0.5, 0)
        }

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
        cropVolume = ObjectCropVolume(
            center: center,
            extent: extent,
            transform: transform
        )
        voxelMap.removeAll()
        frameCount = 0
        updateCropBoxNode()
        snapCropBoxToPlanes()
        onCropBoxPlaced?()
    }

    private func snapCropBoxToPlanes() {
        guard var volume = cropVolume,
              let frame = sceneView.session.currentFrame else {
            return
        }
        let planeAnchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planeAnchors.isEmpty else { return }

        let center = volume.center
        let half = volume.extent * 0.5
        var floorY: Float?

        for anchor in planeAnchors {
            let transform = anchor.transform
            let planeCenter = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
            let normal = SIMD3<Float>(
                transform.columns.2.x,
                transform.columns.2.y,
                transform.columns.2.z
            )
            let distance = simd_dot(center - planeCenter, normal)
            if abs(normal.y) > 0.7, abs(distance) < 0.25 {
                floorY = planeCenter.y
            }
        }

        var transform = volume.transform
        if let floorY {
            transform.columns.3.y = floorY + half.y
        }

        let newCenter = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        cropVolume = ObjectCropVolume(
            center: newCenter,
            extent: volume.extent,
            transform: transform
        )
        updateCropBoxNode()
    }

    func moveCropBox(axis: SIMD3<Float>) {
        guard let volume = cropVolume else { return }
        let newCenter = volume.center + axis * 0.05
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

        let cameraPosition = cameraPositionOfScene
        ObjectBoxVisual.addEdgeGeometry(
            to: root,
            extent: volume.extent,
            cameraPosition: cameraPosition,
            isOccupied: { [weak self] world in
                self?.isOccupied(world) ?? false
            }
        )
        ObjectBoxVisual.addAxes(to: root, extent: volume.extent)
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

        func addCylinder(
            axis: SIMD3<Float>,
            length: Float,
            offset: SIMD3<Float>,
            material: SCNMaterial
        ) {
            let cylinder = SCNCylinder(radius: 0.008, height: CGFloat(length))
            cylinder.firstMaterial = material
            let node = SCNNode(geometry: cylinder)
            node.position = SCNVector3(offset.x, offset.y, offset.z)
            node.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: axis
            )
            root.addChildNode(node)
        }

        let solidMaterial = SCNMaterial()
        solidMaterial.lightingModel = .constant
        solidMaterial.diffuse.contents = lineColor
        solidMaterial.emission.contents = lineColor

        let dashedMaterial = SCNMaterial()
        dashedMaterial.lightingModel = .constant
        dashedMaterial.diffuse.contents = lineColor.withAlphaComponent(0.5)
        dashedMaterial.emission.contents = lineColor.withAlphaComponent(0.5)

        func addLine(
            axis: SIMD3<Float>,
            length: Float,
            offset: SIMD3<Float>,
            dashed: Bool
        ) {
            if !dashed {
                addCylinder(
                    axis: axis,
                    length: length,
                    offset: offset,
                    material: solidMaterial
                )
                return
            }
            let dashLength: Float = 0.05
            let gapLength: Float = 0.04
            var cursor: Float = 0
            while cursor < length {
                let dash = min(dashLength, length - cursor)
                let halfLength = length * 0.5
                let centerAlongAxis = -halfLength + cursor + dash * 0.5
                let position = offset + axis * centerAlongAxis
                addCylinder(
                    axis: axis,
                    length: dash,
                    offset: position,
                    material: dashedMaterial
                )
                cursor += dash + gapLength
            }
        }

        var edges: [(SIMD3<Float>, Float, SIMD3<Float>, Float)] = []
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

    private func addCorners(to root: SCNNode, extent: SIMD3<Float>) {
        let half = extent * 0.5
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = lineColor
        material.emission.contents = lineColor
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(-half.x, -half.y, -half.z),
            SIMD3<Float>(-half.x, -half.y, half.z),
            SIMD3<Float>(-half.x, half.y, -half.z),
            SIMD3<Float>(-half.x, half.y, half.z),
            SIMD3<Float>(half.x, -half.y, -half.z),
            SIMD3<Float>(half.x, -half.y, half.z),
            SIMD3<Float>(half.x, half.y, -half.z),
            SIMD3<Float>(half.x, half.y, half.z)
        ]
        for corner in corners {
            let sphere = SCNSphere(radius: 0.012)
            sphere.firstMaterial = material
            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(corner.x, corner.y, corner.z)
            root.addChildNode(node)
        }
    }

    private func animateFlow(on root: SCNNode) {
        root.removeAllActions()
        let action = SCNAction.repeatForever(
            SCNAction.customAction(duration: 1.6) { node, elapsed in
                let phase = (sin(elapsed / 1.6 * 2 * .pi) + 1) / 2
                let alpha = 0.55 + 0.45 * phase
                node.childNodes.forEach { child in
                    child.geometry?.firstMaterial?.emission.contents =
                        UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: alpha)
                }
            }
        )
        root.runAction(action)
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCapturing else { return }
        frameCount += 1
        guard frameCount % 10 == 0 else { return }

        lastPlaneInfos = frame.anchors.compactMap { anchor in
            guard let plane = anchor as? ARPlaneAnchor else { return nil }
            let transform = plane.transform
            return ScanPlaneInfo(
                centerX: transform.columns.3.x,
                centerY: transform.columns.3.y,
                centerZ: transform.columns.3.z,
                normalX: transform.columns.2.x,
                normalY: transform.columns.2.y,
                normalZ: transform.columns.2.z,
                width: plane.extent.x,
                height: plane.extent.y
            )
        }
        captureMeshPoints(from: frame)
        if voxelMap.count >= maxVoxels {
            compactVoxelMap()
        }
        let snapshot = snapshotPoints()
        DispatchQueue.main.async {
            self.updatePointCloud(snapshot, frame: frame)
            self.updateOcclusionMeshes(from: frame)
            if self.cropVolume != nil {
                self.updateCropBoxNode()
            }
            self.onPointCount?(snapshot.count)
        }
    }

    private func updateOcclusionMeshes(from frame: ARFrame) {
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let currentIDs = Set(anchors.map(\.identifier))
        for id in meshOcclusionNodes.keys where !currentIDs.contains(id) {
            meshOcclusionNodes[id]?.removeFromParentNode()
            meshOcclusionNodes.removeValue(forKey: id)
        }
        for anchor in anchors {
            let node: SCNNode
            if let existing = meshOcclusionNodes[anchor.identifier] {
                node = existing
            } else {
                node = SCNNode()
                node.name = "occlusionMesh"
                node.renderingOrder = -20
                sceneView.scene.rootNode.addChildNode(node)
                meshOcclusionNodes[anchor.identifier] = node
            }
            node.simdTransform = anchor.transform
            if let geometry = makeOcclusionGeometry(anchor) {
                node.geometry = geometry
            }
        }
    }

    private func makeOcclusionGeometry(_ anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        guard geo.vertices.count > 0, geo.faces.count > 0 else { return nil }

        let base = geo.vertices.buffer.contents()
        let stride = geo.vertices.stride
        let offset = geo.vertices.offset
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(geo.vertices.count)
        for i in 0..<geo.vertices.count {
            let local = (base + offset + i * stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            vertices.append(SCNVector3(local.x, local.y, local.z))
        }

        let faceBuffer = geo.faces.buffer.contents()
        let bytesPerIndex = geo.faces.bytesPerIndex
        let faceCount = geo.faces.count
        var indices: [Int32] = []
        indices.reserveCapacity(faceCount * 3)
        for faceIndex in 0..<faceCount {
            let baseOffset = faceIndex * 3 * bytesPerIndex
            func read(_ byteOffset: Int) -> Int {
                if bytesPerIndex == 2 {
                    return Int(faceBuffer.load(
                        fromByteOffset: baseOffset + byteOffset,
                        as: UInt16.self
                    ))
                }
                return Int(faceBuffer.load(
                    fromByteOffset: baseOffset + byteOffset,
                    as: UInt32.self
                ))
            }
            indices.append(Int32(read(0)))
            indices.append(Int32(read(bytesPerIndex)))
            indices.append(Int32(read(bytesPerIndex * 2)))
        }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.clear
        material.colorBufferWriteMask = []
        material.writesToDepthBuffer = true
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
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
                if let classificationBuffer {
                    let raw = classificationBuffer.load(
                        fromByteOffset: classificationOffset + i * classificationStride,
                        as: UInt8.self
                    )
                    classification = Int(raw)
                }
                var color = SIMD3<Float>(0.95, 0.55, 0.2)
                let existingCount = voxelMap[key]?.count ?? 0
                if (voxelMap[key] == nil || existingCount < 3),
                   let sampled = sampleCameraColor(frame: frame, world: world) {
                    color = sampled
                } else if let classification {
                    color = classificationColor(ARMeshClassification(rawValue: classification))
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

    private func sampleCameraColor(frame: ARFrame, world: SIMD3<Float>) -> SIMD3<Float>? {
        let image = frame.capturedImage
        let sensorWidth = CVPixelBufferGetWidth(image)
        let sensorHeight = CVPixelBufferGetHeight(image)
        let portraitWidth = CGFloat(sensorHeight)
        let portraitHeight = CGFloat(sensorWidth)
        guard portraitWidth > 0, portraitHeight > 0 else { return nil }
        let projected = frame.camera.projectPoint(
            world,
            orientation: .portrait,
            viewportSize: CGSize(width: portraitWidth, height: portraitHeight)
        )
        guard projected.x.isFinite, projected.y.isFinite,
              projected.x >= 0, projected.y >= 0,
              projected.x <= portraitWidth, projected.y <= portraitHeight else {
            return nil
        }
        let sensorX = Int(projected.y.rounded())
        let sensorY = sensorHeight - 1 - Int(projected.x.rounded())
        let pixelX = min(max(sensorX, 0), sensorWidth - 1)
        let pixelY = min(max(sensorY, 0), sensorHeight - 1)

        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetPlaneCount(image) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0)?
                .assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(image, 1)?
                .assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        let yWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(image, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        guard pixelX < yWidth, pixelY < yHeight else { return nil }
        let yValue = Float(yBase[pixelY * yRow + pixelX])
        let uvX = min(max(pixelX / 2, 0), uvWidth - 1)
        let uvY = min(max(pixelY / 2, 0), uvHeight - 1)
        let uvIndex = uvY * uvRow + uvX * 2
        let cbValue = Float(uvBase[uvIndex]) - 128
        let crValue = Float(uvBase[uvIndex + 1]) - 128
        let rRaw = (yValue + 1.402 * crValue) / 255
        let gRaw = (yValue - 0.344136 * cbValue - 0.714136 * crValue) / 255
        let bRaw = (yValue + 1.772 * cbValue) / 255
        return SIMD3<Float>(
            min(max(rRaw, 0), 1),
            min(max(gRaw, 0), 1),
            min(max(bRaw, 0), 1)
        )
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

    private func updatePointCloud(_ points: [ObjectPoint], frame: ARFrame) {
        guard !points.isEmpty else { return }
        var displayPoints: [ObjectPoint] = []
        displayPoints.reserveCapacity(40_000)
        let scanColor = SIMD3<Float>(0.55, 0.05, 0.05)
        for point in sampled(points, limit: 40_000) {
            let world = point.position
            guard isPointVisible(world: world, frame: frame) else { continue }
            displayPoints.append(ObjectPoint(
                x: point.x,
                y: point.y,
                z: point.z,
                r: scanColor.x,
                g: scanColor.y,
                b: scanColor.z,
                classification: point.classification
            ))
        }
        guard !displayPoints.isEmpty else {
            sceneView.scene.rootNode.childNodes
                .filter { $0.name == "scanPoints" }
                .forEach { $0.removeFromParentNode() }
            return
        }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.black
        material.emission.contents = UIColor(red: 0.55, green: 0.05, blue: 0.05, alpha: 1)
        material.blendMode = .alpha
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

    private func isPointVisible(world: SIMD3<Float>, frame: ARFrame) -> Bool {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return true
        }
        let buffer = frame.capturedImage
        let portraitWidth = CGFloat(CVPixelBufferGetHeight(buffer))
        let portraitHeight = CGFloat(CVPixelBufferGetWidth(buffer))
        guard portraitWidth > 0, portraitHeight > 0 else { return true }
        let projected = frame.camera.projectPoint(
            world,
            orientation: .portrait,
            viewportSize: CGSize(width: portraitWidth, height: portraitHeight)
        )
        guard projected.x.isFinite, projected.y.isFinite,
              projected.x >= 0, projected.y >= 0,
              projected.x <= portraitWidth, projected.y <= portraitHeight else {
            return true
        }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard depthWidth > 0, depthHeight > 0 else { return true }
        let normalizedX = projected.y / portraitHeight
        let normalizedY = 1 - projected.x / portraitWidth
        let depthX = Int(normalizedX * CGFloat(depthWidth))
        let depthY = Int(normalizedY * CGFloat(depthHeight))
        guard depthX >= 0, depthY >= 0, depthX < depthWidth, depthY < depthHeight else {
            return true
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap)?
            .assumingMemoryBound(to: Float32.self) else {
            return true
        }
        let row = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let depthValue = base[depthY * row + depthX]
        guard depthValue > 0.1 else { return true }
        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        let pointDistance = simd_length(world - cameraPosition)
        return pointDistance <= depthValue + 0.15
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
