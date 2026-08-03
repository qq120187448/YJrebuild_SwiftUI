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
    @State private var adjustments = RoomAdjustments()
    @State private var buildingID: String?
    @State private var suiteMode = false
    @State private var photographedCount = 0
    @State private var recognizedCount = 0

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
                                adjustments: $adjustments,
                                suiteMode: suiteMode,
                                onSave: saveRoom,
                                onSaveAndContinue: saveRoomAndContinue,
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
        .onAppear {
            updateScreenSleepPrevention()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: phase) { _, _ in
            updateScreenSleepPrevention()
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

            Toggle("套房连续扫描（整套房多房间）", isOn: $suiteMode)
                .font(.subheadline)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                tipRow(icon: "sun.max", text: "保证光线充足")
                tipRow(icon: "figure.walk", text: "缓慢绕房间一周")
                tipRow(icon: "arrow.up.and.down", text: "从地板扫到天花板")
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
            photos = []
            adjustments = RoomAdjustments()
            buildingID = buildingID ?? UUID().uuidString
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
        ZStack {
            RoomCaptureViewWrapper(
                stopRequested: $stopRequested,
                onCaptureComplete: { room in
                    capturedRoom = room
                    phase = .results
                },
                onCaptureError: { err in
                    error = err.localizedDescription
                },
                onComponentCaptured: { image, label, componentID in
                    appendComponentPhoto(image: image, label: label, componentID: componentID)
                },
                onStatusUpdate: { photographed, recognized in
                    photographedCount = photographed
                    recognizedCount = recognized
                }
            )
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.white)
                    Text("已拍 \(photographedCount)/\(max(recognizedCount, photographedCount))")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    if recognizedCount > photographedCount {
                        Text("有构件未拍照")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(.top, 8)
                .padding(.horizontal, 16)

                Spacer()
            }
        }
    }

    private func updateScreenSleepPrevention() {
        UIApplication.shared.isIdleTimerDisabled = (phase == .scanning)
    }

    private func appendComponentPhoto(image: UIImage, label: String, componentID: String) {
        guard let id = UUID(uuidString: componentID) else { return }
        if let index = photos.firstIndex(where: { $0.componentID == id }) {
            photos[index] = PhotoAttachment(label: label, image: image, componentID: id)
        } else {
            photos.append(PhotoAttachment(label: label, image: image, componentID: id))
        }
    }

    private func deduplicatedPhotos(_ input: [PhotoAttachment]) -> [PhotoAttachment] {
        var seenIDs = Set<UUID>()
        var seenLabels = Set<String>()
        return input.reversed().filter { photo in
            var duplicate = false
            if let id = photo.componentID {
                duplicate = seenIDs.contains(id)
                seenIDs.insert(id)
            }
            if !duplicate && seenLabels.contains(photo.label) {
                duplicate = true
            }
            seenLabels.insert(photo.label)
            return !duplicate
        }.reversed()
    }

    private func saveRoom() {
        guard let room = capturedRoom else { return }
        do {
            try persistRoom(room)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveRoomAndContinue() {
        guard let room = capturedRoom else { return }
        do {
            try persistRoom(room)
            roomName = ""
            roomType = "其他"
            photos = []
            adjustments = RoomAdjustments()
            capturedRoom = nil
            phase = .instructions
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func persistRoom(_ room: CapturedRoom) throws {
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

            let quantityData = try QuantityTakeoffExporter.makeJSON(
                room: room,
                roomName: name,
                roomType: roomType,
                adjustments: adjustments
            )

            var photoLabels: [String] = []
            var photoFileNames: [String] = []
            var photoComponentIDs: [String] = []
            let labelMap = QuantityTakeoffExporter.componentLabels(room: room)
            for photo in deduplicatedPhotos(photos) {
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
                photoComponentIDs: photoComponentIDs,
                buildingID: buildingID,
                adjustmentsJSON: AdjustmentStorage.encode(adjustments)
            )

            modelContext.insert(record)
            try modelContext.save()
    }
}
