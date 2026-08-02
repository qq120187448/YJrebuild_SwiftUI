import Foundation
import RoomPlan

struct QuantityTakeoffItem: Codable {
    let code: String
    let name: String
    let spec: String
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
        let plasterArea = max(0, wallArea - doorArea - windowArea - openingArea)
        let perimeter = roomPerimeter(room)

        var items: [QuantityTakeoffItem] = [
            .init(code: "010101001",
                  name: "建筑面积",
                  spec: "扫描识别的房间投影面积",
                  unit: "m²",
                  quantity: rounded(floorArea),
                  note: "由 RoomPlan 地面/墙体估算"),
            .init(code: "011101001",
                  name: "水泥砂浆楼地面",
                  spec: "按房间地面面积",
                  unit: "m²",
                  quantity: rounded(floorArea),
                  note: "约等于建筑面积"),
            .init(code: "011201001",
                  name: "墙面一般抹灰",
                  spec: "墙面面积扣除门窗洞口",
                  unit: "m²",
                  quantity: rounded(plasterArea),
                  note: "扣门/窗/开口面积，洞口侧壁不增加"),
            .init(code: "011301001",
                  name: "天棚抹灰",
                  spec: "按地面面积近似",
                  unit: "m²",
                  quantity: rounded(floorArea),
                  note: "天棚与地面投影接近"),
            .init(code: "011105001",
                  name: "踢脚线",
                  spec: "按房间净周长",
                  unit: "m",
                  quantity: rounded(perimeter),
                  note: "由地面多边形/墙体宽度估算"),
            .init(code: "010301001",
                  name: "层高",
                  spec: "最高墙面高度",
                  unit: "m",
                  quantity: rounded(ceilingHeight),
                  note: ""),
            .init(code: "010101002",
                  name: "房间体积",
                  spec: "建筑面积 × 层高",
                  unit: "m³",
                  quantity: rounded(volume),
                  note: "")
        ]

        for (index, door) in room.doors.enumerated() {
            let width = Double(door.dimensions.x)
            let height = Double(door.dimensions.y)
            let area = width * height
            items.append(.init(
                code: "010801001",
                name: "门\(index + 1)",
                spec: "宽 \(rounded(width)) m × 高 \(rounded(height)) m",
                unit: "樘",
                quantity: 1,
                note: "洞口面积 \(rounded(area)) m²"
            ))
        }
        if !room.doors.isEmpty {
            items.append(.init(
                code: "010801001",
                name: "门合计",
                spec: "含所有门",
                unit: "樘",
                quantity: Double(room.doors.count),
                note: "洞口面积合计 \(rounded(doorArea)) m²"
            ))
        }

        for (index, window) in room.windows.enumerated() {
            let width = Double(window.dimensions.x)
            let height = Double(window.dimensions.y)
            let area = width * height
            items.append(.init(
                code: "010807001",
                name: "窗\(index + 1)",
                spec: "宽 \(rounded(width)) m × 高 \(rounded(height)) m",
                unit: "扇",
                quantity: 1,
                note: "洞口面积 \(rounded(area)) m²"
            ))
        }
        if !room.windows.isEmpty {
            items.append(.init(
                code: "010807001",
                name: "窗合计",
                spec: "含所有窗",
                unit: "扇",
                quantity: Double(room.windows.count),
                note: "洞口面积合计 \(rounded(windowArea)) m²"
            ))
        }

        if !room.openings.isEmpty {
            items.append(.init(
                code: "010809001",
                name: "洞口",
                spec: "非门窗的开口",
                unit: "处",
                quantity: Double(room.openings.count),
                note: "洞口面积合计 \(rounded(openingArea)) m²"
            ))
        }

        let grouped = Dictionary(grouping: room.objects, by: { objectCategoryName($0.category) })
        for key in grouped.keys.sorted() {
            let objects = grouped[key] ?? []
            let volumeSum = objects.reduce(0.0) {
                $0 + Double($1.dimensions.x * $1.dimensions.y * $1.dimensions.z)
            }
            items.append(.init(
                code: objectCode(for: key),
                name: "\(key)合计",
                spec: "RoomPlan 识别物体",
                unit: "个",
                quantity: Double(objects.count),
                note: "总体积 \(rounded(volumeSum)) m³"
            ))
        }

        for (index, object) in room.objects.enumerated() {
            let width = Double(object.dimensions.x)
            let depth = Double(object.dimensions.y)
            let height = Double(object.dimensions.z)
            let volume = width * depth * height
            items.append(.init(
                code: objectCode(for: objectCategoryName(object.category)),
                name: "\(objectCategoryName(object.category))\(index + 1)",
                spec: "宽 \(rounded(width)) × 深 \(rounded(depth)) × 高 \(rounded(height)) m",
                unit: "个",
                quantity: 1,
                note: "体积 \(rounded(volume)) m³"
            ))
        }

        items.append(.init(
            code: "010502001",
            name: "梁体积",
            spec: "承重梁",
            unit: "m³",
            quantity: 0,
            note: "RoomPlan 暂不识别，需要点云分割")
        )
        items.append(.init(
            code: "010402001",
            name: "柱体积",
            spec: "承重柱",
            unit: "m³",
            quantity: 0,
            note: "RoomPlan 暂不识别，需要点云分割")
        )
        items.append(.init(
            code: "010505001",
            name: "板面积",
            spec: "楼板",
            unit: "m²",
            quantity: 0,
            note: "RoomPlan 暂不识别，需要点云分割")
        )

        return items
    }

    static func makeJSON(room: CapturedRoom, roomName: String) throws -> Data {
        let items = makeItems(room: room).map { item -> [String: Any] in
            [
                "清单编码": item.code,
                "项目名称": item.name,
                "项目特征": item.spec,
                "单位": item.unit,
                "工程量": item.quantity,
                "备注": item.note
            ]
        }
        let floorArea = RoomDataProcessor.estimateFloorArea(room)
        let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)
        let envelope: [String: Any] = [
            "清单名称": "房间工程量清单",
            "房间名称": roomName,
            "建筑面积": rounded(floorArea),
            "层高": rounded(ceilingHeight),
            "生成时间": ISO8601DateFormatter().string(from: Date()),
            "说明": "清单编码为参考编码，请按当地 2024 版清单/定额核对；梁板柱需点云分割。",
            "项目": items
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    static func makeCSV(room: CapturedRoom, roomName: String) -> String {
        var lines = ["清单编码,项目名称,项目特征,单位,工程量,备注"]
        for item in makeItems(room: room) {
            lines.append("\(csv(item.code)),\(csv(item.name)),\(csv(item.spec)),\(csv(item.unit)),\(item.quantity),\(csv(item.note))")
        }
        return lines.joined(separator: "\n")
    }

    static func makeExportFiles(room: CapturedRoom, roomName: String) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuantityTakeoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let xlsxURL = directory.appendingPathComponent("工程量清单.xlsx")
        let workbook = try XLSXWriter.makeWorkbook(sheetName: "工程量清单", rows: xlsxRows(room: room, roomName: roomName))
        try workbook.write(to: xlsxURL)
        return [xlsxURL]
    }

    static func xlsxRows(room: CapturedRoom, roomName: String) -> [[XLSXWriter.Cell]] {
        let floorArea = RoomDataProcessor.estimateFloorArea(room)
        let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)
        let volume = floorArea * ceilingHeight
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var rows: [[XLSXWriter.Cell]] = [
            [XLSXWriter.Cell("房间工程量清单", bold: true)],
            [XLSXWriter.Cell("房间名称"), XLSXWriter.Cell(roomName)],
            [XLSXWriter.Cell("建筑面积"), XLSXWriter.Cell(String(format: "%.2f m²", floorArea))],
            [XLSXWriter.Cell("层高"), XLSXWriter.Cell(String(format: "%.2f m", ceilingHeight))],
            [XLSXWriter.Cell("房间体积"), XLSXWriter.Cell(String(format: "%.2f m³", volume))],
            [XLSXWriter.Cell("生成时间"), XLSXWriter.Cell(formatter.string(from: Date()))],
            [XLSXWriter.Cell("")]
        ]

        rows.append([
            XLSXWriter.Cell("序号", bold: true),
            XLSXWriter.Cell("清单编码（参考）", bold: true),
            XLSXWriter.Cell("项目名称", bold: true),
            XLSXWriter.Cell("项目特征", bold: true),
            XLSXWriter.Cell("单位", bold: true),
            XLSXWriter.Cell("工程量", bold: true),
            XLSXWriter.Cell("备注", bold: true)
        ])

        for (index, item) in makeItems(room: room).enumerated() {
            rows.append([
                XLSXWriter.Cell("\(index + 1)"),
                XLSXWriter.Cell(item.code),
                XLSXWriter.Cell(item.name),
                XLSXWriter.Cell(item.spec),
                XLSXWriter.Cell(item.unit),
                XLSXWriter.Cell(formatQuantity(item.quantity)),
                XLSXWriter.Cell(item.note)
            ])
        }
        return rows
    }

    private static func formatQuantity(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    private static func roomPerimeter(_ room: CapturedRoom) -> Double {
        if let floor = room.floors.first, floor.polygonCorners.count >= 3 {
            let corners = floor.polygonCorners.map {
                RoomDataProcessor.transformCornerToWorld($0, transform: floor.transform)
            }
            var perimeter = 0.0
            for index in 0..<corners.count {
                let a = corners[index]
                let b = corners[(index + 1) % corners.count]
                let dx = Double(b.x - a.x)
                let dz = Double(b.z - a.z)
                perimeter += (dx * dx + dz * dz).squareRoot()
            }
            return perimeter
        }
        return room.walls.reduce(0.0) { $0 + Double($1.dimensions.x) }
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

    private static func objectCode(for name: String) -> String {
        switch name {
        case "洗手盆": return "031004001"
        case "坐便器": return "031004003"
        case "浴缸": return "031004006"
        case "厨房洗涤盆", "洗碗机": return "031004002"
        default: return "011501001"
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
