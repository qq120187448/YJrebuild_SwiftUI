import SwiftUI
import UIKit

struct CrackRecognitionResultView: View {
    let result: CrackRecognitionResult
    let annotatedImage: UIImage?

    var body: some View {
        List {
            if let annotatedImage {
                Section("标注预览") {
                    Image(uiImage: annotatedImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Section("识别概要") {
                LabeledContent("识别结果", value: result.detectedClass)
                LabeledContent("置信度", value: String(format: "%.2f", result.confidence))
                LabeledContent("模式", value: result.mode == "hairline" ? "发丝级" : "常规")
                LabeledContent("模型", value: result.modelSize.uppercased())
                LabeledContent("骨架长度", value: String(format: "%.1f px", result.totalPixelLength))
                if let totalMMLength = result.totalMMLength {
                    LabeledContent("总长度", value: String(format: "%.1f mm", totalMMLength))
                } else {
                    LabeledContent("总长度", value: "未换算毫米")
                }
                LabeledContent("实测长度", value: String(format: "%.3f m", result.totalLengthM))
                LabeledContent("缺陷面积", value: String(format: "%.4f m²", result.totalAreaM2))
            }

            if !result.surfaceSummaries.isEmpty {
                Section("墙面/地面归属") {
                    ForEach(result.surfaceSummaries) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.label)
                                .font(.headline)
                            Text("裂缝 \(summary.componentCount) 条 · 总长 \(String(format: "%.3f m", summary.totalLengthM))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("面积 \(String(format: "%.4f m²", summary.areaM2)) · 最长 \(String(format: "%.3f m", summary.longestLengthM))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !result.components.isEmpty {
                Section("裂缝明细") {
                    ForEach(Array(result.components.enumerated()), id: \.offset) { _, component in
                        HStack {
                            Text("裂缝 \(component.id)")
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.1f px", component.pixelLength))
                                    .monospacedDigit()
                                if let lengthM = component.lengthM {
                                    Text(String(format: "%.3f m", lengthM))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let mm = component.mmLength {
                                    Text(String(format: "%.1f mm", mm))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("裂缝识别结果")
    }
}
