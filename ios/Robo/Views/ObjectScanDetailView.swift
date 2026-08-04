import SwiftUI

struct ObjectScanDetailView: View {
    let record: ObjectScanRecord

    @State private var metrics: ObjectScanMetrics?
    @State private var points: [ObjectPoint] = []
    @State private var shareURLs: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
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
                    ObjectPointCloud3DView(points: points)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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
            }

            Section("体素表面重建（Surface Nets）") {
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
}
