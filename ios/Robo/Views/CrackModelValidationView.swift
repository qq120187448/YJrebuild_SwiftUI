import PhotosUI
import SwiftUI
import UIKit

struct CrackModelValidationView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var results: [CrackResolutionValidationResult] = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var progressMessage = ""
    @State private var nextIndex = 0
    @State private var modelStatus = "未检查"
    @State private var timeoutWorkItem: DispatchWorkItem?
    @State private var didTimeout = false

    private let resolutions = [640, 800, 960, 1280, 1600, 1920, 2240]
    private var engineConfig: CrackRecognitionConfig {
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
                .onChange(of: selectedItem) { _, newValue in
                    loadPhoto(from: newValue)
                }

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            if image != nil {
                Section("模型") {
                    Button {
                        checkModel()
                    } label: {
                        Label("检查模型", systemImage: "cpu")
                    }
                    .disabled(isWorking)

                    Text(modelStatus)
                        .font(.caption)
                        .foregroundStyle(modelStatus.contains("成功") ? .green : .orange)

                    LabeledContent(
                        "计算单元",
                        value: engineConfig.computeMode == "cpu"
                            ? "仅 CPU"
                            : "自动（CPU+神经网络）"
                    )
                    LabeledContent(
                        "推理通道",
                        value: engineConfig.inferenceBackend == "vision"
                            ? "Vision"
                            : "CoreML 直连"
                    )
                }

                Section("验证") {
                    Button {
                        startCurrentValidation()
                    } label: {
                        if isWorking {
                            HStack {
                                ProgressView()
                                Text("验证中...")
                            }
                        } else if nextIndex < resolutions.count {
                            Label(
                                "验证下一档：\(resolutions[nextIndex])",
                                systemImage: "checkmark.seal"
                            )
                        } else {
                            Label("全部档位已验证", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .disabled(isWorking || nextIndex >= resolutions.count)

                    if isWorking, !progressMessage.isEmpty {
                        Text(progressMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if didTimeout {
                        Text("推理已挂起，无法取消。请退出验证页后重新进入 App，避免再次触发。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if !results.isEmpty {
                Section("分辨率结果") {
                    ForEach(results) { result in
                        HStack(spacing: 12) {
                            if let annotatedImage = result.annotatedImage {
                                Image(uiImage: annotatedImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Image(systemName: "photo")
                                    .frame(width: 64, height: 64)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(result.resolution) × \(result.resolution)")
                                    .font(.headline)
                                if let errorMessage = result.errorMessage {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else {
                                    Text("裂缝 \(result.detectionCount) 处")
                                        .font(.subheadline)
                                    Text(
                                        String(
                                            format: "置信度 %.2f · 掩码 %d px",
                                            result.confidence,
                                            result.maskPixelCount
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("模型分辨率验证")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadPhoto(from item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let loaded = UIImage(data: data) {
                image = loaded
                results = []
                nextIndex = 0
                modelStatus = "未检查"
                errorMessage = nil
                progressMessage = ""
                didTimeout = false
            } else {
                errorMessage = "无法读取所选照片"
            }
        }
    }

    private func checkModel() {
        modelStatus = "正在检查..."
        DispatchQueue.global(qos: .userInitiated).async {
            let status = CrackRecognitionEngine.checkModelLoad()
            DispatchQueue.main.async {
                self.modelStatus = status
            }
        }
    }

    private func startCurrentValidation() {
        guard let image else { return }
        guard nextIndex < resolutions.count else { return }
        let resolution = resolutions[nextIndex]
        isWorking = true
        didTimeout = false
        errorMessage = nil
        progressMessage = "准备 \(resolution)×\(resolution)"
        timeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem {
            DispatchQueue.main.async {
                guard self.isWorking else { return }
                self.didTimeout = true
                self.progressMessage = "推理已挂起超过 30 秒，当前无法取消；请退出本页并重启 App"
            }
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 30,
            execute: timeout
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let output = CrackRecognitionEngine.validateResolutions(
                image: image,
                resolutions: [resolution]
            ) { status, partialResults in
                DispatchQueue.main.async {
                    self.progressMessage = status
                }
            }
            DispatchQueue.main.async {
                if let result = output.first {
                    self.results.append(result)
                }
                self.nextIndex += 1
                self.progressMessage = "\(resolution) 完成"
                self.didTimeout = false
                self.isWorking = false
                self.timeoutWorkItem?.cancel()
            }
        }
    }
}
