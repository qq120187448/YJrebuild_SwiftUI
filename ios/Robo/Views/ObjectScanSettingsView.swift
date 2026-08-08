import SwiftUI

struct ObjectScanSettingsView: View {
    @State private var scanPointSize: Double = ObjectScanSettings.pointSize
    @State private var previewPointLimit: Double = Double(ObjectScanSettings.previewPointLimit)
    @State private var previewPointSize: Double = ObjectScanSettings.previewPointSize
    @AppStorage("objectScanRealtimeVoxel") private var realtimeVoxel = false

    var body: some View {
        Form {
            Section("扫描显示") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("扫描点云大小")
                        Spacer()
                        Text(String(format: "%.1f", scanPointSize))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $scanPointSize, in: 1...20, step: 0.5)
                }
                Text("扫描过程中红色点云的大小，范围 1-20。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("预览显示") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("预览云点大小")
                        Spacer()
                        Text(String(format: "%.1f", previewPointSize))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $previewPointSize, in: 1...10, step: 0.5)
                }
                Text("预览 3D 时云点的大小，默认 4。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("预览点云密度")
                        Spacer()
                        Text("\(Int(previewPointLimit))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $previewPointLimit, in: 10_000...200_000, step: 10_000)
                }
                Text("预览 3D 点云时显示的最大点数，默认 80000。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("计算") {
                Toggle("实时体素计算", isOn: $realtimeVoxel)
                Text("开启后调整盒子立即重算体素；关闭时停止操作 0.5 秒后自动重算。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("物体工程扫描设置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scanPointSize) { _, newValue in
            ObjectScanSettings.pointSize = newValue
        }
        .onChange(of: previewPointLimit) { _, newValue in
            ObjectScanSettings.previewPointLimit = Int(newValue)
        }
        .onChange(of: previewPointSize) { _, newValue in
            ObjectScanSettings.previewPointSize = newValue
        }
        .onDisappear {
            ObjectScanSettings.pointSize = scanPointSize
            ObjectScanSettings.previewPointLimit = Int(previewPointLimit)
            ObjectScanSettings.previewPointSize = previewPointSize
        }
    }
}
