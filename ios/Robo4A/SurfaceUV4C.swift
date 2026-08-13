import Foundation
import RoomPlan
import simd

/// 4C：ARWorld → RoomPlan Surface → Surface-local → UV（米）。
/// 只做“数据适配 + 坐标包装”：直接使用 CapturedRoom.Surface 的
/// identifier / transform / dimensions，不实现任何自研 3D 几何引擎。
enum SurfaceUV4C {

    struct MappedPoint {
        let source: CrackPoint
        let world: SIMD3<Float>?
        let surfaceID: UUID?
        let category: CapturedRoom.Surface.Category?
        let u: Double?
        let v: Double?
        let localZ: Double?
        let status: String
    }

    struct PolylineUV {
        let index: Int
        let sampleCount: Int
        let worldHitCount: Int
        let assignedCount: Int
        let surfaceID: UUID?
        let category: CapturedRoom.Surface.Category?
        let points: [MappedPoint]
        let uvPoints: [(u: Double, v: Double)]

        var assignedRatio: Double {
            worldHitCount == 0 ? 0 : Double(assignedCount) / Double(worldHitCount)
        }
    }

    struct Report {
        let scenario: String
        let surfaceTotal: Int
        let surfaceWalls: Int
        let surfaceFloors: Int
        let surfaceOthers: Int
        let polylines: [PolylineUV]
        let totalSamples: Int
        let totalAssigned: Int
        let totalWorldHits: Int
        let captureToRaycastDelayMs: Double?
        let diagnostics: [String]

        var assignedRatio: Double {
            totalWorldHits == 0 ? 0 : Double(totalAssigned) / Double(totalWorldHits)
        }

        func text() -> String {
            var lines: [String] = []
            lines.append("4C Surface UV 报告")
            lines.append("场景：\(scenario)")
            if let delay = captureToRaycastDelayMs {
                lines.append(String(format: "Capture→Raycast 延迟：%.0f ms", delay))
            }
            lines.append(
                "表面：总数 \(surfaceTotal)（wall \(surfaceWalls) · floor \(surfaceFloors) · other \(surfaceOthers)）"
            )
            for polyline in polylines {
                lines.append("裂缝 \(polyline.index + 1)：")
                lines.append(
                    String(
                        format: "  采样点 %d | world 命中 %d | 分配表面 %d | 分配率 %.1f%%",
                        polyline.sampleCount,
                        polyline.worldHitCount,
                        polyline.assignedCount,
                        polyline.assignedRatio * 100
                    )
                )
                if let id = polyline.surfaceID {
                    lines.append(
                        "  surfaceID：\(id.uuidString)（\(categoryName(polyline.category))）"
                    )
                    let us = polyline.uvPoints.map { $0.u }
                    let vs = polyline.uvPoints.map { $0.v }
                    if let uMin = us.min(), let uMax = us.max(),
                       let vMin = vs.min(), let vMax = vs.max() {
                        lines.append(
                            String(
                                format: "  UV(米)：u ∈ [%.3f, %.3f] · v ∈ [%.3f, %.3f]（表面中心原点）",
                                uMin, uMax, vMin, vMax
                            )
                        )
                    }
                } else {
                    lines.append("  surfaceID：无（未分配到表面）")
                }
                let unassigned = polyline.points.filter { $0.status == "noSurface" }.count
                if unassigned > 0 {
                    lines.append("  未分配：\(unassigned)（noSurface）")
                }
            }
            lines.append(
                String(
                    format: "总计：采样 %d | world 命中 %d | 分配 %d | 分配率 %.1f%%",
                    totalSamples,
                    totalWorldHits,
                    totalAssigned,
                    assignedRatio * 100
                )
            )
            if !diagnostics.isEmpty {
                lines.append("未分配诊断（最近表面）：")
                lines.append(contentsOf: diagnostics)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// World 点 → Surface-local 坐标（直接使用 surface.transform 的逆矩阵）。
    static func surfaceLocal(
        _ world: SIMD3<Float>,
        surface: CapturedRoom.Surface
    ) -> SIMD3<Float> {
        let v = surface.transform.inverse
            * SIMD4<Float>(world.x, world.y, world.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    /// 在 surface 集合中查找包含该 world 点的表面（含容差），取最贴近表面平面的那个。
    /// 注意：2cm 只是“哪个 Surface 接收该点”的关联分类阈值，不代表 UV 测量精度。
    static func map(
        world: SIMD3<Float>,
        surfaces: [CapturedRoom.Surface],
        toleranceM: Float = 0.02
    ) -> (surface: CapturedRoom.Surface, local: SIMD3<Float>)? {
        var bestSurface: CapturedRoom.Surface?
        var bestLocal: SIMD3<Float>?
        var bestAbsZ = Float.greatestFiniteMagnitude
        for surface in surfaces {
            let local = surfaceLocal(world, surface: surface)
            let halfX = surface.dimensions.x * 0.5 + toleranceM
            let halfY = surface.dimensions.y * 0.5 + toleranceM
            let halfZ = surface.dimensions.z * 0.5 + toleranceM
            guard abs(local.x) <= halfX,
                  abs(local.y) <= halfY,
                  abs(local.z) <= halfZ else {
                continue
            }
            if abs(local.z) < bestAbsZ {
                bestAbsZ = abs(local.z)
                bestSurface = surface
                bestLocal = local
            }
        }
        guard let bestSurface, let bestLocal else { return nil }
        return (bestSurface, bestLocal)
    }

    static func buildReport(
        scenario: String,
        raycast: Raycast4BReport,
        room: CapturedRoom
    ) -> Report {
        let surfaces =
            room.walls + room.floors + room.doors + room.windows + room.openings
        var polylines: [PolylineUV] = []
        var totalSamples = 0
        var totalAssigned = 0
        var totalWorldHits = 0
        var diagnostics: [String] = []

        for polyline in raycast.polylines {
            var points: [MappedPoint] = []
            var assignedCount = 0
            var counts: [UUID: Int] = [:]
            var uvPoints: [(u: Double, v: Double)] = []

            for (pointIndex, point) in polyline.points.enumerated() {
                totalSamples += 1
                guard let world = point.world else {
                    points.append(
                        MappedPoint(
                            source: point.source,
                            world: nil,
                            surfaceID: nil,
                            category: nil,
                            u: nil,
                            v: nil,
                            localZ: nil,
                            status: "miss"
                        )
                    )
                    continue
                }
                totalWorldHits += 1
                if let mapped = map(world: world, surfaces: surfaces) {
                    assignedCount += 1
                    totalAssigned += 1
                    counts[mapped.surface.identifier, default: 0] += 1
                    let u = Double(mapped.local.x)
                    let v = Double(mapped.local.y)
                    uvPoints.append((u, v))
                    points.append(
                        MappedPoint(
                            source: point.source,
                            world: world,
                            surfaceID: mapped.surface.identifier,
                            category: mapped.surface.category,
                            u: u,
                            v: v,
                            localZ: Double(mapped.local.z),
                            status: "assigned"
                        )
                    )
                } else {
                    if diagnostics.count < 3 {
                        var bestSurface: CapturedRoom.Surface?
                        var bestLocal = SIMD3<Float>(0, 0, 0)
                        var bestZ = Float.greatestFiniteMagnitude
                        for surface in surfaces {
                            let local = surfaceLocal(world, surface: surface)
                            if abs(local.z) < bestZ {
                                bestZ = abs(local.z)
                                bestSurface = surface
                                bestLocal = local
                            }
                        }
                        if let bestSurface {
                            let shortID = bestSurface.identifier.uuidString.prefix(8)
                            diagnostics.append(
                                String(
                                    format: "[裂缝%d·点%d] 最近 %@ %@ local=(%.3f, %.3f, %.3f) dims=(%.2f, %.2f, %.2f)",
                                    polyline.index + 1,
                                    pointIndex + 1,
                                    categoryName(bestSurface.category),
                                    String(shortID),
                                    bestLocal.x,
                                    bestLocal.y,
                                    bestLocal.z,
                                    bestSurface.dimensions.x,
                                    bestSurface.dimensions.y,
                                    bestSurface.dimensions.z
                                )
                            )
                        }
                    }
                    points.append(
                        MappedPoint(
                            source: point.source,
                            world: world,
                            surfaceID: nil,
                            category: nil,
                            u: nil,
                            v: nil,
                            localZ: nil,
                            status: "noSurface"
                        )
                    )
                }
            }

            let dominantID = counts.max { $0.value < $1.value }?.key
            let category = surfaces
                .first { $0.identifier == dominantID }?
                .category
            polylines.append(
                PolylineUV(
                    index: polyline.index,
                    sampleCount: polyline.sampleCount,
                    worldHitCount: polyline.hitCount,
                    assignedCount: assignedCount,
                    surfaceID: dominantID,
                    category: category,
                    points: points,
                    uvPoints: uvPoints
                )
            )
        }

        return Report(
            scenario: scenario,
            surfaceTotal: surfaces.count,
            surfaceWalls: room.walls.count,
            surfaceFloors: room.floors.count,
            surfaceOthers: room.doors.count + room.windows.count + room.openings.count,
            polylines: polylines,
            totalSamples: totalSamples,
            totalAssigned: totalAssigned,
            totalWorldHits: totalWorldHits,
            captureToRaycastDelayMs: raycast.captureToRaycastDelayMs,
            diagnostics: diagnostics
        )
    }

    static func categoryName(
        _ category: CapturedRoom.Surface.Category?
    ) -> String {
        guard let category else { return "?" }
        switch category {
        case .wall: return "wall"
        case .door: return "door"
        case .window: return "window"
        case .opening: return "opening"
        case .floor: return "floor"
        @unknown default: return "unknown"
        }
    }
}
