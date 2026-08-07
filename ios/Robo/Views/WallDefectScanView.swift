import ARKit
import RoomPlan
import SwiftUI
import UIKit

struct WallDefectScanView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case instructions
        case scanning
        case model
    }

    @State private var phase: Phase = .instructions
    @State private var scanID = UUID()
    @State private var capturedRoom: CapturedRoom?
    @State private var surfaces: [WallDefectSurface] = []
    @State private var photos: [WallDefectPhoto] = []
    @State private var defectARSession: ARSession?
    @State private var stopRequested = false
    @State private var errorMessage: String?
    @State private var savedPath: String?

    var body: some View {
        NavigationStack {
            Group {
                if !RoomCaptureSession.isSupported {
                    ContentUnavailableView(
                        "不支持 LiDAR",
                        systemImage: "camera.metering.unknown",
                        description: Text("墙地面缺陷扫描需要带 LiDAR 的 iPhone Pro 或 iPad Pro。")
                    )
                } else {
                    switch phase {
                    case .instructions:
                        instructionsView
                    case .scanning:
                        scanningView
                    case .model:
                        if let capturedRoom, let defectARSession {
                            WallDefectModelView(
                                room: capturedRoom,
                                surfaces: surfaces,
                                arSession: defectARSession,
                                onPhoto: { associations, capture in
                                    handlePhoto(associations: associations, capture: capture)
                                },
                                onSave: {
                                    saveDocument()
                                },
                                onDiscard: {
                                    dismiss()
                                }
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
                        Button("完成扫描") {
                            stopRequested = true
                        }
                    } else {
                        Button("关闭") {
                            dismiss()
                        }
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
                    if phase == .scanning {
                        phase = .instructions
                    }
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
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .instructions: return "墙地面缺陷扫描"
        case .scanning: return "RoomPlan 建模"
        case .model: return "墙体补拍"
        }
    }

    private var instructionsView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.07, blue: 0.10),
                    Color(red: 0.07, green: 0.12, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 18)
                    Image(systemName: "paintbrush.pointed")
                        .font(.system(size: 58))
                        .foregroundStyle(.cyan)
                    Text("墙地面缺陷扫描")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text("先用 RoomPlan 建立全屋墙体底座，再定点拍摄霉斑、水渍、污渍和裂缝。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    VStack(alignment: .leading, spacing: 12) {
                        tipRow(icon: "figure.walk", text: "缓慢环绕房间扫描，覆盖所有墙面和地面")
                        tipRow(icon: "square.split.2x1", text: "扫描后自动拆分墙体并生成 UV 坐标")
                        tipRow(icon: "camera.viewfinder", text: "对准缺陷定点拍摄，记录相机位姿和 LiDAR 深度")
                        tipRow(icon: "bolt.badge.a", text: "识别结果按墙 ID 汇总，输出修缮工程量")
                    }
                    .padding(18)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)

                    Button {
                        startScan()
                    } label: {
                        Text("开始 RoomPlan 建模")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 30)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var scanningView: some View {
        ZStack {
            RoomCaptureViewWrapper(
                stopRequested: $stopRequested,
                onCaptureComplete: { room in
                    capturedRoom = room
                    surfaces = WallDefectGeometry.surfaces(from: room)
                    if let defectARSession {
                        saveWorldMap(defectARSession)
                    }
                    phase = .model
                },
                onCaptureError: { error in
                    errorMessage = error.localizedDescription
                },
                initialWorldMap: WallDefectARSessionStore.load(),
                onARSessionReady: { session in
                    defectARSession = session
                    saveWorldMap(session)
                },
                keepARSessionAlive: true
            )
            .ignoresSafeArea()

            VStack {
                Label("正在扫描，请缓慢移动", systemImage: "figure.walk")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(.top, 10)
                Spacer()
            }
        }
    }

    private func startScan() {
        scanID = UUID()
        capturedRoom = nil
        surfaces = []
        photos = []
        defectARSession = nil
        errorMessage = nil
        savedPath = nil
        phase = .scanning
    }

    private func saveWorldMap(_ session: ARSession) {
        session.getCurrentWorldMap { worldMap, _ in
            guard let worldMap else { return }
            try? WallDefectARSessionStore.save(worldMap)
        }
    }

    private func handlePhoto(
        associations: [WallDefectSurfaceAssociation],
        capture: DefectCameraCapture
    ) {
        guard let primary = associations.first else { return }
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
                wallID: primary.surfaceID,
                imageFileName: stored.imageFileName,
                pose: capture.pose,
                intrinsics: capture.intrinsics,
                depthFileName: stored.depthFileName,
                depthWidth: capture.depthWidth,
                depthHeight: capture.depthHeight,
                detectedClass: nil,
                note: "识别中...",
                surfaceAssociations: associations,
                annotatedFileName: nil,
                crackResult: nil
            )
            photos.append(photo)

            let config = CrackRecognitionSettings.load()
            let capturedSurfaces = surfaces
            let capturedScanID = scanID
            let capturedImage = capture.image
            let capturedPose = capture.pose
            let capturedIntrinsics = capture.intrinsics
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try CrackRecognitionEngine.analyze(
                        image: capturedImage,
                        pose: capturedPose,
                        intrinsics: capturedIntrinsics,
                        surfaces: capturedSurfaces,
                        config: config
                    )
                    let annotatedFileName = try WallDefectStore.saveAnnotatedPhoto(
                        documentID: capturedScanID,
                        photoID: photoID,
                        image: output.annotatedImage
                    )
                    DispatchQueue.main.async {
                        guard let index = self.photos.firstIndex(
                            where: { $0.id == photoID }
                        ) else {
                            return
                        }
                        self.photos[index].crackResult = output.result
                        self.photos[index].annotatedFileName = annotatedFileName
                        self.photos[index].detectedClass = output.result.detectedClass
                        self.photos[index].note = output.result.isEmpty
                            ? "未识别到裂缝"
                            : "裂缝 \(output.result.components.count) 条 · 总长 \(String(format: "%.3f m", output.result.totalLengthM))"
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let index = self.photos.firstIndex(
                            where: { $0.id == photoID }
                        ) else {
                            return
                        }
                        self.photos[index].note = "识别失败：\(error.localizedDescription)"
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveDocument() {
        guard let capturedRoom else { return }
        do {
            let roomJSON = try RoomDataProcessor.encodeFullRoom(capturedRoom)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            let document = WallDefectScanDocument(
                id: scanID,
                name: "墙地面缺陷扫描 \(formatter.string(from: Date()))",
                roomJSON: roomJSON,
                surfaces: surfaces,
                photos: photos
            )
            let url = try WallDefectStore.save(document: document)
            savedPath = url.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
