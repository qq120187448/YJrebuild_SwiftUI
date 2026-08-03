import Foundation
import RoomPlan
import simd

enum RoomDataProcessor {

    static let metersToFeet = 3.28084
    static let sqmToSqft = 10.7639

    // MARK: - Summary

    /// Creates an AI-friendly summary from a CapturedRoom.
    /// Includes both metric and imperial, plus computed insights.
    static func summarizeRoom(_ room: CapturedRoom) -> [String: Any] {
        let ceilingHeight = estimateCeilingHeight(room.walls)
        let floorArea = estimateFloorArea(room)
        let totalWallArea = computeTotalWallArea(room.walls)
        let volume = floorArea * ceilingHeight

        let wallData = room.walls.map { surface -> [String: Any] in
            let dims = surface.dimensions
            let w = Double(dims.x)
            let h = Double(dims.y)
            let pos = surface.transform.columns.3
            let rotDeg = rotationYDegrees(from: surface.transform)
            return [
                "width_m": r2(w),
                "height_m": r2(h),
                "width_ft": r2(w * metersToFeet),
                "height_ft": r2(h * metersToFeet),
                "area_sqm": r2(w * h),
                "area_sqft": r2(w * h * sqmToSqft),
                "center_x_ft": r2(Double(pos.x) * metersToFeet),
                "center_y_ft": r2(Double(pos.z) * metersToFeet),
                "rotation_deg": r2(rotDeg)
            ]
        }

        let doorData = room.doors.map { surface -> [String: Any] in
            let dims = surface.dimensions
            let w = Double(dims.x)
            let h = Double(dims.y)
            return [
                "width_m": r2(w), "height_m": r2(h),
                "width_ft": r2(w * metersToFeet), "height_ft": r2(h * metersToFeet)
            ]
        }

        let windowData = room.windows.map { surface -> [String: Any] in
            let dims = surface.dimensions
            let w = Double(dims.x)
            let h = Double(dims.y)
            return [
                "width_m": r2(w), "height_m": r2(h),
                "width_ft": r2(w * metersToFeet), "height_ft": r2(h * metersToFeet)
            ]
        }

        let objectData = room.objects.map { object -> [String: Any] in
            let dims = object.dimensions
            let w = Double(dims.x)
            let d = Double(dims.y)
            let h = Double(dims.z)
            let pos = object.transform.columns.3
            return [
                "category": cleanCategory(object.category),
                "width_m": r2(w), "depth_m": r2(d), "height_m": r2(h),
                "width_ft": r2(w * metersToFeet),
                "depth_ft": r2(d * metersToFeet),
                "height_ft": r2(h * metersToFeet),
                "center_x_ft": r2(Double(pos.x) * metersToFeet),
                "center_y_ft": r2(Double(pos.z) * metersToFeet)
            ]
        }

        let wallWidths = room.walls.map { Double($0.dimensions.x) }
        let longestWall = wallWidths.max() ?? 0
        let shortestWall = wallWidths.min() ?? 0

        var summary: [String: Any] = [
            "wall_count": room.walls.count,
            "door_count": room.doors.count,
            "window_count": room.windows.count,
            "object_count": room.objects.count,
            "ceiling_height_m": r2(ceilingHeight),
            "ceiling_height_ft": r2(ceilingHeight * metersToFeet),
            "estimated_floor_area_sqm": r2(floorArea),
            "estimated_floor_area_sqft": r2(floorArea * sqmToSqft),
            "total_wall_area_sqm": r2(totalWallArea),
            "total_wall_area_sqft": r2(totalWallArea * sqmToSqft),
            "volume_m3": r2(volume),
            "volume_ft3": r2(volume * metersToFeet * metersToFeet * metersToFeet),
            "longest_wall_m": r2(longestWall),
            "longest_wall_ft": r2(longestWall * metersToFeet),
            "shortest_wall_m": r2(shortestWall),
            "shortest_wall_ft": r2(shortestWall * metersToFeet),
            "room_shape": describeRoomShape(room.walls),
            "walls": wallData,
            "doors": doorData,
            "windows": windowData,
            "objects": objectData
        ]

        // Approximate room dimensions (bounding box)
        let dims = estimateRoomDimensions(room.walls)
        if let dims {
            summary["room_length_m"] = r2(dims.length)
            summary["room_width_m"] = r2(dims.width)
            summary["room_length_ft"] = r2(dims.length * metersToFeet)
            summary["room_width_ft"] = r2(dims.width * metersToFeet)
        }

        // Floor polygon in 2D world coordinates (for AI agents building floor plans)
        if let firstFloor = room.floors.first {
            let worldCorners = firstFloor.polygonCorners.map { corner -> simd_float3 in
                transformCornerToWorld(corner, transform: firstFloor.transform)
            }
            summary["floor_polygon_2d_m"] = worldCorners.map { corner in
                ["x": r2(Double(corner.x)), "y": r2(Double(corner.z))]
            }
            summary["floor_polygon_2d_ft"] = worldCorners.map { corner in
                ["x": r2(Double(corner.x) * metersToFeet), "y": r2(Double(corner.z) * metersToFeet)]
            }
        }

        return summary
    }

    // MARK: - Metrics

    /// Ceiling height derived from the tallest wall surface.
    static func estimateCeilingHeight(_ walls: [CapturedRoom.Surface]) -> Double {
        walls.map { Double($0.dimensions.y) }.max() ?? 0
    }

    /// Floor area from CapturedRoom. Prefers floor surfaces (iOS 17+),
    /// falls back to wall bounding box, then perimeter estimate.
    static func estimateFloorArea(_ room: CapturedRoom) -> Double {
        // Best: use actual floor surfaces with polygon corners
        if !room.floors.isEmpty {
            let area = room.floors.reduce(0.0) { total, floor in
                let corners = floor.polygonCorners
                if corners.count >= 3 {
                    return total + polygonArea(corners)
                }
                // Rectangular floor fallback: x=width, y=height (second planar extent), z=thickness
                let w = Double(floor.dimensions.x)
                let h = Double(floor.dimensions.y)
                let d = Double(floor.dimensions.z)
                // Use the two largest dimensions (avoids thickness axis ambiguity)
                let sorted = [w, h, d].sorted().reversed()
                let dim1 = sorted[sorted.startIndex]
                let dim2 = sorted[sorted.index(after: sorted.startIndex)]
                return total + dim1 * dim2
            }
            #if DEBUG
            print("[RoomDataProcessor] Floor area from floor surfaces: \(area) sqm (\(r2(area * sqmToSqft)) sqft)")
            #endif
            return area
        }
        // Fallback: bounding box from wall positions
        if let dims = estimateRoomDimensions(room.walls) {
            let area = dims.length * dims.width
            #if DEBUG
            print("[RoomDataProcessor] Floor area from wall bounding box: \(area) sqm (\(r2(area * sqmToSqft)) sqft)")
            #endif
            return area
        }
        // Last resort: assume square from perimeter
        let area = perimeterSquareArea(room.walls.map { Double($0.dimensions.x) })
        #if DEBUG
        print("[RoomDataProcessor] Floor area from perimeter estimate: \(area) sqm (\(r2(area * sqmToSqft)) sqft)")
        #endif
        return area
    }

    /// Shoelace formula for polygon area from 3D corner points.
    /// RoomPlan floor `polygonCorners` are in the surface's local coordinate system
    /// where the floor lies in the X-Y plane (Z is always 0), so we use X and Y.
    static func polygonArea(_ corners: [simd_float3]) -> Double {
        var area = 0.0
        for i in 0..<corners.count {
            let j = (i + 1) % corners.count
            area += Double(corners[i].x) * Double(corners[j].y)
            area -= Double(corners[j].x) * Double(corners[i].y)
        }
        return abs(area) / 2.0
    }

    /// Estimate floor area assuming a square room from wall perimeter.
    static func perimeterSquareArea(_ wallWidths: [Double]) -> Double {
        let perimeter = wallWidths.reduce(0.0, +)
        let side = perimeter / 4.0
        return side * side
    }

    /// Sum of individual wall areas (width x height).
    static func computeTotalWallArea(_ walls: [CapturedRoom.Surface]) -> Double {
        walls.reduce(0.0) { $0 + Double($1.dimensions.x) * Double($1.dimensions.y) }
    }

    /// Bounding-box room dimensions (length x width) from wall center positions.
    static func estimateRoomDimensions(_ walls: [CapturedRoom.Surface]) -> (length: Double, width: Double)? {
        guard walls.count >= 3 else { return nil }
        let positions = walls.map { (x: Double($0.transform.columns.3.x), z: Double($0.transform.columns.3.z)) }
        return boundingBoxDimensions(positions)
    }

    /// Bounding-box dimensions from a set of (x, z) positions. Testable without CapturedRoom.
    static func boundingBoxDimensions(_ positions: [(x: Double, z: Double)]) -> (length: Double, width: Double)? {
        guard positions.count >= 3 else { return nil }
        let xs = positions.map(\.x)
        let zs = positions.map(\.z)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minZ = zs.min(), let maxZ = zs.max() else { return nil }
        let dx = maxX - minX
        let dz = maxZ - minZ
        return (length: max(dx, dz), width: min(dx, dz))
    }

    /// Describe room shape based on wall count and arrangement.
    static func describeRoomShape(_ walls: [CapturedRoom.Surface]) -> String {
        switch walls.count {
        case 0...2: return "partial"
        case 3: return "triangular"
        case 4: return "rectangular"
        case 5: return "pentagonal"
        case 6: return "L-shaped or hexagonal"
        default: return "irregular (\(walls.count) walls)"
        }
    }

    // MARK: - Spatial Transforms

    /// Transform a polygon corner from surface-local to world coordinates.
    static func transformCornerToWorld(_ corner: simd_float3, transform: simd_float4x4) -> simd_float3 {
        let local = SIMD4<Float>(corner.x, corner.y, corner.z, 1.0)
        let world = transform * local
        return simd_float3(world.x, world.y, world.z)
    }

    /// Extract Y-axis rotation (yaw) in degrees from a transform matrix.
    private static func rotationYDegrees(from transform: simd_float4x4) -> Double {
        let col0 = transform.columns.0
        let angle = atan2(Double(col0.z), Double(col0.x))
        return angle * 180.0 / .pi
    }

    // MARK: - Encoding

    /// Encodes the full CapturedRoom to JSON via Codable.
    static func encodeFullRoom(_ room: CapturedRoom) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(room)
    }

    /// Decodes a CapturedRoom from JSON data.
    static func decodeFullRoom(_ data: Data) throws -> CapturedRoom {
        return try JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    /// Encodes the summary dictionary to JSON Data.
    static func encodeSummary(_ summary: [String: Any]) throws -> Data {
        return try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Helpers

    /// Round to 2 decimal places.
    private static func r2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Clean verbose RoomPlan category names to simple labels.
    private static func cleanCategory(_ category: CapturedRoom.Object.Category) -> String {
        // String(describing:) gives e.g. "table" for known categories
        let raw = String(describing: category)
        // Strip any enum-style prefix if present
        if let dot = raw.lastIndex(of: ".") {
            return String(raw[raw.index(after: dot)...])
        }
        return raw
    }
}
