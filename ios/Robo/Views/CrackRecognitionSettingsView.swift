import SwiftUI

struct CrackRecognitionSettingsView: View {
    @State private var config = CrackRecognitionSettings.load()

    var body: some View {
        Form {
            Section("识别模式") {
                Picker("识别模式", selection: $config.mode) {
                    Text("常规").tag("normal")
                    Text("发丝级").tag("hairline")
                }
                .pickerStyle(.segmented)

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

            Section("检测参数") {
                sliderRow(
                    title: "检测置信度",
                    value: $config.confidence,
                    range: 0.1...0.9,
                    step: 0.05,
                    format: "%.2f"
                )
                sliderRow(
                    title: "IoU",
                    value: $config.iou,
                    range: 0.1...0.9,
                    step: 0.05,
                    format: "%.2f"
                )
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

            Section("长度单位") {
                Picker("长度单位", selection: $config.lengthUnit) {
                    Text("像素").tag("pixel")
                    Text("已知毫米").tag("known")
                }
                .pickerStyle(.segmented)

                if config.lengthUnit == "known" {
                    HStack {
                        Text("每像素毫米数")
                        Spacer()
                        TextField(
                            "0",
                            value: $config.mmPerPixel,
                            format: .number
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    }
                }
            }
        }
        .navigationTitle("识别设置")
        .onChange(of: config) { _, newValue in
            CrackRecognitionSettings.save(newValue)
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
