import SwiftUI

struct CrackRecognitionSettingsView: View {
    @State private var config = CrackRecognitionSettings.load()

    var body: some View {
        Form {
            Section("识别模式") {
                Picker("YOLO 模型", selection: $config.modelSize) {
                    Text("n").tag("n")
                    Text("s").tag("s")
                }
                .pickerStyle(.segmented)

                Picker("分割引擎", selection: $config.engine) {
                    Text("YOLO 分割").tag("yolo")
                    Text("MobileSAM").tag("mobilesam")
                }
                .pickerStyle(.segmented)
                if config.engine == "mobilesam" {
                    Text("MobileSAM CoreML 尚未内置，暂用 YOLO 分割")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("CoreML 引擎") {
                Picker("计算单元", selection: $config.computeMode) {
                    Text("自动（CPU+神经网络）").tag("neural")
                    Text("仅 CPU").tag("cpu")
                }
                .pickerStyle(.segmented)

                Picker("推理通道", selection: $config.inferenceBackend) {
                    Text("CoreML 直连").tag("direct")
                    Text("Vision A/B").tag("vision")
                }
                .pickerStyle(.segmented)

                Text("已启用 MLE5 兼容开关，iOS 17+ 生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("参数") {
                Button("恢复默认参数") {
                    config = .defaultConfig
                    CrackRecognitionSettings.save(config)
                }
                .foregroundStyle(.orange)
            }

            Section("检测参数") {
                sliderRow(
                    title: "检测置信度",
                    value: $config.confidence,
                    range: 0.1...0.9,
                    step: 0.05,
                    format: "%.2f"
                )
                Text("置信度越高误报越少，但会漏掉细小裂缝；越低越容易识别，但误报增加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                sliderRow(
                    title: "IoU",
                    value: $config.iou,
                    range: 0.1...0.9,
                    step: 0.05,
                    format: "%.2f"
                )
                Text("IoU 越大越容易保留重叠框；越小越倾向合并相近候选框。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                stepperRow(
                    title: "候选框上限",
                    value: $config.maxDetections,
                    range: 1...10,
                    step: 1
                )
                Text("候选框越多识别越全，但掩码生成更慢。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                stepperRow(
                    title: "发丝级分块尺寸",
                    value: $config.tileSize,
                    range: 512...1600,
                    step: 64
                )
                stepperRow(
                    title: "发丝级分块重叠",
                    value: $config.tileOverlap,
                    range: 64...512,
                    step: 16
                )
                stepperRow(
                    title: "最小掩码面积",
                    value: $config.minMaskArea,
                    range: 10...500,
                    step: 10
                )
            }

            Section("骨架统计") {
                Picker("骨架统计模式", selection: $config.skeletonMode) {
                    Text("全部").tag("all")
                    Text("主裂缝").tag("main")
                }
                .pickerStyle(.segmented)

                stepperRow(
                    title: "保留主裂缝数量",
                    value: $config.topCracks,
                    range: 1...5,
                    step: 1
                )
                stepperRow(
                    title: "短分支修剪长度",
                    value: $config.minSpurLength,
                    range: 10...200,
                    step: 10
                )
                stepperRow(
                    title: "最短骨架保留长度",
                    value: $config.minSkeletonLength,
                    range: 20...500,
                    step: 20
                )
            }

            Section("补拍输出") {
                stepperRow(
                    title: "方形裁剪分辨率",
                    value: $config.captureResolution,
                    range: 512...2048,
                    step: 128
                )
                sliderRow(
                    title: "AR 投影宽度",
                    value: $config.arLineWidth,
                    range: 0.1...5,
                    step: 0.1,
                    format: "%.1f"
                )
                Text("补拍时按该分辨率输出方形照片送模型识别。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("跨照片去重") {
                Stepper(
                    "去重距离：\(Int(config.dedupDistanceMM)) mm",
                    value: $config.dedupDistanceMM,
                    in: 1...100,
                    step: 1
                )
                Text("同一面墙上，裂缝 3D 位置相距小于该距离时视为重复拍摄，不重复计入工程量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("物理长度") {
                Stepper(
                    "最小有效裂缝长度：\(Int(config.minPhysicalLengthMM)) mm",
                    value: $config.minPhysicalLengthMM,
                    in: 1...100,
                    step: 1
                )
                Text("补拍时骨架投影到墙面后，短于该长度的裂缝不计入工程量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("识别设置")
        .onChange(of: config) { _, newValue in
            CrackRecognitionSettings.save(newValue)
        }
        .onDisappear {
            CrackRecognitionSettings.save(config)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func stepperRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        Stepper(
            "\(title)：\(value.wrappedValue)",
            value: value,
            in: range,
            step: step
        )
    }
}
