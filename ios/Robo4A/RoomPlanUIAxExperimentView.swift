import ARKit
import RoomPlan
import SwiftUI
import UIKit

/// RoomPlan 扫描 UI A/B/C/D 真机实验页。
///
/// 目的：隔离“共享 ARSession”与“预先配置 Mesh/Plane”两个变量，
/// 确认此前集成版“透明面层”的来源。每组测完必须彻底杀掉 App 再重开。
struct RoomPlanUIAxExperimentView: View {

    enum Mode: String, CaseIterable, Identifiable {
        case a = "A 基座"
        case b = "B 集成"
        case c = "C 干净"
        case d = "D 共享"

        var id: String { rawValue }

        var sessionDescription: String {
            switch self {
            case .a:
                return "全新 ARSession（RoomCaptureView 内部）· 无预配置"
            case .b:
                return "共享 ARSession · 先 run Mesh/Plane · 再 RoomCaptureView"
            case .c:
                return "全新 ARSession（RoomCaptureView 内部）· 无预配置"
            case .d:
                return "共享 ARSession · 不预配置 Mesh/Plane"
            }
        }
    }

    @State private var mode: Mode = .a
    @State private var isScanning = false
    @State private var sharedSession = ARSession()
    @State private var scanID = UUID()
    @State private var statusText =
        "选组后点“开始扫描”；每组测完彻底杀 App 再重开，再测下一组"
    @State private var coachingText = "—"

    var body: some View {
        VStack(spacing: 8) {
            Picker("组别", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isScanning)
            .padding(.horizontal)

            Text("当前组：\(mode.rawValue)（\(mode.sessionDescription)）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            ZStack {
                if isScanning {
                    RoomCaptureViewAx(
                        mode: mode,
                        sharedSession: sharedSession,
                        scanID: scanID,
                        onInstruction: { text in
                            coachingText = text
                        }
                    ) { view in
                        var configuration = RoomCaptureSession.Configuration()
                        configuration.isCoachingEnabled = true
                        view.captureSession.run(configuration: configuration)
                    }
                    .id(scanID)

                    VStack {
                        Spacer()
                        Text("coaching：\(coachingText)")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                            .padding(.bottom, 16)
                    }
                    .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.85))
                        .overlay(
                            Text("选择组别后点“开始扫描”\nRoomCaptureView 仅在本组开始时创建")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        )
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(isScanning ? "结束扫描" : "开始扫描") {
                if isScanning {
                    stopScan()
                } else {
                    startScan()
                }
            }
            .buttonStyle(.borderedProminent)

            Text("记录项：RoomPlan（coaching/墙/地/门窗）· 视觉（轮廓/半透明面层/彩色面层/底部模型/模型更新/摄像头）· Session（currentFrame/sceneDepth/mesh anchors）")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle("4C UI A/B/C/D")
    }

    private func startScan() {
        // 每组都使用全新 ARSession，避免上一组状态污染。
        let freshSession = ARSession()
        sharedSession = freshSession
        coachingText = "—"

        if mode == .b {
            // 复现 4C 集成版（c540d6e）：先跑 ARKit mesh/plane 配置。
            let configuration = ARWorldTrackingConfiguration()
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                configuration.sceneReconstruction = .meshWithClassification
            }
            configuration.planeDetection = [.horizontal, .vertical]
            configuration.environmentTexturing = .automatic
            freshSession.run(configuration)
        }

        Task { @MainActor in
            if mode == .b {
                // 让 mesh 配置先生效，再交给 RoomCaptureView（贴近集成版时序）。
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            scanID = UUID()
            isScanning = true
            statusText = "组 \(mode.rawValue) 扫描中… 结束后先记录，再彻底杀 App 测下一组"
        }
    }

    private func stopScan() {
        isScanning = false
        statusText = "组 \(mode.rawValue) 已停止。记录本组结果，然后彻底杀掉 App 再测下一组"
    }
}

/// RoomCaptureView 的 SwiftUI 包装：按组别决定使用内部会话还是共享会话。
private struct RoomCaptureViewAx: UIViewRepresentable {
    let mode: RoomPlanUIAxExperimentView.Mode
    let sharedSession: ARSession
    let scanID: UUID
    let onInstruction: (String) -> Void
    let onStart: (RoomCaptureView) -> Void

    func makeUIView(context: Context) -> RoomCaptureView {
        let view: RoomCaptureView
        switch mode {
        case .a, .c:
            // 全新 ARSession（RoomCaptureView 内部创建）。
            view = RoomCaptureView(frame: .zero)
        case .b, .d:
            // 共享 ARSession。
            view = RoomCaptureView(frame: .zero, arSession: sharedSession)
        }
        view.captureSession.delegate = context.coordinator
        view.delegate = context.coordinator
        onStart(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        uiView.captureSession.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInstruction: onInstruction)
    }

    @objc(RoboScanAxRoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, NSCoding {
        let onInstruction: (String) -> Void

        init(onInstruction: @escaping (String) -> Void) {
            self.onInstruction = onInstruction
            super.init()
        }

        required init?(coder: NSCoder) {
            fatalError("Not implemented")
        }

        func encode(with coder: NSCoder) {}

        func captureSession(
            _ session: RoomCaptureSession,
            didProvide instruction: RoomCaptureSession.Instruction
        ) {
            DispatchQueue.main.async {
                self.onInstruction(Self.text(for: instruction))
            }
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
        ) {}

        private static func text(for instruction: RoomCaptureSession.Instruction) -> String {
            switch instruction {
            case .normal:
                return "正常，请缓慢移动"
            case .slowDown:
                return "请放慢速度"
            case .moveCloseToWall:
                return "请靠近墙面"
            case .moveAwayFromWall:
                return "请离墙稍远"
            case .turnOnLight:
                return "请打开灯光"
            case .lowTexture:
                return "请对准有纹理区域"
            @unknown default:
                return "请缓慢移动"
            }
        }
    }
}
