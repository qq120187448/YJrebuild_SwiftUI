import SwiftUI
import RoomPlan

struct ComponentAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    let room: CapturedRoom
    @Binding var adjustments: RoomAdjustments

    private var roomLength: Double {
        adjustments.roomDimensions?.length ?? measuredLength
    }

    private var roomWidth: Double {
        adjustments.roomDimensions?.width ?? measuredWidth
    }

    private var measuredLength: Double {
        boundingBox().0
    }

    private var measuredWidth: Double {
        boundingBox().1
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("房间尺寸") {
                    LabeledContent("实测长", value: String(format: "%.2f m", measuredLength))
                    LabeledContent("实测宽", value: String(format: "%.2f m", measuredWidth))
                    HStack {
                        Text("长")
                        TextField("长 (m)", value: roomLengthBinding, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("宽")
                        TextField("宽 (m)", value: roomWidthBinding, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if !room.doors.isEmpty {
                    Section("门") {
                        componentRows(
                            components: room.doors.enumerated().map { index, door in
                                AdjustmentRowData(
                                    id: door.identifier.uuidString,
                                    label: "门\(index + 1)",
                                    width: Double(door.dimensions.x),
                                    height: Double(door.dimensions.y),
                                    depth: Double(door.dimensions.z),
                                    usesDepth: false
                                )
                            }
                        )
                    }
                }

                if !room.windows.isEmpty {
                    Section("窗") {
                        componentRows(
                            components: room.windows.enumerated().map { index, window in
                                AdjustmentRowData(
                                    id: window.identifier.uuidString,
                                    label: "窗\(index + 1)",
                                    width: Double(window.dimensions.x),
                                    height: Double(window.dimensions.y),
                                    depth: Double(window.dimensions.z),
                                    usesDepth: false
                                )
                            }
                        )
                    }
                }

                if !room.openings.isEmpty {
                    Section("洞口") {
                        componentRows(
                            components: room.openings.enumerated().map { index, opening in
                                AdjustmentRowData(
                                    id: opening.identifier.uuidString,
                                    label: "洞口\(index + 1)",
                                    width: Double(opening.dimensions.x),
                                    height: Double(opening.dimensions.y),
                                    depth: Double(opening.dimensions.z),
                                    usesDepth: false
                                )
                            }
                        )
                    }
                }

                if !room.objects.isEmpty {
                    Section("物体/家具") {
                        componentRows(
                            components: room.objects.enumerated().map { index, object in
                                AdjustmentRowData(
                                    id: object.identifier.uuidString,
                                    label: "\(QuantityTakeoffExporter.objectCategoryName(object.category))\(index + 1)",
                                    width: Double(object.dimensions.x),
                                    height: Double(object.dimensions.z),
                                    depth: Double(object.dimensions.y),
                                    usesDepth: true
                                )
                            }
                        )
                    }
                }
            }
            .navigationTitle("调整构件尺寸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func componentRows(components: [AdjustmentRowData]) -> some View {
        ForEach(components) { data in
            let existing = adjustments.components[data.id]
            let width = Binding<Double>(
                get: { existing?.width ?? data.width },
                set: { value in
                    adjustments.components[data.id, default: ComponentAdjustment(
                        componentID: data.id,
                        label: data.label
                    )].width = value > 0 ? value : nil
                }
            )
            let height = Binding<Double>(
                get: { existing?.height ?? data.height },
                set: { value in
                    adjustments.components[data.id, default: ComponentAdjustment(
                        componentID: data.id,
                        label: data.label
                    )].height = value > 0 ? value : nil
                }
            )
            let depth = Binding<Double>(
                get: { existing?.depth ?? data.depth },
                set: { value in
                    adjustments.components[data.id, default: ComponentAdjustment(
                        componentID: data.id,
                        label: data.label
                    )].depth = value > 0 ? value : nil
                }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(data.label)
                    .font(.headline)
                Text("实测 \(String(format: "%.2f", data.width)) × \(String(format: "%.2f", data.height)) × \(String(format: "%.2f", data.depth)) m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    dimensionField("宽", binding: width, usesDepth: data.usesDepth)
                    dimensionField("高", binding: height, usesDepth: data.usesDepth)
                    if data.usesDepth {
                        dimensionField("深", binding: depth, usesDepth: true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func dimensionField(
        _ name: String,
        binding: Binding<Double>,
        usesDepth: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("m", value: binding, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 70)
        }
    }

    private var roomLengthBinding: Binding<Double> {
        Binding(
            get: { roomLength },
            set: { value in
                if adjustments.roomDimensions == nil {
                    adjustments.roomDimensions = RoomDimensionOverride()
                }
                adjustments.roomDimensions?.length = value > 0 ? value : nil
            }
        )
    }

    private var roomWidthBinding: Binding<Double> {
        Binding(
            get: { roomWidth },
            set: { value in
                if adjustments.roomDimensions == nil {
                    adjustments.roomDimensions = RoomDimensionOverride()
                }
                adjustments.roomDimensions?.width = value > 0 ? value : nil
            }
        )
    }

    private func boundingBox() -> (Double, Double) {
        if let floor = room.floors.first, floor.polygonCorners.count >= 3 {
            let xs = floor.polygonCorners.map { Double($0.x) }
            let ys = floor.polygonCorners.map { Double($0.y) }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else {
                return (0, 0)
            }
            return (maxX - minX, maxY - minY)
        }
        return (0, 0)
    }
}

private struct AdjustmentRowData: Identifiable {
    let id: String
    let label: String
    let width: Double
    let height: Double
    let depth: Double
    let usesDepth: Bool
}
