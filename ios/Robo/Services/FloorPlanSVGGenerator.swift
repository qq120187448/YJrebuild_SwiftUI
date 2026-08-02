import Foundation

enum FloorPlanSVGGenerator {

    /// Generates a 2D SVG floor plan from room summary data.
    /// Returns nil if no floor polygon is available.
    static func generateSVG(from summary: [String: Any], roomName: String) -> String? {
        guard let polygonPoints = summary["floor_polygon_2d_ft"] as? [[String: Double]],
              polygonPoints.count >= 3 else {
            return nil
        }

        let points = polygonPoints.compactMap { dict -> (x: Double, y: Double)? in
            guard let x = dict["x"], let y = dict["y"] else { return nil }
            return (x: x, y: y)
        }
        guard points.count >= 3 else { return nil }

        // Bounding box
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let roomW = maxX - minX
        let roomH = maxY - minY

        // SVG sizing: fit room into ~800px wide, with padding for labels
        let padding = 80.0
        let scale = min(700.0 / max(roomW, 0.1), 700.0 / max(roomH, 0.1))
        let svgW = roomW * scale + padding * 2
        let svgH = roomH * scale + padding * 2

        func tx(_ x: Double) -> Double { (x - minX) * scale + padding }
        func ty(_ y: Double) -> Double { (y - minY) * scale + padding }

        var svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(r1(svgW)) \(r1(svgH))" width="\(r1(svgW))" height="\(r1(svgH))">
        <style>
          .wall { fill: #f0f4f8; stroke: #1a365d; stroke-width: 2.5; stroke-linejoin: round; }
          .dim { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 13px; fill: #2d3748; text-anchor: middle; }
          .room-name { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 18px; font-weight: 600; fill: #1a365d; text-anchor: middle; }
          .area { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 14px; fill: #4a5568; text-anchor: middle; }
        </style>

        """

        // Draw floor polygon
        let pathPoints = points.enumerated().map { i, p in
            "\(i == 0 ? "M" : "L")\(r1(tx(p.x))),\(r1(ty(p.y)))"
        }.joined(separator: " ")
        svg += "  <path class=\"wall\" d=\"\(pathPoints) Z\"/>\n"

        // Wall dimension labels on each edge
        for i in 0..<points.count {
            let j = (i + 1) % points.count
            let p1 = points[i], p2 = points[j]
            let length = sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
            guard length > 0.3 else { continue } // skip tiny edges

            let midX = (tx(p1.x) + tx(p2.x)) / 2
            let midY = (ty(p1.y) + ty(p2.y)) / 2

            // Offset label outward from the polygon center
            let cx = points.reduce(0.0) { $0 + $1.x } / Double(points.count)
            let cy = points.reduce(0.0) { $0 + $1.y } / Double(points.count)
            let edgeMidRealX = (p1.x + p2.x) / 2
            let edgeMidRealY = (p1.y + p2.y) / 2
            let dx = edgeMidRealX - cx
            let dy = edgeMidRealY - cy
            let dist = sqrt(dx * dx + dy * dy)
            let offset = 18.0
            let ox = dist > 0.01 ? dx / dist * offset : 0
            let oy = dist > 0.01 ? dy / dist * offset : 0

            let label = formatFeetInches(length)
            svg += "  <text class=\"dim\" x=\"\(r1(midX + ox))\" y=\"\(r1(midY + oy))\">\(label)</text>\n"
        }

        // Room name and area in center
        let centroidX = points.reduce(0.0) { $0 + tx($1.x) } / Double(points.count)
        let centroidY = points.reduce(0.0) { $0 + ty($1.y) } / Double(points.count)

        let displayName = roomName.isEmpty ? "Room" : roomName
        svg += "  <text class=\"room-name\" x=\"\(r1(centroidX))\" y=\"\(r1(centroidY - 10))\">\(escapeXML(displayName))</text>\n"

        if let areaSqft = summary["estimated_floor_area_sqft"] as? Double, areaSqft > 0 {
            svg += "  <text class=\"area\" x=\"\(r1(centroidX))\" y=\"\(r1(centroidY + 12))\">\(r1(areaSqft)) sq ft</text>\n"
        }

        svg += "</svg>\n"
        return svg
    }

    // MARK: - Helpers

    private static func formatFeetInches(_ feet: Double) -> String {
        let wholeFeet = Int(feet)
        let inches = Int((feet - Double(wholeFeet)) * 12.0 + 0.5)
        if inches == 0 || inches == 12 {
            return "\(inches == 12 ? wholeFeet + 1 : wholeFeet)\u{2032}"
        }
        return "\(wholeFeet)\u{2032}\(inches)\u{2033}"
    }

    private static func r1(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
