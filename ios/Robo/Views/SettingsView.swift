import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @State private var showClearConfirm = false
    @State private var showPriceImporter = false
    @State private var priceMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("关于") {
                    LabeledContent("名称", value: "Robo 工程量扫描")
                    LabeledContent("版本", value: "0.2.1")
                    Text("基于 Robo 精简改造：只保留 LiDAR 房间扫描与工程量清单导出，数据仅保存在本机，不连接任何后端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("数据") {
                    Button("清空所有扫描记录", role: .destructive) {
                        showClearConfirm = true
                    }
                    .disabled(rooms.isEmpty)
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
                    try? modelContext.save()
                }
            } message: {
                Text("此操作无法撤销。")
            }
        }
    }
}
