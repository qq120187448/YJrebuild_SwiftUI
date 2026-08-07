import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @Query(sort: \TextureScanRecord.capturedAt, order: .reverse)
    private var textureScans: [TextureScanRecord]

    @State private var showClearConfirm = false
    @State private var showPriceImporter = false
    @State private var priceMessage = ""
    @State private var scanPointSize: Double = ObjectScanSettings.pointSize
    @State private var previewPointLimit: Double = Double(ObjectScanSettings.previewPointLimit)
    @State private var previewPointSize: Double = ObjectScanSettings.previewPointSize
    @AppStorage("objectScanRealtimeVoxel") private var realtimeVoxel = false

    var body: some View {
        NavigationStack {
            Form {
                Section("关于") {
                    LabeledContent("名称", value: "Robo 工程量扫描")
                    LabeledContent("版本", value: "0.62")
                    Text("基于 Robo 精简改造：只保留 LiDAR 房间扫描与工程量清单导出，数据仅保存在本机，不连接任何后端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("缺陷识别") {
                    NavigationLink {
                        CrackRecognitionSettingsView()
                    } label: {
                        Label("识别设置", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        CrackPhotoLabView()
                    } label: {
                        Label("裂缝照片检测", systemImage: "photo.on.rectangle")
                    }
                    NavigationLink {
                        CrackModelValidationView()
                    } label: {
                        Label("模型分辨率验证", systemImage: "checkmark.seal")
                    }
                }

                Section("数据") {
                    Button("清空所有扫描记录", role: .destructive) {
                        showClearConfirm = true
                    }
                    .disabled(rooms.isEmpty && textureScans.isEmpty)
                }

                Section("物体工程扫描") {
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

                    Toggle("实时体素计算", isOn: $realtimeVoxel)
                    Text("开启后调整盒子立即重算体素；关闭时停止操作 0.5 秒后自动重算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("单价表") {
                    Button {
                        showPriceImporter = true
                    } label: {
                        Label("导入单价表（CSV）", systemImage: "tablecells")
                    }
                    Text("CSV 需包含：清单编码、项目名称、单位、综合单价。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !priceMessage.isEmpty {
                        Text(priceMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let count = UnitPriceStore.load().count
                    Text("当前已加载 \(count) 条单价")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(AppStrings.Tabs.settings)
            .onChange(of: scanPointSize) { _, newValue in
                ObjectScanSettings.pointSize = newValue
            }
            .onChange(of: previewPointLimit) { _, newValue in
                ObjectScanSettings.previewPointLimit = Int(newValue)
            }
            .onChange(of: previewPointSize) { _, newValue in
                ObjectScanSettings.previewPointSize = newValue
            }
            .fileImporter(
                isPresented: $showPriceImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text]
            ) { result in
                switch result {
                case .success(let url):
                    do {
                        let text = try String(contentsOf: url, encoding: .utf8)
                        let outcome = UnitPriceStore.importCSV(text)
                        priceMessage = outcome.message
                    } catch {
                        priceMessage = "读取单价表失败"
                    }
                case .failure:
                    priceMessage = "未选择单价表"
                }
            }
            .confirmationDialog(
                "清空所有扫描记录？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("删除全部", role: .destructive) {
                    for room in rooms {
                        for fileName in room.photoFileNames {
                            PhotoStorage.delete(fileName: fileName)
                        }
                        modelContext.delete(room)
                    }
                    for record in textureScans {
                        modelContext.delete(record)
                    }
                    try? modelContext.save()
                }
            } message: {
                Text("此操作无法撤销。")
            }
        }
    }
}
