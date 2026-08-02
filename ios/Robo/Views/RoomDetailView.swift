import SwiftUI
import SwiftData
import RoomPlan

struct RoomDetailView: View {
    let room: RoomScanRecord

    @State private var shareURLs: [URL] = []
    @State private var show3D = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.roomName)
                        .font(.title2.bold())
                    Text(room.capturedAt, format: .dateTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("工程量") {
                LabeledContent("墙面", value: "\(room.wallCount) 面")
                LabeledContent("门", value: "\(room.doorCount) 樘")
                LabeledContent("窗", value: "\(room.windowCount) 扇")
                LabeledContent("物体", value: "\(room.objectCount) 个")
                LabeledContent("地面面积", value: String(format: "%.2f m²", room.floorAreaSqM))
                LabeledContent("层高", value: String(format: "%.2f m", room.ceilingHeightM))
                LabeledContent("墙面面积", value: String(format: "%.2f m²", room.totalWallAreaSqM))
                LabeledContent("房间体积", value: String(format: "%.2f m³", room.volumeM3))
            }

            if room.usdzData != nil {
                Section("3D 预览") {
                    Picker("视图", selection: $show3D) {
                        Text("2D").tag(false)
                        Text("3D").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if show3D {
                        Room3DView(room: room)
                            .frame(height: 300)
                    }
                }
            }

            Section {
                Button {
                    exportQuantity()
                } label: {
                    Label(AppStrings.Scan.exportQuantity, systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("扫描详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs = [] } }
        )) {
            ActivityView(activityItems: shareURLs)
        }
    }

    private func exportQuantity() {
        do {
            let capturedRoom = try RoomDataProcessor.decodeFullRoom(room.fullRoomDataJSON)
            shareURLs = try QuantityTakeoffExporter.makeExportFiles(room: capturedRoom)
        } catch {
            // 导出失败时保持静默，避免打断详情页
        }
    }
}
