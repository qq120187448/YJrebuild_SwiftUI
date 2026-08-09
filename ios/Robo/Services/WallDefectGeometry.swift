import Foundation
import RoomPlan
import simd

enum WallDefectGeometry {

    static func surfaces(from room: CapturedRoom) -> [WallDefectSurface] {
        var result: [WallDefectSurface] = []
        for (index, wall) in room.walls.enumerated() {
            result.append(
                makePlaneSurface(
                    id: wall.identifier,
                    kind: .wall,
                    label: "墙 \(index + 1)",
                    transform: wall.transform,
                    width: Double(wall.dimensions.x),
                    height: Double(wall.dimensions.y)
                )
            )
        }
        for (index, floor) in room.floors.enumerated() {
            let area = floorArea(floor)
            result.append(
                makeFloorSurface(
                    id: floor.identifier,
                    index: index,
                    transform: floor.transform,
                    dimensions: floor.dimensions,
                    area: area
                )
            )
        }
        let ceilingHeight = RoomDataProcessor.estimateCeilingHeight(room.walls)
        if ceilingHeight > 0.3 {
            for (index, floor) in room.floors.enumerated() {
                result.append(
                    makeCeilingSurface(
                        id: UUID(),
                        index: index,
                        floor: floor,
                        ceilingHeight: ceilingHeight
                    )
                )
            }
        }
        return result
    }

    static func planeOrigin(for surface: WallDefectSurface) -> SIMD3<Double> {
        guard surface.origin.count == 3 else { return .zero }
        return SIMD3<Double>(
            surface.origin[0],
            surface.origin[1],
            surface.origin[2]
        )
    }

    static func planeUAxis(for surface: WallDefectSurface) -> SIMD3<Double> {
        guard surface.uAxis.count == 3 else { return .zero }
        return SIMD3<Double>(
            surface.uAxis[0],
            surface.uAxis[1],
            surface.uAxis[2]
        )
    }

    static func planeVAxis(for surface: WallDefectSurface) -> SIMD3<Double> {
        guard surface.vAxis.count == 3 else { return .zero }
        return SIMD3<Double>(
            surface.vAxis[0],
            surface.vAxis[1],
            surface.vAxis[2]
        )
    }

    static func planeNormal(for surface: WallDefectSurface) -> SIMD3<Double> {
        guard surface.normal.count == 3 else { return .zero }
        return SIMD3<Double>(
            surface.normal[0],
            surface.normal[1],
            surface.normal[2]
        )
    }

    /// Converts a world-space point to the surface UV plane.
    /// Returns (u, v) in meters, or nil when the point is behind the plane.
    static func uvPoint(
        worldPoint: SIMD3<Float>,
        surface: WallDefectSurface
    ) -> SIMD2<Double>? {
        let point = SIMD3<Double>(
            Double(worldPoint.x),
            Double(worldPoint.y),
            Double(worldPoint.z)
        )
        let origin = planeOrigin(for: surface)
        let uAxis = planeUAxis(for: surface)
        let vAxis = planeVAxis(for: surface)
        let normal = planeNormal(for: surface)

        let toPoint = point - origin
        let signedDistance = simd_dot(toPoint, normal)
        guard abs(signedDistance) < 0.5 else { return nil }

        let u = simd_dot(toPoint, uAxis) / max(simd_length(uAxis), 0.0001)
        let v = simd_dot(toPoint, vAxis) / max(simd_length(vAxis), 0.0001)
        guard u >= -0.02, v >= -0.02,
              u <= surface.width + 0.02,
              v <= surface.height + 0.02 else {
            return nil
        }
        return SIMD2<Double>(u, v)
    }

    private static func makePlaneSurface(
        id: UUID,
        kind: WallDefectSurfaceKind,
        label: String,
        transform: simd_float4x4,
        width: Double,
        height: Double
    ) -> WallDefectSurface {
        let center = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let uDir = simd_normalize(SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        ))
        let vDir = simd_normalize(SIMD3<Float>(
            transform.columns.1.x,
            transform.columns.1.y,
            transform.columns.1.z
        ))
        let normalDir = simd_cross(uDir, vDir)

        let origin = center - uDir * Float(width / 2) - vDir * Float(height / 2)
        let uVec = uDir * Float(width)
        let vVec = vDir * Float(height)

        return WallDefectSurface(
            id: id,
            kind: kind,
            label: label,
            width: width,
            height: height,
            area: width * height,
            origin: double3(origin),
            uAxis: double3(uVec),
            vAxis: double3(vVec),
            normal: double3(normalDir)
        )
    }

    private static func makeFloorSurface(
        id: UUID,
        index: Int,
        transform: simd_float4x4,
        dimensions: simd_float3,
        area: Double
    ) -> WallDefectSurface {
        let center = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let uDir = simd_normalize(SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        ))
        let vDir = simd_normalize(SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        ))
        let normalDir = SIMD3<Float>(0, 1, 0)
        let width = Double(dimensions.x)
        let depth = Double(dimensions.z)

        let origin = center - uDir * Float(width / 2) - vDir * Float(depth / 2)
        let uVec = uDir * Float(width)
        let vVec = vDir * Float(depth)

        return WallDefectSurface(
            id: id,
            kind: .floor,
            label: "地面 \(index + 1)",
            width: width,
            height: depth,
            area: area > 0.001 ? area : width * depth,
            origin: double3(origin),
            uAxis: double3(uVec),
            vAxis: double3(vVec),
            normal: double3(normalDir)
        )
    }

    private static func makeCeilingSurface(
        id: UUID,
        index: Int,
        floor: CapturedRoom.Surface,
        ceilingHeight: Double
    ) -> WallDefectSurface {
        let center = SIMD3<Float>(
            floor.transform.columns.3.x,
            floor.transform.columns.3.y,
            floor.transform.columns.3.z
        )
        let uDir = simd_normalize(SIMD3<Float>(
            floor.transform.columns.0.x,
            floor.transform.columns.0.y,
            floor.transform.columns.0.z
        ))
        let vDir = simd_normalize(SIMD3<Float>(
            floor.transform.columns.2.x,
            floor.transform.columns.2.y,
            floor.transform.columns.2.z
        ))
        let up = SIMD3<Float>(0, 1, 0)
        let width = Double(floor.dimensions.x)
        let depth = Double(floor.dimensions.z)
        let elevated = center + up * Float(ceilingHeight)
        let origin = elevated - uDir * Float(width / 2) - vDir * Float(depth / 2)
        let uVec = uDir * Float(width)
        let vVec = vDir * Float(depth)

        return WallDefectSurface(
            id: id,
            kind: .ceiling,
            label: "天面 \(index + 1)",
            width: width,
            height: depth,
            area: width * depth,
            origin: double3(origin),
            uAxis: double3(uVec),
            vAxis: double3(vVec),
            normal: double3(-up)
        )
    }

    private static func floorArea(_ floor: CapturedRoom.Surface) -> Double {
        let corners = floor.polygonCorners
        guard corners.count >= 3 else { return 0 }
        var area = 0.0
        for i in 0..<corners.count {
            let j = (i + 1) % corners.count
            area += Double(corners[i].x) * Double(corners[j].y)
            area -= Double(corners[j].x) * Double(corners[i].y)
        }
        return abs(area) / 2.0
    }

    private static func double3(_ value: SIMD3<Float>) -> [Double] {
        [Double(value.x), Double(value.y), Double(value.z)]
    }
}
