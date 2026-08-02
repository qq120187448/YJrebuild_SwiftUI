import SwiftUI
import RoomPlan

struct RoomResultView: View {
    let room: CapturedRoom
    @Binding var roomName: String
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var shareURLs: [URL] = []
    @State private var isExporting = false
    @State private var exportError: String?

    private var floorArea: Double {
        RoomDataProcessor.estimateFloorArea(room)
    }

    private var ceilingHeight: Double {
        RoomDataProcessor.estimateCeilingHeight(room.walls)
    }

    private var wallArea: Double {
        RoomDataProcessor.computeTotalWallArea(room.walls)
    }

    private var volume: Double {
        floorArea * ceilingHeight
    }

    private var displayName: String {
        let trimmed = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名房间" : trimmed
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .padding(.top, 24)

                Text(AppStrings.Scan.complete)
                    .font(.title.bold())

                TextField(AppStrings.Scan.roomNamePlaceholder, text: $roomName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 24)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    statCard(value: "\(room.walls.count)", label: "墙", icon: "square.split.2x1")
                    statCard(value: "\(room.doors.count)", label: "门", icon: "door.left.hand.open")
                    statCard(value: "\(room.windows.count)", label: "窗", icon: "window.vertical.open")
                    statCard(value: "\(room.objects.count)", label: "物体", icon: "cube")
                }
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    metricRow(label: "地面面积", value: String(format: "%.2f m²", floorArea))
                    metricRow(label: "层高", value: String(format: "%.2f m", ceilingHeight))
                    metricRow(label: "墙面面积", value: String(format: "%.2f m²", wallArea))
                    metricRow(label: "房间体积", value: String(format: "%.2f m³", volume))
                }
                .padding()
                .background(.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button(action: onSave) {
                        Label(AppStrings.Scan.save, systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        exportQuantity()
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .tint(.accentColor)
                            } else {
                                Image(systemName: "doc.text")
                            }
                            Text(AppStrings.Scan.exportQuantity)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.secondary.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isExporting)

                    Button(AppStrings.Scan.discard, role: .destructive) {
                        onDiscard()
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
        }
        .alert("导出失败", isPresented: .constant(exportError != nil)) {
            Button("好") { exportError = nil }
        } message: {
            if let exportError {
                Text(exportError)
            }
        }
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs = [] } }
        )) {
            ActivityView(activityItems: shareURLs)
        }
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline)
        }
    }

    private func exportQuantity() {
        isExporting = true
        do {
            shareURLs = try QuantityTakeoffExporter.makeExportFiles(room: room, roomName: displayName)
        } catch {
            exportError = error.localizedDescription
        }
        isExporting = false
    }
}
