import PhotosUI
import SwiftUI
import UIKit

struct CrackPhotoLabView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var result: CrackRecognitionResult?
    @State private var annotatedImage: UIImage?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var recognitionProgress = ""
    @State private var timeoutWorkItem: DispatchWorkItem?
    @State private var didTimeout = false

    private var config: CrackRecognitionConfig {
        CrackRecognitionSettings.load()
    }

    var body: some View {
        List {
            Section("选择照片") {
                PhotosPicker(
                    selection: $selectedItem,
                    matching: .images
                ) {
                    Label(
                        image == nil ? "从相册选择" : "重新选择",
                        systemImage: "photo.on.rectangle"
                    )
                }
                .disabled(isWorking)
                .onChange(of: selectedItem) { _, newValue in
                    loadPhoto(from: newValue)
                }

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            if image != nil {
                Section("标尺标定") {
                    if let calibrationImage = image {
                        NavigationLink {
                            RulerCalibrationView(image: calibrationImage)
                        } label: {
                            Label("用照片中的标尺换算毫米/像素", systemImage: "ruler")
                        }
                    }
                }

                Section("识别") {
                    Button {
                        startRecognition()
                    } label: {
                        if isWorking {
                            HStack {
                                ProgressView()
                                Text("识别中...")
                            }
                        } else {
                            Label("开始识别", systemImage: "bolt.fill")
                        }
                    }
                    .disabled(isWorking)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if isWorking, !recognitionProgress.isEmpty {
                        Text(recognitionProgress)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if didTimeout {
                        Text("识别已挂起，无法取消。请退出本页后重新进入 App，避免再次触发。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let result {
                Section {
                    NavigationLink {
                        CrackRecognitionResultView(
                            result: result,
                            annotatedImage: annotatedImage
                        )
                    } label: {
                        Label("查看长度结果与标注", systemImage: "list.bullet.rectangle")
                    }
                }
            }
        }
        .navigationTitle("裂缝照片检测")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let loaded = UIImage(data: data) {
                image = loaded
                result = nil
                annotatedImage = nil
                errorMessage = nil
                recognitionProgress = ""
                didTimeout = false
                isWorking = false
                timeoutWorkItem?.cancel()
            } else {
                errorMessage = "无法读取所选照片"
            }
        }
    }

    private func startRecognition() {
        guard let image else { return }
        isWorking = true
        didTimeout = false
        errorMessage = nil
        recognitionProgress = "正在加载模型"
        timeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem {
            DispatchQueue.main.async {
                guard self.isWorking else { return }
                self.didTimeout = true
                self.errorMessage = "识别已挂起超过 30 秒，当前无法取消；请退出本页并重启 App"
            }
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 30,
            execute: timeout
        )
        let config = self.config
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try CrackRecognitionEngine.analyze(
                    image: image,
                    pose: [],
                    intrinsics: [],
                    surfaces: [],
                    config: config,
                    progress: { message, _ in
                        DispatchQueue.main.async {
                            self.recognitionProgress = message
                        }
                    }
                )
                DispatchQueue.main.async {
                    self.result = output.result
                    self.annotatedImage = output.annotatedImage
                    self.didTimeout = false
                    self.isWorking = false
                    self.recognitionProgress = ""
                    self.timeoutWorkItem?.cancel()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.didTimeout = false
                    self.isWorking = false
                    self.recognitionProgress = ""
                    self.timeoutWorkItem?.cancel()
                }
            }
        }
    }
}

struct RulerCalibrationView: View {
    let image: UIImage

    @State private var viewPoints: [CGPoint] = []
    @State private var knownLengthText = "100"
    @State private var message = ""
    @State private var imageViewSize = CGSize.zero

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let rect = fittedRect(in: geo.size)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    Canvas { context, size in
                        let drawRect = fittedRect(in: size)
                        for point in viewPoints {
                            let circle = CGRect(
                                x: point.x - 6,
                                y: point.y - 6,
                                width: 12,
                                height: 12
                            )
                            context.fill(
                                Path(ellipseIn: circle),
                                with: .color(.yellow)
                            )
                        }
                        if viewPoints.count == 2 {
                            var path = Path()
                            path.move(to: viewPoints[0])
                            path.addLine(to: viewPoints[1])
                            context.stroke(
                                path,
                                with: .color(.yellow),
                                lineWidth: 3
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard fittedRect(in: geo.size).contains(location) else {
                            return
                        }
                        if viewPoints.count >= 2 {
                            viewPoints = []
                        }
                        viewPoints.append(location)
                        message = ""
                    }
                }
                .onAppear {
                    imageViewSize = geo.size
                }
                .onChange(of: geo.size) { _, newValue in
                    imageViewSize = newValue
                }
            }
            .frame(maxHeight: 420)

            HStack {
                Text("标尺长度 (mm)")
                Spacer()
                TextField("100", text: $knownLengthText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16)

            Text(
                viewPoints.count == 2
                    ? String(
                        format: "像素长度 %.0f px",
                        pixelDistance ?? 0
                    )
                    : "在照片上点选标尺两端"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            HStack(spacing: 16) {
                Button("清除") {
                    viewPoints = []
                    message = ""
                }
                .buttonStyle(.bordered)

                Button("保存标尺") {
                    saveCalibration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewPoints.count != 2)
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("标尺标定")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pixelDistance: Double? {
        guard viewPoints.count == 2 else { return nil }
        let rect = fittedRect(in: imageViewSize)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let dx = Double(
            (viewPoints[1].x - viewPoints[0].x)
                / rect.width * image.size.width
        )
        let dy = Double(
            (viewPoints[1].y - viewPoints[0].y)
                / rect.height * image.size.height
        )
        return hypot(dx, dy)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0,
              size.width > 0, size.height > 0 else {
            return .zero
        }
        let scale = min(
            size.width / image.size.width,
            size.height / image.size.height
        )
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func saveCalibration() {
        guard let knownMM = Double(knownLengthText), knownMM > 0,
              let pixels = pixelDistance, pixels > 1 else {
            message = "请先点选标尺两端并输入有效长度"
            return
        }
        var config = CrackRecognitionSettings.load()
        config.lengthUnit = "known"
        config.mmPerPixel = knownMM / pixels
        CrackRecognitionSettings.save(config)
        message = String(
            format: "已保存：%.4f mm/px",
            knownMM / pixels
        )
    }
}
