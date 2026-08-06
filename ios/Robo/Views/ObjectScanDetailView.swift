import SwiftUI

private enum HistoryPointMode: String, CaseIterable, Identifiable {
    case all
    case cropBoxOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部点云"
        case .cropBoxOnly: return "仅裁剪盒内"
        }
    }
}

struct ObjectScanDetailView: View {
    let record: ObjectScanRecord

    @State private var metrics: ObjectScanMetrics?
    @State private var points: [ObjectPoint] = []
    @State private var cropVolume: ObjectCropVolume?
    @State private var axisMoveCommand: AxisMoveCommand = .none
    @State private var shareURLs: [URL] = []
    @State private var errorMessage: String?
    @State private var metricsTask: Task<Void, Never>?
    @State private var historyPointMode: HistoryPointMode = .all
    @AppStorage("objectScanPreviewPointSize") private var previewPointSizeSetting: Double = 4
    @AppStorage("objectScanBoxLineWidth") private var boxLineWidthSetting: Double = 4
    @AppStorage("objectScanRealtimeVoxel") private var realtimeVoxel = false

    var body: some View {
        let voxelOK = metrics?.voxelReconstructionSucceeded
            ?? (metrics?.voxelMeshVolumeM3 != nil)
        let displayPoints = historyPointMode == .cropBoxOnly
            ? points.filter { cropVolume?.contains(worldPoint: $0.position) ?? true }
            : points
        List {
            Section("3D 预览") {
                if points.isEmpty {
                    ContentUnavailableView(
                        "暂无 3D 点云",
                        systemImage: "cube.transparent",
                        description: Text("该历史记录没有保存点云数据。")
                    )
                    .frame(height: 200)
                } else {
                    Picker("显示点云", selection: $historyPointMode) {
                        ForEach(HistoryPointMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(cropVolume == nil)

                    ObjectCropBox3DView(
                        points: displayPoints,
                        targetPoints: displayPoints,
                        previewMode: .all,
                        cropVolume: cropVolume,
                        placeRequested: false,
                        axisMoveCommand: axisMoveCommand,
                        onCropVolumeChanged: { cropVolume = $0 },
                        onCropBoxEditEnded: { volume in
                            recomputeMetrics(for: volume)
                        },
                        onCommandHandled: { axisMoveCommand = .none }
                    )
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .id("\(previewPointSizeSetting)-\(boxLineWidthSetting)")

                    if cropVolume != nil {
                        historyCropBoxPanel
                        if let volume = cropVolume {
                            let groundY = points.map { $0.y }.min() ?? volume.origin.y
                            LabeledContent(
                                "离地高度",
                                value: String(
                                    format: "%.2f m",
                                    max(0, volume.origin.y - groundY)
                                )
                            )
                        }
                    }
                }
            }

            Section("对象") {
                LabeledContent("名称", value: record.objectName)
                LabeledContent("扫描时间", value: record.capturedAt.formatted())
                LabeledContent("原始点数", value: "\(record.pointCount)")
                LabeledContent("处理点数", value: "\(record.processedPointCount)")
                LabeledContent("目标点数", value: "\(record.targetPointCount)")
                LabeledContent("点簇数量", value: "\(record.clusterCount)")
                if let removedCount = metrics?.backgroundRemovedCount,
                   let ratio = metrics?.backgroundRemovedRatio {
                    LabeledContent(
                        "已剔除背景点",
                        value: "\(removedCount)（\(String(format: "%.1f%%", ratio * 100))）"
                    )
                }
                if let value = metrics?.classificationRemovedCount {
                    LabeledContent("分类剔除", value: "\(value)")
                }
                if let value = metrics?.planeAnchorRemovedCount {
                    LabeledContent("AR 平面剔除", value: "\(value)")
                }
                if let value = metrics?.groundRemovedCount {
                    LabeledContent("地面剔除", value: "\(value)")
                }
                if let value = metrics?.ransacRemovedCount {
                    LabeledContent("RANSAC 平面剔除", value: "\(value)")
                }
                if let value = metrics?.localPlaneRemovedCount {
                    LabeledContent("局部平面剔除", value: "\(value)")
                }
                if let value = metrics?.recognizedGroundPointCount {
                    LabeledContent("识别地面点数", value: "\(value)")
                }
                if let value = metrics?.recognizedWallPointCount {
                    LabeledContent("识别墙面点数", value: "\(value)")
                }
                if let value = metrics?.wallRemovedCount {
                    LabeledContent("已剔除墙面点数", value: "\(value)")
                }
                LabeledContent(
                    "OBB 长×宽×高",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        record.obbLengthM,
                        record.obbWidthM,
                        record.obbHeightM
                    )
                )
                LabeledContent(
                    "占地面积",
                    value: String(
                        format: "%.2f m²",
                        metrics?.footprintAreaM2 ?? 0
                    )
                )
                DisclosureGroup("OBB 说明") {
                    Text("OBB：按物体自身方向拟合的最优外包围盒。")
                }
            }

            Section("体素表面重建（Surface Nets）") {
                if voxelOK {
                    LabeledContent(
                        "体积（闭合封口）",
                        value: String(
                            format: "%.3f m³",
                            metrics?.voxelMeshVolumeM3 ?? record.heightfieldVolumeM3
                        )
                    )
                    LabeledContent(
                        "上表面积（外露表面，不含地面/墙面）",
                        value: String(
                            format: "%.3f m²",
                            metrics?.voxelMeshSurfaceAreaM2 ?? record.heightfieldSurfaceAreaM2
                        )
                    )
                    LabeledContent(
                        "网格总表面积",
                        value: String(
                            format: "%.3f m²",
                            metrics?.voxelMeshTotalSurfaceAreaM2 ?? record.heightfieldSurfaceAreaM2
                        )
                    )
                    if let voxelSize = metrics?.voxelSizeM {
                        LabeledContent(
                            "体素尺寸",
                            value: String(format: "%.4f m", voxelSize)
                        )
                    }
                    if let coverage = metrics?.voxelCoverageEstimate {
                        LabeledContent(
                            "点云覆盖率",
                            value: String(format: "%.0f%%", coverage * 100)
                        )
                    }
                    if let note = metrics?.voxelNote {
                        LabeledContent("体素说明", value: note)
                    }
                } else {
                    LabeledContent(
                        "体素重建状态",
                        value: metrics?.voxelFailureReason ?? "未生成"
                    )
                    Text("请参考高度场或凸包结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("体素说明") {
                    Text("用小立方体填充点云后计算体积；上表面积按外露表面计算，已扣除地面和墙面接触。")
                }
            }

            Section("堆体/土方（高度场，参考）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", record.heightfieldVolumeM3)
                )
                LabeledContent(
                    "高度场表面积（上表面，不含地面）",
                    value: String(format: "%.3f m²", record.heightfieldSurfaceAreaM2)
                )
                DisclosureGroup("高度场说明") {
                    Text("按网格最高点估算体积和上表面面积，不包含纯地面面积。")
                }
            }

            Section("设备（凸包）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", record.convexHullVolumeM3)
                )
                LabeledContent(
                    "表面积",
                    value: String(format: "%.3f m²", record.convexHullSurfaceAreaM2)
                )
                DisclosureGroup("凸包说明") {
                    Text("包裹所有点云的最小凸多面体。")
                }
            }

            Section {
                Button {
                    exportExcel()
                } label: {
                    Label("导出 Excel", systemImage: "tablecells")
                }
                Button {
                    export()
                } label: {
                    Label("导出 PLY / USDZ / JSON", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("物体工程扫描")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            metrics = try? JSONDecoder().decode(
                ObjectScanMetrics.self,
                from: record.metricsJSON
            )
            points = (try? JSONDecoder().decode([ObjectPoint].self, from: record.pointsJSON)) ?? []
            if let data = record.cropVolumeData,
               let snapshot = try? JSONDecoder().decode(
                ObjectCropVolumeSnapshot.self,
                from: data
               ),
               let volume = ObjectCropVolume(snapshot: snapshot) {
                cropVolume = volume
                recomputeMetrics(for: volume)
            }
        }
        .alert("导出失败", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
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

    private func export() {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ObjectScan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = directory.appendingPathComponent("object-scan")
            let jsonURL = base.appendingPathExtension("json")
            try record.metricsJSON.write(to: jsonURL)
            var urls = [jsonURL]
            if let plyData = record.plyData {
                let plyURL = base.appendingPathExtension("ply")
                try plyData.write(to: plyURL)
                urls.append(plyURL)
            }
            if let usdzData = record.usdzData {
                let usdzURL = base.appendingPathExtension("usdz")
                try usdzData.write(to: usdzURL)
                urls.append(usdzURL)
            }
            shareURLs = urls
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportExcel() {
        guard let metrics else {
            errorMessage = "测量数据缺失，无法导出"
            return
        }
        let thumbnail = ObjectPointCloud3DView.thumbnail(points: points)
        do {
            let url = try ObjectScanExporter.makeExcelFile(
                input: ObjectScanExporter.Input(
                    objectName: record.objectName,
                    capturedAt: record.capturedAt,
                    metrics: metrics,
                    rawPointCount: record.pointCount,
                    thumbnail: thumbnail
                )
            )
            shareURLs = [url]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var historyCropBoxPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text("移动").font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 28)
                RepeatCommandButton(title: "X-", color: .red, command: .xMinus, current: $axisMoveCommand)
                RepeatCommandButton(title: "X+", color: .red, command: .xPlus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Y-", color: .green, command: .yMinus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Y+", color: .green, command: .yPlus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Z-", color: .blue, command: .zMinus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Z+", color: .blue, command: .zPlus, current: $axisMoveCommand)
            }
            HStack(spacing: 5) {
                Text("尺寸").font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 28)
                RepeatCommandButton(title: "X-", color: .red, command: .sizeXMinus, current: $axisMoveCommand)
                RepeatCommandButton(title: "X+", color: .red, command: .sizeXPlus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Y-", color: .green, command: .sizeYMinus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Y+", color: .green, command: .sizeYPlus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Z-", color: .blue, command: .sizeZMinus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Z+", color: .blue, command: .sizeZPlus, current: $axisMoveCommand)
            }
            HStack(spacing: 5) {
                Text("旋转").font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 28)
                RepeatCommandButton(title: "Z-1°", color: .blue, command: .rotateZMinus, current: $axisMoveCommand)
                RepeatCommandButton(title: "Z+1°", color: .blue, command: .rotateZPlus, current: $axisMoveCommand)
            }
        }
        .padding(.vertical, 6)
    }

    private func recomputeMetrics(for volume: ObjectCropVolume) {
        let recognizedGround = metrics?.recognizedGroundPointCount
        let recognizedWall = metrics?.recognizedWallPointCount
        let filtered = points.filter { volume.contains(worldPoint: $0.position) }
        let groundY = filtered.map { $0.y }.min() ?? volume.origin.y
        var lightweight = ObjectScanProcessor.lightweightMetrics(
            for: filtered,
            groundY: groundY
        )
        let aligned = volume.alignedExtents(points: filtered)
        let alignedX = aligned.x
        let alignedY = aligned.y
        let alignedZ = aligned.z
        lightweight.obbLengthM = Double(alignedX)
        lightweight.obbWidthM = Double(alignedZ)
        lightweight.obbHeightM = Double(alignedY)
        lightweight.recognizedGroundPointCount = recognizedGround
        lightweight.recognizedWallPointCount = recognizedWall
        metrics = lightweight
        metricsTask?.cancel()
        let useRealtime = realtimeVoxel
        let task = Task.detached(priority: .userInitiated) {
            if !useRealtime {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if Task.isCancelled { return }
            let pair = ObjectScanProcessor.metricsAndUSDZ(for: filtered)
            await MainActor.run {
                var metrics = pair.metrics
                metrics.obbLengthM = Double(alignedX)
                metrics.obbWidthM = Double(alignedZ)
                metrics.obbHeightM = Double(alignedY)
                metrics.recognizedGroundPointCount = recognizedGround
                metrics.recognizedWallPointCount = recognizedWall
                self.metrics = metrics
            }
        }
        metricsTask = task
    }

}
