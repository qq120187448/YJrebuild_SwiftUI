import SwiftUI
import UIKit
import RoomPlan

struct RoomResultView: View {
    let room: CapturedRoom
    @Binding var roomName: String
    @Binding var roomType: String
    @Binding var photos: [PhotoAttachment]
    @Binding var adjustments: RoomAdjustments
    let suiteMode: Bool
    let onSave: () -> Void
    let onSaveAndContinue: () -> Void
    let onDiscard: () -> Void

    private let roomTypes = ["客厅", "卧室", "餐厅", "厨房", "卫生间", "其他"]

    @State private var shareURLs: [URL] = []
    @State private var isExporting = false
    @State private var isExportingModel = false
    @State private var showAdjustments = false
    @State private var showQuantityPreview = false
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("房间类型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("房间类型", selection: $roomType) {
                        ForEach(roomTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
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

                photoSummarySection
                    .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button(action: onSave) {
                        Label(
                            suiteMode ? "保存并结束整套房扫描" : AppStrings.Scan.save,
                            systemImage: "square.and.arrow.down"
                        )
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

                    if suiteMode {
                        Button {
                            onSaveAndContinue()
                        } label: {
                            Label("保存并扫描下一间", systemImage: "plus.rectangle.on.rectangle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.secondary.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    Button {
                        showAdjustments = true
                    } label: {
                        Label("调整构件尺寸", systemImage: "ruler")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.secondary.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        showQuantityPreview = true
                    } label: {
                        Label("预览工程量清单", systemImage: "list.number")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.secondary.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        exportModel()
                    } label: {
                        HStack {
                            if isExportingModel {
                                ProgressView()
                                    .tint(.accentColor)
                            } else {
                                Image(systemName: "cube.transparent")
                            }
                            Text("导出 3D 模型（USDZ/PLY）")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.secondary.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isExportingModel)

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
        .sheet(isPresented: $showAdjustments) {
            ComponentAdjustmentView(room: room, adjustments: $adjustments)
        }
        .sheet(isPresented: $showQuantityPreview) {
            QuantityPreviewView(
                room: room,
                roomName: displayName,
                roomType: roomType,
                adjustments: adjustments,
                photos: photos.compactMap { photo -> XLSXWriter.ImageAttachment? in
                    guard let data = photo.image.jpegData(compressionQuality: 0.7) else { return nil }
                    return XLSXWriter.ImageAttachment(
                        label: photo.label,
                        data: data,
                        fileExtension: "jpg",
                        componentID: photo.componentID?.uuidString
                    )
                }
            )
        }
    }

    @ViewBuilder
    private var photoSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("扫描过程实拍照片")
                    .font(.headline)
                Spacer()
                Text("\(photos.count) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if photos.isEmpty {
                Text("本次扫描未拍摄构件照片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(photos) { photo in
                            VStack(spacing: 4) {
                                Image(uiImage: photo.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(photo.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            let imageAttachments = photos.compactMap { photo -> XLSXWriter.ImageAttachment? in
                guard let data = photo.image.jpegData(compressionQuality: 0.8) else { return nil }
                return XLSXWriter.ImageAttachment(
                    label: photo.label,
                    data: data,
                    fileExtension: "jpg",
                    componentID: photo.componentID?.uuidString
                )
            }
            shareURLs = try QuantityTakeoffExporter.makeExportFiles(
                room: room,
                roomName: displayName,
                roomType: roomType,
                capturedAt: Date(),
                unitPrices: UnitPriceStore.load(),
                photos: imageAttachments,
                adjustments: adjustments
            )
        } catch {
            exportError = error.localizedDescription
        }
        isExporting = false
    }

    private func exportModel() {
        isExportingModel = true
        do {
            shareURLs = try ModelExportService.makeExportFiles(
                room: room,
                roomName: displayName
            )
        } catch {
            exportError = error.localizedDescription
        }
        isExportingModel = false
    }
}
