import SwiftUI
import UIKit
import RoomPlan
import SwiftData

struct LiDARScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var phase: ScanPhase = .instructions
    @State private var capturedRoom: CapturedRoom?
    @State private var error: String?
    @State private var stopRequested = false
    @State private var roomName = ""
    @State private var roomType = "其他"
    @State private var photos: [PhotoAttachment] = []
    @State private var seenComponentIDs: Set<String> = []
    @State private var pendingComponents: [String: String] = [:]
    @State private var pendingPhotoComponentID: String?
    @State private var showCamera = false

    private enum ScanPhase {
        case instructions
        case scanning
        case results
    }

    var body: some View {
        NavigationStack {
            Group {
                if !RoomCaptureSession.isSupported {
                    ContentUnavailableView(
                        "不支持 LiDAR",
                        systemImage: "camera.metering.unknown",
                        description: Text("需要带 LiDAR 的 iPhone Pro 或 iPad Pro。")
                    )
                } else {
                    switch phase {
                    case .instructions:
                        instructionsView
                    case .scanning:
                        scanningView
                    case .results:
                        if let capturedRoom {
                            RoomResultView(
                                room: capturedRoom,
                                roomName: $roomName,
                                roomType: $roomType,
                                photos: $photos,
                                onSave: saveRoom,
                                onDiscard: { dismiss() }
                            )
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .scanning {
                        Button(AppStrings.Scan.done) {
                            stopRequested = true
                        }
                    } else if phase == .instructions {
                        Button(AppStrings.Scan.cancel) {
                            dismiss()
                        }
                    }
                }
            }
            .alert("扫描出错", isPresented: .constant(error != nil)) {
                Button("好") {
                    error = nil
                    phase = .instructions
                }
            } message: {
                if let error {
                    Text(error)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .instructions: return AppStrings.Scan.title
        case .scanning: return AppStrings.Scan.scanning
        case .results: return "扫描结果"
        }
    }

    private var instructionsView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "camera.metering.spot")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text(AppStrings.Scan.title)
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 12) {
                tipRow(icon: "sun.max", text: "保证光线充足")
                tipRow(icon: "figure.walk", text: "缓慢绕房间一周")
                tipRow(icon: "arrow.up.and.down", text: "从地板扫到天花板")
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                resetScanPhotos()
                phase = .scanning
            } label: {
                Text(AppStrings.Scan.start)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }

    private var scanningView: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureViewWrapper(
                stopRequested: $stopRequested,
                onCaptureComplete: { room in
                    capturedRoom = room
                    phase = .results
                },
                onCaptureError: { err in
                    error = err.localizedDescription
                },
                onRoomUpdate: { room in
                    handleRoomUpdate(room)
                }
            )
            .ignoresSafeArea()

            photoPromptOverlay
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                capturePhoto(image: image)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var photoPromptOverlay: some View {
        if !pendingComponents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("构件拍照")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(pendingComponents.count) 项待拍")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pendingComponents.keys.sorted()), id: \.self) { id in
                            Button {
                                pendingPhotoComponentID = id
                                showCamera = true
                            } label: {
                                HStack(spacing: 6) {
                                    Text(pendingComponents[id] ?? "")
                                        .font(.caption.bold())
                                    Image(systemName: "camera.fill")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.16))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
    }

    private func handleRoomUpdate(_ room: CapturedRoom) {
        var found: [String: String] = [:]
        for (index, door) in room.doors.enumerated() {
            found[door.identifier.uuidString] = "门\(index + 1)"
        }
        for (index, window) in room.windows.enumerated() {
            found[window.identifier.uuidString] = "窗\(index + 1)"
        }
        for (index, opening) in room.openings.enumerated() {
            found[opening.identifier.uuidString] = "洞口\(index + 1)"
        }
        for (index, object) in room.objects.enumerated() {
            found[object.identifier.uuidString] =
                "\(QuantityTakeoffExporter.objectCategoryName(object.category))\(index + 1)"
        }

        var added: [String: String] = [:]
        for (id, label) in found where !seenComponentIDs.contains(id) {
            added[id] = label
        }
        guard !added.isEmpty else { return }
        seenComponentIDs.formUnion(added.keys)
        for (id, label) in added {
            if !photos.contains(where: { $0.componentID?.uuidString == id }) {
                pendingComponents[id] = label
            }
        }
    }

    private func capturePhoto(image: UIImage) {
        guard let id = pendingPhotoComponentID, let componentID = UUID(uuidString: id) else {
            showCamera = false
            return
        }
        let label = pendingComponents[id] ?? "构件"
        if let index = photos.firstIndex(where: { $0.componentID == componentID }) {
            photos[index] = PhotoAttachment(label: label, image: image, componentID: componentID)
        } else {
            photos.append(PhotoAttachment(label: label, image: image, componentID: componentID))
        }
        pendingComponents.removeValue(forKey: id)
        pendingPhotoComponentID = nil
        showCamera = false
    }

    private func resetScanPhotos() {
        seenComponentIDs = []
        pendingComponents = [:]
        pendingPhotoComponentID = nil
        photos = []
        showCamera = false
    }

    private func saveRoom() {
        guard let room = capturedRoom else { return }

        do {
            let summary = RoomDataProcessor.summarizeRoom(room)
            let summaryData = try RoomDataProcessor.encodeSummary(summary)
            let fullData = try RoomDataProcessor.encodeFullRoom(room)

            let trimmedName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if trimmedName.isEmpty {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M月d日 HH:mm"
                name = "房间 \(formatter.string(from: Date()))"
            } else {
                name = trimmedName
            }

            let quantityData = try QuantityTakeoffExporter.makeJSON(room: room, roomName: name, roomType: roomType)

            var photoLabels: [String] = []
            var photoFileNames: [String] = []
            var photoComponentIDs: [String] = []
            let labelMap = QuantityTakeoffExporter.componentLabels(room: room)
            for photo in photos {
                let finalLabel: String
                if let id = photo.componentID, let mapped = labelMap[id] {
                    finalLabel = mapped
                } else {
                    finalLabel = photo.label
                }
                let saved = try PhotoStorage.save(image: photo.image, label: finalLabel)
                photoLabels.append(saved.label)
                photoFileNames.append(saved.fileName)
                photoComponentIDs.append(photo.componentID?.uuidString ?? "")
            }

            var usdzData: Data?
            do {
                let usdzURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).usdz")
                try room.export(to: usdzURL, exportOptions: .model)
                usdzData = try Data(contentsOf: usdzURL)
                try? FileManager.default.removeItem(at: usdzURL)
            } catch {
                // USDZ 导出失败不影响记录保存
            }

            let floorArea = RoomDataProcessor.estimateFloorArea(room)
            let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)

            let record = RoomScanRecord(
                roomName: name,
                wallCount: room.walls.count,
                doorCount: room.doors.count,
                windowCount: room.windows.count,
                openingCount: room.openings.count,
                objectCount: room.objects.count,
                floorAreaSqM: floorArea,
                ceilingHeightM: ceilingHeight,
                totalWallAreaSqM: RoomDataProcessor.computeTotalWallArea(room.walls),
                volumeM3: floorArea * ceilingHeight,
                roomType: roomType,
                summaryJSON: summaryData,
                fullRoomDataJSON: fullData,
                quantityJSON: quantityData,
                usdzData: usdzData,
                photoLabels: photoLabels,
                photoFileNames: photoFileNames,
                photoComponentIDs: photoComponentIDs
            )

            modelContext.insert(record)
            try modelContext.save()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
