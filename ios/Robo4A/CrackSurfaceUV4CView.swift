import ARKit
import RealityKit
import RoomPlan
import simd
import SwiftUI
import UIKit

private let roboscan4CReportLogKey = "Robo4C.reportLog"

/// RoomPlan 会话回调桥接（RoomCaptureView/RoomCaptureSession 使用与 ARView 同一个 ARSession）。
@objc(RoboScan4CScanCoordinator)
final class RoomPlanSessionCoordinator: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, NSCoding {
    var onDidEnd: ((CapturedRoomData, Error?) -> Void)?
    var onDidPresent: ((CapturedRoom, Error?) -> Void)?
    var onDidFail: ((Error) -> Void)?
    var onInstruction: ((String) -> Void)?
    /// 手动结束扫描后置 true，避免 dismantle 重复 stop。
    var scanStopped = false

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

    /// 使用框架自带处理结果页：官方 mini room 由 RoomCaptureView 展示，不自建几何渲染。
    func captureView(
        shouldPresent roomDataForProcessing: CapturedRoomData,
        error: (any Error)?
    ) -> Bool {
        true
    }

    func captureView(
        didPresent processedResult: CapturedRoom,
        error: (any Error)?
    ) {
        onDidPresent?(processedResult, error)
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

/// 4C：常驻 ARView（测量）+ 单一 ARSession + RoomCaptureView（官方扫描引导/底部 3D 模型）。
/// 照片叠加 4A 折线/采样点，AR 画面叠加 4B 世界点/连线，便于逐条裂缝对照。
struct CrackSurfaceUV4CView: View {

    private enum Phase: Equatable {
        case idle
        case scanning
        case reviewing
        case processing
        case ready
    }

    private enum MeshControl: String, CaseIterable, Identifiable, Equatable {
        case baseline = "保留既有 mesh"
        case clear = "扫描前清空 mesh"

        var id: String { rawValue }
    }

    @StateObject private var viewModel = ContentViewModel()
    @State private var coordinator = RoomPlanSessionCoordinator()
    @State private var sharedSession = ARSession()
    @State private var roomCaptureViewReference: RoomCaptureView?
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
    @State private var roomCaptureFrameTimestamp: TimeInterval?
    @State private var roomCaptureCameraPosition: SIMD3<Float>?
    @State private var meshControl: MeshControl = .baseline
    @State private var surfaceToleranceMM: Double = 20
    @State private var showParameterPanel = false
    @State private var reportLog: [String] = []
    @State private var performanceText = ""

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
            ZStack {
                // 常驻 ARView：整个 4C 生命周期只创建一次，不销毁不重建；
                // 扫描期间透明度为 0（保持实例存活），结束后恢复显示用于拍照测量。
                ARViewContainer4C(session: sharedSession) { arView in
                    arViewReference = arView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity((phase == .scanning || phase == .reviewing) ? 0 : 1)

                // 官方 RoomPlan 扫描视图：自带引导、进度与底部 3D 模型（isModelEnabled 默认 true）。
                if phase == .scanning || phase == .reviewing {
                    RoomCaptureView4C(
                        session: sharedSession,
                        coordinator: coordinator
                    ) { view in
                        roomCaptureViewReference = view
                        var configuration = RoomCaptureSession.Configuration()
                        configuration.isCoachingEnabled = true
                        view.captureSession.run(configuration: configuration)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isRunning {
                    Text("正在分析本次照片…")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: max(geo.size.height * 0.55, 320))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            Picker("场景", selection: $scenario) {
                ForEach(CrackRaycast4B.scenarios, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)

            Picker("Mesh 对照", selection: $meshControl) {
                ForEach(MeshControl.allCases) { control in
                    Text(control.rawValue).tag(control)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Button {
                showParameterPanel = true
            } label: {
                Label("参数", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.orange)
            if !performanceText.isEmpty {
                Text(performanceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("照片红线/蓝点 = 4A 折线与采样点；AR 红点/红线 = raycast 世界点；扫描时 = 官方 RoomPlan 引导 + 底部 3D 模型")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                if phase == .scanning {
                    Button("结束扫描") {
                        stopScan()
                    }
                } else if phase == .reviewing {
                    Button("完成房间确认") {
                        finishRoomReview()
                    }
                    .disabled(capturedRoom == nil)
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
                        let full = [report.clippedText(limit: 1000), comparisonText]
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

            HStack(spacing: 8) {
                Text("累计日志 \(reportLog.count) 条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("复制累计日志") {
                    UIPasteboard.general.string = reportLog.joined(
                        separator: "\n\n=====\n\n"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(reportLog.isEmpty)

                Button("清空日志") {
                    clearReportLog()
                }
                .buttonStyle(.bordered)
                .disabled(reportLog.isEmpty)
            }
            .padding(.horizontal)

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
                        Text([report.clippedText(limit: 1000), comparisonText]
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
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .navigationTitle("4C Surface UV")
        .onAppear {
            setupCoordinator()
            reportLog = UserDefaults.standard.stringArray(
                forKey: roboscan4CReportLogKey
            ) ?? []
        }
        .sheet(isPresented: $showParameterPanel) {
            parameterPanel
        }
    }

    private var parameterPanel: some View {
        NavigationView {
            Form {
                Section("Surface 误差（高级参数）") {
                    Slider(value: $surfaceToleranceMM, in: 10...50, step: 1)
                    Text("\(Int(surfaceToleranceMM)) mm")
                }
                Section("模型参数") {
                    Slider(value: $viewModel.confidenceThreshold, in: 0...1)
                    Text(
                        String(
                            format: "Conf：%.2f",
                            viewModel.confidenceThreshold
                        )
                    )
                    Slider(value: $viewModel.iouThreshold, in: 0...1)
                    Text(
                        String(
                            format: "IoU：%.2f",
                            viewModel.iouThreshold
                        )
                    )
                }
            }
            .navigationTitle("参数")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showParameterPanel = false
                    }
                }
            }
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
            phase = .reviewing
            statusText = "扫描已停止，正在展示官方 3D 房间结果…"
            coachingText = "请查看官方 3D 结果并确认"
            captureSessionSnapshot()
        }
        coordinator.onDidPresent = { room, error in
            if let error {
                statusText = "官方结果展示失败：\(error.localizedDescription)"
                phase = .idle
                coachingText = "扫描失败"
                return
            }
            capturedRoom = room
            phase = .reviewing
            statusText =
                "官方结果已生成：wall \(room.walls.count) · floor \(room.floors.count) · other \(room.doors.count + room.windows.count + room.openings.count)，请确认后进入测量"
            coachingText = "确认房间无误后点“完成房间确认”"
            captureSessionSnapshot()
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
        guard arViewReference != nil else { return }
        capturedRoom = nil
        report = nil
        comparisonText = ""
        lastReports = [:]
        clearWorldVisualization()
        viewModel.centerlineResult = nil
        viewModel.centerlineStats = ""

        // RoomCaptureView 由 SwiftUI 在 phase == .scanning 时创建，
        // 其 onMake 中执行 captureSession.run。
        coordinator.scanStopped = false
        roomCaptureViewReference = nil

        if meshControl == .clear, let arView = arViewReference {
            arView.session.run(
                Self.noMeshConfiguration(),
                options: [.resetTracking, .removeExistingAnchors]
            )
        }

        phase = .scanning
        coachingText = "开始扫描：请缓慢移动设备"
        statusText = meshControl == .clear
            ? "RoomPlan 扫描中…（对照组：已清空既有 mesh）"
            : "RoomPlan 扫描中…（官方引导 + 底部 3D 模型）"
    }

    private func stopScan() {
        guard let view = roomCaptureViewReference else { return }
        if !coordinator.scanStopped {
            view.captureSession.stop(pauseARSession: false)
            coordinator.scanStopped = true
        }
        phase = .reviewing
        coachingText = "正在展示官方 3D 房间结果…"
        statusText = "RoomPlan 官方结果生成中，请稍候"
    }

    private func finishRoomReview() {
        guard capturedRoom != nil else { return }
        // 专家确认：不得重新 run ARWorldTrackingConfiguration，保持 RoomPlan 世界原点。
        guard let arView = arViewReference else { return }
        let beforeCamera = arView.session.currentFrame?.camera.transform.position
        let beforeMesh = Self.meshAnchorCount(arView)

        phase = .ready
        statusText = "房间确认完成，可拍照映射 UV"
        coachingText = "请对准裂缝拍照"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let afterCamera = arView.session.currentFrame?.camera.transform.position
            let afterMesh = Self.meshAnchorCount(arView)
            let log = Self.finishReviewDiagnosticText(
                beforeCamera: beforeCamera,
                beforeMesh: beforeMesh,
                afterCamera: afterCamera,
                afterMesh: afterMesh
            )
            self.appendReportLog(log)
        }
    }

    private func captureSessionSnapshot() {
        guard let frame = arViewReference?.session.currentFrame else { return }
        roomCaptureFrameTimestamp = frame.timestamp
        roomCaptureCameraPosition = frame.camera.transform.position
    }

    // MARK: - 测量

    private func measure() {
        guard let arView = arViewReference, let room = capturedRoom else { return }
        isRunning = true
        let totalStart = Date()
        performanceText = ""
        statusText = "等待相机就绪…"

        Task { @MainActor in
            let ready = await waitForFrame(on: arView, timeout: 3)
            guard ready else {
                statusText = "相机尚未就绪，请稍后重试"
                isRunning = false
                return
            }
            statusText = "拍照中…"

            // 拍照时间戳：用于 Capture→Raycast 延迟统计（专家建议指标）。
            let captureTime = Date()
            let captureFrame = arView.session.currentFrame
            let orientation =
                arView.window?.windowScene?.interfaceOrientation ?? .portrait
            let captureContext = captureFrame.map { frame in
                CaptureFrameSpatialContext(
                    timestamp: frame.timestamp,
                    cameraTransform: frame.camera.transform,
                    cameraIntrinsics: frame.camera.intrinsics,
                    imageResolution: frame.camera.imageResolution,
                    displayTransform: frame.displayTransform(
                        for: orientation,
                        viewportSize: arView.bounds.size
                    )
                )
            }
            arView.snapshot(saveToHDR: false) { image in
                Task { @MainActor in
                    guard let image else {
                        statusText = "拍照失败"
                        isRunning = false
                        return
                    }
                    statusText = "正在分析本次照片…"
                    viewModel.centerlineResult = nil
                    viewModel.centerlineStats = ""
                    let analysisImage = Self.resizedImage(
                        image,
                        maxSide: 1024
                    )
                    viewModel.uiImage = analysisImage
                    let inferenceStart = Date()
                    await viewModel.runInference()
                    let inferenceDuration =
                        Date().timeIntervalSince(inferenceStart) * 1000

                    guard let samples = viewModel.centerlineResult?.samplePointsPerPolyline,
                          !samples.isEmpty else {
                        statusText = "未识别到裂缝，无法 4C"
                        isRunning = false
                        return
                    }

                    let scale: CGFloat
                    if analysisImage.size.width > 0 {
                        scale = arView.bounds.width / analysisImage.size.width
                    } else {
                        scale = 1
                    }

                    statusText = "raycast + Surface UV 映射中…"
                    let spatialStart = Date()
                    let raycast: Raycast4BReport
                    if let captureContext {
                        raycast = CaptureFrameSurfaceMapper.map(
                            arView: arView,
                            context: captureContext,
                            room: room,
                            samplePointsPerPolyline: samples,
                            imageToViewScale: scale,
                            captureTime: captureTime
                        )
                    } else {
                        raycast = CrackRaycast4B.measure(
                            arView: arView,
                            scenario: scenario,
                            samplePointsPerPolyline: samples,
                            imageToViewScale: scale,
                            captureTime: captureTime
                        )
                    }
                    let sessionDiagnosticText = Self.sessionDiagnosticText(
                        arView: arView,
                        roomCaptureFrameTimestamp: roomCaptureFrameTimestamp,
                        roomCaptureCameraPosition: roomCaptureCameraPosition
                    )
                    let surfaceReport = SurfaceUV4C.buildReport(
                        scenario: scenario,
                        raycast: raycast,
                        room: room,
                        sessionDiagnosticText: sessionDiagnosticText,
                        toleranceM: surfaceToleranceMM / 1000.0,
                        totalPixelLengthPx: viewModel.centerlineResult?.totalPixelLength,
                        maxWidthPx: viewModel.centerlineResult?.maxWidthPx,
                        averageWidthPx: viewModel.centerlineResult?.averageWidthPx
                    )
                    addWorldVisualization(arView: arView, report: raycast)
                    comparisonText = compareWithPrevious(surfaceReport)
                    lastReports[scenario] = surfaceReport
                    report = surfaceReport
                    appendReportLog(surfaceReport.clippedText(limit: 1000))
                    let spatialDuration =
                        Date().timeIntervalSince(spatialStart) * 1000
                    let totalDuration =
                        Date().timeIntervalSince(totalStart) * 1000
                    let timing = viewModel.stageTimings
                    let performance = [
                        String(format: "requestSetup=%.0fms", timing["requestSetup"] ?? 0),
                        String(format: "coreML=%.0fms", timing["coreML"] ?? 0),
                        String(format: "maskDecode=%.0fms", timing["maskDecode"] ?? 0),
                        String(format: "centerline=%.0fms", timing["centerline"] ?? 0),
                        String(format: "spatial=%.0fms", spatialDuration),
                        String(format: "total=%.0fms", totalDuration),
                        viewModel.inferenceHardware
                    ].joined(separator: " · ")
                    performanceText = performance
                    appendReportLog(performance)
                    statusText = String(
                        format: "表面分配率 %.1f%% · UV 单位米 · 已解除静止锁定",
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
            let bothAssigned =
                a.surfaceID != nil && b.surfaceID != nil
                && !a.uvPoints.isEmpty && !b.uvPoints.isEmpty
            if bothAssigned {
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
            } else {
                var worldDelta = 0.0
                var worldPairs = 0
                let pointCount = min(a.points.count, b.points.count)
                for j in 0..<pointCount {
                    guard let wa = a.points[j].world,
                          let wb = b.points[j].world else { continue }
                    worldDelta += Double(simd_distance(wa, wb))
                    worldPairs += 1
                }
                let averageWorldDelta = worldPairs == 0
                    ? 0
                    : worldDelta / Double(worldPairs)
                lines.append(
                    String(
                        format: "[%d] surfaceID 不可比（至少一侧 noSurface） · 平均 |Δworld| = %.4f m · 可比点 %d",
                        index + 1,
                        averageWorldDelta,
                        worldPairs
                    )
                )
            }
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

    private func appendReportLog(_ text: String) {
        let clipped = String(text.prefix(1000))
        reportLog.append(clipped)
        UserDefaults.standard.set(reportLog, forKey: roboscan4CReportLogKey)
    }

    private func clearReportLog() {
        reportLog.removeAll()
        UserDefaults.standard.set(reportLog, forKey: roboscan4CReportLogKey)
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

    private static func sessionDiagnosticText(
        arView: ARView,
        roomCaptureFrameTimestamp: TimeInterval?,
        roomCaptureCameraPosition: SIMD3<Float>?
    ) -> String {
        let frame = arView.session.currentFrame
        let meshAnchorCount = frame?.anchors
            .compactMap { $0 as? ARMeshAnchor }
            .count ?? 0
        let trackingState = Self.trackingStateText(frame?.camera.trackingState)
        let timestamp = frame?.timestamp ?? 0
        var cameraText = "-"
        if let cameraTransform = frame?.camera.transform {
            let position = cameraTransform.position
            cameraText = String(
                format: "(%.3f, %.3f, %.3f)",
                position.x,
                position.y,
                position.z
            )
        }
        var coordinateText = "没有 RoomPlan 完成时快照"
        if let captureTimestamp = roomCaptureFrameTimestamp,
           let capturePosition = roomCaptureCameraPosition,
           let cameraTransform = frame?.camera.transform {
            let deltaTime = timestamp - captureTimestamp
            let deltaPosition = cameraTransform.position - capturePosition
            let deltaLength = simd_length(deltaPosition)
            coordinateText = String(
                format: "capture→measure Δt=%.3fs Δcam=%.3fm",
                deltaTime,
                deltaLength
            )
        }
        return "Session 诊断：meshAnchorCount=\(meshAnchorCount) cameraTrackingState=\(trackingState) frameTimestamp=\(timestamp) cameraCenter=\(cameraText) · \(coordinateText)"
    }

    private static func meshAnchorCount(_ arView: ARView?) -> Int {
        arView?.session.currentFrame?.anchors
            .compactMap { $0 as? ARMeshAnchor }
            .count ?? 0
    }

    private static func finishReviewDiagnosticText(
        beforeCamera: SIMD3<Float>?,
        beforeMesh: Int,
        afterCamera: SIMD3<Float>?,
        afterMesh: Int
    ) -> String {
        let before = vectorText(beforeCamera)
        let after = vectorText(afterCamera)
        let delta = cameraDeltaText(from: beforeCamera, to: afterCamera)
        return "finishRoomReview 前后：camera before=\(before) mesh=\(beforeMesh) · camera after=\(after) mesh=\(afterMesh) · Δcamera=\(delta)"
    }

    private static func vectorText(_ value: SIMD3<Float>?) -> String {
        guard let value else { return "nil" }
        return String(
            format: "(%.3f, %.3f, %.3f)",
            value.x,
            value.y,
            value.z
        )
    }

    private static func cameraDeltaText(
        from a: SIMD3<Float>?,
        to b: SIMD3<Float>?
    ) -> String {
        guard let a, let b else { return "-" }
        return String(format: "%.3fm", simd_distance(a, b))
    }

    private static func resizedImage(
        _ image: UIImage,
        maxSide: CGFloat
    ) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxSide, largest > 0 else { return image }
        let scale = maxSide / largest
        let size = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { context in
                context.cgContext.interpolationQuality = .high
                image.draw(in: CGRect(origin: .zero, size: size))
            }
    }

    private static func trackingStateText(
        _ state: ARCamera.TrackingState?
    ) -> String {
        guard let state else { return "nil" }
        switch state {
        case .normal:
            return "normal"
        case .limited:
            return "limited"
        case .notAvailable:
            return "notAvailable"
        @unknown default:
            return "unknown"
        }
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

    static func noMeshConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = []
        return configuration
    }
}

/// 官方 RoomPlan 扫描视图（自带引导、进度与底部 3D 模型），与 ARView 共享同一个 ARSession。
struct RoomCaptureView4C: UIViewRepresentable {
    let session: ARSession
    let coordinator: RoomPlanSessionCoordinator
    var onMake: (RoomCaptureView) -> Void

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: session)
        view.captureSession.delegate = coordinator
        view.delegate = coordinator
        onMake(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    static func dismantleUIView(
        _ uiView: RoomCaptureView,
        coordinator: RoomPlanSessionCoordinator
    ) {
        // 手动“结束扫描”已 stop；这里只兜底（例如直接切走页面）。
        if !coordinator.scanStopped {
            if #available(iOS 17.0, *) {
                uiView.captureSession.stop(pauseARSession: false)
            } else {
                uiView.captureSession.stop()
            }
        }
    }

    func makeCoordinator() -> RoomPlanSessionCoordinator {
        coordinator
    }
}

/// 常驻 ARView：整个 4C 生命周期只创建一次，不销毁不重建；扫描时被 RoomCaptureView 覆盖。
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
        if session.configuration == nil {
            session.run(CrackSurfaceUV4CView.meshConfiguration())
        }
        onReady(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
