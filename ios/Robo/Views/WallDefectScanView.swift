import RoomPlan
import SwiftUI
import UIKit

struct WallDefectScanView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case instructions
        case scanning
        case walls
    }

    @State private var phase: Phase = .instructions
    @State private var scanID = UUID()
    @State private var capturedRoom: CapturedRoom?
    @State private var surfaces: [WallDefectSurface] = []
    @State private var photos: [WallDefectPhoto] = []
    @State private var selectedSurface: WallDefectSurface?
    @State private var showCapture = false
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
                    case .walls:
                        if let capturedRoom {
                            wallsView(room: capturedRoom)
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
            .sheet(isPresented: $showCapture) {
                if let selectedSurface {
                    WallDefectPhotoCaptureView(surface: selectedSurface) { capture in
                        handlePhoto(capture)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .instructions: return "墙地面缺陷扫描"
        case .scanning: return "RoomPlan 建模"
        case .walls: return "墙体底座"
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
                    phase = .walls
                },
                onCaptureError: { error in
                    errorMessage = error.localizedDescription
                }
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

    private func wallsView(room: CapturedRoom) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryHeader(room: room)

                ForEach(surfaces) { surface in
                    surfaceCard(surface)
                }

                Button {
                    saveDocument()
                } label: {
                    Label(
                        photos.isEmpty ? "保存墙体底座" : "保存扫描包（\(photos.count) 张照片）",
                        systemImage: "square.and.arrow.down"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.cyan)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)

                Button(role: .destructive) {
                    dismiss()
                } label: {
                    Label("不保存退出", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .padding(.vertical, 12)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.07, blue: 0.10),
                    Color(red: 0.07, green: 0.12, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private func summaryHeader(room: CapturedRoom) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 30))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.teal.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("墙体底座")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("\(room.walls.count) 面墙 · \(room.floors.count) 块地面")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .padding(16)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func surfaceCard(_ surface: WallDefectSurface) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(
                    systemName: surface.kind == .wall
                        ? "square.split.2x1"
                        : "rectangle.split.2x1"
                )
                .foregroundStyle(.cyan)
                Text(surface.label)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(surface.id.uuidString.prefix(8).uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.45))
            }

            Text(surface.uvDescription)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))

            HStack(spacing: 10) {
                Button {
                    selectedSurface = surface
                    showCapture = true
                } label: {
                    Label("拍摄缺陷", systemImage: "camera.viewfinder")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.cyan.opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Text("\(photoCount(for: surface.id)) 张")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 58)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func photoCount(for surfaceID: UUID) -> Int {
        photos.filter { $0.wallID == surfaceID }.count
    }

    private func startScan() {
        scanID = UUID()
        capturedRoom = nil
        surfaces = []
        photos = []
        selectedSurface = nil
        errorMessage = nil
        savedPath = nil
        phase = .scanning
    }

    private func handlePhoto(_ capture: DefectCameraCapture) {
        guard let selectedSurface else { return }
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
                wallID: selectedSurface.id,
                imageFileName: stored.imageFileName,
                pose: capture.pose,
                intrinsics: capture.intrinsics,
                depthFileName: stored.depthFileName,
                depthWidth: capture.depthWidth,
                depthHeight: capture.depthHeight,
                detectedClass: nil,
                note: "待 CoreML 识别"
            )
            photos.append(photo)
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
