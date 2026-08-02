import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("关于") {
                    LabeledContent("名称", value: "Robo 工程量扫描")
                    LabeledContent("版本", value: "1.0")
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
            }
            .navigationTitle(AppStrings.Tabs.settings)
            .confirmationDialog(
                "清空所有扫描记录？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("删除全部", role: .destructive) {
                    for room in rooms {
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
