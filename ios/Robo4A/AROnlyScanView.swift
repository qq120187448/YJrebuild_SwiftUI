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
    /// 0.74D：统一空间会话管理（WorldMap/relocalization/状态机）。
    @State private var spatialSession = SpatialSessionManager()
    @State private var worldAnchors: [AnchorEntity] = []
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
            if !spatialSession.lastDiagnostic.isEmpty {
                Text(spatialSession.lastDiagnostic)
                    .font(.caption2)
                    .foregroundStyle(
                        spatialSession.isMeasurementAllowed
                            ? Color.secondary
                            : Color.orange
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            HStack(spacing: 12) {
                Button(isRunning ? "分析中…" : "拍照测量") {
                    measure()
                }
                .disabled(
                    isRunning || !spatialSession.isMeasurementAllowed
                )
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
            spatialSession.onLog = { [self] text in
                appendReportLog("会话：" + text)
            }
        }
        .onDisappear {
            spatialSession.stop(session: session)
        }
    }

    private static let reportLogKey = "roboscanAROnlyReportLogKey"

    // MARK: - 会话配置

    private func runConfiguration(arView: ARView) {
        spatialSession.start(arView: arView)
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
                var uvLength = 0.0
                var collectedWorldPoints: [SIMD3<Float>] = []
                var previousSurfaceID: UUID?
                var previousUV: SIMD2<Double>?
                for polyline in samples {
                    var previousWorld: SIMD3<Float>?
                    for point in polyline {
                        totalSamples += 1
                        let viewPoint = CGPoint(
                            x: CGFloat(point.x) * scale,
                            y: CGFloat(point.y) * scale
                        )
                        // 官方 ARView.raycast（4B 已验证），只做 SurfaceHit 胶水包装。
                        let results = arView.raycast(
                            from: viewPoint,
                            allowing: .estimatedPlane,
                            alignment: .any
                        )
                        guard let result = results.first else { continue }
                        hits += 1
                        let surfaceHit = ARMeasurementSurface.hit(
                            from: result
                        )
                        let world = result.worldTransform.position
                        collectedWorldPoints.append(world)
                        if let previousWorld {
                            totalLength += Double(
                                simd_distance(previousWorld, world)
                            )
                        }
                        previousWorld = world
                        // UV：同表面连续累加（surface-local XY）
                        let uv = SIMD2<Double>(
                            Double(surfaceHit.localPoint.x),
                            Double(surfaceHit.localPoint.y)
                        )
                        if let previousSurfaceID,
                           previousSurfaceID == surfaceHit.id,
                           let previousUV {
                            uvLength += hypot(
                                uv.x - previousUV.x,
                                uv.y - previousUV.y
                            )
                        }
                        previousSurfaceID = surfaceHit.id
                        previousUV = uv
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
                    format: "长度(3D) %.3f m · 长度(UV) %.3f m · 命中 %.1f%% (%d/%d) · 重投影 avg %.2fpx · tracking %@ · 表面 %d",
                    totalLength,
                    uvLength,
                    hitRate,
                    hits,
                    totalSamples,
                    avgError,
                    tracking,
                    arView.session.currentFrame?.anchors
                        .compactMap { $0 as? ARPlaneAnchor }
                        .count ?? 0
                )
                statusText = "测量完成"
                appendReportLog("测量：\(reportText)")
                appendReportLog(performance)
                addWorldVisualization(
                    arView: arView,
                    worldPoints: collectedWorldPoints
                )
                // 0.74D：SpatialSessionManager 状态机 + WorldMap 自动保存 + 失配自动恢复
                spatialSession.poll(
                    arView: arView,
                    hitRate: totalSamples > 0
                        ? Double(hits) / Double(totalSamples)
                        : nil
                )
                if spatialSession.state == .tracking
                    || spatialSession.state == .recovered {
                    Task { @MainActor in
                        _ = await spatialSession.autoSaveWorldMap(
                            arView: arView
                        )
                    }
                }
                if spatialSession.state == .spatialDegraded {
                    appendReportLog(
                        "会话：" + spatialSession.lastDiagnostic
                    )
                    _ = spatialSession.loadWorldMap(arView: arView)
                }
            }
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
