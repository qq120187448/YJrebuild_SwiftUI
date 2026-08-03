import SwiftUI
import SwiftData
import RoomPlan

struct RoomDetailView: View {
    let room: RoomScanRecord

    @State private var shareURLs: [URL] = []
    @State private var show3D = false
    @State private var isExportingModel = false
    @State private var showQuantityPreview = false

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
                LabeledContent("房间类型", value: room.roomType)
                LabeledContent("地面面积", value: String(format: "%.2f m²", room.floorAreaSqM))
                LabeledContent("层高", value: String(format: "%.2f m", room.ceilingHeightM))
                LabeledContent("墙面面积", value: String(format: "%.2f m²", room.totalWallAreaSqM))
                LabeledContent("房间体积", value: String(format: "%.2f m³", room.volumeM3))
                LabeledContent("实拍照片", value: "\(room.photoLabels.count) 张")
            }

            Section("预览") {
                Picker("视图", selection: $show3D) {
                    Text("2D").tag(false)
                    Text("3D").tag(true)
                }
                .pickerStyle(.segmented)

                if show3D {
                    Room3DView(room: room)
                        .frame(height: 300)
                } else {
                    FloorPlan2DView(room: room)
                        .frame(height: 300)
                }
            }

            Section {
                Button {
                    exportQuantity()
                } label: {
                    Label(AppStrings.Scan.exportQuantity, systemImage: "doc.text")
                }
                Button {
                    exportModel()
                } label: {
                    HStack {
                        if isExportingModel {
                            ProgressView()
                        } else {
                            Image(systemName: "cube.transparent")
                        }
                        Text("导出 3D 模型（USDZ/PLY）")
                    }
                }
                .disabled(isExportingModel)

                Button {
                    showQuantityPreview = true
                } label: {
                    Label("预览工程量清单", systemImage: "list.number")
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
        .sheet(isPresented: $showQuantityPreview) {
            QuantityPreviewView(
                room: try? RoomDataProcessor.decodeFullRoom(room.fullRoomDataJSON),
                roomName: room.roomName,
                roomType: room.roomType,
                adjustments: AdjustmentStorage.decode(room.adjustmentsJSON)
            )
        }
    }

    private func exportQuantity() {
        do {
            let baseRoom = try RoomDataProcessor.decodeFullRoom(room.fullRoomDataJSON)
            let savedAdjustments = AdjustmentStorage.decode(room.adjustmentsJSON)
            let photos = zip(room.photoLabels, room.photoFileNames).enumerated().compactMap { index, pair in
                let id = index < room.photoComponentIDs.count ? room.photoComponentIDs[index] : ""
                return PhotoStorage.load(
                    label: pair.0,
                    fileName: pair.1,
                    componentID: id.isEmpty ? nil : id
                )
            }
            shareURLs = try QuantityTakeoffExporter.makeExportFiles(
                room: baseRoom,
                roomName: room.roomName,
                roomType: room.roomType,
                capturedAt: room.capturedAt,
                unitPrices: UnitPriceStore.load(),
                photos: photos,
                adjustments: savedAdjustments
            )
        } catch {
            // 导出失败时保持静默，避免打断详情页
        }
    }

    private func exportModel() {
        do {
            let baseRoom = try RoomDataProcessor.decodeFullRoom(room.fullRoomDataJSON)
            isExportingModel = true
            shareURLs = try ModelExportService.makeExportFiles(
                room: baseRoom,
                roomName: room.roomName
            )
        } catch {
            // 导出失败时保持静默，避免打断详情页
        }
        isExportingModel = false
    }
}
