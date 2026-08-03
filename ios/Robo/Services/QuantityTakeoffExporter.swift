import Foundation
import RoomPlan
import UIKit

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

    static func componentLabels(room: CapturedRoom) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for (index, door) in room.doors.enumerated() {
            map[door.identifier] = "门\(index + 1)"
        }
        for (index, window) in room.windows.enumerated() {
            map[window.identifier] = "窗\(index + 1)"
        }
        for (index, opening) in room.openings.enumerated() {
            map[opening.identifier] = "洞口\(index + 1)"
        }
        for (index, object) in room.objects.enumerated() {
            map[object.identifier] = "\(objectCategoryName(object.category))\(index + 1)"
        }
        return map
    }

    static func componentIDByLabel(room: CapturedRoom) -> [String: UUID] {
        var map: [String: UUID] = [:]
        for (index, door) in room.doors.enumerated() {
            map["门\(index + 1)"] = door.identifier
        }
        for (index, window) in room.windows.enumerated() {
            map["窗\(index + 1)"] = window.identifier
        }
        for (index, opening) in room.openings.enumerated() {
            map["洞口\(index + 1)"] = opening.identifier
        }
        for (index, object) in room.objects.enumerated() {
            map["\(objectCategoryName(object.category))\(index + 1)"] = object.identifier
        }
        return map
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
        capturedAt: Date,
        unitPrices: [String: Double],
        photos: [XLSXWriter.ImageAttachment]
    ) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuantityTakeoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let xlsxURL = directory.appendingPathComponent("工程量清单.xlsx")
        let labelMap = componentLabels(room: room)
        var mappedPhotos = photos.compactMap { photo -> XLSXWriter.ImageAttachment? in
            var label = photo.label
            if let idString = photo.componentID,
               let id = UUID(uuidString: idString),
               let mapped = labelMap[id] {
                label = mapped
            }
            guard let image = UIImage(data: photo.data) else { return nil }
            let resized = ImageResizer.resized(image, maxDimension: 512)
            guard let resizedData = resized.jpegData(compressionQuality: 0.8) else { return nil }
            return XLSXWriter.ImageAttachment(
                label: label,
                data: resizedData,
                fileExtension: "jpg",
                componentID: photo.componentID
            )
        }
        mappedPhotos = deduplicatePhotos(mappedPhotos)
        let (_, mainItemRows) = makeMainSheet(
            room: room,
            roomName: roomName,
            roomType: roomType,
            capturedAt: capturedAt,
            unitPrices: [:],
            photoLinks: [:],
            componentIDsByLabel: componentIDByLabel(room: room)
        )
        let (photoSheet, photoLinks) = makePhotoSheet(
            photos: mappedPhotos,
            mainItemRows: mainItemRows
        )
        let (mainSheet, _) = makeMainSheet(
            room: room,
            roomName: roomName,
            roomType: roomType,
            capturedAt: capturedAt,
            unitPrices: unitPrices,
            photoLinks: photoLinks,
            componentIDsByLabel: componentIDByLabel(room: room)
        )
        let workbook = try XLSXWriter.makeWorkbook(
            sheets: [
                mainSheet,
                photoSheet
            ]
        )
        try workbook.write(to: xlsxURL)
        return [xlsxURL]
    }

    private static func deduplicatePhotos(
        _ photos: [XLSXWriter.ImageAttachment]
    ) -> [XLSXWriter.ImageAttachment] {
        var seenComponentIDs = Set<String>()
        var seenLabels = Set<String>()
        return photos.reversed().filter { photo in
            var duplicate = false
            if let componentID = photo.componentID {
                duplicate = seenComponentIDs.contains(componentID)
                seenComponentIDs.insert(componentID)
            }
            if !duplicate {
                duplicate = seenLabels.contains(photo.label)
                seenLabels.insert(photo.label)
            }
            return !duplicate
        }.reversed()
    }

    static func makeMainSheet(
        room: CapturedRoom,
        roomName: String,
        roomType: String,
        capturedAt: Date,
        unitPrices: [String: Double],
        photoLinks: [String: String],
        componentIDsByLabel: [String: UUID]
    ) -> (XLSXWriter.Sheet, [String: Int]) {
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
        let doorPerimeter = room.doors.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let windowPerimeter = room.windows.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let openingPerimeter = room.openings.reduce(0.0) {
            $0 + 2 * (Double($1.dimensions.x) + Double($1.dimensions.y))
        }
        let sanitaryNames = ["洗手盆", "坐便器", "浴缸", "洗碗机", "洗衣机"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let summaryText = [
            "房间名称：\(roomName)",
            "扫描时间：\(formatter.string(from: capturedAt))",
            "类型：\(roomType)",
            "建筑面积：\(String(format: "%.2f", floorArea)) m²",
            "层高：\(String(format: "%.2f", ceilingHeight)) m",
            "体积：\(String(format: "%.2f", volume)) m³",
            "周长：\(String(format: "%.2f", perimeter)) m",
            "形状：\(shapeName(room))",
            "识别类型：\(sectionNames(room))"
        ].joined(separator: "；")

        var rows: [[XLSXWriter.Cell]] = [
            [XLSXWriter.Cell("房间工程量清单", bold: true)],
            [XLSXWriter.Cell("房间概要", bold: true), XLSXWriter.Cell(summaryText)],
            [XLSXWriter.Cell("")]
        ]

        let summaryRowHeight = max(
            30,
            Double(summaryText.count / 70 + 1) * 16
        )

        let groups: [(title: String, items: [QuantityTakeoffItem])] = [
            (
                "一、土建装饰",
                civilItems(
                    room: room,
                    floorArea: floorArea,
                    ceilingHeight: ceilingHeight,
                    volume: volume,
                    perimeter: perimeter,
                    plasterArea: max(0, wallArea - doorArea - windowArea - openingArea),
                    wallArea: wallArea,
                    wallVolume: wallVolume(room),
                    waterproofArea: waterproofArea(room, roomType: roomType, floorArea: floorArea, perimeter: perimeter)
                )
            ),
            (
                "二、门窗",
                doorWindowItems(
                    room: room,
                    doorArea: doorArea,
                    windowArea: windowArea,
                    openingArea: openingArea,
                    doorPerimeter: doorPerimeter,
                    windowPerimeter: windowPerimeter,
                    openingPerimeter: openingPerimeter
                )
            ),
            (
                "三、洁具给排水",
                sanitaryItems(
                    room: room,
                    sanitaryObjects: room.objects.filter {
                        sanitaryNames.contains(objectCategoryName($0.category))
                    }
                )
            ),
            (
                "四、家具家电",
                furnitureItems(room: room, sanitaryNames: sanitaryNames)
            ),
            (
                "五、待点云结构",
                structureItems()
            )
        ]

        var totalPrice = 0.0
        var itemRows: [String: Int] = [:]
        for group in groups {
            rows.append([XLSXWriter.Cell(group.title, section: true)])
            rows.append(itemHeaderRow())
            for (index, item) in group.items.enumerated() {
                let price = unitPrices[item.code] ?? unitPrices[item.name] ?? 0
                totalPrice += item.quantity * price
                itemRows[item.name] = rows.count + 1
                rows.append(itemRow(
                    index: index,
                    item: item,
                    unitPrices: unitPrices,
                    photoLinks: photoLinks,
                    componentIDsByLabel: componentIDsByLabel
                ))
            }
            rows.append([XLSXWriter.Cell("")])
        }
        rows.append([
            XLSXWriter.Cell("清单合计（元）", bold: true),
            XLSXWriter.Cell(String(format: "%.2f", totalPrice), bold: true)
        ])

        let columnWidths: [Double] = [6, 12, 18, 32, 6, 10, 24, 18, 12, 12, 10]
        let sheet = XLSXWriter.Sheet(
            name: "工程量清单",
            rows: rows,
            columnWidths: columnWidths,
            rowHeights: [2: summaryRowHeight]
        )
        return (sheet, itemRows)
    }

    // MARK: - Row builders

    private static func itemHeaderRow() -> [XLSXWriter.Cell] {
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
    }

    private static func itemRow(
        index: Int,
        item: QuantityTakeoffItem,
        unitPrices: [String: Double],
        photoLinks: [String: String],
        componentIDsByLabel: [String: UUID]
    ) -> [XLSXWriter.Cell] {
        let price = unitPrices[item.code] ?? unitPrices[item.name] ?? 0
        let total = item.quantity * price
        let photoName = photoLabel(for: item)
        let photoCell: XLSXWriter.Cell
        let componentID = componentIDsByLabel[photoName]
        let linkLocation = componentID.flatMap { photoLinks[$0.uuidString] } ?? photoLinks[photoName]
        if !photoName.isEmpty, let location = linkLocation {
            photoCell = XLSXWriter.Cell("查看照片", hyperlink: location)
        } else {
            photoCell = XLSXWriter.Cell("")
        }
        return [
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
            photoCell
        ]
    }

    private static func makePhotoSheet(
        photos: [XLSXWriter.ImageAttachment],
        mainItemRows: [String: Int] = [:]
    ) -> (XLSXWriter.Sheet, [String: String]) {
        var rows: [[XLSXWriter.Cell]] = [
            [XLSXWriter.Cell("项目", bold: true), XLSXWriter.Cell("实拍照片", bold: true)]
        ]
        var images: [XLSXWriter.ImageAttachment] = []
        var rowHeights: [Int: Double] = [:]
        var photoLinks: [String: String] = [:]

        for photo in photos {
            let labelRow = rows.count + 1
            rows.append([XLSXWriter.Cell(photo.label, bold: true)])
            rows.append([XLSXWriter.Cell("")])
            let photoRow = labelRow + 1
            rowHeights[labelRow] = 22

            let (displayWidth, displayHeight) = displaySize(for: photo.data)
            rowHeights[photoRow] = max(40, displayHeight * 0.75 + 5)

            images.append(XLSXWriter.ImageAttachment(
                label: photo.label,
                data: photo.data,
                fileExtension: photo.fileExtension,
                componentID: photo.componentID,
                anchorRow: photoRow,
                displayWidth: displayWidth,
                displayHeight: displayHeight,
                hyperlink: mainItemRows[photo.label].map { "#工程量清单!A\($0)" }
            ))
            let location = "'构件照片'!A\(labelRow)"
            photoLinks[photo.label] = location
            if let componentID = photo.componentID {
                photoLinks[componentID] = location
            }
        }

        let sheet = XLSXWriter.Sheet(
            name: "构件照片",
            rows: rows,
            images: images,
            columnWidths: [18, 32],
            rowHeights: rowHeights
        )
        return (sheet, photoLinks)
    }

    private static func displaySize(for data: Data) -> (width: Double, height: Double) {
        guard let image = UIImage(data: data) else { return (240, 180) }
        let width = Double(image.size.width)
        let height = Double(image.size.height)
        guard width > 0, height > 0 else { return (240, 180) }
        let maxWidth = 320.0
        let maxHeight = 300.0
        let scale = min(maxWidth / width, maxHeight / height, 1.0)
        return (max(80, width * scale), max(60, height * scale))
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

    static func objectCategoryName(_ category: CapturedRoom.Object.Category) -> String {
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
