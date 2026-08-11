import ARKit
import simd
import SwiftUI
import UIKit

struct WallDefectScanView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var scanID = UUID()
    @State private var photos: [WallDefectPhoto] = []
    @State private var arSession: ARSession?
    @State private var latestRecognition: WallDefectPhotoRecognitionResult?
    @State private var isPhotoAnalyzing = false
    @State private var recognitionProgress = ""
    @State private var errorMessage: String?
    @State private var savedPath: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if let arSession {
                    WallDefectModelView(
                        arSession: arSession,
                        latestRecognition: latestRecognition,
                        isRecognizing: isPhotoAnalyzing,
                        progressMessage: recognitionProgress,
                        onPhoto: { capture, plane in
                            handlePhoto(capture: capture, plane: plane)
                        },
                        onSave: {
                            saveDocument()
                        },
                        onDiscard: {
                            dismiss()
                        }
                    )
                } else {
                    Color.black
                        .overlay {
                            ProgressView("正在启动 ARKit")
                                .foregroundStyle(.white)
                        }
                }
            }
            .navigationTitle("墙地面缺陷扫描")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .alert(
                "扫描出错",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好") {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                "已保存",
                isPresented: Binding(
                    get: { savedPath != nil },
                    set: { if !$0 { savedPath = nil } }
                )
            ) {
                Button("好") {
                    savedPath = nil
                }
            } message: {
                if let savedPath {
                    Text("扫描包已保存：\(savedPath)")
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                startSession()
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                arSession?.pause()
            }
        }
    }

    private func startSession() {
        guard arSession == nil else { return }
        CrackRecognitionSettings.save(.defaultConfig)
        scanID = UUID()
        photos = []
        latestRecognition = nil
        isPhotoAnalyzing = false
        recognitionProgress = ""
        errorMessage = nil
        savedPath = nil

        let session = ARSession()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        session.run(configuration)
        arSession = session
    }

    private func handlePhoto(
        capture: DefectCameraCapture,
        plane: WallDefectSurface?
    ) {
        let primaryID = plane?.id ?? UUID()
        isPhotoAnalyzing = true
        latestRecognition = nil
        recognitionProgress = "正在保存照片"
        let photoID = UUID()
        do {
            let stored = try WallDefectStore.savePhoto(
                documentID: scanID,
                image: capture.image,
                depth: capture.depth,
                photoID: photoID
            )
            let photo = WallDefectPhoto(
                id: photoID,
                wallID: primaryID,
                imageFileName: stored.imageFileName,
                pose: capture.pose,
                intrinsics: capture.intrinsics,
                depthFileName: stored.depthFileName,
                depthWidth: capture.depthWidth,
                depthHeight: capture.depthHeight,
                detectedClass: nil,
                note: "识别中...",
                surfaceAssociations: plane.map {
                    [WallDefectSurfaceAssociation(
                        surfaceID: $0.id,
                        label: "墙面",
                        coverageRatio: 1
                    )]
                } ?? [],
                planeSurface: plane
            )
            photos.append(photo)

            let config = CrackRecognitionSettings.load()
            let surfaces = plane.map { [$0] } ?? []
            let image = capture.image
            let pose = capture.pose
            let intrinsics = capture.intrinsics
            let depthContext: CrackDepthContext?
            if let depth = capture.depth,
               let depthWidth = capture.depthWidth,
               let depthHeight = capture.depthHeight,
               let depthBytesPerRow = capture.depthBytesPerRow {
                depthContext = CrackDepthContext(
                    depth: depth,
                    depthWidth: depthWidth,
                    depthHeight: depthHeight,
                    depthBytesPerRow: depthBytesPerRow,
                    sensorIntrinsics: capture.sensorIntrinsics,
                    depthNormalizedTransform: capture.depthNormalizedTransform,
                    fullImageSize: capture.fullImageSize,
                    cropRect: capture.cropRect,
                    sensorImageSize: capture.sensorImageSize
                )
            } else {
                depthContext = nil
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try CrackRecognitionEngine.analyze(
                        image: image,
                        pose: pose,
                        intrinsics: intrinsics,
                        surfaces: surfaces,
                        config: config,
                        progress: { message, _ in
                            DispatchQueue.main.async {
                                self.recognitionProgress = message
                            }
                        },
                        depthContext: depthContext
                    )
                    DispatchQueue.main.async {
                        guard let index = self.photos.firstIndex(
                            where: { $0.id == photoID }
                        ) else {
                            return
                        }
                        self.photos[index].crackResult = output.result
                        self.photos[index].detectedClass = output.result.detectedClass
                        self.photos[index].arSkeleton3D = output.arSkeleton.map {
                            [
                                Double($0.pixel.x),
                                Double($0.pixel.y),
                                Double($0.world.x),
                                Double($0.world.y),
                                Double($0.world.z)
                            ]
                        }
                        if output.result.isEmpty {
                            let reason = output.filteredReason
                                ?? "未识别到有效裂缝"
                            self.photos[index].note = "检测 \(output.rawDetectionCount) 处 · 掩码 \(output.maskPointCount) 点 · 骨架 \(output.preFilterComponentCount) 组 · \(reason)"
                        } else {
                            self.photos[index].note = "裂缝 \(output.result.components.count) 条 · 总长 \(String(format: "%.3f m", output.result.totalLengthM))"
                        }
                        self.applyDedup()
                        self.latestRecognition = WallDefectPhotoRecognitionResult(
                            result: output.result,
                            annotatedImage: output.annotatedImage,
                            arSkeleton: output.arSkeleton,
                            timings: output.timings,
                            rawDetectionCount: output.rawDetectionCount,
                            skeletonComponentCount: output.skeletonComponentCount,
                            projectedComponentCount: output.projectedComponentCount,
                            pixelLengthReported: output.pixelLengthReported,
                            maskPointCount: output.maskPointCount,
                            preFilterComponentCount: output.preFilterComponentCount,
                            filteredReason: output.filteredReason
                        )
                        self.isPhotoAnalyzing = false
                        self.recognitionProgress = ""
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let index = self.photos.firstIndex(
                            where: { $0.id == photoID }
                        ) else {
                            return
                        }
                        self.photos[index].note = "识别失败：\(error.localizedDescription)"
                        self.latestRecognition = nil
                        self.isPhotoAnalyzing = false
                        self.recognitionProgress = ""
                    }
                }
            }
        } catch {
            isPhotoAnalyzing = false
            recognitionProgress = ""
            errorMessage = error.localizedDescription
        }
    }

    private func applyDedup() {
        let threshold = CrackRecognitionSettings.load().dedupDistanceMM / 1000
        var representatives: [WallDefectSurface] = []
        var groups: [[Int]] = []

        for (index, photo) in photos.enumerated() {
            guard let plane = photo.planeSurface else { continue }
            var groupID = -1
            for (g, rep) in representatives.enumerated()
            where WallDefectPlaneEstimator.samePlane(rep, plane) {
                groupID = g
                break
            }
            if groupID < 0 {
                representatives.append(plane)
                groups.append([index])
            } else {
                groups[groupID].append(index)
            }
        }

        for indices in groups {
            var existing: [SIMD3<Double>] = []
            for index in indices {
                guard let points = photos[index].arSkeleton3D,
                      !points.isEmpty else {
                    continue
                }
                let worldPoints = points.map {
                    SIMD3<Double>($0[2], $0[3], $0[4])
                }
                let matched = worldPoints.filter { point in
                    existing.contains {
                        simd_distance(point, $0) < threshold
                    }
                }.count
                if Double(matched) / Double(worldPoints.count) > 0.5 {
                    photos[index].isDuplicate = true
                    photos[index].note = "重复拍摄，已去重"
                } else {
                    existing.append(contentsOf: worldPoints)
                }
            }
        }
    }

    private func uniquePlaneSurfaces() -> [WallDefectSurface] {
        var result: [WallDefectSurface] = []
        for photo in photos {
            guard let plane = photo.planeSurface else { continue }
            if !result.contains(where: {
                WallDefectPlaneEstimator.samePlane($0, plane)
            }) {
                result.append(plane)
            }
        }
        return result.enumerated().map { index, surface in
            WallDefectSurface(
                id: surface.id,
                kind: surface.kind,
                label: "墙面 \(index + 1)",
                width: surface.width,
                height: surface.height,
                area: surface.area,
                origin: surface.origin,
                uAxis: surface.uAxis,
                vAxis: surface.vAxis,
                normal: surface.normal
            )
        }
    }

    private func saveDocument() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        let document = WallDefectScanDocument(
            id: scanID,
            name: "墙地面缺陷扫描 \(formatter.string(from: Date()))",
            surfaces: uniquePlaneSurfaces(),
            photos: photos
        )
        do {
            let url = try WallDefectStore.save(document: document)
            savedPath = url.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
