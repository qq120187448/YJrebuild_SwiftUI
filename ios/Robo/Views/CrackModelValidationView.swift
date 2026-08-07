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

    private let resolutions = [640, 800, 960, 1280]

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
                Section("验证") {
                    Button {
                        startValidation()
                    } label: {
                        if isWorking {
                            HStack {
                                ProgressView()
                                Text("验证中...")
                            }
                        } else {
                            Label("开始验证 640/800/960/1280", systemImage: "checkmark.seal")
                        }
                    }
                    .disabled(isWorking)

                    if isWorking, !progressMessage.isEmpty {
                        Text(progressMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                errorMessage = nil
                progressMessage = ""
            } else {
                errorMessage = "无法读取所选照片"
            }
        }
    }

    private func startValidation() {
        guard let image else { return }
        isWorking = true
        errorMessage = nil
        progressMessage = "准备验证..."
        DispatchQueue.global(qos: .userInitiated).async {
            let output = CrackRecognitionEngine.validateResolutions(
                image: image,
                resolutions: resolutions
            ) { status, partialResults in
                DispatchQueue.main.async {
                    self.progressMessage = status
                    self.results = partialResults
                }
            }
            DispatchQueue.main.async {
                self.results = output
                self.progressMessage = "验证完成"
                self.isWorking = false
            }
        }
    }
}
