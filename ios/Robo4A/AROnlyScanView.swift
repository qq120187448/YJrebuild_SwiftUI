import ARKit
import RealityKit
import SwiftUI
import UIKit

/// 4C-L ARKit-Only POC（专家 A/B 优先级最高，2026-08-14）：
/// 不用 RoomPlan——ARKit WorldMap + ARPlane/ARMesh + raycast 作为唯一表面。
/// 测量：拍照 → YOLO → 采样点 → ARView.raycast → world 3D 折线长度 + 重投影。
/// 长期恢复：WorldMap 保存 / initialWorldMap 恢复（跟踪 normal 后恢复测量）。
/// 与 RoomPlan 4C-L 同设备/同场景/同轨迹 A/B，比较 5/10/20/30min 的
/// tracking、recovery、surface assignment、reprojection、长度。
struct AROnlyScanView: View {

    @StateObject private var viewModel = ContentViewModel()
    @State private var session = ARSession()
    @State private var arViewRef: ARView?
    @State private var statusText = "对准裂缝拍照测量（ARKit-Only，无 RoomPlan）"
    @State private var isRunning = false
    @State private var reportText = ""
    @State private var savedWorldMap: ARWorldMap?
    @State private var isRelocalizing = false
    @State private var worldAnchors: [AnchorEntity] = []
    @State private var autoSaved = false
    /// 历史投影颜色循环（区分每次测量，观察漂移）。
    @State private var colorIndex = 0
    @State private var reportLog: [String] = []

    var body: some View {
        VStack(spacing: 8) {
            ARViewContainerAROnly(session: session) { arView in
                arViewRef = arView
                runConfiguration(arView: arView)
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 24)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.orange)

            if !reportText.isEmpty {
                Text(reportText)
                    .font(.caption2)
                    .monospaced()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            HStack(spacing: 12) {
                Button(isRunning ? "分析中…" : "拍照测量") {
                    measure()
                }
                .disabled(isRunning || isRelocalizing)
                if !worldAnchors.isEmpty {
                    Button("清除投影") {
                        clearWorldVisualization()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            HStack(spacing: 12) {
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
                Text(reportLog.joined(separator: "\n"))
                    .font(.caption2)
                    .monospaced()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(.horizontal)
        }
        .navigationTitle("4C-L ARKit-Only POC")
        .onAppear {
            reportLog = UserDefaults.standard.stringArray(
                forKey: Self.reportLogKey
            ) ?? []
        }
        .onDisappear {
            session.pause()
        }
    }

    private static let reportLogKey = "roboscanAROnlyReportLogKey"

    // MARK: - 会话配置

    private func runConfiguration(arView: ARView) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(
            .meshWithClassification
        ) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.environmentTexturing = .automatic
        session.run(configuration)
    }

    // MARK: - 测量（raycast → world 3D 折线长度）

    @MainActor
    private func measure() {
        guard let arView = arViewRef else { return }
        isRunning = true
        statusText = "拍照中…"
        let totalStart = Date()
        arView.snapshot(saveToHDR: false) { image in
            Task { @MainActor in
                defer { isRunning = false }
                guard let image else {
                    statusText = "拍照失败"
                    return
                }
                statusText = "识别裂缝中…"
                viewModel.centerlineResult = nil
                viewModel.uiImage = Self.resizedImage(image, maxSide: 1024)
                await viewModel.runInference()

                guard let samples =
                    viewModel.centerlineResult?.samplePointsPerPolyline,
                    !samples.isEmpty else {
                    statusText = "未识别到裂缝"
                    return
                }
                let imageWidth = viewModel.uiImage?.size.width ?? 1
                let scale = imageWidth > 0
                    ? arView.bounds.width / imageWidth
                    : 1

                let spatialStart = Date()
                var totalSamples = 0
                var hits = 0
                var errors: [Double] = []
                var totalLength = 0.0
                var collectedWorldPoints: [SIMD3<Float>] = []
                for polyline in samples {
                    var previousWorld: SIMD3<Float>?
                    for point in polyline {
                        totalSamples += 1
                        let viewPoint = CGPoint(
                            x: CGFloat(point.x) * scale,
                            y: CGFloat(point.y) * scale
                        )
                        let results = arView.raycast(
                            from: viewPoint,
                            allowing: .estimatedPlane,
                            alignment: .any
                        )
                        guard let hit = results.first else { continue }
                        hits += 1
                        let world = hit.worldTransform.position
                        collectedWorldPoints.append(world)
                        if let previousWorld {
                            totalLength += Double(
                                simd_distance(previousWorld, world)
                            )
                        }
                        previousWorld = world
                        if let projected = arView.project(world) {
                            errors.append(
                                hypot(
                                    Double(projected.x - viewPoint.x),
                                    Double(projected.y - viewPoint.y)
                                )
                            )
                        }
                    }
                }

                let hitRate = totalSamples > 0
                    ? Double(hits) / Double(totalSamples) * 100
                    : 0
                let avgError = errors.isEmpty
                    ? 0
                    : errors.reduce(0, +) / Double(errors.count)
                let tracking = Self.trackingText(
                    arView.session.currentFrame?.camera.trackingState
                )
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
                reportText = String(
                    format: "长度 %.3f m · 命中 %.1f%% (%d/%d) · 重投影 avg %.2fpx · tracking %@",
                    totalLength,
                    hitRate,
                    hits,
                    totalSamples,
                    avgError,
                    tracking
                )
                statusText = "测量完成"
                appendReportLog("测量：\(reportText)")
                appendReportLog(performance)
                addWorldVisualization(
                    arView: arView,
                    worldPoints: collectedWorldPoints
                )
                // WorldMap 自动保存（mapped 时，仅一次）
                if !autoSaved {
                    autoSaveWorldMapIfMapped(arView: arView)
                }
                // 自动失配检测 → 自动 recovery
                autoDetectAndRecover(
                    arView: arView,
                    totalSamples: totalSamples,
                    hits: hits,
                    avgError: avgError
                )
            }
        }
    }

    // MARK: - WorldMap 自动保存 / 自动恢复

    /// mapped 时自动保存基准 WorldMap（仅一次）。
    private func autoSaveWorldMapIfMapped(arView: ARView) {
        guard let frame = arView.session.currentFrame else { return }
        guard frame.worldMappingStatus == .mapped else {
            appendReportLog(
                "WorldMap 未保存：worldMappingStatus=\(frame.worldMappingStatus)（等待 mapped）"
            )
            return
        }
        arView.session.getCurrentWorldMap { map, error in
            if let map {
                savedWorldMap = map
                autoSaved = true
                appendReportLog(
                    "WorldMap 已自动保存（\(map.anchors.count) 锚点，mapped）"
                )
            } else {
                appendReportLog(
                    "WorldMap 自动保存失败：\(error?.localizedDescription ?? "未知")"
                )
            }
        }
    }

    /// 失配检测（命中率/重投影/tracking）→ 自动 ARWorldMap recovery。
    @MainActor
    private func autoDetectAndRecover(
        arView: ARView,
        totalSamples: Int,
        hits: Int,
        avgError: Double
    ) {
        let tracking = arView.session.currentFrame?.camera.trackingState
        let trackingText = Self.trackingText(tracking)
        let hitRate = totalSamples > 0
            ? Double(hits) / Double(totalSamples)
            : 0
        var mismatch = false
        var reason = ""
        if tracking != .normal {
            mismatch = true
            reason = "tracking=\(trackingText)"
        } else if hitRate < 0.8 {
            mismatch = true
            reason = String(
                format: "命中率 %.1f%% <80%%",
                hitRate * 100
            )
        } else if avgError > 3 {
            mismatch = true
            reason = String(format: "重投影 %.1fpx >3px", avgError)
        }
        guard mismatch else {
            appendReportLog(
                String(
                    format: "空间健康 GOOD（命中 %.1f%% · 重投影 %.2fpx · %@）",
                    hitRate * 100,
                    avgError,
                    trackingText
                )
            )
            return
        }
        appendReportLog("空间失配（\(reason)），自动触发 recovery")
        recoverWorldMap()
    }

    /// 用 initialWorldMap 重启会话并等待 normal（自动恢复测量）。
    @MainActor
    private func recoverWorldMap() {
        guard let arView = arViewRef, let savedWorldMap else {
            appendReportLog("无已保存 WorldMap，无法自动恢复")
            return
        }
        guard !isRelocalizing else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = savedWorldMap
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(
            .meshWithClassification
        ) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        configuration.environmentTexturing = .automatic
        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        isRelocalizing = true
        statusText = "正在自动重新定位空间…请缓慢移动手机观察已扫描区域"
        appendReportLog("ARWorldMap 自动 recovery 已触发（relocalizing…）")

        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let frame = arView.session.currentFrame else { continue }
                if frame.camera.trackingState == .normal {
                    isRelocalizing = false
                    statusText = "recovery 成功：tracking normal"
                    appendReportLog("recovery 成功：tracking normal")
                    return
                }
            }
            isRelocalizing = false
            statusText = "recovery 超时（60s），请回到已扫描区域"
            appendReportLog("recovery 超时（60s），请回到已扫描区域")
        }
    }

    // MARK: - 工具

    /// AR 红点/红线投影（4B 同款：世界点红球 + 相邻点连线）。
    private func addWorldVisualization(
        arView: ARView,
        worldPoints: [SIMD3<Float>]
    ) {
        // 保持历史投影（用户要求）：不清除旧投影，每次测量用不同颜色便于对比漂移。
        let colors: [UIColor] = [
            .red, .green, .blue, .orange, .purple, .cyan
        ]
        let color = colors[colorIndex % colors.count]
        colorIndex += 1
        var previous: SIMD3<Float>?
        for world in worldPoints {
            let anchor = AnchorEntity(world: world)
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.004),
                materials: [SimpleMaterial(
                    color: color,
                    isMetallic: false
                )]
            )
            anchor.addChild(sphere)
            arView.scene.addAnchor(anchor)
            worldAnchors.append(anchor)
            if let previous {
                let delta = world - previous
                let length = simd_length(delta)
                if length > 0.001 {
                    let lineAnchor = AnchorEntity(
                        world: (previous + world) * 0.5
                    )
                    let line = ModelEntity(
                        mesh: .generateBox(
                            size: SIMD3<Float>(0.003, 0.003, length),
                            cornerRadius: 0.0015
                        ),
                        materials: [SimpleMaterial(
                            color: color,
                            isMetallic: false
                        )]
                    )
                    line.orientation = simd_quatf(
                        from: SIMD3<Float>(0, 0, 1),
                        to: simd_normalize(delta)
                    )
                    lineAnchor.addChild(line)
                    arView.scene.addAnchor(lineAnchor)
                    worldAnchors.append(lineAnchor)
                }
            }
            previous = world
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

    private static func trackingText(
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

/// ARKit-Only 常驻 ARView（自动配置 session，无 RoomPlan）。
struct ARViewContainerAROnly: UIViewRepresentable {
    let session: ARSession
    var onReady: (ARView) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        arView.session = session
        onReady(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
