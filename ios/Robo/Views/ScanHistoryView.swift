import SwiftUI
import SwiftData

enum ScanHistoryFilter: Hashable {
    case all
    case room
    case object
    case texture
}

struct ScanHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var filter: ScanHistoryFilter

    @Query(sort: \RoomScanRecord.capturedAt, order: .reverse)
    private var rooms: [RoomScanRecord]

    @Query(sort: \ObjectScanRecord.capturedAt, order: .reverse)
    private var objectScans: [ObjectScanRecord]

    @Query(sort: \TextureScanRecord.capturedAt, order: .reverse)
    private var textureScans: [TextureScanRecord]

    @State private var showingLiDAR = false
    @State private var shareURLs: [URL] = []

    private struct BuildingGroup: Identifiable {
        let id: String
        let name: String
        let rooms: [RoomScanRecord]
    }

    private var buildingGroups: [BuildingGroup] {
        let grouped = Dictionary(grouping: rooms) { room -> String in
            room.buildingID ?? "单间-\(room.id)"
        }
        return grouped.map { id, groupRooms in
            let sorted = groupRooms.sorted { $0.capturedAt < $1.capturedAt }
            let name = sorted.count > 1
                ? "整套房（\(sorted.count) 个房间）"
                : (sorted.first?.roomName ?? "房间")
            return BuildingGroup(id: id, name: name, rooms: sorted)
        }
        .sorted {
            ($0.rooms.first?.capturedAt ?? .distantPast) >
                ($1.rooms.first?.capturedAt ?? .distantPast)
        }
    }

    init(filter: Binding<ScanHistoryFilter> = .constant(.all)) {
        _filter = filter
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("类型", selection: $filter) {
                        Text("全部").tag(ScanHistoryFilter.all)
                        Text("房间").tag(ScanHistoryFilter.room)
                        Text("物体").tag(ScanHistoryFilter.object)
                        Text("实景").tag(ScanHistoryFilter.texture)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowInsets(EdgeInsets())

                if filter == .all || filter == .room {
                    if rooms.isEmpty {
                        emptyRow("暂无房间扫描记录", systemImage: "house")
                    } else {
                        ForEach(buildingGroups) { group in
                            Section {
                                ForEach(group.rooms) { room in
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
                            } header: {
                                HStack {
                                    Text(group.name)
                                    Spacer()
                                    if group.rooms.count > 1 {
                                        Button("导出整房") {
                                            exportBuilding(group)
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }

                if filter == .all || filter == .object {
                    if objectScans.isEmpty {
                        emptyRow("暂无物体工程扫描记录", systemImage: "cube.transparent")
                    } else {
                        Section("物体工程扫描") {
                            ForEach(objectScans) { record in
                                NavigationLink(value: record) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.objectName)
                                            .font(.headline)
                                        Text("点数 \(record.pointCount) · 体积 \(String(format: "%.3f m³", record.heightfieldVolumeM3))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("上表面积 \(String(format: "%.3f m²", record.heightfieldSurfaceAreaM2))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(record)
                                        try? modelContext.save()
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                if filter == .all || filter == .texture {
                    if textureScans.isEmpty {
                        emptyRow("暂无实景建模记录", systemImage: "camera.aperture")
                    } else {
                        Section("实景建模 / 玩具箱") {
                            ForEach(textureScans) { record in
                                NavigationLink(value: record) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("实景建模 \(record.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.headline)
                                        Text("\(record.deviceModel) · \(record.photoCount) 张照片 · \(record.deviceMaxResolution)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "扫描时长 %.0f 秒", record.duration))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(record)
                                        try? modelContext.save()
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
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
            .navigationDestination(for: ObjectScanRecord.self) { record in
                ObjectScanDetailView(record: record)
            }
            .navigationDestination(for: TextureScanRecord.self) { record in
                TextureScanHistoryDetailView(record: record)
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
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs = [] } }
        )) {
            ActivityView(activityItems: shareURLs)
        }
    }

    private func emptyRow(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

private func exportBuilding(_ group: BuildingGroup) {
        do {
            let inputs = try group.rooms.map { record -> QuantityTakeoffExporter.RoomExportInput in
                let baseRoom = try RoomDataProcessor.decodeFullRoom(record.fullRoomDataJSON)
                let photos = zip(record.photoLabels, record.photoFileNames).enumerated().compactMap { index, pair in
                    let id = index < record.photoComponentIDs.count ? record.photoComponentIDs[index] : ""
                    return PhotoStorage.load(
                        label: pair.0,
                        fileName: pair.1,
                        componentID: id.isEmpty ? nil : id
                    )
                }
                return QuantityTakeoffExporter.RoomExportInput(
                    room: baseRoom,
                    roomName: record.roomName,
                    roomType: record.roomType,
                    capturedAt: record.capturedAt,
                    photos: photos,
                    adjustments: AdjustmentStorage.decode(record.adjustmentsJSON)
                )
            }
            shareURLs = try QuantityTakeoffExporter.makeMultiRoomExportFiles(inputs: inputs)
        } catch {
            // 导出失败时保持静默，避免打断列表页
        }
    }
}

struct TextureScanHistoryDetailView: View {
    let record: TextureScanRecord
    @State private var showPreview = false
    @State private var showShare = false

    private var usdzURL: URL {
        URL(fileURLWithPath: record.usdzPath)
    }

    private var usdzExists: Bool {
        !record.usdzPath.isEmpty &&
        FileManager.default.fileExists(atPath: record.usdzPath)
    }

    var body: some View {
        List {
            Section("扫描信息") {
                LabeledContent("设备", value: record.deviceModel)
                LabeledContent("模式", value: record.deviceMaxResolution)
                LabeledContent("照片数", value: "\(record.photoCount)")
                LabeledContent("扫描时长", value: String(format: "%.0f 秒", record.duration))
                LabeledContent("模型格式", value: "USDZ")
            }

            Section("模型") {
                if usdzExists {
                    Button {
                        showPreview = true
                    } label: {
                        Label("预览 3D 模型", systemImage: "arkit")
                    }
                    Button {
                        showShare = true
                    } label: {
                        Label("导出 USDZ", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("模型文件不存在")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("实景建模记录")
        .sheet(isPresented: $showPreview) {
            NavigationStack {
                USDZSceneView(url: usdzURL)
                    .ignoresSafeArea()
                    .background(Color.black)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") {
                                showPreview = false
                            }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(activityItems: [usdzURL])
        }
    }
}
