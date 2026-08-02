import SwiftUI
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
        RoomCaptureViewWrapper(
            stopRequested: $stopRequested,
            onCaptureComplete: { room in
                capturedRoom = room
                phase = .results
            },
            onCaptureError: { err in
                error = err.localizedDescription
            }
        )
        .ignoresSafeArea()
    }

    private func saveRoom() {
        guard let room = capturedRoom else { return }

        do {
            let summary = RoomDataProcessor.summarizeRoom(room)
            let summaryData = try RoomDataProcessor.encodeSummary(summary)
            let fullData = try RoomDataProcessor.encodeFullRoom(room)
            let quantityData = try QuantityTakeoffExporter.makeJSON(room: room)

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
                summaryJSON: summaryData,
                fullRoomDataJSON: fullData,
                quantityJSON: quantityData,
                usdzData: usdzData
            )

            modelContext.insert(record)
            try modelContext.save()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
