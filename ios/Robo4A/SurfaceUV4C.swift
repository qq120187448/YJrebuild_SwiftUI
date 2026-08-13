import Foundation
import RoomPlan
import simd

/// 4C：ARWorld → RoomPlan Surface → Surface-local → UV（米）。
/// 只做“数据适配 + 坐标包装”：直接使用 CapturedRoom.Surface 的
/// identifier / transform / dimensions，不实现任何自研 3D 几何引擎。
enum SurfaceUV4C {

    struct SurfaceCandidate {
        let identifier: UUID
        let category: CapturedRoom.Surface.Category?
        let local: SIMD3<Float>
        let dimensions: simd_float3
        let planeDistance: Float
        let insideX: Bool
        let insideY: Bool
        let insideZ: Bool
        let insideBounds: Bool
        let score: Float
    }

    struct SurfaceInventoryItem {
        let identifier: UUID
        let category: CapturedRoom.Surface.Category?
        let dimensions: simd_float3
        let transform: simd_float4x4
    }

    struct MappedPoint {
        let source: CrackPoint
        let world: SIMD3<Float>?
        let surfaceID: UUID?
        let category: CapturedRoom.Surface.Category?
        let u: Double?
        let v: Double?
        let localZ: Double?
        let status: String
        let raycastResultsCount: Int?
        let firstRaycastDistance: Double?
        let raycastAnchorType: String?
        let raycastTarget: String?
        let raycastTargetAlignment: String?
        let candidates: [SurfaceCandidate]
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
        let surfaceInventory: [SurfaceInventoryItem]
        let sessionDiagnosticText: String?
        let thresholdRates: [(thresholdMm: Int, ratio: Double)]
        let raycastTargetSummary: [String: Int]

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
            if let sessionDiagnosticText {
                lines.append(sessionDiagnosticText)
            }
            lines.append(SurfaceUV4C.raycastTargetSummaryText(raycastTargetSummary))
            lines.append(SurfaceUV4C.thresholdRatesText(thresholdRates))
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
            let noSurfacePoints = polylines.flatMap { polyline in
                polyline.points.enumerated().compactMap { index, point -> (Int, Int, MappedPoint)? in
                    point.status == "noSurface" ? (polyline.index, index, point) : nil
                }
            }
            if !noSurfacePoints.isEmpty {
                lines.append("未分配诊断（仅列最近 2 个候选）：")
                for (polylineIndex, pointIndex, point) in noSurfacePoints {
                    guard let world = point.world else { continue }
                    let raycastInfo = SurfaceUV4C.raycastInfoText(point)
                    lines.append(
                        String(
                            format: "[裂缝%d·点%d] world=(%.3f, %.3f, %.3f) %@",
                            polylineIndex + 1,
                            pointIndex + 1,
                            world.x,
                            world.y,
                            world.z,
                            raycastInfo
                        )
                    )
                    if point.candidates.isEmpty {
                        lines.append("  （无候选 Surface）")
                    }
                    for candidate in point.candidates.prefix(2) {
                        lines.append(
                            String(
                                format: "  %@ %@ local=(%.3f, %.3f, %.3f) planeDistance=%.3f insideX=%@ insideY=%@ insideZ=%@ insideBounds=%@",
                                categoryName(candidate.category),
                                String(candidate.identifier.uuidString.prefix(8)),
                                candidate.local.x,
                                candidate.local.y,
                                candidate.local.z,
                                candidate.planeDistance,
                                candidate.insideX ? "true" : "false",
                                candidate.insideY ? "true" : "false",
                                candidate.insideZ ? "true" : "false",
                                candidate.insideBounds ? "true" : "false"
                            )
                        )
                    }
                    if point.candidates.count > 2 {
                        lines.append("  …其余 \(point.candidates.count - 2) 个候选略")
                    }
                }
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
        room: CapturedRoom,
        diagnosticCategories: [CapturedRoom.Surface.Category] = [.wall, .floor],
        sessionDiagnosticText: String? = nil
    ) -> Report {
        let surfaces =
            room.walls + room.floors + room.doors + room.windows + room.openings
        let surfaceInventory = surfaces.map {
            SurfaceInventoryItem(
                identifier: $0.identifier,
                category: $0.category,
                dimensions: $0.dimensions,
                transform: $0.transform
            )
        }
        var polylines: [PolylineUV] = []
        var totalSamples = 0
        var totalAssigned = 0
        var totalWorldHits = 0
        var worldPoints: [SIMD3<Float>] = []
        var raycastTargetSummary: [String: Int] = [:]

        for polyline in raycast.polylines {
            var points: [MappedPoint] = []
            var assignedCount = 0
            var counts: [UUID: Int] = [:]
            var uvPoints: [(u: Double, v: Double)] = []

            for (_, point) in polyline.points.enumerated() {
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
                            status: "miss",
                            raycastResultsCount: point.raycastResultsCount,
                            firstRaycastDistance: point.firstRaycastDistance,
                            raycastAnchorType: point.raycastAnchorType,
                            raycastTarget: point.raycastTarget,
                            raycastTargetAlignment: point.raycastTargetAlignment,
                            candidates: []
                        )
                    )
                    continue
                }
                totalWorldHits += 1
                worldPoints.append(world)
                if let target = point.raycastTarget {
                    raycastTargetSummary[target, default: 0] += 1
                }
                let candidates = candidateDiagnostics(
                    world: world,
                    surfaces: surfaces,
                    allowedCategories: diagnosticCategories
                )
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
                            status: "assigned",
                            raycastResultsCount: point.raycastResultsCount,
                            firstRaycastDistance: point.firstRaycastDistance,
                            raycastAnchorType: point.raycastAnchorType,
                            raycastTarget: point.raycastTarget,
                            raycastTargetAlignment: point.raycastTargetAlignment,
                            candidates: candidates
                        )
                    )
                } else {
                    points.append(
                        MappedPoint(
                            source: point.source,
                            world: world,
                            surfaceID: nil,
                            category: nil,
                            u: nil,
                            v: nil,
                            localZ: nil,
                            status: "noSurface",
                            raycastResultsCount: point.raycastResultsCount,
                            firstRaycastDistance: point.firstRaycastDistance,
                            raycastAnchorType: point.raycastAnchorType,
                            raycastTarget: point.raycastTarget,
                            raycastTargetAlignment: point.raycastTargetAlignment,
                            candidates: candidates
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

        let thresholdRates: [(thresholdMm: Int, ratio: Double)] =
            [20, 30, 40, 50].map { thresholdMm in
                let toleranceM = Float(thresholdMm) / 1000.0
                let assigned = worldPoints.filter {
                    map(world: $0, surfaces: surfaces, toleranceM: toleranceM)
                        != nil
                }.count
                let ratio = worldPoints.isEmpty
                    ? 0
                    : Double(assigned) / Double(worldPoints.count)
                return (thresholdMm: thresholdMm, ratio: ratio)
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
            surfaceInventory: surfaceInventory,
            sessionDiagnosticText: sessionDiagnosticText,
            thresholdRates: thresholdRates,
            raycastTargetSummary: raycastTargetSummary
        )
    }

    static func candidateDiagnostics(
        world: SIMD3<Float>,
        surfaces: [CapturedRoom.Surface],
        allowedCategories: [CapturedRoom.Surface.Category]?
    ) -> [SurfaceCandidate] {
        let candidateSurfaces = surfaces.filter { surface in
            guard let allowedCategories else { return true }
            let category = surface.category
            return allowedCategories.contains(category)
        }
        return candidateSurfaces.map { surface in
            let local = surfaceLocal(world, surface: surface)
            let halfX = surface.dimensions.x * 0.5
            let halfY = surface.dimensions.y * 0.5
            let halfZ = surface.dimensions.z * 0.5
            let insideX = abs(local.x) <= halfX
            let insideY = abs(local.y) <= halfY
            let insideZ = abs(local.z) <= halfZ
            let insideBounds = insideX && insideY && insideZ
            let planeDistance = abs(local.z)
            return SurfaceCandidate(
                identifier: surface.identifier,
                category: surface.category,
                local: local,
                dimensions: surface.dimensions,
                planeDistance: planeDistance,
                insideX: insideX,
                insideY: insideY,
                insideZ: insideZ,
                insideBounds: insideBounds,
                score: planeDistance
            )
        }
        .sorted { $0.planeDistance < $1.planeDistance }
    }

    private static func raycastInfoText(_ point: MappedPoint) -> String {
        let count = point.raycastResultsCount.map(String.init) ?? "-"
        let target = point.raycastTarget ?? "-"
        let alignment = point.raycastTargetAlignment ?? "-"
        let distance = point.firstRaycastDistance.map {
            String(format: "%.3f m", $0)
        } ?? "-"
        let anchor = point.raycastAnchorType ?? "-"
        return "raycastResults=\(count) target=\(target) alignment=\(alignment) anchor=\(anchor) firstDistance=\(distance)"
    }

    private static func raycastTargetSummaryText(
        _ summary: [String: Int]
    ) -> String {
        if summary.isEmpty { return "Raycast target 统计：无" }
        let parts = summary.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " · ")
        return "Raycast target 统计：\(parts)"
    }

    private static func thresholdRatesText(
        _ rates: [(thresholdMm: Int, ratio: Double)]
    ) -> String {
        let parts = rates.map { threshold, ratio in
            String(format: "%dmm=%.1f%%", threshold, ratio * 100)
        }.joined(separator: " · ")
        return "阈值敏感性（Debug）：\(parts)"
    }

    private static func float3Text(_ value: simd_float3) -> String {
        String(
            format: "%.2f, %.2f, %.2f",
            value.x,
            value.y,
            value.z
        )
    }

    private static func transformText(_ value: simd_float4x4) -> String {
        let c0 = value.columns.0
        let c1 = value.columns.1
        let c2 = value.columns.2
        let c3 = value.columns.3
        return String(
            format: "[%.3f,%.3f,%.3f,%.3f; %.3f,%.3f,%.3f,%.3f; %.3f,%.3f,%.3f,%.3f; %.3f,%.3f,%.3f,%.3f]",
            c0.x, c0.y, c0.z, c0.w,
            c1.x, c1.y, c1.z, c1.w,
            c2.x, c2.y, c2.z, c2.w,
            c3.x, c3.y, c3.z, c3.w
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
