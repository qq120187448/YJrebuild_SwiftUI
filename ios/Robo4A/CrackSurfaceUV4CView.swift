import ARKit
import RealityKit
import RoomPlan
import simd
import SwiftUI
import UIKit

/// RoomPlan 官方扫描视图回调桥接（RoomCaptureView + 共享 ARSession）。
final class RoomPlanSessionCoordinator:
    NSObject,
    RoomCaptureSessionDelegate,
    RoomCaptureViewDelegate
{
    var onDidPresent: ((CapturedRoom, Error?) -> Void)?
    var onDidFail: ((Error) -> Void)?

    func captureSession(
        _ session: RoomCaptureSession,
        didStartWith configuration: RoomCaptureSession.Configuration
    ) {
        // 官方 RoomCaptureView 自带引导与进度，无需额外处理。
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didEndWith data: CapturedRoomData,
        error: Error?
    ) {
        // 最终结果由 captureView(didPresent:) 提供。
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didFailWithError error: Error
    ) {
        onDidFail?(error)
    }

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
}

/// 4C：官方 RoomCaptureView 扫描（自带引导/进度）+ 4B world 点 → Surface UV（米）。
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
    @State private var phase: Phase = .idle
    @State private var scenario = CrackRaycast4B.scenarios[0]
    @State private var statusText =
        "先“开始扫描”墙面（RoomPlan 官方引导界面），结束扫描后再拍照映射 UV"
    @State private var isRunning = false
    @State private var arViewReference: ARView?
    @State private var roomCaptureViewReference: RoomCaptureView?
    @State private var capturedRoom: CapturedRoom?
    @State private var report: SurfaceUV4C.Report?
    @State private var comparisonText = ""
    @State private var lastReports: [String: SurfaceUV4C.Report] = [:]
    @State private var worldAnchors: [AnchorEntity] = []

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if phase == .scanning || phase == .processing {
                    RoomCaptureView4C(session: sharedSession) { view in
                        roomCaptureViewReference = view
                        view.captureSession.delegate = coordinator
                        view.delegate = coordinator
                        view.captureSession.run(
                            configuration: RoomCaptureSession.Configuration()
                        )
                        statusText = "RoomPlan 扫描中…（白色引导框，缓慢绕房间扫描）"
                    }
                } else {
                    ARViewContainer4C(session: sharedSession) { arView in
                        arViewReference = arView
                    }
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
            Text("照片红线/蓝点 = 4A 折线与采样点；AR 红点/红线 = raycast 世界点")
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

    // MARK: - RoomPlan 官方扫描

    private func setupCoordinator() {
        coordinator.onDidPresent = { room, error in
            if let error {
                statusText = "扫描出错：\(error.localizedDescription)"
                phase = .idle
                return
            }
            capturedRoom = room
            phase = .ready
            statusText =
                "扫描完成：wall \(room.walls.count) · floor \(room.floors.count) · other \(room.doors.count + room.windows.count + room.openings.count)，可拍照映射"
        }
        coordinator.onDidFail = { error in
            statusText = "RoomPlan 失败：\(error.localizedDescription)"
            phase = .idle
        }
    }

    private func startScan() {
        capturedRoom = nil
        report = nil
        comparisonText = ""
        lastReports = [:]
        clearWorldVisualization()
        viewModel.centerlineResult = nil
        viewModel.centerlineStats = ""
        phase = .scanning
        statusText = "正在启动 RoomPlan 官方扫描…"
    }

    private func stopScan() {
        guard let view = roomCaptureViewReference else { return }
        view.captureSession.stop(pauseARSession: false)
        phase = .processing
        statusText = "RoomPlan 处理中…（官方处理页）"
    }

    // MARK: - 测量

    private func measure() {
        guard let arView = arViewReference, let room = capturedRoom else { return }
        isRunning = true
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

/// 官方 RoomPlan 扫描视图（自带引导、进度与处理页），与 ARView 共享 ARSession。
struct RoomCaptureView4C: UIViewRepresentable {
    let session: ARSession
    var onMake: (RoomCaptureView) -> Void

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: session)
        view.isCoachingOverlayEnabled = true
        onMake(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

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
        session.run(CrackSurfaceUV4CView.meshConfiguration())
        onReady(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
