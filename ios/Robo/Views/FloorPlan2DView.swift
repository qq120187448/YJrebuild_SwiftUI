import SwiftUI

struct FloorPlan2DView: View {
    let room: RoomScanRecord

    private struct PlanPoint {
        let x: Double
        let y: Double
    }

    var body: some View {
        Canvas { context, size in
            guard let points = planPoints(), points.count >= 3 else {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.draw(
                    Text("暂无 2D 平面数据")
                        .font(.subheadline),
                    at: center
                )
                return
            }

            let bounds = normalizedBounds(points)
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

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let areaText = "\(String(format: "%.2f", room.floorAreaSqM)) m²"
            context.draw(
                Text(room.roomName)
                    .font(.headline),
                at: CGPoint(x: center.x, y: center.y - 10)
            )
            context.draw(
                Text(areaText)
                    .font(.subheadline),
                at: CGPoint(x: center.x, y: center.y + 12)
            )

            for point in projected {
                let dot = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                context.fill(dot, with: .color(.accentColor))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 4)
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

    private func normalizedBounds(_ points: [PlanPoint]) -> (minX: Double, minY: Double, width: Double, height: Double) {
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
