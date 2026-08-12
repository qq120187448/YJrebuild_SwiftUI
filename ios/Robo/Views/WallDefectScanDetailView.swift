import SwiftUI
import UIKit

struct WallDefectScanDetailView: View {
    let document: WallDefectScanDocument

    private var photosDirectory: URL {
        WallDefectStore.rootDirectory()
            .appendingPathComponent(document.id.uuidString)
            .appendingPathComponent("Photos", isDirectory: true)
    }

    private var planeSummaries: [PlaneSummary] {
        var groups: [[WallDefectPhoto]] = []
        for photo in document.photos {
            guard let plane = photo.planeSurface else { continue }
            var target = -1
            for (index, group) in groups.enumerated() {
                guard let first = group.first,
                      let rep = first.planeSurface,
                      WallDefectPlaneEstimator.samePlane(rep, plane) else {
                    continue
                }
                target = index
                break
            }
            if target >= 0 {
                groups[target].append(photo)
            } else {
                groups.append([photo])
            }
        }
        return groups.enumerated().map { index, group in
            let nonDuplicate = group.filter { !$0.isDuplicate }
            let totalLength = nonDuplicate.reduce(0) {
                $0 + ($1.crackResult?.totalLengthM ?? 0)
            }
            let crackCount = nonDuplicate.reduce(0) {
                $0 + ($1.crackResult?.components.count ?? 0)
            }
            return PlaneSummary(
                id: group.first?.planeSurface?.id ?? UUID(),
                label: "墙面 \(index + 1)",
                photoCount: group.count,
                duplicateCount: group.count - nonDuplicate.count,
                totalLengthM: totalLength,
                crackCount: crackCount
            )
        }
    }

    var body: some View {
        List {
            Section("扫描信息") {
                LabeledContent("名称", value: document.name)
                LabeledContent("扫描时间", value: document.capturedAt.formatted())
                LabeledContent("墙面", value: "\(planeSummaries.count)")
                LabeledContent("照片", value: "\(document.photos.count) 张")
            }

            if !planeSummaries.isEmpty {
                Section("墙面裂缝汇总") {
                    ForEach(planeSummaries) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.label)
                                .font(.headline)
                            Text("裂缝 \(summary.crackCount) 条 · 总长 \(String(format: "%.3f m", summary.totalLengthM))")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                            Text("照片 \(summary.photoCount) 张 · 去重 \(summary.duplicateCount) 张")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if document.surfaces.isEmpty, planeSummaries.isEmpty {
                Section("墙面") {
                    Text("尚无墙面平面，请先完成扫描与拍照")
                        .foregroundStyle(.secondary)
                }
            }

            if !document.photos.isEmpty {
                Section("缺陷照片") {
                    ForEach(document.photos) { photo in
                        HStack(spacing: 12) {
                            thumbnail(for: photo)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(surfaceLabel(photo))
                                    .font(.headline)
                                Text(photo.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(photo.note.isEmpty ? "待 CoreML 识别" : photo.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let crackResult = photo.crackResult {
                                    Text("裂缝 \(crackResult.components.count) 条 · 总长 \(String(format: "%.3f m", crackResult.totalLengthM))")
                                        .font(.caption.bold())
                                        .foregroundStyle(.orange)
                                }
                                if let annotatedFileName = photo.annotatedFileName {
                                    NavigationLink {
                                        CrackRecognitionResultView(
                                            result: photo.crackResult
                                                ?? emptyResult(),
                                            annotatedImage: annotatedImage(
                                                fileName: annotatedFileName
                                            )
                                        )
                                    } label: {
                                        Label("查看标注", systemImage: "wand.and.stars")
                                            .font(.caption)
                                    }
                                }
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

    private func surfaceLabel(_ photo: WallDefectPhoto) -> String {
        if let plane = photo.planeSurface {
            if let surface = document.surfaces.first(
                where: { $0.id == plane.id }
            ) {
                return surface.label
            }
            if let surface = document.surfaces.first(
                where: { WallDefectPlaneEstimator.samePlane($0, plane) }
            ) {
                return surface.label
            }
        }
        return "未知墙面"
    }

    private func annotatedImage(fileName: String) -> UIImage? {
        let url = photosDirectory.appendingPathComponent(fileName)
        return UIImage(contentsOfFile: url.path)
    }

    private func emptyResult() -> CrackRecognitionResult {
        CrackRecognitionResult(
            detectedClass: "无结果",
            confidence: 0,
            totalPixelLength: 0,
            totalMMLength: nil,
            totalLengthM: 0,
            totalAreaM2: 0,
            components: [],
            surfaceSummaries: [],
            mode: "normal",
            modelSize: "s",
            engine: "yolo",
            measurementVersion: nil,
            measurementEngine: nil
        )
    }

    private struct PlaneSummary: Identifiable {
        let id: UUID
        let label: String
        let photoCount: Int
        let duplicateCount: Int
        let totalLengthM: Double
        let crackCount: Int
    }
}
