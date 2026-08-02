import SwiftUI
import SwiftData

struct ScanHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @State private var showingLiDAR = false

    var body: some View {
        NavigationStack {
            Group {
                if rooms.isEmpty {
                    ContentUnavailableView {
                        Label("暂无扫描记录", systemImage: "camera.metering.spot")
                    } description: {
                        Text("扫描房间后，工程量清单会保存在这里。")
                    } actions: {
                        Button(AppStrings.Scan.start) {
                            showingLiDAR = true
                        }
                    }
                } else {
                    List {
                        ForEach(rooms) { room in
                            NavigationLink(value: room) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(room.roomName)
                                        .font(.headline)
                                    Text("墙 \(room.wallCount) · 门 \(room.doorCount) · 窗 \(room.windowCount) · 物体 \(room.objectCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "面积 %.2f m² · 体积 %.2f m³", room.floorAreaSqM, room.volumeM3))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    for fileName in room.photoFileNames {
                                        PhotoStorage.delete(fileName: fileName)
                                    }
                                    modelContext.delete(room)
                                    try? modelContext.save()
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationDestination(for: RoomScanRecord.self) { room in
                RoomDetailView(room: room)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingLiDAR = true
                    } label: {
                        Label(AppStrings.Scan.title, systemImage: "camera.metering.spot")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingLiDAR) {
            LiDARScanView()
        }
    }
}
