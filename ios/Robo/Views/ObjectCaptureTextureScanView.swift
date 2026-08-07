import Combine
import Darwin
import Foundation
import QuickLook
import RealityKit
import SceneKit
import SwiftData
import SwiftUI
import UIKit

enum ObjectCaptureMode: String, CaseIterable {
    case area
    case object

    var displayName: String {
        switch self {
        case .area: return "区域实景建模"
        case .object: return "趣味物体建模"
        }
    }
}

struct ObjectCaptureTextureScanView: View {
    let mode: ObjectCaptureMode
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: ObjectCaptureScanCoordinator

    init(mode: ObjectCaptureMode = .area) {
        self.mode = mode
        _coordinator = StateObject(wrappedValue: ObjectCaptureScanCoordinator(mode: mode))
    }

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
                case .failed:
                    reconstructionFailedView
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
            .alert("实景建模失败", isPresented: $coordinator.showErrorAlert) {
                Button("好") { coordinator.clearError() }
            } message: {
                Text(coordinator.errorMessage ?? "发生未知错误")
            }
            .preferredColorScheme(.dark)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                coordinator.cancelTasks()
            }
            .onReceive(
                Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            ) { _ in
                coordinator.refreshState()
            }
        }
    }

    private var navigationTitle: String {
        switch coordinator.phase {
        case .instructions: return mode == .area ? "实景建模" : "玩具箱"
        case .capturing: return mode == .area ? "区域扫描" : "物体扫描"
        case .reconstructing: return "生成 USDZ"
        case .failed: return "生成失败"
        case .result: return mode == .area ? "区域建模结果" : "物体建模结果"
        }
    }

    private var instructionsView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.aperture")
                .font(.system(size: 64))
                .foregroundColor(.cyan)
            Text(mode.displayName)
                .font(.title.bold())
                .foregroundStyle(.white)
            Text(
                mode == .area
                    ? "苹果官方区域模式，扫描墙面、天面或地面，在 iPhone 本地生成带纹理 USDZ"
                    : "苹果官方物体模式，围绕单个物体生成带纹理 USDZ，不输出工程量"
            )
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                if mode == .area {
                    tipRow(icon: "square.dashed", text: "对准墙面、天面或地面，缓慢移动保持画面重叠")
                    tipRow(icon: "camera.fill", text: "系统自动拍摄照片，并在取景器中给出实时引导")
                    tipRow(icon: "cube.transparent", text: "扫描完成后自动重建网格并生成带纹理 USDZ")
                    tipRow(icon: "iphone", text: "区域模式需要 iOS 18 或更新系统")
                } else {
                    tipRow(icon: "viewfinder", text: "将单个物体放入取景器，调整边框完整包围目标")
                    tipRow(icon: "camera.fill", text: "围绕物体缓慢移动，系统自动拍摄照片")
                    tipRow(icon: "cube.transparent", text: "扫描完成后自动生成带纹理 USDZ")
                    tipRow(icon: "iphone", text: "需要 iPhone 12 Pro 或更新机型，支持 LiDAR")
                }
            }
            .padding(18)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)

            Spacer()

            Button {
                coordinator.startCapture()
            } label: {
                Text(mode == .area ? "开始区域扫描" : "开始趣味扫描")
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
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 10) {
                    if let state = coordinator.captureState {
                        switch state {
                        case .ready:
                            Text(
                                mode == .area
                                    ? "对准墙面、天面或地面，缓慢移动开始区域扫描"
                                    : "将目标物体置于取景器中央，开始检测"
                            )
                                .font(.headline)
                                .foregroundStyle(.white)
                            Button {
                                coordinator.beginCaptureFlow()
                            } label: {
                                Label(
                                    mode == .area ? "开始区域扫描" : "检测物体",
                                    systemImage: mode == .area ? "square.dashed" : "viewfinder"
                                )
                                    .font(.headline)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 14)
                                    .background(Color.cyan)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        case .detecting:
                            Text(mode == .area ? "正在准备区域扫描" : "调整边框，确保完整包围目标")
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
        if mode == .area, #available(iOS 18.0, *) {
            ObjectCaptureView(session: session)
                .hideObjectReticle(true)
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

    private var reconstructionFailedView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)

                Text(coordinator.failureTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                if coordinator.canRetry {
                    Text("扫描已完成，共拍摄 \(coordinator.photoCount) 张照片，但模型生成没有成功。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }

                Text(coordinator.errorMessage ?? "未知错误")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if coordinator.canRetry {
                    Button {
                        coordinator.retryReconstruction()
                    } label: {
                        Label("重试生成 USDZ", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.cyan)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button {
                    coordinator.clearError()
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.04, green: 0.06, blue: 0.11).ignoresSafeArea())
    }
}

@MainActor
final class ObjectCaptureScanCoordinator: ObservableObject {
    let mode: ObjectCaptureMode

    enum Phase {
        case instructions
        case capturing
        case reconstructing
        case failed
        case result
    }

    @Published var phase: Phase = .instructions
    @Published var session: ObjectCaptureSession?
    @Published var captureState: ObjectCaptureSession.CaptureState?
    @Published var errorMessage: String?
    @Published var showErrorAlert = false
    @Published var failureTitle = "实景建模失败"
    @Published var canRetry = false
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

    init(mode: ObjectCaptureMode) {
        self.mode = mode
    }

    func startCapture() {
        guard ObjectCaptureSession.isSupported else {
            errorMessage = "当前设备不支持 Object Capture，需要 iPhone 12 Pro 或更新机型。"
            showErrorAlert = true
            return
        }
        if mode == .area {
            if #available(iOS 18.0, *) {
            } else {
                errorMessage = "区域模式需要 iOS 18 或更新系统，请改用玩具箱物体模式。"
                showErrorAlert = true
                return
            }
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
            showErrorAlert = true
            return
        }

        let newSession = ObjectCaptureSession()
        session = newSession
        captureState = newSession.state
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            await self?.monitor(session: newSession)
        }

        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = snapshots
        configuration.isOverCaptureEnabled = false
        newSession.start(imagesDirectory: images, configuration: configuration)

        errorMessage = nil
        captureState = newSession.state
        photoCount = newSession.numberOfShotsTaken
        imagesDirectory = images
        outputDirectory = baseDirectory
        outputURL = models.appendingPathComponent("model-mobile.usdz")
        startedAt = Date()
        phase = .capturing
    }

    func beginCaptureFlow() {
        guard let session else { return }
        if mode == .area {
            if #available(iOS 18.0, *) {
                guard session.state == .ready else { return }
                session.startCapturing()
                return
            }
        }
        switch session.state {
        case .ready:
            _ = session.startDetecting()
        case .detecting:
            session.startCapturing()
        default:
            break
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

    func refreshState() {
        guard let session else { return }
        captureState = session.state
        photoCount = session.numberOfShotsTaken
    }

    func clearError() {
        errorMessage = nil
        showErrorAlert = false
        failureTitle = "实景建模失败"
        canRetry = false
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
        captureState = session.state
        photoCount = session.numberOfShotsTaken

        for await state in session.stateUpdates {
            guard !Task.isCancelled else { return }
            captureState = state
            photoCount = session.numberOfShotsTaken

            switch state {
            case .completed:
                await beginReconstruction()
                return
            case .failed(let error):
                failureTitle = "扫描失败"
                canRetry = false
                errorMessage = "扫描失败：\(error.localizedDescription)"
                phase = .failed
                return
            default:
                break
            }
        }
    }

    private func beginReconstruction() async {
        guard let imagesDirectory, let outputURL else { return }
        errorMessage = nil
        failureTitle = "生成 USDZ 失败"
        canRetry = true
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
                    phase = .failed
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
            phase = .failed
        }
    }

    func retryReconstruction() {
        guard phase == .failed else { return }
        Task { [weak self] in
            await self?.beginReconstruction()
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
            mode: mode,
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
    let mode: ObjectCaptureMode
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
                    if FileManager.default.fileExists(atPath: result.usdzURL.path) {
                        USDZSceneView(url: result.usdzURL)
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        ContentUnavailableView(
                            "模型文件不存在",
                            systemImage: "exclamationmark.triangle",
                            description: Text("USDZ 文件可能已被移动或删除。")
                        )
                        .frame(height: 260)
                    }
                } label: {
                    Label(
                        result.mode == .area ? "区域实景 USDZ 模型" : "趣味物体 USDZ 模型",
                        systemImage: "cube.transparent"
                    )
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

                Text("此功能只生成带纹理 USDZ，不输出工程量清单。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)

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
                    Label("导出 USDZ", systemImage: "square.and.arrow.up")
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
            deviceMaxResolution: result.mode == .area ? "区域模式" : "物体模式",
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

struct USDZSceneView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        loadScene(into: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene == nil {
            loadScene(into: uiView)
        }
    }

    private func loadScene(into view: SCNView) {
        guard let scene = try? SCNScene(url: url) else { return }
        view.scene = scene

        let minBounds = scene.rootNode.boundingBox.min
        let maxBounds = scene.rootNode.boundingBox.max
        guard minBounds.x < maxBounds.x,
              minBounds.y < maxBounds.y,
              minBounds.z < maxBounds.z else { return }

        let center = SCNVector3(
            (minBounds.x + maxBounds.x) / 2,
            (minBounds.y + maxBounds.y) / 2,
            (minBounds.z + maxBounds.z) / 2
        )
        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )
        let distance = max(max(size.x, size.y), 0.6) * 1.8 + 0.6

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        cameraNode.position = SCNVector3(
            center.x,
            center.y + size.y * 0.25,
            center.z + distance
        )
        cameraNode.look(at: center)
        view.pointOfView = cameraNode
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
