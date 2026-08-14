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
    @State private var reportLog: [String] = []
    @State private var measurementSummary = ""

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
            ARViewContainer { arView in
                arViewReference = arView
            }
            .frame(height: Self.viewfinderHeight(in: geo))
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
            if !measurementSummary.isEmpty {
                Text(measurementSummary)
                    .font(.caption2)
                    .monospaced()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
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
        }
        .navigationTitle("4B Raycast")
        .onAppear {
            viewModel.deferWidthStats = true
            reportLog = UserDefaults.standard.stringArray(
                forKey: Self.reportLogKey
            ) ?? []
        }
    }

    private static let reportLogKey = "roboscan4BReportLogKey"

    /// Fixed viewfinder height so post-capture info never squeezes it.
    private static func viewfinderHeight(in geo: GeometryProxy) -> CGFloat {
        max(180, geo.size.height - Self.bottomPanelHeight)
    }

    private static let bottomPanelHeight: CGFloat = 350

    private func measure() {
        guard let arView = arViewReference else { return }
        isRunning = true
        statusText = "拍照中…"
        let totalStart = Date()

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
                // 性能：拍照图统一压到 1024 长边（缩小中心线 grid，采样点坐标仍在 1024 空间）。
                let analysisImage = Self.resizedImage(image, maxSide: 1024)
                viewModel.uiImage = analysisImage
                await viewModel.runInference()

                guard let samples = viewModel.centerlineResult?.samplePointsPerPolyline,
                      !samples.isEmpty else {
                    statusText = "未识别到裂缝，无法 4B"
                    isRunning = false
                    return
                }

                let scale: CGFloat
                if analysisImage.size.width > 0 {
                    scale = arView.bounds.width / analysisImage.size.width
                } else {
                    scale = 1
                }

                statusText = "raycast + 反投影中…"
                let spatialStart = Date()
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
                // 长度/宽度后台异步计算（不阻塞拍照→出数）；分步时间写入累计日志（屏幕不显示）。
                let spatialDuration =
                    Date().timeIntervalSince(spatialStart) * 1000
                let totalDuration =
                    Date().timeIntervalSince(totalStart) * 1000
                let timing = viewModel.stageTimings
                let performance = [
                    String(
                        format: "requestSetup=%.0fms",
                        timing["requestSetup"] ?? 0
                    ),
                    String(
                        format: "coreML=%.0fms",
                        timing["coreML"] ?? 0
                    ),
                    String(
                        format: "maskDecode=%.0fms",
                        timing["maskDecode"] ?? 0
                    ),
                    String(
                        format: "centerline=%.0fms",
                        timing["centerline"] ?? 0
                    ),
                    String(format: "spatial=%.0fms", spatialDuration),
                    String(format: "total=%.0fms", totalDuration),
                    viewModel.inferenceHardware
                ].joined(separator: " · ")
                appendReportLog(performance)
                appendReportLog(measured.text())

                let widthMasks = viewModel.maskPredictions ?? []
                let widthSamples = samples
                let widthImageSize = analysisImage.size
                let measuredCopy = measured
                Task.detached(priority: .userInitiated) {
                    let widthStart = Date()
                    // 长度：world 3D 折线（后台）
                    var length3D = 0.0
                    for polyline in measuredCopy.polylines {
                        var previousWorld: SIMD3<Float>?
                        for point in polyline.points {
                            guard let world = point.world else {
                                previousWorld = nil
                                continue
                            }
                            if let previousWorld {
                                length3D += Double(
                                    simd_distance(previousWorld, world)
                                )
                            }
                            previousWorld = world
                        }
                    }
                    // 宽度：mask 轮廓法向（后台）
                    let widthStats = CrackCenterlineOverlay
                        .computeWidthStats(
                            masks: widthMasks,
                            imageSize: widthImageSize,
                            samplesPerPolyline: widthSamples
                        )
                    let widthDuration = Date().timeIntervalSince(widthStart) * 1000
                    // Scale: mm per image pixel, derived from the crack's own
                    // pixel length (not the sample-point count).
                    var imagePixelLength = 0.0
                    for polyline in widthSamples {
                        for index in 1..<polyline.count {
                            imagePixelLength += hypot(
                                Double(polyline[index].x - polyline[index - 1].x),
                                Double(polyline[index].y - polyline[index - 1].y)
                            )
                        }
                    }
                    let mmPerPx = imagePixelLength > 0 && length3D > 0
                        ? length3D * 1000 / imagePixelLength
                        : nil
                    let summary: String
                    if let mmPerPx {
                        summary = String(
                            format: "长度(3D) %.3f m · 宽度 平均 %.1f · 最大 %.1f mm",
                            length3D,
                            widthStats.averagePx * mmPerPx,
                            widthStats.maxPx * mmPerPx
                        )
                    } else {
                        summary = String(
                            format: "长度(3D) %.3f m · 宽度 平均 %.1f · 最大 %.1f px",
                            length3D,
                            widthStats.averagePx,
                            widthStats.maxPx
                        )
                    }
                    await MainActor.run {
                        measurementSummary = summary
                        appendReportLog(summary)
                        let gridSize = String(
                            format: "%dx%d",
                            Int(widthImageSize.width.rounded()),
                            Int(widthImageSize.height.rounded())
                        )
                        let maskSize = widthMasks.first.map {
                            "\($0.maskSize.width)x\($0.maskSize.height)"
                        } ?? "none"
                        let pxText = String(
                            format: "min/avg/max %.1f/%.1f/%.1f px · P10/P50/P90 %.1f/%.1f/%.1f px · %@ · samples %d · pxLen %.1f · mmPerPx %@ · grid %@ · mask %@ · width=%.0fms",
                            widthStats.minPx,
                            widthStats.averagePx,
                            widthStats.maxPx,
                            widthStats.p10Px,
                            widthStats.p50Px,
                            widthStats.p90Px,
                            widthStats.quality.label,
                            widthSamples.reduce(0) { $0 + $1.count },
                            imagePixelLength,
                            mmPerPx.map { String(format: "%.4f", $0) } ?? "nil",
                            gridSize,
                            maskSize,
                            widthDuration
                        )
                        appendReportLog("宽度诊断: " + pxText)
                    }
                }

                if !reportLog.isEmpty {
                    Button("复制累计日志") {
                        UIPasteboard.general.string = reportLog.joined(
                            separator: "\n\n=====\n\n"
                        )
                    }
                }
                isRunning = false
            }
        }
    }

    private func appendReportLog(_ text: String) {
        let clipped = String(text.prefix(1200))
        reportLog.append(clipped)
        if reportLog.count > 300 {
            reportLog.removeFirst(reportLog.count - 300)
        }
        UserDefaults.standard.set(
            reportLog,
            forKey: Self.reportLogKey
        )
    }

    private func clearReportLog() {
        reportLog.removeAll()
        UserDefaults.standard.set(
            reportLog,
            forKey: Self.reportLogKey
        )
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

    /// 等比压缩长边到 maxSide（性能：缩小中心线 grid，坐标仍在 1024 空间）。
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
            .image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
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
