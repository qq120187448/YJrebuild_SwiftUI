import ARKit
import RealityKit
import RoomPlan
import SwiftUI
import UIKit

/// RoomPlan 会话回调桥接（RoomCaptureSession 使用与 ARView 同一个 ARSession）。
final class RoomPlanSessionCoordinator: NSObject, RoomCaptureSessionDelegate {
    var onDidStart: (() -> Void)?
    var onDidEnd: ((CapturedRoomData, Error?) -> Void)?
    var onDidFail: ((Error) -> Void)?

    func captureSession(
        _ session: RoomCaptureSession,
        didStartWith configuration: RoomCaptureSession.Configuration
    ) {
        onDidStart?()
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
}

/// 4C：RoomPlan 扫描 + 4B world 点 → Surface UV（米）。
struct CrackSurfaceUV4CView: View {

    @StateObject private var viewModel = ContentViewModel()
    @State private var coordinator = RoomPlanSessionCoordinator()
    @State private var scenario = CrackRaycast4B.scenarios[0]
    @State private var statusText = "先“开始扫描”墙面（RoomPlan），再拍照映射 UV"
    @State private var isRunning = false
    @State private var isScanning = false
    @State private var arViewReference: ARView?
    @State private var roomCaptureSession: RoomCaptureSession?
    @State private var capturedRoom: CapturedRoom?
    @State private var report: SurfaceUV4C.Report?
    @State private var comparisonText = ""
    @State private var lastReports: [String: SurfaceUV4C.Report] = [:]

    var body: some View {
        VStack(spacing: 8) {
            ARViewContainer4C { arView in
                arViewReference = arView
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

            HStack {
                if isScanning {
                    Button("结束扫描") {
                        roomCaptureSession?.stop(pauseARSession: false)
                        isScanning = false
                        if let arView = arViewReference {
                            arView.session.run(Self.meshConfiguration())
                        }
                        statusText = "RoomPlan 处理中…"
                    }
                } else {
                    Button("开始扫描") {
                        startRoomPlanScan()
                    }
                }

                Button("拍照并映射 UV") {
                    measure()
                }
                .disabled(isRunning || capturedRoom == nil || arViewReference == nil)

                if let report {
                    Button("复制报告") {
                        let full = [report.text(), comparisonText]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        UIPasteboard.general.string = full
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            ScrollView {
                if let report {
                    Text([report.text(), comparisonText]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("扫描并测量后此处显示 4C 报告（区域固定，取景框比例不变）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 190)
            .padding(.horizontal)
        }
        .navigationTitle("4C Surface UV")
        .onAppear {
            setupCoordinator()
        }
    }

    // MARK: - RoomPlan

    private func setupCoordinator() {
        coordinator.onDidStart = { [weak self] in
            guard let self else { return }
            self.isScanning = true
            self.statusText = "RoomPlan 扫描中…（结束扫描后恢复 mesh）"
        }
        coordinator.onDidEnd = { [weak self] data, error in
            guard let self else { return }
            self.isScanning = false
            if let error {
                self.statusText = "扫描出错：\(error.localizedDescription)"
                return
            }
            Task {
                do {
                    let room = try await RoomBuilder().capturedRoom(from: data)
                    self.capturedRoom = room
                    self.statusText =
                        "扫描完成：wall \(room.walls.count) · floor \(room.floors.count) · other \(room.doors.count + room.windows.count + room.openings.count)，可拍照映射"
                } catch {
                    self.statusText = "CapturedRoom 构建失败：\(error.localizedDescription)"
                }
            }
        }
        coordinator.onDidFail = { [weak self] error in
            guard let self else { return }
            self.isScanning = false
            self.statusText = "RoomPlan 失败：\(error.localizedDescription)"
        }
    }

    private func startRoomPlanScan() {
        guard let arView = arViewReference else { return }
        let session = RoomCaptureSession(arSession: arView.session)
        session.delegate = coordinator
        roomCaptureSession = session
        capturedRoom = nil
        report = nil
        comparisonText = ""
        session.run(configuration: RoomCaptureSession.Configuration())
        statusText = "正在启动 RoomPlan…"
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
                comparisonText = compareWithPrevious(surfaceReport)
                lastReports[scenario] = surfaceReport
                report = surfaceReport
                statusText = String(
                    format: "表面分配率 %.1f%% · UV 单位米",
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

struct ARViewContainer4C: UIViewRepresentable {
    var onReady: (ARView) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        let session = ARSession()
        arView.session = session
        session.run(CrackSurfaceUV4CView.meshConfiguration())
        onReady(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
