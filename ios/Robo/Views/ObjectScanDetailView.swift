import SwiftUI

struct ObjectScanDetailView: View {
    let record: ObjectScanRecord

    @State private var metrics: ObjectScanMetrics?
    @State private var points: [ObjectPoint] = []
    @State private var cropVolume: ObjectCropVolume?
    @State private var axisMoveCommand: AxisMoveCommand = .none
    @State private var shareURLs: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        let voxelOK = metrics?.voxelReconstructionSucceeded
            ?? (metrics?.voxelMeshVolumeM3 != nil)
        let previewPoints = sampled(points, limit: ObjectScanSettings.previewPointLimit)
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
                    ObjectCropBox3DView(
                        points: previewPoints,
                        targetPoints: previewPoints,
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

                    if cropVolume != nil {
                        historyCropBoxPanel
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
                LabeledContent(
                    "AABB 外包围尺寸",
                    value: String(
                        format: "%.2f × %.2f × %.2f m",
                        metrics?.aabb.sizeX ?? 0,
                        metrics?.aabb.sizeY ?? 0,
                        metrics?.aabb.sizeZ ?? 0
                    )
                )
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
                DisclosureGroup("AABB / OBB 说明") {
                    Text("AABB：沿世界坐标 X/Y/Z 方向的外包围盒。")
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
                        "不规则物体表面积（不含地面/墙面接触）",
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
                    Text("用小立方体填充点云后计算体积和表面积。")
                }
            }

            Section("堆体/土方（高度场，参考）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", record.heightfieldVolumeM3)
                )
                LabeledContent(
                    "高度场表面积（参考）",
                    value: String(format: "%.3f m²", record.heightfieldSurfaceAreaM2)
                )
                DisclosureGroup("高度场说明") {
                    Text("从上方按网格高度估算体积和表面积。")
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
        let filtered = points.filter { volume.contains(worldPoint: $0.position) }
        Task.detached(priority: .userInitiated) {
            let pair = ObjectScanProcessor.metricsAndUSDZ(for: filtered)
            await MainActor.run {
                metrics = pair.metrics
            }
        }
    }

    private func sampled(_ points: [ObjectPoint], limit: Int) -> [ObjectPoint] {
        guard points.count > limit, limit > 0 else { return points }
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
}
