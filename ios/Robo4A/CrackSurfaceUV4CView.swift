import ARKit
import RealityKit
import RoomPlan
import simd
import SwiftUI
import UIKit

/// RoomPlan 会话回调桥接（RoomCaptureSession 使用与 ARView 同一个 ARSession）。
final class RoomPlanSessionCoordinator: NSObject, RoomCaptureSessionDelegate, NSCoding {
    var onDidEnd: ((CapturedRoomData, Error?) -> Void)?
    var onDidFail: ((Error) -> Void)?
    var onInstruction: ((String) -> Void)?

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    func encode(with coder: NSCoder) {}

    func captureSession(
        _ session: RoomCaptureSession,
        didStartWith configuration: RoomCaptureSession.Configuration
    ) {
        // 开始后由 didProvide 提供 Apple 引导指令。
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didEndWith data: CapturedRoomData,
        error: Error?
    ) {
        onDidEnd?(data, error)
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didFailWithError error: Error
    ) {
        onDidFail?(error)
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didProvide instruction: RoomCaptureSession.Instruction
    ) {
        onInstruction?(Self.coachingText(for: instruction))
    }

    /// Apple 官方引导指令 → 自定义中文文案。
    private static func coachingText(
        for instruction: RoomCaptureSession.Instruction
    ) -> String {
        switch instruction {
        case .normal:
            return "扫描正常，请缓慢移动设备"
        case .slowDown:
            return "请放慢移动速度"
        case .moveCloseToWall:
            return "请靠近墙面"
        case .moveAwayFromWall:
            return "请离墙稍远"
        case .turnOnLight:
            return "请打开灯光"
        case .lowTexture:
            return "请对准有纹理的区域"
        @unknown default:
            return "请缓慢移动设备"
        }
    }
}

/// 4C：常驻 ARView（白线 mesh）+ 单一 ARSession + RoomCaptureSession。
/// 照片叠加 4A 折线/采样点，AR 画面叠加 4B 世界点/连线，便于逐条裂缝对照。
struct CrackSurfaceUV4CView: View {

    private enum Phase: Equatable {
        case idle
        case scanning
        case processing
        case ready
    }

    @StateObject private var viewModel = ContentViewModel()
    @State private var coordinator = RoomPlanSessionCoordinator()
    @State private var sharedSession = ARSession()
    @State private var roomCaptureSession: RoomCaptureSession?
    @State private var phase: Phase = .idle
    @State private var scenario = CrackRaycast4B.scenarios[0]
    @State private var statusText =
        "先“开始扫描”墙面（RoomPlan），结束扫描后再拍照映射 UV"
    @State private var coachingText = "开始扫描后此处显示 Apple 引导提示"
    @State private var isRunning = false
    @State private var arViewReference: ARView?
    @State private var capturedRoom: CapturedRoom?
    @State private var report: SurfaceUV4C.Report?
    @State private var comparisonText = ""
    @State private var lastReports: [String: SurfaceUV4C.Report] = [:]
    @State private var worldAnchors: [AnchorEntity] = []

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // 常驻 ARView：整个 4C 生命周期只创建一次，不销毁不重建。
                ARViewContainer4C(session: sharedSession) { arView in
                    arViewReference = arView
                }

                // 自定义引导文案：由 Apple 的 didProvide(instruction) 驱动。
                if phase == .scanning || phase == .processing {
                    VStack {
                        Spacer()
                        Text(coachingText)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                        Spacer().frame(height: 70)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            Picker("场景", selection: $scenario) {
                ForEach(CrackRaycast4B.scenarios, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.orange)
            Text("照片红线/蓝点 = 4A 折线与采样点；AR 红点/红线 = raycast 世界点；白线 = mesh")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                if phase == .scanning {
                    Button("结束扫描") {
                        stopScan()
                    }
                } else if phase != .processing {
                    Button("开始扫描") {
                        startScan()
                    }
                }

                Button("拍照并映射 UV") {
                    measure()
                }
                .disabled(
                    isRunning || capturedRoom == nil
                        || arViewReference == nil || phase != .ready
                )

                if let report {
                    Button("复制报告") {
                        let full = [report.text(), comparisonText]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        UIPasteboard.general.string = full
                    }
                }

                if !worldAnchors.isEmpty {
                    Button("清除投影") {
                        clearWorldVisualization()
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let uiImage = viewModel.uiImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                CenterlineOverlayView(
                                    result: viewModel.centerlineResult,
                                    imageSize: uiImage.size
                                )
                            )
                            .frame(maxWidth: .infinity)
                    }

                    if let report {
                        Text([report.text(), comparisonText]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("扫描并测量后此处显示：裂缝照片叠加、4C 报告（区域固定，取景框比例不变）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 210)
            .padding(.horizontal)
        }
        .navigationTitle("4C Surface UV")
        .onAppear {
            setupCoordinator()
        }
    }

    // MARK: - RoomPlan 扫描

    private func setupCoordinator() {
        coordinator.onDidEnd = { data, error in
            if let error {
                statusText = "扫描出错：\(error.localizedDescription)"
                phase = .idle
                coachingText = "扫描失败"
                return
            }
            phase = .processing
            statusText = "RoomPlan 处理中…"
            coachingText = "正在生成房间模型…"
            Task {
                do {
                    let room = try await RoomBuilder(options: [])
                        .capturedRoom(from: data)
                    capturedRoom = room
                    phase = .ready
                    statusText =
                        "扫描完成：wall \(room.walls.count) · floor \(room.floors.count) · other \(room.doors.count + room.windows.count + room.openings.count)，可拍照映射"
                } catch {
                    statusText = "CapturedRoom 构建失败：\(error.localizedDescription)"
                    phase = .idle
                }
            }
        }
        coordinator.onDidFail = { error in
            statusText = "RoomPlan 失败：\(error.localizedDescription)"
            phase = .idle
            coachingText = "扫描失败"
        }
        coordinator.onInstruction = { text in
            coachingText = text
        }
    }

    private func startScan() {
        guard let arView = arViewReference else { return }
        capturedRoom = nil
        report = nil
        comparisonText = ""
        lastReports = [:]
        clearWorldVisualization()
        viewModel.centerlineResult = nil
        viewModel.centerlineStats = ""

        let session = RoomCaptureSession(arSession: arView.session)
        session.delegate = coordinator
        roomCaptureSession = session
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        session.run(configuration: configuration)

        phase = .scanning
        coachingText = "开始扫描：请缓慢移动设备"
        statusText = "RoomPlan 扫描中…（Apple 引导文案驱动，无彩色面层）"
    }

    private func stopScan() {
        guard let session = roomCaptureSession else { return }
        session.stop(pauseARSession: false)
        phase = .processing
        coachingText = "正在生成房间模型…"
        statusText = "RoomPlan 处理中…"
        // RoomPlan 已停止，恢复 ARKit mesh 配置，让白线回到 ARView。
        restoreMesh()
    }

    private func restoreMesh() {
        if let arView = arViewReference {
            arView.session.run(Self.meshConfiguration())
        }
    }

    // MARK: - 测量

    private func measure() {
        guard let arView = arViewReference, let room = capturedRoom else { return }
        isRunning = true
        statusText = "等待相机就绪…"

        Task { @MainActor in
            let ready = await waitForFrame(on: arView, timeout: 3)
            guard ready else {
                statusText = "相机尚未就绪，请稍后重试"
                isRunning = false
                return
            }
            statusText = "拍照中…"

            arView.snapshot(saveToHDR: false) { image in
                Task { @MainActor in
                    guard let image else {
                        statusText = "拍照失败"
                        isRunning = false
                        return
                    }
                    statusText = "4A 识别裂缝中…"
                    viewModel.centerlineResult = nil
                    viewModel.centerlineStats = ""
                    viewModel.uiImage = image
                    await viewModel.runInference()

                    guard let samples = viewModel.centerlineResult?.samplePointsPerPolyline,
                          !samples.isEmpty else {
                        statusText = "未识别到裂缝，无法 4C"
                        isRunning = false
                        return
                    }

                    let scale: CGFloat
                    if image.size.width > 0 {
                        scale = arView.bounds.width / image.size.width
                    } else {
                        scale = 1
                    }

                    statusText = "raycast + Surface UV 映射中…"
                    let raycast = CrackRaycast4B.measure(
                        arView: arView,
                        scenario: scenario,
                        samplePointsPerPolyline: samples,
                        imageToViewScale: scale
                    )
                    let surfaceReport = SurfaceUV4C.buildReport(
                        scenario: scenario,
                        raycast: raycast,
                        room: room
                    )
                    addWorldVisualization(arView: arView, report: raycast)
                    comparisonText = compareWithPrevious(surfaceReport)
                    lastReports[scenario] = surfaceReport
                    report = surfaceReport
                    statusText = String(
                        format: "表面分配率 %.1f%% · UV 单位米 · 照片与 AR 已叠加",
                        surfaceReport.assignedRatio * 100
                    )
                    isRunning = false
                }
            }
        }
    }

    /// 拍照前等待 AR 会话有可用帧（安全闸门，最多 3 秒）。
    private func waitForFrame(
        on arView: ARView,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if arView.session.currentFrame != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return arView.session.currentFrame != nil
    }

    /// 与上次同场景测量对比：surfaceID 稳定性 + World→UV 转换一致性。
    private func compareWithPrevious(_ report: SurfaceUV4C.Report) -> String {
        guard let previous = lastReports[scenario] else { return "" }
        var lines: [String] = []
        lines.append("与上次同场景对比：")
        let count = min(previous.polylines.count, report.polylines.count)
        for index in 0..<count {
            let a = previous.polylines[index]
            let b = report.polylines[index]
            let idSame = a.surfaceID == b.surfaceID
            var du = 0.0
            var dv = 0.0
            var pairs = 0
            let pairCount = min(a.uvPoints.count, b.uvPoints.count)
            for j in 0..<pairCount {
                du += abs(a.uvPoints[j].u - b.uvPoints[j].u)
                dv += abs(a.uvPoints[j].v - b.uvPoints[j].v)
                pairs += 1
            }
            if pairs > 0 {
                du /= Double(pairs)
                dv /= Double(pairs)
            }
            lines.append(
                String(
                    format: "[%d] surfaceID 一致：%@ · 平均 |Δu| = %.4f m · |Δv| = %.4f m",
                    index + 1,
                    idSame ? "✓" : "✗",
                    du,
                    dv
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - AR 世界点可视化（复用 4B 已验证逻辑：红球 + 相邻点连线）

    private func addWorldVisualization(
        arView: ARView,
        report: Raycast4BReport
    ) {
        clearWorldVisualization()
        for polyline in report.polylines {
            var previousWorld: SIMD3<Float>?
            for point in polyline.points {
                guard let world = point.world else {
                    previousWorld = nil
                    continue
                }
                let anchor = AnchorEntity(world: world)
                let sphere = ModelEntity(
                    mesh: .generateSphere(radius: 0.004),
                    materials: [SimpleMaterial(color: .red, isMetallic: false)]
                )
                anchor.addChild(sphere)
                arView.scene.addAnchor(anchor)
                worldAnchors.append(anchor)

                if let previous = previousWorld {
                    if let line = Self.lineEntity(
                        from: previous,
                        to: world,
                        color: .red
                    ) {
                        let midpoint = (previous + world) * 0.5
                        let lineAnchor = AnchorEntity(world: midpoint)
                        lineAnchor.addChild(line)
                        arView.scene.addAnchor(lineAnchor)
                        worldAnchors.append(lineAnchor)
                    }
                }
                previousWorld = world
            }
        }
    }

    private func clearWorldVisualization() {
        for anchor in worldAnchors {
            anchor.removeFromParent()
        }
        worldAnchors.removeAll()
    }

    private static func lineEntity(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        color: UIColor
    ) -> ModelEntity? {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 0.001 else { return nil }
        let direction = delta / length
        let entity = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(0.003, 0.003, length),
                cornerRadius: 0.0015
            ),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        entity.orientation = simd_quatf(
            from: SIMD3<Float>(0, 0, 1),
            to: direction
        )
        return entity
    }

    static func meshConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        return configuration
    }
}

/// 常驻 ARView：整个 4C 生命周期只创建一次，显示白线 mesh（showSceneUnderstanding）。
struct ARViewContainer4C: UIViewRepresentable {
    var session: ARSession
    var onReady: (ARView) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        arView.session = session
        arView.debugOptions.insert(.showSceneUnderstanding)
        session.run(CrackSurfaceUV4CView.meshConfiguration())
        onReady(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
