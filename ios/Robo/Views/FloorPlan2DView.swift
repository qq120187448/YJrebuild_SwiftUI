import SwiftUI
import SwiftData
import RoomPlan
import simd

struct FloorPlan2DView: View {
    @Environment(\.modelContext) private var modelContext
    let room: RoomScanRecord

    @State private var lengthText = ""
    @State private var widthText = ""
    @State private var externalThicknessText = "0.20"
    @State private var internalThicknessText = "0.10"
    @State private var walls: [CapturedRoom.Surface] = []
    @State private var doors: [CapturedRoom.Surface] = []
    @State private var windows: [CapturedRoom.Surface] = []
    @State private var openings: [CapturedRoom.Surface] = []
    @State private var objects: [CapturedRoom.Object] = []
    @State private var selectedComponentID: String?
    @State private var selectedWidthText = ""
    @State private var selectedHeightText = ""
    @State private var selectedDepthText = ""
    @State private var selectedThicknessText = ""
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var lastPanTranslation: CGSize?

    private struct PlanPoint {
        let x: Double
        let y: Double
    }

    private var adjustments: RoomAdjustments {
        AdjustmentStorage.decode(room.adjustmentsJSON)
    }

    private var wallSettings: WallThicknessSettings {
        adjustments.wallThickness ?? WallThicknessSettings()
    }

    private var displayedPoints: [PlanPoint] {
        let points = planPoints() ?? fallbackPoints()
        guard let dimensions = adjustments.roomDimensions,
              let targetLength = dimensions.length,
              let targetWidth = dimensions.width else {
            return points
        }
        let bounds = polygonBounds(points)
        guard bounds.width > 0.01, bounds.height > 0.01 else { return points }
        let scaleX = targetLength / bounds.width
        let scaleY = targetWidth / bounds.height
        let centerX = bounds.minX + bounds.width / 2
        let centerY = bounds.minY + bounds.height / 2
        return points.map { point in
            PlanPoint(
                x: centerX + (point.x - centerX) * scaleX,
                y: centerY + (point.y - centerY) * scaleY
            )
        }
    }

    private var measuredLength: Double {
        polygonBounds(planPoints() ?? fallbackPoints()).width
    }

    private var measuredWidth: Double {
        polygonBounds(planPoints() ?? fallbackPoints()).height
    }

    private var displayLength: Double {
        adjustments.roomDimensions?.length ?? measuredLength
    }

    private var displayWidth: Double {
        adjustments.roomDimensions?.width ?? measuredWidth
    }

    private var planRotationAngle: Double {
        let points = displayedPoints
        guard points.count >= 2 else { return 0 }
        var bestAngle = 0.0
        var bestLength = -1.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            if length > bestLength {
                bestLength = length
                bestAngle = atan2(dy, dx)
            }
        }
        return -bestAngle
    }

    private var orientedPoints: [PlanPoint] {
        let points = displayedPoints
        guard !points.isEmpty else { return points }
        let bounds = polygonBounds(points)
        let centerX = bounds.minX + bounds.width / 2
        let centerY = bounds.minY + bounds.height / 2
        let angle = planRotationAngle
        let cosA = cos(angle)
        let sinA = sin(angle)
        return points.map { point in
            let dx = point.x - centerX
            let dy = point.y - centerY
            return PlanPoint(
                x: centerX + dx * cosA - dy * sinA,
                y: centerY + dx * sinA + dy * cosA
            )
        }
    }

    private var orientedBounds: (minX: Double, minY: Double, width: Double, height: Double) {
        polygonBounds(orientedPoints)
    }

    private var selectedWall: CapturedRoom.Surface? {
        walls.first { $0.identifier.uuidString == selectedComponentID }
    }

    private var selectedOpening: CapturedRoom.Surface? {
        (doors + windows + openings).first { $0.identifier.uuidString == selectedComponentID }
    }

    private var selectedObject: CapturedRoom.Object? {
        objects.first { $0.identifier.uuidString == selectedComponentID }
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                Canvas { context, size in
                    drawPlan(in: &context, size: size)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    selectComponent(at: location, size: proxy.size)
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastZoomScale
                            lastZoomScale = value
                            zoomScale = min(max(0.2, zoomScale * delta), 6.0)
                        }
                        .onEnded { _ in
                            lastZoomScale = 1.0
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if lastPanTranslation == nil {
                                lastPanTranslation = value.translation
                            }
                            let last = lastPanTranslation ?? .zero
                            panOffset.width += value.translation.width - last.width
                            panOffset.height += value.translation.height - last.height
                            lastPanTranslation = value.translation
                        }
                        .onEnded { _ in
                            lastPanTranslation = nil
                        }
                )
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
            )
            editorPanel
        }
        .onAppear {
            loadData()
        }
        .onChange(of: room.adjustmentsJSON) { _, _ in
            loadData()
        }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                dimensionEditor("长 (m)", text: $lengthText, measured: measuredLength) {
                    updateRoomDimension(length: $0, width: nil)
                }
                dimensionEditor("宽 (m)", text: $widthText, measured: measuredWidth) {
                    updateRoomDimension(length: nil, width: $0)
                }
                thicknessEditor("外墙厚", text: $externalThicknessText, value: wallSettings.external) {
                    let value = $0
                    updateWallSettings { settings in
                        settings.external = value
                    }
                }
                thicknessEditor("内墙厚", text: $internalThicknessText, value: wallSettings.internalWall) {
                    let value = $0
                    updateWallSettings { settings in
                        settings.internalWall = value
                    }
                }
            }

            if let wall = selectedWall {
                selectedComponentEditor(
                    title: "选中：墙 \(wallIndexLabel(wall))",
                    fields: [
                        ("长度", $selectedWidthText),
                        ("高度", $selectedHeightText),
                        ("厚度", $selectedThicknessText)
                    ],
                    commit: {
                        updateComponent(
                            id: wall.identifier,
                            width: Double(selectedWidthText),
                            height: Double(selectedHeightText),
                            depth: nil
                        )
                        updateWallSettings { settings in
                            if let value = Double(selectedThicknessText), value > 0.01 {
                                settings.perWall[wall.identifier.uuidString] = value
                            }
                        }
                    }
                )
            } else if let opening = selectedOpening {
                selectedComponentEditor(
                    title: "选中：\(openingLabel(opening))",
                    fields: [
                        ("宽度", $selectedWidthText),
                        ("高度", $selectedHeightText)
                    ],
                    commit: {
                        updateComponent(
                            id: opening.identifier,
                            width: Double(selectedWidthText),
                            height: Double(selectedHeightText),
                            depth: nil
                        )
                    }
                )
            } else if let object = selectedObject {
                selectedComponentEditor(
                    title: "选中：物体 \(objectLabel(object))",
                    fields: [
                        ("宽度", $selectedWidthText),
                        ("深度", $selectedDepthText),
                        ("高度", $selectedHeightText)
                    ],
                    commit: {
                        updateComponent(
                            id: object.identifier,
                            width: Double(selectedWidthText),
                            height: Double(selectedHeightText),
                            depth: Double(selectedDepthText)
                        )
                    }
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("点选构件，或从下面快速选择：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(walls, id: \.identifier) { wall in
                                quickSelectButton(
                                    label: "墙\(wallIndexLabel(wall))",
                                    id: wall.identifier.uuidString
                                )
                            }
                            ForEach(doors, id: \.identifier) { surface in
                                quickSelectButton(
                                    label: openingLabel(surface),
                                    id: surface.identifier.uuidString
                                )
                            }
                            ForEach(windows, id: \.identifier) { surface in
                                quickSelectButton(
                                    label: openingLabel(surface),
                                    id: surface.identifier.uuidString
                                )
                            }
                            ForEach(openings, id: \.identifier) { surface in
                                quickSelectButton(
                                    label: openingLabel(surface),
                                    id: surface.identifier.uuidString
                                )
                            }
                            ForEach(objects, id: \.identifier) { object in
                                quickSelectButton(
                                    label: objectLabel(object),
                                    id: object.identifier.uuidString
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func quickSelectButton(label: String, id: String) -> some View {
        Button {
            selectedComponentID = id
            populateSelectedFields()
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func selectedComponentEditor(
        title: String,
        fields: [(String, Binding<String>)],
        commit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            HStack(spacing: 10) {
                ForEach(fields.indices, id: \.self) { index in
                    TextField(fields[index].0, text: fields[index].1)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }
                Button("应用") {
                    commit()
                    selectedComponentID = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func drawPlan(in context: inout GraphicsContext, size: CGSize) {
        let points = orientedPoints
        guard points.count >= 3 else {
            context.draw(
                Text("暂无 2D 平面数据，请重新扫描").font(.subheadline),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let bounds = orientedBounds
        let project = projection(for: size)
        let projectWorld = worldProjection(for: size)

        drawGrid(in: &context, size: size)

        let projected = points.map { project($0.x, $0.y) }
        var floorPath = Path()
        floorPath.move(to: projected[0])
        for point in projected.dropFirst() {
            floorPath.addLine(to: point)
        }
        floorPath.closeSubpath()
        context.fill(floorPath, with: .color(Color(red: 0.98, green: 0.98, blue: 0.96)))
        context.stroke(floorPath, with: .color(.black), lineWidth: 1.6)

        for (index, wall) in walls.enumerated() {
            drawWall(
                wall,
                index: index,
                in: &context,
                project: projectWorld
            )
        }
        drawOpeningLines(in: &context, project: projectWorld)
        drawObjects(in: &context, project: projectWorld)

        drawDimensionLines(
            in: &context,
            size: size,
            points: points,
            project: project
        )

        let center = project(
            bounds.minX + bounds.width / 2,
            bounds.minY + bounds.height / 2
        )
        context.draw(
            Text(room.roomName).font(.headline),
            at: CGPoint(x: center.x, y: center.y - 18)
        )
        context.draw(
            Text("面积 \(String(format: "%.2f", displayLength * displayWidth)) m²")
                .font(.caption),
            at: CGPoint(x: center.x, y: center.y + 2)
        )
        context.draw(
            Text("长 \(String(format: "%.2f", displayLength)) m × 宽 \(String(format: "%.2f", displayWidth)) m")
                .font(.caption),
            at: CGPoint(x: center.x, y: center.y + 18)
        )
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let step: CGFloat = 24
        var x = step
        while x < size.width {
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)
            x += step
        }
        var y = step
        while y < size.height {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)
            y += step
        }
    }

    private func drawWall(
        _ wall: CapturedRoom.Surface,
        index: Int,
        in context: inout GraphicsContext,
        project: (Double, Double) -> CGPoint
    ) {
        let height = Double(wall.dimensions.y)
        let width = Double(wall.dimensions.x)
        guard height > 0.01, width > 0.01 else { return }
        let thickness = wallThickness(wall)
        let corners = wallCorners(wall, thickness: thickness).map {
            project(Double($0.x), Double($0.z))
        }
        var rect = Path()
        rect.move(to: corners[0])
        for corner in corners.dropFirst() {
            rect.addLine(to: corner)
        }
        rect.closeSubpath()

        let isExternal = isExternalWall(wall)
        let isSelected = selectedComponentID == wall.identifier.uuidString
        context.fill(
            rect,
            with: .color(isExternal
                ? Color(red: 0.45, green: 0.52, blue: 0.62)
                : Color(red: 0.75, green: 0.80, blue: 0.86))
        )
        context.stroke(
            rect,
            with: .color(isSelected ? Color.accentColor : .black.opacity(0.55)),
            lineWidth: isSelected ? 3 : 1
        )

        let center = CGPoint(
            x: (corners[0].x + corners[2].x) / 2,
            y: (corners[0].y + corners[2].y) / 2
        )
        context.draw(
            Text("W\(index + 1)").font(.system(size: 9, weight: .semibold)),
            at: CGPoint(x: center.x, y: center.y - 8)
        )
        context.draw(
            Text("\(String(format: "%.2f", width))m").font(.system(size: 8)),
            at: CGPoint(x: center.x, y: center.y + 8)
        )
    }

    private func drawOpeningLines(
        in context: inout GraphicsContext,
        project: (Double, Double) -> CGPoint
    ) {
        var index = 1
        for door in doors {
            drawOpening(door, symbol: "M\(index)", color: .blue, in: &context, project: project)
            index += 1
        }
        index = 1
        for window in windows {
            drawOpening(window, symbol: "C\(index)", color: .cyan, in: &context, project: project)
            index += 1
        }
        index = 1
        for opening in openings {
            drawOpening(opening, symbol: "K\(index)", color: .orange, in: &context, project: project)
            index += 1
        }
    }

    private func drawOpening(
        _ surface: CapturedRoom.Surface,
        symbol: String,
        color: Color,
        in context: inout GraphicsContext,
        project: (Double, Double) -> CGPoint
    ) {
        let width = Double(surface.dimensions.x)
        guard width > 0.01, Double(surface.dimensions.y) > 0.01 else { return }
        let transform = surface.transform
        let xAxis = SIMD3<Float>(transform.columns.0.x, 0, transform.columns.0.z)
        let length = max(simd_length(xAxis), 0.0001)
        let normalized = xAxis / length
        let center = SIMD3<Float>(
            transform.columns.3.x,
            0,
            transform.columns.3.z
        )
        let start = project(
            Double((center - normalized * Float(width / 2)).x),
            Double((center - normalized * Float(width / 2)).z)
        )
        let end = project(
            Double((center + normalized * Float(width / 2)).x),
            Double((center + normalized * Float(width / 2)).z)
        )
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(
            line,
            with: .color(selectedComponentID == surface.identifier.uuidString ? Color.accentColor : color),
            lineWidth: selectedComponentID == surface.identifier.uuidString ? 5 : 3
        )
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        context.draw(
            Text(symbol).font(.system(size: 9, weight: .bold)),
            at: CGPoint(x: mid.x, y: mid.y - 6)
        )
    }

    private func drawObjects(
        in context: inout GraphicsContext,
        project: (Double, Double) -> CGPoint
    ) {
        for object in objects {
            let width = Double(object.dimensions.x)
            let depth = Double(object.dimensions.y)
            guard width > 0.05, depth > 0.05 else { continue }
            let center = object.transform.columns.3
            let p = project(Double(center.x), Double(center.z))
            let w = max(8, min(36, width * 30))
            let h = max(8, min(36, depth * 30))
            let rect = Path(ellipseIn: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h))
            context.fill(
                rect,
                with: .color(selectedComponentID == object.identifier.uuidString
                    ? Color.accentColor.opacity(0.5)
                    : Color.green.opacity(0.35))
            )
            context.stroke(rect, with: .color(.black.opacity(0.5)), lineWidth: 0.8)
        }
    }

    private func drawDimensionLines(
        in context: inout GraphicsContext,
        size: CGSize,
        points: [PlanPoint],
        project: (Double, Double) -> CGPoint
    ) {
        let bounds = polygonBounds(points)
        let top = project(bounds.minX, bounds.minY + bounds.height)
        let bottom = project(bounds.minX, bounds.minY)
        let left = project(bounds.minX, bounds.minY + bounds.height)
        let right = project(bounds.minX + bounds.width, bounds.minY + bounds.height)

        drawDimension(
            from: left,
            to: right,
            offset: CGSize(width: 0, height: -20),
            label: String(format: "长 %.2f m", displayLength),
            in: &context
        )
        drawDimension(
            from: bottom,
            to: top,
            offset: CGSize(width: -20, height: 0),
            label: String(format: "宽 %.2f m", displayWidth),
            in: &context
        )
    }

    private func drawDimension(
        from: CGPoint,
        to: CGPoint,
        offset: CGSize,
        label: String,
        in context: inout GraphicsContext
    ) {
        let start = CGPoint(x: from.x + offset.width, y: from.y + offset.height)
        let end = CGPoint(x: to.x + offset.width, y: to.y + offset.height)
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(.black), lineWidth: 1)

        let direction = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        let length = max(hypot(direction.dx, direction.dy), 0.0001)
        let unit = CGVector(dx: direction.dx / length, dy: direction.dy / length)
        for point in [start, end] {
            var arrow = Path()
            let tip = point
            let base = CGPoint(x: tip.x - unit.dx * 10, y: tip.y - unit.dy * 10)
            let side = CGVector(dx: -unit.dy, dy: unit.dx)
            arrow.move(to: tip)
            arrow.addLine(to: CGPoint(x: base.x + side.dx * 3.5, y: base.y + side.dy * 3.5))
            arrow.addLine(to: CGPoint(x: base.x - side.dx * 3.5, y: base.y - side.dy * 3.5))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.black))
        }

        context.draw(
            Text(label).font(.system(size: 10, weight: .medium)),
            at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 12)
        )
    }

    private func selectComponent(at location: CGPoint, size: CGSize) {
        let points = displayedPoints
        guard points.count >= 3 else { return }
        let project = worldProjection(for: size)

        var best: (id: String, distance: CGFloat, kind: HitKind)?

        func consider(_ id: String, _ distance: CGFloat, _ kind: HitKind) {
            let threshold: CGFloat = kind == .opening ? 40 : 30
            guard distance <= threshold else { return }
            guard let current = best else {
                best = (id, distance, kind)
                return
            }
            let currentPriority = priority(of: current.kind)
            let newPriority = priority(of: kind)
            if newPriority > currentPriority
                || (newPriority == currentPriority && distance < current.distance) {
                best = (id, distance, kind)
            }
        }

        for wall in walls {
            let corners = wallCorners(wall, thickness: wallThickness(wall)).map {
                project(Double($0.x), Double($0.z))
            }
            for i in 0..<corners.count {
                let distance = distanceToSegment(location, corners[i], corners[(i + 1) % corners.count])
                consider(wall.identifier.uuidString, distance, .wall)
            }
        }
        for surface in doors + windows + openings {
            let width = Double(surface.dimensions.x)
            guard width > 0.01 else { continue }
            let transform = surface.transform
            let xAxis = SIMD3<Float>(transform.columns.0.x, 0, transform.columns.0.z)
            let length = max(simd_length(xAxis), 0.0001)
            let normalized = xAxis / length
            let center = SIMD3<Float>(transform.columns.3.x, 0, transform.columns.3.z)
            let start = project(
                Double((center - normalized * Float(width / 2)).x),
                Double((center - normalized * Float(width / 2)).z)
            )
            let end = project(
                Double((center + normalized * Float(width / 2)).x),
                Double((center + normalized * Float(width / 2)).z)
            )
            let distance = distanceToSegment(location, start, end)
            consider(surface.identifier.uuidString, distance, .opening)
        }
        for object in objects {
            let width = Double(object.dimensions.x)
            let depth = Double(object.dimensions.y)
            guard width > 0.05, depth > 0.05 else { continue }
            let center = object.transform.columns.3
            let p = project(Double(center.x), Double(center.z))
            let w = max(8, min(36, width * 30))
            let h = max(8, min(36, depth * 30))
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            let distance = distanceToRect(location, rect)
            consider(object.identifier.uuidString, distance, .object)
        }

        if let selected = best {
            selectedComponentID = selected.id
            populateSelectedFields()
        } else {
            selectedComponentID = nil
        }
    }

    private enum HitKind {
        case wall
        case opening
        case object
    }

    private func priority(of kind: HitKind) -> Int {
        switch kind {
        case .opening:
            return 2
        case .object:
            return 1
        case .wall:
            return 0
        }
    }

    private func distanceToRect(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func populateSelectedFields() {
        if let wall = selectedWall {
            selectedWidthText = String(format: "%.2f", Double(wall.dimensions.x))
            selectedHeightText = String(format: "%.2f", Double(wall.dimensions.y))
            selectedThicknessText = String(
                format: "%.2f",
                wallSettings.perWall[wall.identifier.uuidString]
                    ?? wallThickness(wall)
            )
        } else if let opening = selectedOpening {
            selectedWidthText = String(format: "%.2f", Double(opening.dimensions.x))
            selectedHeightText = String(format: "%.2f", Double(opening.dimensions.y))
        } else if let object = selectedObject {
            selectedWidthText = String(format: "%.2f", Double(object.dimensions.x))
            selectedDepthText = String(format: "%.2f", Double(object.dimensions.y))
            selectedHeightText = String(format: "%.2f", Double(object.dimensions.z))
        }
    }

    private func loadData() {
        lengthText = String(format: "%.2f", displayLength)
        widthText = String(format: "%.2f", displayWidth)
        externalThicknessText = String(format: "%.2f", wallSettings.external)
        internalThicknessText = String(format: "%.2f", wallSettings.internalWall)
        if let fullRoom = try? RoomDataProcessor.decodeFullRoom(room.fullRoomDataJSON) {
            walls = fullRoom.walls
            doors = fullRoom.doors
            windows = fullRoom.windows
            openings = fullRoom.openings
            objects = fullRoom.objects
        }
        populateSelectedFields()
    }

    private func wallThickness(_ wall: CapturedRoom.Surface) -> Double {
        QuantityTakeoffExporter.wallThicknessFor(wall, walls: walls, settings: wallSettings)
    }

    private func wallCorners(_ wall: CapturedRoom.Surface, thickness: Double) -> [SIMD3<Float>] {
        let width = Double(wall.dimensions.x)
        let transform = wall.transform
        let xAxis = SIMD3<Float>(transform.columns.0.x, 0, transform.columns.0.z)
        let zAxis = SIMD3<Float>(transform.columns.2.x, 0, transform.columns.2.z)
        let xLength = max(simd_length(xAxis), 0.0001)
        let zLength = max(simd_length(zAxis), 0.0001)
        let normalizedX = xAxis / xLength
        let normalizedZ = zAxis / zLength
        let center = SIMD3<Float>(transform.columns.3.x, 0, transform.columns.3.z)
        let halfW = Float(width / 2)
        let halfT = Float(thickness / 2)
        return [
            center - normalizedX * halfW - normalizedZ * halfT,
            center + normalizedX * halfW - normalizedZ * halfT,
            center + normalizedX * halfW + normalizedZ * halfT,
            center - normalizedX * halfW + normalizedZ * halfT
        ]
    }

    private func isExternalWall(_ wall: CapturedRoom.Surface) -> Bool {
        let reference = WallThicknessSettings()
        return QuantityTakeoffExporter.wallThicknessFor(wall, walls: walls, settings: reference) >= 0.15
    }

    private func wallIndexLabel(_ wall: CapturedRoom.Surface) -> Int {
        (walls.firstIndex { $0.identifier.uuidString == wall.identifier.uuidString } ?? 0) + 1
    }

    private func openingLabel(_ surface: CapturedRoom.Surface) -> String {
        if let index = doors.firstIndex(where: { $0.identifier.uuidString == surface.identifier.uuidString }) {
            return "门\(index + 1)"
        }
        if let index = windows.firstIndex(where: { $0.identifier.uuidString == surface.identifier.uuidString }) {
            return "窗\(index + 1)"
        }
        if let index = openings.firstIndex(where: { $0.identifier.uuidString == surface.identifier.uuidString }) {
            return "洞口\(index + 1)"
        }
        return "构件"
    }

    private func objectLabel(_ object: CapturedRoom.Object) -> String {
        let index = (objects.firstIndex { $0.identifier.uuidString == object.identifier.uuidString } ?? 0) + 1
        return "\(QuantityTakeoffExporter.objectCategoryName(object.category))\(index)"
    }

    private func updateComponent(id: UUID, width: Double?, height: Double?, depth: Double?) {
        var newAdjustments = adjustments
        newAdjustments.components[id.uuidString] = ComponentAdjustment(
            componentID: id.uuidString,
            label: selectedComponentID ?? "",
            width: width,
            height: height,
            depth: depth
        )
        room.adjustmentsJSON = AdjustmentStorage.encode(newAdjustments)
        try? modelContext.save()
    }

    private func updateRoomDimension(length: Double?, width: Double?) {
        var newAdjustments = adjustments
        if newAdjustments.roomDimensions == nil {
            newAdjustments.roomDimensions = RoomDimensionOverride()
        }
        if let length {
            newAdjustments.roomDimensions?.length = length
        }
        if let width {
            newAdjustments.roomDimensions?.width = width
        }
        room.adjustmentsJSON = AdjustmentStorage.encode(newAdjustments)
        try? modelContext.save()
    }

    private func updateWallSettings(_ mutate: (inout WallThicknessSettings) -> Void) {
        var settings = wallSettings
        mutate(&settings)
        var newAdjustments = adjustments
        newAdjustments.wallThickness = settings
        room.adjustmentsJSON = AdjustmentStorage.encode(newAdjustments)
        try? modelContext.save()
    }

    private func dimensionEditor(
        _ title: String,
        text: Binding<String>,
        measured: Double,
        commit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let value = Double(text.wrappedValue), value > 0.01 {
                        commit(value)
                    } else {
                        text.wrappedValue = String(format: "%.2f", measured)
                    }
                }
        }
    }

    private func thicknessEditor(
        _ title: String,
        text: Binding<String>,
        value: Double,
        commit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let parsed = Double(text.wrappedValue), parsed > 0.01 {
                        commit(parsed)
                    } else {
                        text.wrappedValue = String(format: "%.2f", value)
                    }
                }
        }
    }

    private func planPoints() -> [PlanPoint]? {
        guard let summary = try? JSONSerialization.jsonObject(with: room.summaryJSON) as? [String: Any],
              let polygon = summary["floor_polygon_2d_m"] as? [[String: Any]] else {
            return nil
        }
        let points = polygon.compactMap { dict -> PlanPoint? in
            guard let x = dict["x"] as? Double, let y = dict["y"] as? Double else { return nil }
            return PlanPoint(x: x, y: y)
        }
        return points.count >= 3 ? points : nil
    }

    private func fallbackPoints() -> [PlanPoint] {
        guard !walls.isEmpty else { return [] }
        let positions = walls.map {
            (x: Double($0.transform.columns.3.x), z: Double($0.transform.columns.3.z))
        }
        guard let minX = positions.map(\.x).min(),
              let maxX = positions.map(\.x).max(),
              let minZ = positions.map(\.z).min(),
              let maxZ = positions.map(\.z).max() else { return [] }
        let margin = 0.3
        return [
            PlanPoint(x: minX - margin, y: minZ - margin),
            PlanPoint(x: maxX + margin, y: minZ - margin),
            PlanPoint(x: maxX + margin, y: maxZ + margin),
            PlanPoint(x: minX - margin, y: maxZ + margin)
        ]
    }

    private func polygonBounds(_ points: [PlanPoint]) -> (minX: Double, minY: Double, width: Double, height: Double) {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return (
            minX: minX,
            minY: minY,
            width: (xs.max() ?? 0) - minX,
            height: (ys.max() ?? 0) - minY
        )
    }

    private func projection(for size: CGSize) -> (Double, Double) -> CGPoint {
        let bounds = orientedBounds
        let padding = 46.0
        let baseScale = min(
            (size.width - padding * 2) / max(bounds.width, 0.01),
            (size.height - padding * 2) / max(bounds.height, 0.01)
        )
        let scale = baseScale * max(0.2, min(6.0, Double(zoomScale)))
        let centerX = bounds.minX + bounds.width / 2
        let centerY = bounds.minY + bounds.height / 2
        let offsetX = Double(panOffset.width)
        let offsetY = Double(panOffset.height)
        return { x, y in
            CGPoint(
                x: size.width / 2 + CGFloat(offsetX + (x - centerX) * scale),
                y: size.height / 2 + CGFloat(offsetY - (y - centerY) * scale)
            )
        }
    }

    private func worldProjection(for size: CGSize) -> (Double, Double) -> CGPoint {
        let points = displayedPoints
        let bounds = polygonBounds(points)
        let centerX = bounds.minX + bounds.width / 2
        let centerY = bounds.minY + bounds.height / 2
        let angle = planRotationAngle
        let cosA = cos(angle)
        let sinA = sin(angle)
        let project = projection(for: size)
        return { x, z in
            let dx = x - centerX
            let dy = z - centerY
            let rotatedX = centerX + dx * cosA - dy * sinA
            let rotatedZ = centerY + dx * sinA + dy * cosA
            return project(rotatedX, rotatedZ)
        }
    }

    private func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSq))
        let closest = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}
