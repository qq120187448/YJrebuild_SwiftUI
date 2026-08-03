import SwiftUI
import SwiftData
import RoomPlan

struct FloorPlan2DView: View {
    @Environment(\.modelContext) private var modelContext
    let room: RoomScanRecord

    @State private var lengthText = ""
    @State private var widthText = ""
    @State private var externalThicknessText = "0.20"
    @State private var internalThicknessText = "0.10"
    @State private var walls: [CapturedRoom.Surface] = []

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
        let points = planPoints() ?? []
        guard let dimensions = adjustments.roomDimensions,
              let targetLength = dimensions.length,
              let targetWidth = dimensions.width else {
            return points
        }
        guard let bounds = polygonBounds(points), bounds.width > 0.01, bounds.height > 0.01 else {
            return points
        }
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
        let points = planPoints() ?? []
        return polygonBounds(points).width
    }

    private var measuredWidth: Double {
        let points = planPoints() ?? []
        return polygonBounds(points).height
    }

    private var displayLength: Double {
        adjustments.roomDimensions?.length ?? measuredLength
    }

    private var displayWidth: Double {
        adjustments.roomDimensions?.width ?? measuredWidth
    }

    var body: some View {
        VStack(spacing: 10) {
            Canvas { context, size in
                let points = displayedPoints
                guard points.count >= 3 else {
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    context.draw(
                        Text("暂无 2D 平面数据").font(.subheadline),
                        at: center
                    )
                    return
                }

                let bounds = polygonBounds(points)
                let scale = min(
                    (size.width - 40) / max(bounds.width, 0.01),
                    (size.height - 40) / max(bounds.height, 0.01)
                )

                func project(_ point: PlanPoint) -> CGPoint {
                    CGPoint(
                        x: 20 + (point.x - bounds.minX) * scale,
                        y: 20 + (bounds.minY + bounds.height - point.y) * scale
                    )
                }

                let projected = points.map(project)
                var path = Path()
                path.move(to: projected[0])
                for point in projected.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()

                context.fill(path, with: .color(Color(red: 0.93, green: 0.96, blue: 1.0)))
                context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)

                drawWalls(in: &context, size: size, points: points)

                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.draw(
                    Text(room.roomName).font(.headline),
                    at: CGPoint(x: center.x, y: center.y - 14)
                )
                context.draw(
                    Text(String(format: "长 %.2f m · 宽 %.2f m", displayLength, displayWidth))
                        .font(.caption),
                    at: CGPoint(x: center.x, y: center.y + 8)
                )

                for point in projected {
                    let dot = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(.accentColor))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                dimensionEditor(
                    title: "长 (m)",
                    text: $lengthText,
                    measured: measuredLength
                ) { value in
                    updateRoomDimension(length: value, width: nil)
                }
                dimensionEditor(
                    title: "宽 (m)",
                    text: $widthText,
                    measured: measuredWidth
                ) { value in
                    updateRoomDimension(length: nil, width: value)
                }
            }

            HStack(spacing: 12) {
                thicknessEditor(
                    title: "外墙厚 (m)",
                    text: $externalThicknessText,
                    value: wallSettings.external
                ) { value in
                    updateWallSettings { settings in
                        settings.external = value
                    }
                }
                thicknessEditor(
                    title: "内墙厚 (m)",
                    text: $internalThicknessText,
                    value: wallSettings.internalWall
                ) { value in
                    updateWallSettings { settings in
                        settings.internalWall = value
                    }
                }
            }

            if !walls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("单墙厚度（可单独修改）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(walls.enumerated()), id: \.element.identifier) { index, wall in
                        let thickness = wallSettings.perWall[wall.identifier.uuidString]
                            ?? QuantityTakeoffExporter.wallThicknessFor(
                                wall,
                                walls: walls,
                                settings: wallSettings
                            )
                        HStack {
                            Text("墙\(index + 1)（\(wallSettings.perWall[wall.identifier.uuidString] == nil ? (isExternalWall(wall) ? "外墙" : "内墙") : "自定义")）")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f m", thickness))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("厚度", value: Binding(
                                get: { thickness },
                                set: { value in
                                    updateWallSettings { settings in
                                        settings.perWall[wall.identifier.uuidString] = value > 0 ? value : nil
                                    }
                                }
                            ), format: .number)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                        }
                    }
                }
            }
        }
        .onAppear {
            lengthText = String(format: "%.2f", displayLength)
            widthText = String(format: "%.2f", displayWidth)
            externalThicknessText = String(format: "%.2f", wallSettings.external)
            internalThicknessText = String(format: "%.2f", wallSettings.internalWall)
            walls = (try? RoomDataProcessor.decodeFullRoom(room.fullRoomDataJSON).walls) ?? []
        }
        .onChange(of: room.adjustmentsJSON) { _, _ in
            lengthText = String(format: "%.2f", displayLength)
            widthText = String(format: "%.2f", displayWidth)
            externalThicknessText = String(format: "%.2f", wallSettings.external)
            internalThicknessText = String(format: "%.2f", wallSettings.internalWall)
        }
    }

    private func drawWalls(
        in context: inout GraphicsContext,
        size: CGSize,
        points: [PlanPoint]
    ) {
        guard points.count >= 3, !walls.isEmpty else { return }
        let bounds = polygonBounds(points)
        let scale = min(
            (size.width - 40) / max(bounds.width, 0.01),
            (size.height - 40) / max(bounds.height, 0.01)
        )
        func project(_ point: SIMD3<Float>) -> CGPoint {
            CGPoint(
                x: 20 + (Double(point.x) - bounds.minX) * scale,
                y: 20 + (bounds.minY + bounds.height - Double(point.z)) * scale
            )
        }

        for wall in walls {
            let height = Double(wall.dimensions.y)
            let width = Double(wall.dimensions.x)
            guard height > 0.01, width > 0.01 else { continue }
            let thickness = QuantityTakeoffExporter.wallThicknessFor(
                wall,
                walls: walls,
                settings: wallSettings
            )
            let transform = wall.transform
            let xAxis = SIMD3<Float>(transform.columns.0.x, 0, transform.columns.0.z)
            let zAxis = SIMD3<Float>(transform.columns.2.x, 0, transform.columns.2.z)
            let normalizedX = simd_normalize(xAxis)
            let normalizedZ = simd_normalize(zAxis)
            let center = SIMD3<Float>(
                transform.columns.3.x,
                0,
                transform.columns.3.z
            )
            let halfW = Float(width / 2)
            let halfT = Float(thickness / 2)
            let corners = [
                center - normalizedX * halfW - normalizedZ * halfT,
                center + normalizedX * halfW - normalizedZ * halfT,
                center + normalizedX * halfW + normalizedZ * halfT,
                center - normalizedX * halfW + normalizedZ * halfT
            ].map(project)

            var rect = Path()
            rect.move(to: corners[0])
            for corner in corners.dropFirst() {
                rect.addLine(to: corner)
            }
            rect.closeSubpath()

            let isExternal = isExternalWall(wall)
            context.fill(
                rect,
                with: .color(isExternal
                    ? Color(red: 0.55, green: 0.62, blue: 0.72)
                    : Color(red: 0.82, green: 0.86, blue: 0.92))
            )
            context.stroke(
                rect,
                with: .color(.primary.opacity(0.45)),
                lineWidth: 0.8
            )
        }
    }

    private func isExternalWall(_ wall: CapturedRoom.Surface) -> Bool {
        let reference = WallThicknessSettings()
        return QuantityTakeoffExporter.wallThicknessFor(wall, walls: walls, settings: reference) >= 0.15
    }

    private func dimensionEditor(
        title: String,
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
        title: String,
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

    private func updateWallSettings(_ mutate: (inout WallThicknessSettings) -> Void) {
        var settings = wallSettings
        mutate(&settings)
        var newAdjustments = adjustments
        newAdjustments.wallThickness = settings
        room.adjustmentsJSON = AdjustmentStorage.encode(newAdjustments)
        try? modelContext.save()
    }

    private func updateRoomDimension(length: Double?, width: Double?) {
        var adjustments = self.adjustments
        if adjustments.roomDimensions == nil {
            adjustments.roomDimensions = RoomDimensionOverride()
        }
        if let length {
            adjustments.roomDimensions?.length = length
        }
        if let width {
            adjustments.roomDimensions?.width = width
        }
        room.adjustmentsJSON = AdjustmentStorage.encode(adjustments)
        try? modelContext.save()
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
}
