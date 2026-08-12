import ARKit
import RealityKit
import SwiftUI
import UIKit

/// 4B：4A 采样点 → ARView.raycast → ARWorld 3D → 反投影 → 重投影误差。
struct CrackRaycast4BView: View {

    @StateObject private var viewModel = ContentViewModel()
    @State private var scenario = CrackRaycast4B.scenarios[0]
    @State private var statusText = "对准墙面，点击“拍照并 4B 测量”"
    @State private var isRunning = false
    @State private var report: Raycast4BReport?
    @State private var history: [Raycast4BReport] = []
    @State private var arViewReference: ARView?

    var body: some View {
        VStack(spacing: 8) {
            ARViewContainer { arView in
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
                Button {
                    measure()
                } label: {
                    Label("拍照并 4B 测量", systemImage: "camera.viewfinder")
                }
                .disabled(isRunning || arViewReference == nil)

                if let report {
                    Button {
                        UIPasteboard.general.string = report.text()
                    } label: {
                        Label("复制本组", systemImage: "doc.on.doc")
                    }
                }

                if !history.isEmpty {
                    Button {
                        UIPasteboard.general.string = history
                            .map { $0.text() }
                            .joined(separator: "\n\n")
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc.fill")
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            if let report {
                ScrollView {
                    Text(report.text())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(.horizontal)
            }
        }
        .navigationTitle("4B Raycast")
    }

    private func measure() {
        guard let arView = arViewReference else { return }
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
                viewModel.uiImage = image
                await viewModel.runInference()

                guard let samples = viewModel.centerlineResult?.samplePointsPerPolyline,
                      !samples.isEmpty else {
                    statusText = "未识别到裂缝，无法 4B"
                    isRunning = false
                    return
                }

                let scale: CGFloat
                if image.size.width > 0 {
                    scale = arView.bounds.width / image.size.width
                } else {
                    scale = 1
                }

                statusText = "raycast + 反投影中…"
                let measured = CrackRaycast4B.measure(
                    arView: arView,
                    scenario: scenario,
                    samplePointsPerPolyline: samples,
                    imageToViewScale: scale
                )
                report = measured
                history.append(measured)
                statusText = String(
                    format: "命中率 %.1f%% · 平均重投影 %.2f px · P95 %.2f px",
                    measured.hitRate * 100,
                    measured.avgError,
                    measured.p95Error
                )
                isRunning = false
            }
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    var onReady: (ARView) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)

        onReady(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
