import ARKit
import RealityKit
import RoomPlan
import SwiftUI
import UIKit

/// 4C/4D 采样点正式数据模型（专家定稿，2026-08-14）：
/// rawWorld 用于 AR 红线显示/重投影；snapWorld/surfaceLocal/uv 用于持久化测量；
/// 保存后可用 Snap / Isect / nearest 重算而无需重跑 YOLO。
struct CrackSamplePoint {
    let pixel: CGPoint
    let rawWorld: SIMD3<Float>?
    let snapWorld: SIMD3<Float>?
    let snapDistanceMM: Double?
    let surfaceID: UUID?
    let surfaceLocal: SIMD3<Float>?
    let uvMeters: SIMD2<Double>?
    let trackingState: String
    let anchorQuality: String
    let reprojectionPx: Double?
}

/// 标定单点三路结果（Raw / Snap / Isect）。
struct CalibrationPointResult {
    let pixel: CGPoint
    let rawUV: SIMD2<Double>?
    let snapUV: SIMD2<Double>?
    let isectUV: SIMD2<Double>?
    let snapDistanceMM: Double?
    let rawReprojectionPx: Double?
    let snapReprojectionPx: Double?
    let isectRoundTripPx: Double?
}

/// 4D.1A 标定视图（专家批复）：已知长度线段（500/1000/2000mm）× 方向 × 距离，
/// 照片点选两端 → Raw/Snap/Isect 三路长度与误差；累计日志统计 Mean/MAE/RMSE/Std。
struct CalibrationView: View {
    let arView: ARView
    let room: CapturedRoom
    let onLog: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var knownLengthMM: Double = 500
    @State private var directionDeg: Double = 0
    @State private var distanceM: Double = 1
    @State private var analysisImage: UIImage?
    @State private var captureContext: CaptureFrameSpatialContext?
    @State private var viewPointScale: CGFloat = 1
    @State private var tapPoints: [CGPoint] = []
    @State private var resultText = ""
    @State private var isCapturing = false

    var body: some View {
        NavigationView {
            Form {
                Section("标定参数") {
                    Picker("已知长度", selection: $knownLengthMM) {
                        Text("500 mm").tag(500.0)
                        Text("1000 mm").tag(1000.0)
                        Text("2000 mm").tag(2000.0)
                    }
                    Picker("方向", selection: $directionDeg) {
                        Text("水平 0°").tag(0.0)
                        Text("45°").tag(45.0)
                        Text("垂直 90°").tag(90.0)
                    }
                    Picker("距离", selection: $distanceM) {
                        Text("1 m").tag(1.0)
                        Text("2 m").tag(2.0)
                    }
                }

                Section("拍摄与点选（点击照片两端）") {
                    Button(isCapturing ? "拍照中…" : "拍照") {
                        capture()
                    }
                    .disabled(isCapturing)

                    if let analysisImage {
                        GeometryReader { geo in
                            let rect = Self.aspectFitRect(
                                image: analysisImage,
                                in: geo.size
                            )
                            ZStack {
                                Image(uiImage: analysisImage)
                                    .resizable()
                                    .scaledToFit()
                                ForEach(
                                    Array(tapPoints.enumerated()),
                                    id: \.offset
                                ) { _, p in
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 16, height: 16)
                                        .position(
                                            Self.viewPoint(
                                                p,
                                                imageRect: rect,
                                                image: analysisImage
                                            )
                                        )
                                }
                            }
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        if let ip = Self.imagePoint(
                                            value.location,
                                            imageRect: rect,
                                            image: analysisImage
                                        ),
                                        tapPoints.count < 2 {
                                            tapPoints.append(ip)
                                        }
                                    }
                            )
                        }
                        .frame(height: 260)
                    }
                }

                Section("结果") {
                    if !resultText.isEmpty {
                        Text(resultText)
                            .font(.system(.caption, design: .monospaced))
                    }
                    Button("计算三路长度") {
                        compute()
                    }
                    .disabled(tapPoints.count < 2 || analysisImage == nil)
                    Button("记入累计日志") {
                        onLog(resultText)
                    }
                    .disabled(resultText.isEmpty)
                }
            }
            .navigationTitle("4D.1A 标定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - 拍摄

    @MainActor
    private func capture() {
        isCapturing = true
        arView.snapshot(saveToHDR: false) { image in
            Task { @MainActor in
                defer { isCapturing = false }
                guard let image else { return }
                let analysis = Self.resizedImage(image, maxSide: 1024)
                analysisImage = analysis
                tapPoints = []
                resultText = ""
                if analysis.size.width > 0 {
                    viewPointScale = arView.bounds.width / analysis.size.width
                }
                if let frame = arView.session.currentFrame {
                    let orientation =
                        arView.window?.windowScene?.interfaceOrientation
                        ?? .portrait
                    captureContext = CaptureFrameSpatialContext(
                        timestamp: frame.timestamp,
                        cameraTransform: frame.camera.transform,
                        cameraIntrinsics: frame.camera.intrinsics,
                        imageResolution: frame.camera.imageResolution,
                        displayTransform: frame.displayTransform(
                            for: orientation,
                            viewportSize: arView.bounds.size
                        ),
                        viewportSize: arView.bounds.size
                    )
                }
            }
        }
    }

    // MARK: - 计算

    @MainActor
    private func compute() {
        guard tapPoints.count >= 2, let analysisImage else { return }
        let results = tapPoints.map { pixel in
            Self.computePoint(
                pixel: pixel,
                arView: arView,
                context: captureContext,
                room: room,
                scale: viewPointScale
            )
        }
        let a = results[0]
        let b = results[1]
        let known = knownLengthMM / 1000.0
        var lines = [
            "标定 \(Int(knownLengthMM))mm · \(Int(directionDeg))° · \(Int(distanceM))m"
        ]
        lines.append(
            Self.lengthLine(
                "Raw",
                uvA: a.rawUV,
                uvB: b.rawUV,
                known: known
            )
        )
        lines.append(
            Self.lengthLine(
                "Snap",
                uvA: a.snapUV,
                uvB: b.snapUV,
                known: known
            )
        )
        lines.append(
            Self.lengthLine(
                "Isect",
                uvA: a.isectUV,
                uvB: b.isectUV,
                known: known
            )
        )
        if let d1 = a.snapDistanceMM, let d2 = b.snapDistanceMM {
            lines.append(
                String(
                    format: "snapDistance: A %.1f · B %.1f mm",
                    d1,
                    d2
                )
            )
        }
        if let r = a.rawReprojectionPx, let s = a.snapReprojectionPx,
           let i = a.isectRoundTripPx {
            lines.append(
                String(
                    format: "点A投影: Raw %.1f · Snap %.1f · Isect roundTrip %.1f px",
                    r,
                    s,
                    i
                )
            )
        }
        resultText = lines.joined(separator: "\n")
    }

    private static func lengthLine(
        _ name: String,
        uvA: SIMD2<Double>?,
        uvB: SIMD2<Double>?,
        known: Double
    ) -> String {
        guard let uvA, let uvB else { return "\(name): 无" }
        let length = hypot(uvB.x - uvA.x, uvB.y - uvA.y)
        let err = length - known
        let pct = known > 0 ? abs(err) / known * 100 : 0
        return String(
            format: "%@: %.3f m · err %+.1f mm · %.2f%%",
            name,
            length,
            err * 1000,
            pct
        )
    }

    /// 单点三路（Raw/Snap/Isect）计算。
    @MainActor
    static func computePoint(
        pixel: CGPoint,
        arView: ARView,
        context: CaptureFrameSpatialContext?,
        room: CapturedRoom,
        scale: CGFloat
    ) -> CalibrationPointResult {
        let surfaces =
            room.walls + room.floors + room.doors
            + room.windows + room.openings
        let viewPoint = CGPoint(
            x: pixel.x * scale,
            y: pixel.y * scale
        )
        var rawUV: SIMD2<Double>?
        var snapUV: SIMD2<Double>?
        var isectUV: SIMD2<Double>?
        var snapDistanceMM: Double?
        var rawReprojectionPx: Double?
        var snapReprojectionPx: Double?
        var isectRoundTripPx: Double?

        let rawResults = arView.raycast(
            from: viewPoint,
            allowing: .estimatedPlane,
            alignment: .any
        )
        let worldRaw = rawResults.first?.worldTransform.position
        if let worldRaw {
            if let m = SurfaceUV4C.map(
                world: worldRaw,
                surfaces: surfaces,
                toleranceM: 0.02,
                snapMaxM: nil
            ) {
                rawUV = SIMD2(Double(m.local.x), Double(m.local.y))
            }
            if let m = SurfaceUV4C.map(
                world: worldRaw,
                surfaces: surfaces,
                toleranceM: 0.02,
                snapMaxM: 0.02
            ) {
                snapUV = SIMD2(Double(m.local.x), Double(m.local.y))
                let rawLocal = SurfaceUV4C.surfaceLocal(
                    worldRaw,
                    surface: m.surface
                )
                snapDistanceMM = Double(abs(rawLocal.z)) * 1000
                let snapWorld = Self.snapWorld(
                    local: m.local,
                    surface: m.surface
                )
                if let projected = arView.project(worldRaw) {
                    rawReprojectionPx = hypot(
                        Double(projected.x - viewPoint.x),
                        Double(projected.y - viewPoint.y)
                    )
                }
                if let projected = arView.project(snapWorld) {
                    snapReprojectionPx = hypot(
                        Double(projected.x - viewPoint.x),
                        Double(projected.y - viewPoint.y)
                    )
                }
            }
        }

        var worldIsect: SIMD3<Float>?
        if let context {
            let sensor = CaptureFrameSurfaceMapper.sensorPoint(
                viewPoint: viewPoint,
                displayTransform: context.displayTransform,
                viewportSize: context.viewportSize,
                imageWidth: context.imageResolution.width,
                imageHeight: context.imageResolution.height
            )
            let fx = context.cameraIntrinsics.columns.0.x
            let fy = context.cameraIntrinsics.columns.1.y
            let cx = context.cameraIntrinsics.columns.2.x
            let cy = context.cameraIntrinsics.columns.2.y
            let localDirection = SIMD3<Float>(
                (sensor.x - cx) / fx,
                -(sensor.y - cy) / fy,
                -1
            )
            let t = context.cameraTransform
            let rotation = simd_float3x3(columns: (
                SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            ))
            let worldDirection = simd_normalize(rotation * localDirection)
            worldIsect = CaptureFrameSurfaceMapper
                .nearestSurfaceIntersection(
                    origin: t.position,
                    direction: worldDirection,
                    surfaces: surfaces,
                    toleranceM: 0.02
                )?.world
        }
        if let worldIsect {
            if let m = SurfaceUV4C.map(
                world: worldIsect,
                surfaces: surfaces,
                toleranceM: 0.02,
                snapMaxM: nil
            ) {
                isectUV = SIMD2(Double(m.local.x), Double(m.local.y))
            }
            if let context,
               let projected = AStarDiagnostics.projectToCaptureFrame(
                   worldIsect,
                   context: context
               ) {
                isectRoundTripPx = hypot(
                    Double(projected.x - viewPoint.x),
                    Double(projected.y - viewPoint.y)
                )
            }
        }

        return CalibrationPointResult(
            pixel: pixel,
            rawUV: rawUV,
            snapUV: snapUV,
            isectUV: isectUV,
            snapDistanceMM: snapDistanceMM,
            rawReprojectionPx: rawReprojectionPx,
            snapReprojectionPx: snapReprojectionPx,
            isectRoundTripPx: isectRoundTripPx
        )
    }

    private static func snapWorld(
        local: SIMD3<Float>,
        surface: CapturedRoom.Surface
    ) -> SIMD3<Float> {
        let world4 = surface.transform
            * SIMD4<Float>(local.x, local.y, local.z, 1)
        return SIMD3<Float>(world4.x, world4.y, world4.z)
    }

    // MARK: - 图像坐标工具

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

    private static func aspectFitRect(
        image: UIImage,
        in size: CGSize
    ) -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0,
              size.width > 0, size.height > 0 else {
            return .zero
        }
        let scale = min(
            size.width / imageSize.width,
            size.height / imageSize.height
        )
        let drawSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: (size.width - drawSize.width) * 0.5,
            y: (size.height - drawSize.height) * 0.5,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    /// 视图坐标 → 图像像素坐标（分析图坐标系，0~analysis 像素）。
    private static func imagePoint(
        _ viewPoint: CGPoint,
        imageRect: CGRect,
        image: UIImage
    ) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        let nx = (viewPoint.x - imageRect.minX) / imageRect.width
        let ny = (viewPoint.y - imageRect.minY) / imageRect.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return CGPoint(
            x: nx * image.size.width,
            y: ny * image.size.height
        )
    }

    /// 图像像素坐标 → 视图坐标。
    private static func viewPoint(
        _ pixel: CGPoint,
        imageRect: CGRect,
        image: UIImage
    ) -> CGPoint {
        guard image.size.width > 0, image.size.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: imageRect.minX + pixel.x / image.size.width * imageRect.width,
            y: imageRect.minY + pixel.y / image.size.height * imageRect.height
        )
    }
}
