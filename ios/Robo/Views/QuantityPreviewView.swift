import SwiftUI
import RoomPlan

struct QuantityPreviewView: View {
    let room: CapturedRoom?
    let roomName: String
    let roomType: String
    let adjustments: RoomAdjustments

    private var items: [QuantityTakeoffItem] {
        guard let room else { return [] }
        return QuantityTakeoffExporter.makeItems(room: room, roomType: roomType, adjustments: adjustments)
    }

    private var floorArea: Double {
        guard let room else { return 0 }
        return QuantityTakeoffExporter.adjustedFloorArea(room, adjustments: adjustments)
    }

    private var ceilingHeight: Double {
        guard let room else { return 0 }
        return QuantityTakeoffExporter.adjustedCeilingHeight(room, adjustments: adjustments)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if room == nil {
                        LabeledContent("房间数据", value: "无法读取，请重新扫描")
                    }
                    LabeledContent("房间", value: roomName)
                    LabeledContent("类型", value: roomType)
                    LabeledContent("建筑面积", value: String(format: "%.2f m²", floorArea))
                    LabeledContent("层高", value: String(format: "%.2f m", ceilingHeight))
                    LabeledContent("清单项数", value: "\(items.count)")
                }

                ForEach(groupedItems, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items, id: \.name) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.name)
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(formatQuantity(item.quantity)) \(item.unit)")
                                        .font(.subheadline.monospacedDigit())
                                }
                                Text(item.spec.isEmpty ? item.formula : "\(item.spec)｜\(item.formula)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("工程量清单预览")
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

    @Environment(\.dismiss) private var dismiss

    private var groupedItems: [(title: String, items: [QuantityTakeoffItem])] {
        let all = items
        let civilNames = Set(all.filter {
            $0.name.contains("墙") || $0.name.contains("地面") || $0.name.contains("天棚")
                || $0.name.contains("抹灰") || $0.name.contains("体积") || $0.name.contains("防水")
                || $0.name.contains("踢脚") || $0.name.contains("顶角") || $0.name.contains("层高")
                || $0.name.contains("建筑面积")
        }.map(\.name))
        let doorWindowNames = Set(all.filter {
            $0.name.contains("门") || $0.name.contains("窗") || $0.name.contains("洞口")
        }.map(\.name))
        let sanitaryNames = Set(all.filter {
            $0.name.contains("洗手盆") || $0.name.contains("坐便器") || $0.name.contains("浴缸")
                || $0.name.contains("洗碗机") || $0.name.contains("洗衣机")
                || $0.name.contains("给水") || $0.name.contains("排水")
        }.map(\.name))
        let structureNames = Set(all.filter {
            $0.name.contains("梁") || $0.name.contains("柱") || $0.name.contains("板")
        }.map(\.name))
        let civil = all.filter { civilNames.contains($0.name) }
        let doorWindow = all.filter { doorWindowNames.contains($0.name) }
        let sanitary = all.filter { sanitaryNames.contains($0.name) }
        let structure = all.filter { structureNames.contains($0.name) }
        let taken = civilNames.union(doorWindowNames).union(sanitaryNames).union(structureNames)
        let furniture = all.filter { !taken.contains($0.name) }
        return [
            ("土建装饰", civil),
            ("门窗洞口", doorWindow),
            ("洁具给排水", sanitary),
            ("家具家电", furniture),
            ("结构（待点云）", structure)
        ].filter { !$0.items.isEmpty }
    }

    private func formatQuantity(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
