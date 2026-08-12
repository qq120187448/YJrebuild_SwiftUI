import PhotosUI
import SwiftUI
import UIKit

/// 4A 像素闭环验证界面：
/// 选照片 → crack_seg → mask（绿）/ 中心线（红）/ 采样点（蓝）叠加显示。
struct CrackPixel4AView: View {

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var detection: CrackPixelDetection?
    @State private var statusText = ""
    @State private var isRunning = false
    private let pipeline = CrackPixelPipeline()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image {
                    Image(uiImage: Self.annotated(image, detection: detection))
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ContentUnavailableView(
                        "选择一张裂缝照片",
                        systemImage: "photo",
                        description: Text("4A：只验证像素层（识别 → mask → 中心线 → 采样点）")
                    )
                }

                if let detection {
                    VStack(spacing: 4) {
                        Text(
                            "中心线 \(detection.centerline.count) 点 · 采样点 \(detection.samplePoints.count) 个 · 像素长度 \(String(format: "%.1f", detection.totalPixelLength)) px"
                        )
                        .font(.caption)
                        Text(
                            "模型 \(detection.modelName) · 推理 \(String(format: "%.2f", detection.timings["CoreML推理"] ?? 0))s · 总耗时 \(String(format: "%.2f", detection.timings["总耗时"] ?? 0))s"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.orange)

                HStack {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("选择照片", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        run()
                    } label: {
                        Label("4A 识别", systemImage: "scope")
                    }
                    .disabled(image == nil || isRunning)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("4A 像素闭环")
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let picked = UIImage(data: data) {
                        image = normalized(picked)
                        detection = nil
                        statusText = ""
                    }
                }
            }
        }
    }

    private func run() {
        guard let image else { return }
        isRunning = true
        statusText = "识别中…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try pipeline.detect(image: image)
                DispatchQueue.main.async {
                    detection = result
                    statusText = "完成"
                    isRunning = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusText = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }

    /// 统一方向，保证像素坐标与显示一致。
    private func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    // MARK: - 叠加绘制

    private static func annotated(
        _ image: UIImage,
        detection: CrackPixelDetection?
    ) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            guard let detection else { return }
            let scaleX = size.width / CGFloat(detection.width)
            let scaleY = size.height / CGFloat(detection.height)

            if let maskImage = makeMaskImage(detection) {
                maskImage.draw(in: CGRect(origin: .zero, size: size))
            }

            let path = UIBezierPath()
            for (index, point) in detection.centerline.enumerated() {
                let location = CGPoint(
                    x: CGFloat(point.x) * scaleX,
                    y: CGFloat(point.y) * scaleY
                )
                if index == 0 {
                    path.move(to: location)
                } else {
                    path.addLine(to: location)
                }
            }
            UIColor.red.setStroke()
            path.lineWidth = max(2, min(size.width, size.height) * 0.003)
            path.lineJoinStyle = .round
            path.stroke()

            UIColor.systemBlue.setFill()
            let radius = max(3, min(size.width, size.height) * 0.004)
            for point in detection.samplePoints {
                let location = CGPoint(
                    x: CGFloat(point.x) * scaleX,
                    y: CGFloat(point.y) * scaleY
                )
                let circle = UIBezierPath(
                    ovalIn: CGRect(
                        x: location.x - radius,
                        y: location.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                circle.fill()
            }
        }
    }

    private static func makeMaskImage(
        _ detection: CrackPixelDetection
    ) -> UIImage? {
        let width = detection.width
        let height = detection.height
        guard width > 0, height > 0, !detection.mask.isEmpty else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where detection.mask[y * width + x] {
                let index = (y * width + x) * 4
                pixels[index] = 0
                pixels[index + 1] = 255
                pixels[index + 2] = 0
                pixels[index + 3] = 80
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
