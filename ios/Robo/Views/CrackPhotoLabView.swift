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
            } else {
                errorMessage = "无法读取所选照片"
            }
        }
    }

    private func startRecognition() {
        guard let image else { return }
        isWorking = true
        errorMessage = nil
        let config = self.config
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try CrackRecognitionEngine.analyze(
                    image: image,
                    pose: [],
                    intrinsics: [],
                    surfaces: [],
                    config: config
                )
                DispatchQueue.main.async {
                    self.result = output.result
                    self.annotatedImage = output.annotatedImage
                    self.isWorking = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isWorking = false
                }
            }
        }
    }
}
