import Foundation
import RoomPlan

struct QuantityTakeoffItem: Codable {
    let code: String
    let name: String
    let spec: String
    let unit: String
    let quantity: Double
    let formula: String
    let note: String
}

enum QuantityTakeoffExporter {
    static func countItemLabels(room: CapturedRoom) -> [String] {
        var labels = room.doors.enumerated().map { "门\($0.offset + 1)" }
        labels += room.windows.enumerated().map { "窗\($0.offset + 1)" }
        labels += room.openings.enumerated().map { "洞口\($0.offset + 1)" }
        labels += room.objects.enumerated().map {
            "\(objectCategoryName($0.element.category))\($0.offset + 1)"
        }
        return labels
    }

    static func makeItems(room: CapturedRoom, roomType: String) -> [QuantityTakeoffItem] {
        let floorArea = RoomDataProcessor.estimateFloorArea(room)
        let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)
        let volume = floorArea * ceilingHeight
        let perimeter = roomPerimeter(room)

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
        let doorPerimeter = room.doors.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let windowPerimeter = room.windows.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let openingPerimeter = room.openings.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let plasterArea = max(0, wallArea - doorArea - windowArea - openingArea)

        let doorPerimeter = room.doors.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let windowPerimeter = room.windows.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let openingPerimeter = room.openings.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }

        let wallVolume = room.walls.reduce(0.0) { total, wall in
            let width = Double(wall.dimensions.x)
            let height = Double(wall.dimensions.y)
            let thickness = Double(wall.dimensions.z > 0 ? wall.dimensions.z : 0.18)
            return total + width * height * thickness
        }

        let returnHeight = (roomType.contains("卫生间") || roomType.contains("厨房")) ? 0.3 : 0.0
        let waterproofArea = floorArea + perimeter * returnHeight

        let sanitaryNames = ["洗手盆", "坐便器", "浴缸", "洗碗机", "洗衣机"]
        let sanitaryObjects = room.objects.filter {
            sanitaryNames.contains(objectCategoryName($0.category))
        }

        var items = civilItems(
            room: room,
            floorArea: floorArea,
            ceilingHeight: ceilingHeight,
            volume: volume,
            perimeter: perimeter,
            plasterArea: plasterArea,
            wallArea: wallArea,
            wallVolume: wallVolume,
            waterproofArea: waterproofArea
        )
        items += doorWindowItems(
            room: room,
            doorArea: doorArea,
            windowArea: windowArea,
            openingArea: openingArea,
            doorPerimeter: doorPerimeter,
            windowPerimeter: windowPerimeter,
            openingPerimeter: openingPerimeter
        )
        items += sanitaryItems(room: room, sanitaryObjects: sanitaryObjects)
        items += furnitureItems(room: room, sanitaryNames: sanitaryNames)
        items += structureItems()
        return items
    }

    static func makeJSON(room: CapturedRoom, roomName: String, roomType: String) throws -> Data {
        let items = makeItems(room: room, roomType: roomType).map { item -> [String: Any] in
            [
                "清单编码": item.code,
                "项目名称": item.name,
                "项目特征": item.spec,
                "单位": item.unit,
                "工程量": item.quantity,
                "计算式": item.formula,
                "备注": item.note
            ]
        }
        let floorArea = RoomDataProcessor.estimateFloorArea(room)
        let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)
        let envelope: [String: Any] = [
            "清单名称": "房间工程量清单",
            "房间名称": roomName,
            "房间类型": roomType,
            "建筑面积": rounded(floorArea),
            "层高": rounded(ceilingHeight),
            "生成时间": ISO8601DateFormatter().string(from: Date()),
            "说明": "清单编码为参考编码，请按当地 2024 版清单/定额核对；梁板柱需点云分割。",
            "项目": items
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    static func makeExportFiles(
        room: CapturedRoom,
        roomName: String,
        roomType: String,
        unitPrices: [String: Double],
        photos: [XLSXWriter.ImageAttachment]
    ) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuantityTakeoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let xlsxURL = directory.appendingPathComponent("工程量清单.xlsx")
        let workbook = try XLSXWriter.makeWorkbook(
            sheets: makeSheets(
                room: room,
                roomName: roomName,
                roomType: roomType,
                unitPrices: unitPrices,
                photos: photos
            )
        )
        try workbook.write(to: xlsxURL)
        return [xlsxURL]
    }

    static func makeSheets(
        room: CapturedRoom,
        roomName: String,
        roomType: String,
        unitPrices: [String: Double],
        photos: [XLSXWriter.ImageAttachment]
    ) -> [XLSXWriter.Sheet] {
        let floorArea = RoomDataProcessor.estimateFloorArea(room)
        let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)
        let volume = floorArea * ceilingHeight
        let perimeter = roomPerimeter(room)
        let wallArea = RoomDataProcessor.computeTotalWallArea(room.walls)
        let doorArea = room.doors.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.y)
        }
        let windowArea = room.windows.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.y)
        }
        let openingArea = room.openings.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.y)
        }
        let sanitaryNames = ["洗手盆", "坐便器", "浴缸", "洗碗机", "洗衣机"]
        let sanitaryCount = room.objects.filter {
            sanitaryNames.contains(objectCategoryName($0.category))
        }.count
        let furnitureCount = room.objects.count - sanitaryCount

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var summaryRows: [[XLSXWriter.Cell]] = [
            [XLSXWriter.Cell("房间工程量清单", bold: true)],
            [XLSXWriter.Cell("")]
        ]
        summaryRows += summaryRow("房间名称", roomName)
        summaryRows += summaryRow("房间类型", roomType)
        summaryRows += summaryRow("建筑面积", String(format: "%.2f m²", floorArea))
        summaryRows += summaryRow("层高", String(format: "%.2f m", ceilingHeight))
        summaryRows += summaryRow("房间体积", String(format: "%.2f m³", volume))
        summaryRows += summaryRow("房间周长", String(format: "%.2f m", perimeter))
        summaryRows += summaryRow("房间形状", shapeName(room))
        summaryRows += summaryRow("楼层", "\(room.story)")
        summaryRows += summaryRow("识别房间类型", sectionNames(room))
        summaryRows += summaryRow("生成时间", formatter.string(from: Date()))
        summaryRows.append([XLSXWriter.Cell("")])
        summaryRows += [
            [XLSXWriter.Cell("墙数量"), XLSXWriter.Cell("\(room.walls.count) 面")],
            [XLSXWriter.Cell("墙面面积"), XLSXWriter.Cell(String(format: "%.2f m²", wallArea))],
            [XLSXWriter.Cell("门数量"), XLSXWriter.Cell("\(room.doors.count) 樘")],
            [XLSXWriter.Cell("门面积"), XLSXWriter.Cell(String(format: "%.2f m²", doorArea))],
            [XLSXWriter.Cell("窗数量"), XLSXWriter.Cell("\(room.windows.count) 扇")],
            [XLSXWriter.Cell("窗面积"), XLSXWriter.Cell(String(format: "%.2f m²", windowArea))],
            [XLSXWriter.Cell("开口数量"), XLSXWriter.Cell("\(room.openings.count) 处")],
            [XLSXWriter.Cell("开口面积"), XLSXWriter.Cell(String(format: "%.2f m²", openingArea))],
            [XLSXWriter.Cell("物体数量"), XLSXWriter.Cell("\(room.objects.count) 个")],
            [XLSXWriter.Cell("洁具数量"), XLSXWriter.Cell("\(sanitaryCount) 个")],
            [XLSXWriter.Cell("家具数量"), XLSXWriter.Cell("\(furnitureCount) 个")]
        ]

        var sheets: [XLSXWriter.Sheet] = [
            XLSXWriter.Sheet(name: "汇总表", rows: summaryRows)
        ]
        sheets.append(itemSheet(
            title: "土建装饰",
            items: civilItems(
                room: room,
                floorArea: floorArea,
                ceilingHeight: ceilingHeight,
                volume: volume,
                perimeter: perimeter,
                plasterArea: max(0, wallArea - doorArea - windowArea - openingArea),
                wallArea: wallArea,
                wallVolume: wallVolume(room),
                waterproofArea: waterproofArea(room, roomType: roomType, floorArea: floorArea, perimeter: perimeter)
            ),
            unitPrices: unitPrices
        ))
        sheets.append(itemSheet(
            title: "门窗",
            items: doorWindowItems(
                room: room,
                doorArea: doorArea,
                windowArea: windowArea,
                openingArea: openingArea,
                doorPerimeter: doorPerimeter,
                windowPerimeter: windowPerimeter,
                openingPerimeter: openingPerimeter
            ),
            unitPrices: unitPrices
        ))

        let sanitaryObjects = room.objects.filter {
            sanitaryNames.contains(objectCategoryName($0.category))
        }
        sheets.append(itemSheet(
            title: "洁具给排水",
            items: sanitaryItems(room: room, sanitaryObjects: sanitaryObjects),
            unitPrices: unitPrices
        ))
        sheets.append(itemSheet(
            title: "家具家电",
            items: furnitureItems(room: room, sanitaryNames: sanitaryNames),
            unitPrices: unitPrices
        ))
        sheets.append(itemSheet(
            title: "待点云结构",
            items: structureItems(),
            unitPrices: unitPrices
        ))

        if !photos.isEmpty {
            var photoRows: [[XLSXWriter.Cell]] = [
                [XLSXWriter.Cell("项目", bold: true), XLSXWriter.Cell("照片", bold: true)]
            ]
            for photo in photos {
                photoRows.append([XLSXWriter.Cell(photo.label), XLSXWriter.Cell("")])
            }
            sheets.append(XLSXWriter.Sheet(name: "照片附件", rows: photoRows, images: photos))
        }

        return sheets
    }

    // MARK: - Sheet builders

    private static func itemSheet(title: String, items: [QuantityTakeoffItem], unitPrices: [String: Double]) -> XLSXWriter.Sheet {
        var rows: [[XLSXWriter.Cell]] = [
            [
                XLSXWriter.Cell("序号", bold: true),
                XLSXWriter.Cell("清单编码（参考）", bold: true),
                XLSXWriter.Cell("项目名称", bold: true),
                XLSXWriter.Cell("项目特征", bold: true),
                XLSXWriter.Cell("单位", bold: true),
                XLSXWriter.Cell("工程量", bold: true),
                XLSXWriter.Cell("计算式", bold: true),
                XLSXWriter.Cell("备注", bold: true),
                XLSXWriter.Cell("综合单价（元）", bold: true),
                XLSXWriter.Cell("合价（元）", bold: true),
                XLSXWriter.Cell("照片", bold: true)
            ]
        ]

        for (index, item) in items.enumerated() {
            let price = unitPrices[item.code] ?? unitPrices[item.name] ?? 0
            let total = item.quantity * price
            let photoLabel = photoLabel(for: item)
            rows.append([
                XLSXWriter.Cell("\(index + 1)"),
                XLSXWriter.Cell(item.code),
                XLSXWriter.Cell(item.name),
                XLSXWriter.Cell(item.spec),
                XLSXWriter.Cell(item.unit),
                XLSXWriter.Cell(formatQuantity(item.quantity)),
                XLSXWriter.Cell(item.formula),
                XLSXWriter.Cell(item.note),
                XLSXWriter.Cell(price > 0 ? String(format: "%.2f", price) : ""),
                XLSXWriter.Cell(total > 0 ? String(format: "%.2f", total) : ""),
                XLSXWriter.Cell(photoLabel)
            ])
        }
        return XLSXWriter.Sheet(name: title, rows: rows)
    }

    private static func summaryRow(_ label: String, _ value: String) -> [[XLSXWriter.Cell]] {
        [[XLSXWriter.Cell(label), XLSXWriter.Cell(value)]]
    }

    private static func photoLabel(for item: QuantityTakeoffItem) -> String {
        if item.unit == "樘" || item.unit == "扇" || item.unit == "处" || item.unit == "个" {
            if !item.name.contains("合计") && !item.name.contains("点位") {
                return item.name
            }
        }
        return ""
    }

    // MARK: - Item groups

    private static func civilItems(
        room: CapturedRoom,
        floorArea: Double,
        ceilingHeight: Double,
        volume: Double,
        perimeter: Double,
        plasterArea: Double,
        wallArea: Double,
        wallVolume: Double,
        waterproofArea: Double
    ) -> [QuantityTakeoffItem] {
        [
            item("010101001", "建筑面积", "扫描识别的房间投影面积", "m²", floorArea, "地面面积", "由 RoomPlan 估算"),
            item("011101001", "水泥砂浆楼地面", "按房间地面面积", "m²", floorArea, "地面面积", ""),
            item("011102001", "找平层", "按房间地面面积", "m²", floorArea, "地面面积", ""),
            item("011103001", "地砖/地板铺贴", "按房间地面面积", "m²", floorArea, "地面面积", "按整屋统一铺贴"),
            item("011201001", "墙面一般抹灰", "墙面面积扣除门窗洞口", "m²", plasterArea, "墙面面积-门-窗-开口", "洞口侧壁不增加"),
            item("011202001", "墙面涂料/乳胶漆", "同抹灰净面积", "m²", plasterArea, "墙面面积-门-窗-开口", ""),
            item("011301001", "天棚抹灰", "按地面投影", "m²", floorArea, "地面面积", ""),
            item("011302001", "天棚吊顶", "按地面投影", "m²", floorArea, "地面面积", ""),
            item("011303001", "天棚涂料", "按地面投影", "m²", floorArea, "地面面积", ""),
            item("011105001", "踢脚线", "按房间净周长", "m", perimeter, "地面多边形周长", ""),
            item("011501001", "顶角线/石膏线", "按房间净周长", "m", perimeter, "房间周长", ""),
            item("010301001", "层高", "最高墙面高度", "m", ceilingHeight, "max(墙高)", ""),
            item("010101002", "房间体积", "建筑面积×层高", "m³", volume, "地面面积×层高", ""),
            item("010502002", "墙体积", "墙宽×墙高×墙厚", "m³", wallVolume, "Σ(墙宽×墙高×墙厚)", "厚度取 dimensions.z，为 0 时按 0.18m 估算"),
            item("011104001", "地面防水", "地面面积+返边", "m²", waterproofArea, "地面面积+返边高度×周长", "卫生间/厨房按 0.3m 返边"),
            item("011203001", "墙裙/护墙板", "需指定高度", "m²", 0, "待用户指定高度", "")
        ]
    }

    private static func doorWindowItems(
        room: CapturedRoom,
        doorArea: Double,
        windowArea: Double,
        openingArea: Double,
        doorPerimeter: Double,
        windowPerimeter: Double,
        openingPerimeter: Double
    ) -> [QuantityTakeoffItem] {
        var items: [QuantityTakeoffItem] = []

        for (index, door) in room.doors.enumerated() {
            let width = Double(door.dimensions.x)
            let height = Double(door.dimensions.y)
            let area = width * height
            let perimeter = 2 * (width + height)
            items.append(item(
                "010801001", "门\(index + 1)",
                "宽 \(rounded(width)) m × 高 \(rounded(height)) m",
                "樘", 1, "1 樘",
                "洞口面积 \(rounded(area)) m²，周长 \(rounded(perimeter)) m"
            ))
        }
        if !room.doors.isEmpty {
            items.append(item("010801001", "门合计", "含所有门", "樘", Double(room.doors.count), "Σ门", ""))
            items.append(item("010801001", "门洞口面积合计", "门宽×门高", "m²", doorArea, "Σ(门宽×门高)", ""))
            items.append(item("010808001", "门洞口周长合计", "2×(宽+高)", "m", doorPerimeter, "Σ(2×(宽+高))", "可套门套/贴脸/过梁"))
        }

        for (index, window) in room.windows.enumerated() {
            let width = Double(window.dimensions.x)
            let height = Double(window.dimensions.y)
            let area = width * height
            let perimeter = 2 * (width + height)
            items.append(item(
                "010807001", "窗\(index + 1)",
                "宽 \(rounded(width)) m × 高 \(rounded(height)) m",
                "扇", 1, "1 扇",
                "洞口面积 \(rounded(area)) m²，周长 \(rounded(perimeter)) m"
            ))
        }
        if !room.windows.isEmpty {
            items.append(item("010807001", "窗合计", "含所有窗", "扇", Double(room.windows.count), "Σ窗", ""))
            items.append(item("010807001", "窗洞口面积合计", "窗宽×窗高", "m²", windowArea, "Σ(窗宽×窗高)", ""))
            items.append(item("010808002", "窗洞口周长合计", "2×(宽+高)", "m", windowPerimeter, "Σ(2×(宽+高))", "可套窗套/窗台板/过梁"))
        }

        if !room.openings.isEmpty {
            items.append(item("010809001", "洞口", "非门窗开口", "处", Double(room.openings.count), "Σ开口", ""))
            items.append(item("010809001", "开口面积合计", "开口宽×高", "m²", openingArea, "Σ(开口宽×高)", ""))
            items.append(item("010808003", "开口周长合计", "2×(宽+高)", "m", openingPerimeter, "Σ(2×(宽+高))", ""))
        }
        return items
    }

    private static func sanitaryItems(room: CapturedRoom, sanitaryObjects: [CapturedRoom.Object]) -> [QuantityTakeoffItem] {
        var items: [QuantityTakeoffItem] = []
        let grouped = Dictionary(grouping: sanitaryObjects, by: { objectCategoryName($0.category) })
        for key in grouped.keys.sorted() {
            let objects = grouped[key] ?? []
            items.append(item(
                objectCode(for: key), "\(key)合计",
                "RoomPlan 识别", "个", Double(objects.count), "Σ\(key)", ""
            ))
        }
        for (index, object) in sanitaryObjects.enumerated() {
            let name = objectCategoryName(object.category)
            items.append(item(
                objectCode(for: name), "\(name)\(index + 1)",
                objectSpec(object), "个", 1, "1 个",
                "体积 \(rounded(objectVolume(object))) m³"
            ))
        }
        if !sanitaryObjects.isEmpty {
            items.append(item("031004099", "给水点", "按洁具数量", "个", Double(sanitaryObjects.count), "Σ洁具", ""))
            items.append(item("031004098", "排水点", "按洁具数量", "个", Double(sanitaryObjects.count), "Σ洁具", ""))
        }
        return items
    }

    private static func furnitureItems(room: CapturedRoom, sanitaryNames: [String]) -> [QuantityTakeoffItem] {
        let furniture = room.objects.filter {
            !sanitaryNames.contains(objectCategoryName($0.category))
        }
        var items: [QuantityTakeoffItem] = []
        let grouped = Dictionary(grouping: furniture, by: { objectCategoryName($0.category) })
        for key in grouped.keys.sorted() {
            let objects = grouped[key] ?? []
            items.append(item(
                objectCode(for: key), "\(key)合计",
                "RoomPlan 识别", "个", Double(objects.count), "Σ\(key)", ""
            ))
        }
        for (index, object) in furniture.enumerated() {
            let name = objectCategoryName(object.category)
            items.append(item(
                objectCode(for: name), "\(name)\(index + 1)",
                objectSpec(object), "个", 1, "1 个",
                "体积 \(rounded(objectVolume(object))) m³"
            ))
        }
        return items
    }

    private static func structureItems() -> [QuantityTakeoffItem] {
        [
            item("010502001", "梁体积", "承重梁", "m³", 0, "待点云分割", "RoomPlan 暂不识别"),
            item("010402001", "柱体积", "承重柱", "m³", 0, "待点云分割", "RoomPlan 暂不识别"),
            item("010505001", "板面积", "楼板", "m²", 0, "待点云分割", "RoomPlan 暂不识别")
        ]
    }

    // MARK: - Metrics helpers

    private static func wallVolume(_ room: CapturedRoom) -> Double {
        room.walls.reduce(0.0) { total, wall in
            let width = Double(wall.dimensions.x)
            let height = Double(wall.dimensions.y)
            let thickness = Double(wall.dimensions.z > 0 ? wall.dimensions.z : 0.18)
            return total + width * height * thickness
        }
    }

    private static func waterproofArea(_ room: CapturedRoom, roomType: String, floorArea: Double, perimeter: Double) -> Double {
        let returnHeight = (roomType.contains("卫生间") || roomType.contains("厨房")) ? 0.3 : 0.0
        return floorArea + perimeter * returnHeight
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

    private static func shapeName(_ room: CapturedRoom) -> String {
        switch RoomDataProcessor.describeRoomShape(room.walls) {
        case "partial": return "部分扫描"
        case "triangular": return "三角形"
        case "rectangular": return "矩形"
        case "pentagonal": return "五边形"
        case "L-shaped or hexagonal": return "L形/六边形"
        default: return "不规则"
        }
    }

    private static func sectionNames(_ room: CapturedRoom) -> String {
        let names = room.sections.map { section -> String in
            switch String(describing: section.label) {
            case "livingRoom": return "客厅"
            case "kitchen": return "厨房"
            case "diningRoom": return "餐厅"
            case "bedroom": return "卧室"
            case "bathroom": return "卫生间"
            default: return "未识别"
            }
        }
        return names.isEmpty ? "未识别" : names.joined(separator: "、")
    }

    private static func objectSpec(_ object: CapturedRoom.Object) -> String {
        let width = Double(object.dimensions.x)
        let depth = Double(object.dimensions.y)
        let height = Double(object.dimensions.z)
        return "宽 \(rounded(width)) × 深 \(rounded(depth)) × 高 \(rounded(height)) m"
    }

    private static func objectVolume(_ object: CapturedRoom.Object) -> Double {
        Double(object.dimensions.x) * Double(object.dimensions.y) * Double(object.dimensions.z)
    }

    private static func item(
        _ code: String,
        _ name: String,
        _ spec: String,
        _ unit: String,
        _ quantity: Double,
        _ formula: String,
        _ note: String = ""
    ) -> QuantityTakeoffItem {
        QuantityTakeoffItem(
            code: code,
            name: name,
            spec: spec,
            unit: unit,
            quantity: quantity,
            formula: formula,
            note: note
        )
    }

    private static func formatQuantity(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
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
        case "洗碗机": return "031004002"
        case "洗衣机": return "031004004"
        default: return "011501001"
        }
    }
}
