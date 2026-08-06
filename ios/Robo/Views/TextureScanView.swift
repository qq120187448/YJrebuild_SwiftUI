import ARKit
import CoreImage
import CoreVideo
import Darwin
import SceneKit
import simd
import SwiftUI
import UIKit

struct TextureScanView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .instructions
    @State private var status = TextureScanStatus()
    @State private var stopRequested = false
    @State private var startedAt = Date()
    @State private var result: TextureScanResult?
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var progressText = "准备"

    private enum Phase {
        case instructions
        case scanning
        case processing
        case result
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .instructions:
                    instructionsView
                case .scanning:
                    scanningView
                case .processing:
                    processingView
                case .result:
                    if let result {
                        TextureScanResultView(result: result)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    switch phase {
                    case .instructions:
                        Button("取消") {
                            dismiss()
                        }
                    case .scanning:
                        Button("完成") {
                            stopRequested = true
                        }
                    case .processing:
                        Button("取消") {
                            dismiss()
                        }
                    case .result:
                        Button("完成") {
                            dismiss()
                        }
                    }
                }
            }
            .alert("实景建模失败", isPresented: .constant(errorMessage != nil)) {
                Button("好") {
                    errorMessage = nil
                    phase = .instructions
                }
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .instructions: return "实景建模"
        case .scanning: return "实景扫描"
        case .processing: return "纹理烘焙"
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
            Text("ARKit + 主摄最高分辨率拍摄，在本机生成 UV 纹理 USDZ")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                tipRow(icon: "figure.walk", text: "缓慢移动，完整覆盖墙面、地面和天面")
                tipRow(icon: "camera.fill", text: "扫描中自动拍摄最高分辨率 HEIF 照片")
                tipRow(icon: "viewfinder", text: "对疑似裂缝/缺陷区域贴近 30-50cm，自动近距补拍")
                tipRow(icon: "cube.transparent", text: "每面墙生成一张 8K 纹理图集并导出 USDZ")
            }
            .padding(18)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)

            Spacer()

            Button {
                startedAt = Date()
                status = TextureScanStatus()
                phase = .scanning
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

    private var scanningView: some View {
        ZStack {
            TextureScanARContainer(
                status: $status,
                stopRequested: $stopRequested,
                onFinish: handleFinish
            )
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 12) {
                    statusPill(icon: "camera.fill", text: "照片 \(status.photoCount)")
                    statusPill(icon: "viewfinder", text: "近距 \(status.closeUpCount)")
                    Spacer()
                    Text(status.maxResolution)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 8) {
                    if status.isCloseUp {
                        Label(
                            "近距补拍 \(String(format: "%.2f", status.distance))m",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.green)
                    } else {
                        Text("常规扫描 \(String(format: "%.2f", status.distance))m")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    Text("缓慢移动覆盖墙面/天面；对疑似裂缝区域贴近 30-50cm 自动补拍")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(12)
            }
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

    private var processingView: some View {
        VStack(spacing: 22) {
            Spacer()
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.cyan)
                .frame(width: 260)
            Text("\(Int(progress * 100))%")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(.white)
            Text(progressText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            Text("本机烘焙中，请保持 App 在前台")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.06, blue: 0.11).ignoresSafeArea())
    }

    private func handleFinish(_ data: TextureScanData) {
        phase = .processing
        progress = 0.02
        progressText = "准备烘焙"

        let outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextureScans/\(data.scanID.uuidString)", isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let baked = try TextureBakeProcessor.process(
                    data: data,
                    outputDirectory: outputDirectory
                ) { value, text in
                    DispatchQueue.main.async {
                        self.progress = value
                        self.progressText = text
                    }
                }
                DispatchQueue.main.async {
                    self.result = baked
                    self.phase = .result
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct TextureScanARContainer: UIViewRepresentable {
    @Binding var status: TextureScanStatus
    @Binding var stopRequested: Bool
    let onFinish: (TextureScanData) -> Void

    func makeUIView(context: Context) -> TextureScanARView {
        let view = TextureScanARView()
        view.onStatus = { value in
            status = value
        }
        view.onFinish = onFinish
        return view
    }

    func updateUIView(_ uiView: TextureScanARView, context: Context) {
        if stopRequested {
            uiView.stopScanning()
            DispatchQueue.main.async {
                stopRequested = false
            }
        }
    }

    static func dismantleUIView(_ uiView: TextureScanARView, coordinator: ()) {
        uiView.pause()
    }
}

private final class TextureScanARView: UIView, ARSessionDelegate {
    var onStatus: ((TextureScanStatus) -> Void)?
    var onFinish: ((TextureScanData) -> Void)?

    private let sceneView = ARSCNView()
    private let photoDirectory: URL
    private let maxResolution: String
    private let deviceModel: String
    private let startedAt = Date()
    private lazy var ciContext = CIContext()

    private var isScanning = false
    private var didFinish = false
    private var photoInFlight = false
    private var frameCount = 0
    private var photos: [TexturePhotoFrame] = []
    private var lastDistance: Float = 0
    private var lastCloseUp = false

    override init(frame: CGRect) {
        photoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextureScanPhotos", isDirectory: true)
        maxResolution = Self.resolveMaxResolution()
        deviceModel = Self.hardwareModel()
        super.init(frame: frame)
        try? FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        setup()
    }

    required init?(coder: NSCoder) {
        photoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextureScanPhotos", isDirectory: true)
        maxResolution = Self.resolveMaxResolution()
        deviceModel = Self.hardwareModel()
        super.init(coder: coder)
        try? FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        setup()
    }

    private func setup() {
        addSubview(sceneView)
        sceneView.frame = bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session.delegate = self
        sceneView.rendersContinuously = true

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        sceneView.session.run(configuration)
        isScanning = true
        updateStatus()
    }

    func stopScanning() {
        guard isScanning, !didFinish else { return }
        isScanning = false
        didFinish = true

        let frame = sceneView.session.currentFrame
        let mesh = makeMesh(from: frame)
        let photosSnapshot = photos
        let data = TextureScanData(
            scanID: UUID(),
            capturedAt: startedAt,
            deviceModel: deviceModel,
            deviceMaxResolution: maxResolution,
            duration: Date().timeIntervalSince(startedAt),
            mesh: mesh,
            photos: photosSnapshot
        )
        sceneView.session.pause()
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?(data)
        }
    }

    func pause() {
        sceneView.session.pause()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }
        frameCount += 1

        if let depth = frame.sceneDepth {
            let depthBuffer = depth.depthMap
            let width = CVPixelBufferGetWidth(depthBuffer)
            let height = CVPixelBufferGetHeight(depthBuffer)
            if width > 0, height > 0 {
                let x = min(width - 1, width / 2)
                let y = min(height - 1, height / 2)
                CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
                defer {
                    CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
                }
                if let base = CVPixelBufferGetBaseAddress(depthBuffer) {
                    let pointer = base.assumingMemoryBound(to: Float32.self)
                    let value = pointer[y * width + x]
                    if value.isFinite, value > 0 {
                        lastDistance = value
                    }
                }
            }
        }

        let closeUp = lastDistance > 0.2 && lastDistance < 0.6
        lastCloseUp = closeUp
        if closeUp {
            requestPhoto(isCloseUp: true)
        } else if frameCount % 6 == 0 {
            requestPhoto(isCloseUp: false)
        }

        let meshFaceCount = frame.anchors
            .compactMap { $0 as? ARMeshAnchor }
            .reduce(0) { $0 + $1.geometry.faces.count }
        DispatchQueue.main.async { [weak self] in
            self?.updateStatus(meshFaceCount: meshFaceCount)
        }
    }

    private func requestPhoto(isCloseUp: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isScanning, !self.photoInFlight else { return }
            self.photoInFlight = true
            self.sceneView.session.captureHighResolutionFrame { [weak self] frame, error in
                guard let self, let frame else {
                    DispatchQueue.main.async {
                        self?.photoInFlight = false
                    }
                    return
                }
                self.savePhoto(frame, isCloseUp: isCloseUp)
                DispatchQueue.main.async {
                    self.photoInFlight = false
                }
            }
        }
    }

    private func savePhoto(_ frame: ARFrame, isCloseUp: Bool) {
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else {
            return
        }
        let id = UUID().uuidString
        let url = photoDirectory.appendingPathComponent("\(id).jpg")
        try? jpeg.write(to: url)

        let photo = TexturePhotoFrame(
            id: id,
            fileURL: url,
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageWidth: Int(frame.camera.imageResolution.width),
            imageHeight: Int(frame.camera.imageResolution.height),
            isCloseUp: isCloseUp,
            distance: lastDistance
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.photos.append(photo)
            self.updateStatus()
        }
    }

    private func updateStatus(meshFaceCount: Int? = nil) {
        var newStatus = TextureScanStatus()
        newStatus.photoCount = photos.count
        newStatus.closeUpCount = photos.filter(\.isCloseUp).count
        newStatus.distance = lastDistance
        newStatus.isCloseUp = lastCloseUp
        newStatus.meshFaceCount = meshFaceCount ?? newStatus.meshFaceCount
        newStatus.maxResolution = maxResolution
        onStatus?(newStatus)
    }

    private func makeMesh(from frame: ARFrame?) -> TextureScanMesh {
        var mesh = TextureScanMesh()
        guard let frame else { return mesh }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

        for anchor in anchors {
            let geometry = anchor.geometry
            let vertexBuffer = geometry.vertices.buffer.contents()
            let vertexStride = geometry.vertices.stride
            let vertexOffset = geometry.vertices.offset
            let base = mesh.vertices.count

            for index in 0..<geometry.vertices.count {
                let local = (vertexBuffer + vertexOffset + index * vertexStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                mesh.vertices.append(SIMD3<Float>(world.x, world.y, world.z))
            }

            let faceBuffer = geometry.faces.buffer.contents()
            let bytesPerIndex = geometry.faces.bytesPerIndex
            var classificationRaw: UnsafeRawPointer?
            var classificationStride = 0
            var classificationOffset = 0
            if let classification = geometry.classification {
                classificationRaw = UnsafeRawPointer(classification.buffer.contents())
                classificationStride = classification.stride
                classificationOffset = classification.offset
            }

            for faceIndex in 0..<geometry.faces.count {
                func readIndex(_ byteOffset: Int) -> Int {
                    if bytesPerIndex == 2 {
                        return Int(faceBuffer.load(
                            fromByteOffset: faceIndex * 3 * bytesPerIndex + byteOffset,
                            as: UInt16.self
                        ))
                    }
                    return Int(faceBuffer.load(
                        fromByteOffset: faceIndex * 3 * bytesPerIndex + byteOffset,
                        as: UInt32.self
                    ))
                }

                let i0 = readIndex(0)
                let i1 = readIndex(bytesPerIndex)
                let i2 = readIndex(bytesPerIndex * 2)
                mesh.indices.append(base + i0)
                mesh.indices.append(base + i1)
                mesh.indices.append(base + i2)

                var votes: [Int: Int] = [:]
                if let classificationRaw {
                    for vertexIndex in [i0, i1, i2] {
                        let raw = classificationRaw.load(
                            fromByteOffset: classificationOffset + vertexIndex * classificationStride,
                            as: UInt8.self
                        )
                        votes[Int(raw), default: 0] += 1
                    }
                }
                mesh.faceClassifications.append(votes.max(by: { $0.value < $1.value })?.key ?? 0)
            }
        }
        return mesh
    }

    private static func resolveMaxResolution() -> String {
        guard let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing else {
            return "自动"
        }
        let size = format.imageResolution
        return "\(Int(size.width))x\(Int(size.height))"
    }

    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? "iPhone" : identifier
    }
}

struct TextureScanResultView: View {
    let result: TextureScanResult
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox {
                    if let scene = try? SCNScene(url: result.usdzURL, options: nil) {
                        SceneView(
                            scene: scene,
                            options: [.autoenablesDefaultLighting, .allowsCameraControl]
                        )
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        ContentUnavailableView(
                            "模型预览不可用",
                            systemImage: "cube.transparent",
                            description: Text("导出文件后可在其他查看器中打开")
                        )
                        .frame(height: 240)
                    }
                } label: {
                    Label("3D 实景模型", systemImage: "cube.transparent")
                }

                GroupBox {
                    Grid(horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow {
                            statCell(value: "\(result.wallCount)", label: "墙面分段")
                            statCell(value: "\(result.atlasSize)", label: "纹理图集")
                            statCell(value: "\(result.photoCount)", label: "照片数")
                        }
                        GridRow {
                            statCell(value: "\(result.closeUpCount)", label: "近距补拍")
                            statCell(value: result.deviceModel, label: "设备")
                            statCell(value: result.deviceMaxResolution, label: "最大分辨率")
                        }
                    }
                } label: {
                    Label("扫描信息", systemImage: "info.circle")
                }

                Button {
                    showShare = true
                } label: {
                    Label("分享 USDZ / PLY / JSON / 纹理", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.cyan)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .background(Color(red: 0.04, green: 0.06, blue: 0.11).ignoresSafeArea())
        .sheet(isPresented: $showShare) {
            ActivityView(
                activityItems: [result.usdzURL, result.plyURL, result.jsonURL] + result.textureURLs
            )
        }
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
