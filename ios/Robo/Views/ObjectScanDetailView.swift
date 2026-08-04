import SwiftUI

struct ObjectScanDetailView: View {
    let record: ObjectScanRecord

    @State private var metrics: ObjectScanMetrics?
    @State private var shareURLs: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("对象") {
                LabeledContent("名称", value: record.objectName)
                LabeledContent("扫描时间", value: record.capturedAt.formatted())
                LabeledContent("原始点数", value: "\(record.pointCount)")
                LabeledContent("处理点数", value: "\(record.processedPointCount)")
                if let metrics {
                    LabeledContent(
                        "外包围尺寸",
                        value: String(
                            format: "%.2f × %.2f × %.2f m",
                            metrics.aabb.sizeX,
                            metrics.aabb.sizeY,
                            metrics.aabb.sizeZ
                        )
                    )
                }
            }

            Section("堆体/土方（高度场）") {
                LabeledContent(
                    "体积",
                    value: String(format: "%.3f m³", record.heightfieldVolumeM3)
                )
                LabeledContent(
                    "表面积",
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
}
