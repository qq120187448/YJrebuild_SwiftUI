import SwiftUI
import UIKit

struct WallDefectScanDetailView: View {
    let document: WallDefectScanDocument

    private var photosDirectory: URL {
        WallDefectStore.rootDirectory()
            .appendingPathComponent(document.id.uuidString)
            .appendingPathComponent("Photos", isDirectory: true)
    }

    var body: some View {
        List {
            Section("扫描信息") {
                LabeledContent("名称", value: document.name)
                LabeledContent("扫描时间", value: document.capturedAt.formatted())
                LabeledContent("墙面/地面", value: "\(document.surfaces.count)")
                LabeledContent("照片", value: "\(document.photos.count) 张")
            }

            Section("墙面 / 地面") {
                ForEach(document.surfaces) { surface in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(surface.label)
                            .font(.headline)
                        Text(surface.uvDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("ID \(surface.id.uuidString.prefix(8).uppercased())")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }

            if !document.photos.isEmpty {
                Section("缺陷照片") {
                    ForEach(document.photos) { photo in
                        HStack(spacing: 12) {
                            thumbnail(for: photo)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(surfaceLabel(photo.wallID))
                                    .font(.headline)
                                Text(photo.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(photo.note.isEmpty ? "待 CoreML 识别" : photo.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("墙地面缺陷扫描")
    }

    @ViewBuilder
    private func thumbnail(for photo: WallDefectPhoto) -> some View {
        let url = photosDirectory.appendingPathComponent(photo.imageFileName)
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func surfaceLabel(_ surfaceID: UUID) -> String {
        document.surfaces.first { $0.id == surfaceID }?.label ?? "未知墙面"
    }
}
