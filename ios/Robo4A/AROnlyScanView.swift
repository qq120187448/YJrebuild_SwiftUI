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
    @State private var logLines: [String] = []

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
                Button("保存 WorldMap") {
                    saveWorldMap()
                }
                .disabled(isRelocalizing)
                Button("恢复 WorldMap") {
                    recoverWorldMap()
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            ScrollView {
                Text(logLines.joined(separator: "\n"))
                    .font(.caption2)
                    .monospaced()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(.horizontal)
        }
        .navigationTitle("4C-L ARKit-Only POC")
        .onDisappear {
            session.pause()
        }
    }

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

                var totalSamples = 0
                var hits = 0
                var errors: [Double] = []
                var totalLength = 0.0
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
                appendLog("测量：\(reportText)")
            }
        }
    }

    // MARK: - WorldMap 保存 / 恢复

    private func saveWorldMap() {
        guard let arView = arViewRef else { return }
        guard let frame = arView.session.currentFrame else {
            statusText = "无当前帧"
            return
        }
        guard frame.worldMappingStatus == .mapped else {
            statusText = "worldMappingStatus=\(frame.worldMappingStatus)，未达 mapped"
            return
        }
        arView.session.getCurrentWorldMap { map, error in
            if let map {
                savedWorldMap = map
                appendLog(
                    "WorldMap 已保存（\(map.anchors.count) 锚点，mapped）"
                )
            } else {
                appendLog(
                    "WorldMap 保存失败：\(error?.localizedDescription ?? "未知")"
                )
            }
        }
    }

    private func recoverWorldMap() {
        guard let arView = arViewRef, let savedWorldMap else {
            statusText = "无已保存 WorldMap"
            return
        }
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
        statusText = "正在重新定位空间…请缓慢移动手机观察已扫描区域"
        appendLog("ARWorldMap recovery 已触发（relocalizing…）")

        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let frame = arView.session.currentFrame else { continue }
                if frame.camera.trackingState == .normal {
                    isRelocalizing = false
                    statusText = "recovery 成功：tracking normal"
                    appendLog("recovery 成功：tracking normal")
                    return
                }
            }
            isRelocalizing = false
            statusText = "recovery 超时（60s），请回到已扫描区域"
            appendLog("recovery 超时（60s），请回到已扫描区域")
        }
    }

    // MARK: - 工具

    private func appendLog(_ text: String) {
        logLines.append(text)
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
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
