import ARKit
import RealityKit
import simd
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
    @State private var worldAnchors: [AnchorEntity] = []

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
            Text("红色球/线 = raycast 命中的世界点，应贴合墙面裂缝")
                .font(.caption2)
                .foregroundStyle(.secondary)

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

                Button {
                    clearWorldVisualization()
                } label: {
                    Label("清除投影", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.borderedProminent)

            ScrollView {
                if let report {
                    Text(report.text())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("测量后此处显示 4B 基线报告（区域固定，取景框比例不变）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 170)
            .padding(.horizontal)
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
                viewModel.centerlineResult = nil
                viewModel.centerlineStats = ""
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
                addWorldVisualization(arView: arView, report: measured)
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

    // MARK: - AR 世界点可视化（红球 + 相邻点连线）

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
