import Combine
import Darwin
import Foundation
import QuickLook
import RealityKit
import SwiftData
import SwiftUI
import UIKit

struct ObjectCaptureTextureScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = ObjectCaptureScanCoordinator()

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.phase {
                case .instructions:
                    instructionsView
                case .capturing:
                    if let session = coordinator.session {
                        captureView(session: session)
                    } else {
                        ProgressView("正在初始化相机")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.ignoresSafeArea())
                    }
                case .reconstructing:
                    reconstructionView
                case .result:
                    if let result = coordinator.result {
                        ObjectCaptureResultView(
                            result: result,
                            onDiscard: {
                                coordinator.discardResult()
                            }
                        )
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(coordinator.phase == .capturing ? "取消" : "完成") {
                        if coordinator.phase == .capturing {
                            coordinator.cancelCapture()
                        }
                        dismiss()
                    }
                }
            }
            .alert("实景建模失败", isPresented: .constant(coordinator.errorMessage != nil)) {
                Button("好") {
                    coordinator.clearError()
                }
            } message: {
                if let errorMessage = coordinator.errorMessage {
                    Text(errorMessage)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                coordinator.cancelTasks()
            }
        }
    }

    private var navigationTitle: String {
        switch coordinator.phase {
        case .instructions: return "实景建模"
        case .capturing: return "官方 Object Capture"
        case .reconstructing: return "生成 USDZ"
        case .result: return "建模结果"
        }
    }

    private var instructionsView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.aperture")
                .font(.system(size: 64))
                .foregroundColor(.cyan)
            Text("实景建模")
                .font(.title.bold())
                .foregroundStyle(.white)
            Text("苹果官方 Object Capture 引导扫描，在 iPhone 本地生成带纹理 USDZ")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                tipRow(icon: "figure.walk", text: "缓慢移动，保持画面重叠，完整覆盖目标区域")
                tipRow(icon: "camera.fill", text: "系统自动拍摄照片，并在取景器中给出实时引导")
                tipRow(icon: "cube.transparent", text: "扫描完成后自动重建网格并生成带纹理 USDZ")
                tipRow(icon: "iphone", text: "需要 iPhone 12 Pro 或更新机型，支持 LiDAR")
            }
            .padding(18)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)

            Spacer()

            Button {
                coordinator.startCapture()
            } label: {
                Text("开始实景扫描")
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
            .padding(.bottom, 36)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.11),
                    Color(red: 0.08, green: 0.12, blue: 0.2)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 30)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func captureView(session: ObjectCaptureSession) -> some View {
        ZStack {
            objectCaptureView(session: session)

            VStack {
                HStack(spacing: 10) {
                    statusPill(icon: "photo", text: "\(coordinator.photoCount) 张")
                    statusPill(icon: "cube", text: "USDZ")
                    Spacer()
                    if coordinator.usesAreaMode {
                        statusPill(icon: "square.dashed", text: "区域模式")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 10) {
                    if let state = coordinator.captureState {
                        switch state {
                        case .ready:
                            Text(coordinator.usesAreaMode
                                 ? "对准墙面、地面或天面后开始扫描"
                                 : "将目标物体置于取景器中央")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Button {
                                coordinator.beginCaptureFlow()
                            } label: {
                                Label("开始扫描", systemImage: "camera.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 14)
                                    .background(Color.cyan)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        case .detecting:
                            Text("调整边框，确保完整包围目标")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Button {
                                coordinator.beginCaptureFlow()
                            } label: {
                                Label("开始扫描", systemImage: "camera.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 14)
                                    .background(Color.cyan)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        case .capturing:
                            Text("缓慢移动，等待系统自动拍摄")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Button {
                                coordinator.finishCapture()
                            } label: {
                                Label("完成并生成 USDZ", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 14)
                                    .background(Color.teal)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        case .finishing:
                            ProgressView()
                                .tint(.white)
                            Text("正在保存扫描数据")
                                .font(.headline)
                                .foregroundStyle(.white)
                        case .completed:
                            Text("扫描完成")
                                .font(.headline)
                                .foregroundStyle(.white)
                        case .failed:
                            Text("扫描失败，请重新开始")
                                .font(.headline)
                                .foregroundStyle(.red)
                        default:
                            ProgressView()
                                .tint(.white)
                            Text("正在初始化")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                    } else {
                        ProgressView()
                            .tint(.white)
                        Text("正在初始化")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func objectCaptureView(session: ObjectCaptureSession) -> some View {
        if #available(iOS 18.0, *) {
            ObjectCaptureView(session: session)
                .hideObjectReticle(coordinator.usesAreaMode)
                .ignoresSafeArea()
        } else {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()
        }
    }

    private func statusPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.45))
            .clipShape(Capsule())
    }

    private var reconstructionView: some View {
        VStack(spacing: 22) {
            Spacer()
            ProgressView(value: coordinator.progress)
                .progressViewStyle(.linear)
                .tint(.cyan)
                .frame(width: 260)
            Text("\(Int(coordinator.progress * 100))%")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(.white)
            Text(coordinator.stageText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            Text("苹果官方摄影测量正在生成带纹理 USDZ")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.06, blue: 0.11).ignoresSafeArea())
    }
}

@MainActor
final class ObjectCaptureScanCoordinator: ObservableObject {
    enum Phase {
        case instructions
        case capturing
        case reconstructing
        case result
    }

    @Published var phase: Phase = .instructions
    @Published var session: ObjectCaptureSession?
    @Published var captureState: ObjectCaptureSession.CaptureState?
    @Published var errorMessage: String?
    @Published var progress: Double = 0
    @Published var stageText = "准备生成模型"
    @Published var photoCount = 0

    private(set) var result: ObjectCaptureScanResult?
    private var imagesDirectory: URL?
    private var outputDirectory: URL?
    private var outputURL: URL?
    private var startedAt = Date()
    private var captureTask: Task<Void, Never>?
    private var photogrammetrySession: PhotogrammetrySession?

    var usesAreaMode: Bool {
        if #available(iOS 18.0, *) {
            return true
        }
        return false
    }

    func startCapture() {
        guard ObjectCaptureSession.isSupported else {
            errorMessage = "当前设备不支持 Object Capture，需要 iPhone 12 Pro 或更新机型。"
            return
        }

        let scanID = UUID()
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseDirectory = documentDirectory
            .appendingPathComponent("ObjectCaptureScans/\(scanID.uuidString)", isDirectory: true)
        let images = baseDirectory.appendingPathComponent("Images", isDirectory: true)
        let snapshots = baseDirectory.appendingPathComponent("Snapshots", isDirectory: true)
        let models = baseDirectory.appendingPathComponent("Models", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        } catch {
            errorMessage = "无法创建扫描目录：\(error.localizedDescription)"
            return
        }

        let newSession = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = snapshots
        configuration.isOverCaptureEnabled = true
        newSession.start(imagesDirectory: images, configuration: configuration)

        session = newSession
        captureState = newSession.state
        imagesDirectory = images
        outputDirectory = baseDirectory
        outputURL = models.appendingPathComponent("model-mobile.usdz")
        startedAt = Date()
        photoCount = 0
        phase = .capturing

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            await self?.monitor(session: newSession)
        }
    }

    func beginCaptureFlow() {
        guard let session else { return }
        if usesAreaMode {
            session.startCapturing()
        } else {
            _ = session.startDetecting()
        }
    }

    func finishCapture() {
        session?.finish()
    }

    func cancelCapture() {
        session?.cancel()
        session = nil
        captureTask?.cancel()
        captureTask = nil
        phase = .instructions
    }

    func cancelTasks() {
        captureTask?.cancel()
        photogrammetrySession?.cancel()
    }

    func clearError() {
        errorMessage = nil
        phase = .instructions
    }

    func discardResult() {
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        result = nil
        phase = .instructions
    }

    private func monitor(session: ObjectCaptureSession) async {
        for await state in session.stateUpdates {
            guard !Task.isCancelled else { return }
            captureState = state
            photoCount = session.numberOfShotsTaken

            switch state {
            case .completed:
                await beginReconstruction()
                return
            case .failed(let error):
                errorMessage = "扫描失败：\(error.localizedDescription)"
                phase = .instructions
                return
            default:
                break
            }
        }
    }

    private func beginReconstruction() async {
        guard let imagesDirectory, let outputURL else { return }
        session = nil
        captureTask = nil
        phase = .reconstructing
        progress = 0.02
        stageText = "准备生成模型"

        var configuration = PhotogrammetrySession.Configuration()
        configuration.checkpointDirectory = outputDirectory?
            .appendingPathComponent("Snapshots", isDirectory: true)

        do {
            let reconstruction = try PhotogrammetrySession(
                input: imagesDirectory,
                configuration: configuration
            )
            photogrammetrySession = reconstruction
            var outputIterator = reconstruction.outputs.makeAsyncIterator()
            try reconstruction.process(requests: [
                .modelFile(url: outputURL, detail: .reduced)
            ])

            while let output = try await outputIterator.next() {
                switch output {
                case .requestProgress(_, fractionComplete: let fraction):
                    progress = max(0.02, min(1, fraction))
                case .requestProgressInfo(_, let info):
                    stageText = info.processingStage?.processingStageText ?? "正在生成模型"
                case .requestComplete:
                    break
                case .processingComplete:
                    finishReconstruction()
                    return
                case .processingCancelled:
                    phase = .instructions
                    return
                case .requestError(_, let requestError):
                    errorMessage = "生成 USDZ 失败：\(requestError.localizedDescription)"
                    phase = .instructions
                    return
                case .stitchingIncomplete:
                    stageText = "网格连接不完整，将使用当前已生成的数据"
                case .invalidSample(id: _, reason: _),
                     .skippedSample(id: _),
                     .automaticDownsampling,
                     .inputComplete:
                    break
                @unknown default:
                    break
                }
            }
        } catch {
            errorMessage = "生成 USDZ 失败：\(error.localizedDescription)"
            phase = .instructions
        }
    }

    private func finishReconstruction() {
        guard let outputURL, let imagesDirectory, let outputDirectory else { return }
        photogrammetrySession = nil
        result = ObjectCaptureScanResult(
            scanID: UUID(),
            capturedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            deviceModel: ObjectCaptureScanCoordinator.hardwareModel(),
            photoCount: photoCount,
            imagesDirectory: imagesDirectory,
            outputDirectory: outputDirectory,
            usdzURL: outputURL
        )
        phase = .result
    }

    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(value)))
        }
        let names: [String: String] = [
            "iPhone12,1": "iPhone 11",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max"
        ]
        return names[identifier] ?? (identifier.isEmpty ? "iPhone" : identifier)
    }
}

private extension PhotogrammetrySession.Output.ProcessingStage {
    var processingStageText: String {
        switch self {
        case .preProcessing: return "预处理照片"
        case .imageAlignment: return "对齐照片"
        case .pointCloudGeneration: return "生成点云"
        case .meshGeneration: return "生成网格"
        case .textureMapping: return "映射纹理"
        case .optimization: return "优化模型"
        default: return "正在生成模型"
        }
    }
}

struct ObjectCaptureScanResult {
    let scanID: UUID
    let capturedAt: Date
    let duration: TimeInterval
    let deviceModel: String
    let photoCount: Int
    let imagesDirectory: URL
    let outputDirectory: URL
    let usdzURL: URL
}

struct ObjectCaptureResultView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let result: ObjectCaptureScanResult
    let onDiscard: () -> Void
    @State private var showQuickLook = false
    @State private var showShare = false
    @State private var showDiscardConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox {
                    QuickLookPreview(url: result.usdzURL)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } label: {
                    Label("带纹理 USDZ 模型", systemImage: "cube.transparent")
                }

                GroupBox {
                    Grid(horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow {
                            statCell(value: "\(result.photoCount)", label: "照片数")
                            statCell(value: result.deviceModel, label: "设备")
                            statCell(value: String(format: "%.0f 秒", result.duration), label: "扫描时长")
                        }
                    }
                } label: {
                    Label("扫描信息", systemImage: "info.circle")
                }

                Button {
                    showQuickLook = true
                } label: {
                    Label("全屏预览 USDZ", systemImage: "arkit")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.indigo)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)

                Button {
                    showShare = true
                } label: {
                    Label("分享 USDZ", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.cyan)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)

                Button {
                    saveRecord()
                } label: {
                    Label("保存历史记录", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)

                Button(role: .destructive) {
                    showDiscardConfirm = true
                } label: {
                    Label("不保存并退出", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .background(Color(red: 0.04, green: 0.06, blue: 0.11).ignoresSafeArea())
        .alert("不保存并退出？", isPresented: $showDiscardConfirm) {
            Button("不保存", role: .destructive) {
                onDiscard()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前 USDZ 不会被保存到历史记录，但会保留在 App 缓存目录。")
        }
        .sheet(isPresented: $showQuickLook) {
            QuickLookPreview(url: result.usdzURL)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(activityItems: [result.usdzURL])
        }
    }

    private func saveRecord() {
        let record = TextureScanRecord(
            scanID: result.scanID,
            capturedAt: result.capturedAt,
            deviceModel: result.deviceModel,
            deviceMaxResolution: "Apple Object Capture",
            photoCount: result.photoCount,
            closeUpCount: 0,
            wallCount: 0,
            atlasSize: 0,
            duration: result.duration,
            outputDirectoryPath: result.outputDirectory.path,
            usdzPath: result.usdzURL.path,
            objPath: "",
            plyPath: "",
            jsonPath: "",
            packagePath: "",
            texturePaths: []
        )
        modelContext.insert(record)
        try? modelContext.save()
        dismiss()
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.reloadData()
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
