import ARKit
import CoreImage
import CoreVideo
import Darwin
import ImageIO
import SceneKit
import simd
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
                    statusPill(icon: "checkerboard.rectangle", text: "覆盖 \(Int(status.coverage * 100))%")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(status.photoResolution)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                        Text("实际照片")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45))
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 8) {
                    if status.speed > 0.6 {
                        Label(
                            "移动过快，请放慢（\(String(format: "%.1f", status.speed))m/s）",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.orange)
                    } else if status.distance > 2.5 {
                        Label(
                            "距离过远，请靠近至 1-2m",
                            systemImage: "arrow.turn.down.right"
                        )
                        .font(.headline)
                        .foregroundStyle(.yellow)
                    } else if status.distance < 0.2 {
                        Label(
                            "距离过近，请稍后退",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.red)
                    }
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
                    Text("绿色网格为已拍摄覆盖；缓慢移动补齐橙色区域")
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
    private var lastSpeed: Float = 0
    private var lastCameraPosition: SIMD3<Float>?
    private var lastCameraTime: TimeInterval?
    private var lastNormalPhotoTime: Date?
    private var lastCloseUpPhotoTime: Date?
    private var lastRequestedPosition: SIMD3<Float>?
    private var coverageFrameCounter = 0
    private var coverageNodes: [UUID: SCNNode] = [:]
    private var lastCoverage: Double = 0
    private let maxPhotos = 400

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

        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        if let lastPosition = lastCameraPosition,
           let lastTime = lastCameraTime {
            let delta = frame.timestamp - lastTime
            if delta > 0.001 {
                lastSpeed = simd_distance(cameraPosition, lastPosition) / Float(delta)
            }
        }
        lastCameraPosition = cameraPosition
        lastCameraTime = frame.timestamp

        let closeUp = lastDistance > 0.2 && lastDistance < 0.6
        lastCloseUp = closeUp
        let now = Date()
        if photos.count < maxPhotos {
            if closeUp {
                if lastCloseUpPhotoTime == nil ||
                    now.timeIntervalSince(lastCloseUpPhotoTime!) >= 0.6 {
                    lastCloseUpPhotoTime = now
                    requestPhoto(isCloseUp: true)
                }
            } else if lastNormalPhotoTime == nil ||
                now.timeIntervalSince(lastNormalPhotoTime!) >= 2.0 {
                if lastRequestedPosition == nil ||
                    simd_distance(cameraPosition, lastRequestedPosition!) > 0.08 {
                    lastNormalPhotoTime = now
                    requestPhoto(isCloseUp: false)
                }
            }
        }

        coverageFrameCounter += 1
        if coverageFrameCounter % 20 == 0 {
            let coverageFrame = frame
            DispatchQueue.main.async { [weak self] in
                self?.updateCoverageOverlay(from: coverageFrame)
            }
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
            if let frame = self.sceneView.session.currentFrame {
                let position = SIMD3<Float>(
                    frame.camera.transform.columns.3.x,
                    frame.camera.transform.columns.3.y,
                    frame.camera.transform.columns.3.z
                )
                self.lastRequestedPosition = position
            }
            if #available(iOS 26.0, *) {
                self.sceneView.session.captureHighResolutionFrame(using: nil) { [weak self] frame, _ in
                    self?.handleCapturedFrame(frame, isCloseUp: isCloseUp)
                }
            } else {
                self.sceneView.session.captureHighResolutionFrame { [weak self] frame, _ in
                    self?.handleCapturedFrame(frame, isCloseUp: isCloseUp)
                }
            }
        }
    }

    private func handleCapturedFrame(_ frame: ARFrame?, isCloseUp: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.photoInFlight = false
            }
            guard let frame else { return }
            self.savePhoto(frame, isCloseUp: isCloseUp)
        }
    }

    private func savePhoto(_ frame: ARFrame, isCloseUp: Bool) {
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        let id = UUID().uuidString
        var url = photoDirectory.appendingPathComponent("\(id).heic")
        if !writeHEIF(image, to: url) {
            url = photoDirectory.appendingPathComponent("\(id).jpg")
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
            try? jpeg.write(to: url)
        }

        let photo = TexturePhotoFrame(
            id: id,
            fileURL: url,
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageWidth: cgImage.width,
            imageHeight: cgImage.height,
            isCloseUp: isCloseUp,
            distance: lastDistance
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.photos.append(photo)
            self.updateStatus()
        }
    }

    private func writeHEIF(_ image: UIImage, to url: URL) -> Bool {
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil
              ) else {
            return false
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private func updateStatus(meshFaceCount: Int? = nil) {
        var newStatus = TextureScanStatus()
        newStatus.photoCount = photos.count
        newStatus.closeUpCount = photos.filter(\.isCloseUp).count
        newStatus.distance = lastDistance
        newStatus.isCloseUp = lastCloseUp
        newStatus.meshFaceCount = meshFaceCount ?? newStatus.meshFaceCount
        newStatus.maxResolution = maxResolution
        if let lastPhoto = photos.last {
            newStatus.photoResolution = "\(lastPhoto.imageWidth)x\(lastPhoto.imageHeight)"
        } else {
            newStatus.photoResolution = maxResolution
        }
        newStatus.coverage = lastCoverage
        newStatus.speed = lastSpeed
        onStatus?(newStatus)
    }

    private func updateCoverageOverlay(from frame: ARFrame) {
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let currentIDs = Set(anchors.map(\.identifier))
        for id in coverageNodes.keys where !currentIDs.contains(id) {
            coverageNodes[id]?.removeFromParentNode()
            coverageNodes.removeValue(forKey: id)
        }

        var coveredFaces = 0
        var totalFaces = 0
        for anchor in anchors {
            let node: SCNNode
            if let existing = coverageNodes[anchor.identifier] {
                node = existing
            } else {
                node = SCNNode()
                node.name = "textureCoverage"
                sceneView.scene.rootNode.addChildNode(node)
                coverageNodes[anchor.identifier] = node
            }
            node.simdTransform = anchor.transform
            node.childNodes.forEach { $0.removeFromParentNode() }

            let result = makeCoverageOverlayGeometry(anchor)
            coveredFaces += result.coveredCount
            totalFaces += result.totalCount
            if let covered = result.coveredGeometry {
                let child = SCNNode(geometry: covered)
                child.renderingOrder = 12
                node.addChildNode(child)
            }
            if let uncovered = result.uncoveredGeometry {
                let child = SCNNode(geometry: uncovered)
                child.renderingOrder = 11
                node.addChildNode(child)
            }
        }
        lastCoverage = totalFaces > 0 ? Double(coveredFaces) / Double(totalFaces) : 0
    }

    private func makeCoverageOverlayGeometry(
        _ anchor: ARMeshAnchor
    ) -> (coveredGeometry: SCNGeometry?, uncoveredGeometry: SCNGeometry?, coveredCount: Int, totalCount: Int) {
        let geometry = anchor.geometry
        guard geometry.vertices.count > 0, geometry.faces.count > 0 else {
            return (nil, nil, 0, 0)
        }

        let vertexBuffer = geometry.vertices.buffer.contents()
        let vertexStride = geometry.vertices.stride
        let vertexOffset = geometry.vertices.offset
        var localVertices: [SIMD3<Float>] = []
        localVertices.reserveCapacity(geometry.vertices.count)
        for index in 0..<geometry.vertices.count {
            localVertices.append(
                (vertexBuffer + vertexOffset + index * vertexStride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            )
        }

        let faceBuffer = geometry.faces.buffer.contents()
        let bytesPerIndex = geometry.faces.bytesPerIndex
        var coveredPositions: [SCNVector3] = []
        var coveredIndices: [Int32] = []
        var uncoveredPositions: [SCNVector3] = []
        var uncoveredIndices: [Int32] = []
        var coveredCount = 0

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
            let v0 = localVertices[i0]
            let v1 = localVertices[i1]
            let v2 = localVertices[i2]
            let localNormal = simd_normalize(simd_cross(v1 - v0, v2 - v0))
            let transformedNormal = anchor.transform * SIMD4<Float>(
                localNormal.x,
                localNormal.y,
                localNormal.z,
                0
            )
            let worldNormal = simd_normalize(
                SIMD3<Float>(transformedNormal.x, transformedNormal.y, transformedNormal.z)
            )
            let localCentroid = (v0 + v1 + v2) / 3
            let transformedCentroid = anchor.transform * SIMD4<Float>(
                localCentroid.x,
                localCentroid.y,
                localCentroid.z,
                1
            )
            let worldCentroid = SIMD3<Float>(
                transformedCentroid.x,
                transformedCentroid.y,
                transformedCentroid.z
            )

            let isCovered = isWorldCovered(worldCentroid, normal: worldNormal)
            if isCovered {
                let base = coveredPositions.count
                coveredPositions.append(SCNVector3(v0.x, v0.y, v0.z))
                coveredPositions.append(SCNVector3(v1.x, v1.y, v1.z))
                coveredPositions.append(SCNVector3(v2.x, v2.y, v2.z))
                coveredIndices.append(Int32(base))
                coveredIndices.append(Int32(base + 1))
                coveredIndices.append(Int32(base + 2))
                coveredCount += 1
            } else {
                let base = uncoveredPositions.count
                uncoveredPositions.append(SCNVector3(v0.x, v0.y, v0.z))
                uncoveredPositions.append(SCNVector3(v1.x, v1.y, v1.z))
                uncoveredPositions.append(SCNVector3(v2.x, v2.y, v2.z))
                uncoveredIndices.append(Int32(base))
                uncoveredIndices.append(Int32(base + 1))
                uncoveredIndices.append(Int32(base + 2))
            }
        }

        let coveredGeometry = makeCoverageGeometry(
            positions: coveredPositions,
            indices: coveredIndices,
            color: UIColor(red: 0.25, green: 0.9, blue: 0.45, alpha: 0.28)
        )
        let uncoveredGeometry = makeCoverageGeometry(
            positions: uncoveredPositions,
            indices: uncoveredIndices,
            color: UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 0.32)
        )
        return (
            coveredGeometry,
            uncoveredGeometry,
            coveredCount,
            geometry.faces.count
        )
    }

    private func makeCoverageGeometry(
        positions: [SCNVector3],
        indices: [Int32],
        color: UIColor
    ) -> SCNGeometry? {
        guard !positions.isEmpty, !indices.isEmpty else { return nil }
        let source = SCNGeometrySource(vertices: positions)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.blendMode = .alpha
        geometry.materials = [material]
        return geometry
    }

    private func isWorldCovered(_ world: SIMD3<Float>, normal: SIMD3<Float>) -> Bool {
        for photo in photos.suffix(30) {
            let inverse = simd_inverse(photo.cameraTransform)
            let cameraPoint = inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
            guard cameraPoint.z > 0.05 else { continue }
            let fx = photo.intrinsics.columns.0.x
            let fy = photo.intrinsics.columns.1.y
            let cx = photo.intrinsics.columns.2.x
            let cy = photo.intrinsics.columns.2.y
            let px = fx * cameraPoint.x / cameraPoint.z + cx
            let py = fy * cameraPoint.y / cameraPoint.z + cy
            guard px >= 0, py >= 0,
                  px < Float(photo.imageWidth - 1),
                  py < Float(photo.imageHeight - 1) else {
                continue
            }
            let toCamera = SIMD3<Float>(-cameraPoint.x, -cameraPoint.y, -cameraPoint.z)
            let distance = simd_length(toCamera)
            guard distance > 0.05, distance < 3 else { continue }
            let cosAngle = simd_dot(normal, simd_normalize(toCamera))
            if cosAngle > 0.25 {
                return true
            }
        }
        return false
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
                    if let scene = try? SCNScene(url: result.objURL, options: nil) {
                        SceneView(
                            scene: scene,
                            options: [.autoenablesDefaultLighting, .allowsCameraControl]
                        )
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let scene = try? SCNScene(url: result.usdzURL, options: nil) {
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
