import Foundation
import RoomPlan

struct QuantityTakeoffItem: Codable {
    let item: String
    let unit: String
    let quantity: Double
    let note: String
}

enum QuantityTakeoffExporter {
    static func makeItems(room: CapturedRoom) -> [QuantityTakeoffItem] {
        let wallArea = room.walls.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.y)
        }
        let doorArea = room.doors.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.y)
        }
        let windowArea = room.windows.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.y)
        }
        let openingArea = room.openings.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.y)
        }
        let floorArea = RoomDataProcessor.estimateFloorArea(room)
        let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)
        let volume = floorArea * ceilingHeight

        var items: [QuantityTakeoffItem] = [
            .init(item: "房间数量", unit: "间", quantity: 1, note: "本次扫描"),
            .init(item: "地面面积", unit: "m²", quantity: rounded(floorArea), note: ""),
            .init(item: "房间体积", unit: "m³", quantity: rounded(volume), note: ""),
            .init(item: "层高", unit: "m", quantity: rounded(ceilingHeight), note: ""),
            .init(item: "墙面数量", unit: "面", quantity: Double(room.walls.count), note: ""),
            .init(item: "墙面面积", unit: "m²", quantity: rounded(wallArea), note: "未扣除门窗洞口"),
            .init(item: "门数量", unit: "樘", quantity: Double(room.doors.count), note: ""),
            .init(item: "门面积", unit: "m²", quantity: rounded(doorArea), note: ""),
            .init(item: "窗数量", unit: "扇", quantity: Double(room.windows.count), note: ""),
            .init(item: "窗面积", unit: "m²", quantity: rounded(windowArea), note: ""),
            .init(item: "开口数量", unit: "处", quantity: Double(room.openings.count), note: ""),
            .init(item: "开口面积", unit: "m²", quantity: rounded(openingArea), note: ""),
            .init(item: "地面板块数量", unit: "块", quantity: Double(room.floors.count), note: "RoomPlan 识别"),
            .init(item: "梁体积", unit: "m³", quantity: 0, note: "RoomPlan 暂不识别，需要点云分割"),
            .init(item: "柱体积", unit: "m³", quantity: 0, note: "RoomPlan 暂不识别，需要点云分割"),
            .init(item: "板面积", unit: "m²", quantity: 0, note: "RoomPlan 暂不识别，需要点云分割")
        ]

        let grouped = Dictionary(grouping: room.objects, by: { objectCategoryName($0.category) })
        for key in grouped.keys.sorted() {
            let objects = grouped[key] ?? []
            let volumeSum = objects.reduce(0.0) {
                $0 + Double($1.dimensions.x * $1.dimensions.y * $1.dimensions.z)
            }
            items.append(.init(
                item: "\(key)数量",
                unit: "个",
                quantity: Double(objects.count),
                note: "总体积 \(rounded(volumeSum)) m³"
            ))
        }
        return items
    }

    static func makeJSON(room: CapturedRoom) throws -> Data {
        let items = makeItems(room: room).map { item -> [String: Any] in
            [
                "项目": item.item,
                "单位": item.unit,
                "数量": item.quantity,
                "备注": item.note
            ]
        }
        let envelope: [String: Any] = [
            "清单名称": "房间工程量清单",
            "生成时间": ISO8601DateFormatter().string(from: Date()),
            "说明": "梁、板、柱需要点云分割后才能计算，当前为占位数据。",
            "项目": items
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    static func makeCSV(room: CapturedRoom) -> String {
        var lines = ["项目,单位,数量,备注"]
        for item in makeItems(room: room) {
            lines.append("\(csv(item.item)),\(csv(item.unit)),\(item.quantity),\(csv(item.note))")
        }
        return lines.joined(separator: "\n")
    }

    static func makeExportFiles(room: CapturedRoom) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuantityTakeoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let jsonURL = directory.appendingPathComponent("工程量清单.json")
        let csvURL = directory.appendingPathComponent("工程量清单.csv")
        try makeJSON(room: room).write(to: jsonURL)
        try Data(makeCSV(room: room).utf8).write(to: csvURL)
        return [jsonURL, csvURL]
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func objectCategoryName(_ category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: return "储物柜"
        case .refrigerator: return "冰箱"
        case .stove: return "灶台"
        case .bed: return "床"
        case .sink: return "洗手盆"
        case .washerDryer: return "洗衣机"
        case .toilet: return "坐便器"
        case .bathtub: return "浴缸"
        case .oven: return "烤箱"
        case .dishwasher: return "洗碗机"
        case .table: return "桌子"
        case .sofa: return "沙发"
        case .chair: return "椅子"
        case .fireplace: return "壁炉"
        case .television: return "电视"
        case .stairs: return "楼梯"
        @unknown default: return "其他物体"
        }
    }

    private static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
