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

    struct UVLengthSegment {
        let surfaceID: UUID
        let category: CapturedRoom.Surface.Category?
        let lengthM: Double
        let pointCount: Int
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
        let existingWorld: SIMD3<Float>?
        let existingLocalZ: Double?
        let existingPlaneDistance: Double?
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
        let targetComparisonRates: [(thresholdMm: Int, estimatedRatio: Double, existingRatio: Double)]
        let uvLengthM: Double?
        let uvLengthSegments: [UVLengthSegment]
        let crossSurfaceTransitionCount: Int
        let averageWidthM: Double?
        let maxWidthM: Double?

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
            lines.append(SurfaceUV4C.targetComparisonRatesText(targetComparisonRates))
            lines.append(
                SurfaceUV4C.uvLengthText(
                    uvLengthM,
                    segments: uvLengthSegments,
                    crossSurfaceTransitions: crossSurfaceTransitionCount
                )
            )
            lines.append(SurfaceUV4C.uvWidthText(averageWidthM, maxWidthM: maxWidthM))
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
                    if let existingLocalZ = point.existingLocalZ,
                       let existingPlaneDistance = point.existingPlaneDistance {
                        let estimatedLocalZ = point.candidates.first?.local.z
                        let estimatedZText = estimatedLocalZ.map {
                            String(format: "%.3f", $0)
                        } ?? "-"
                        lines.append(
                            String(
                                format: "  目标对照：estimated z=%@ · existing z=%.3f · existing |z|=%.3f",
                                estimatedZText,
                                existingLocalZ,
                                existingPlaneDistance
                            )
                        )
                    }
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

        /// 单份报告截断到指定字符数以内，便于真机导出与累积保存。
        func clippedText(limit: Int = 1000) -> String {
            let full = compactText()
            guard full.count > limit else { return full }
            let cut = full.index(full.startIndex, offsetBy: limit)
            return String(full[..<cut]) + "\n…（已截断至 \(limit) 字符）"
        }

        /// 当前 4D.1 阶段精简日志：只保留裂缝总长、平均宽度、最大宽度。
        func compactText() -> String {
            var lines = [
                "4C Surface UV",
                "场景：\(scenario)"
            ]
            if let uvLengthM, uvLengthM > 0 {
                lines.append(String(format: "裂缝总长：%.3f m", uvLengthM))
            } else {
                let assigned = polylines.reduce(0) { $0 + $1.assignedCount }
                lines.append(
                    "裂缝总长：无法计算（world 命中 \(totalWorldHits) · 分配 \(assigned)）"
                )
            }
            if let averageWidthM, averageWidthM > 0,
               let maxWidthM, maxWidthM > 0 {
                lines.append(
                    String(
                        format: "裂缝宽度：平均 %.3f mm · 最大 %.3f mm",
                        averageWidthM * 1000,
                        maxWidthM * 1000
                    )
                )
            } else {
                lines.append("裂缝宽度：无法估算")
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
        sessionDiagnosticText: String? = nil,
        toleranceM: Double = 0.03,
        totalPixelLengthPx: Double? = nil,
        maxWidthPx: Double? = nil,
        averageWidthPx: Double? = nil
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
        var existingWorldPoints: [SIMD3<Float>] = []
        var raycastTargetSummary: [String: Int] = [:]

        // 把一个 raycast 单点结果映射为 MappedPoint（密集采样与简化折线共用）。
        func mappedPoint(
            from point: Raycast4BPointResult,
            surfaces: [CapturedRoom.Surface],
            toleranceM: Float,
            diagnosticCategories: [CapturedRoom.Surface.Category]
        ) -> MappedPoint {
            guard let world = point.world else {
                let existingCandidate = point.existingWorld.flatMap {
                    candidateDiagnostics(
                        world: $0,
                        surfaces: surfaces,
                        allowedCategories: diagnosticCategories
                    ).first
                }
                return MappedPoint(
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
                    existingWorld: point.existingWorld,
                    existingLocalZ: existingCandidate.map { Double($0.local.z) },
                    existingPlaneDistance: existingCandidate.map { Double($0.planeDistance) },
                    candidates: []
                )
            }
            let candidates = candidateDiagnostics(
                world: world,
                surfaces: surfaces,
                allowedCategories: diagnosticCategories
            )
            let existingCandidate = point.existingWorld.flatMap {
                candidateDiagnostics(
                    world: $0,
                    surfaces: surfaces,
                    allowedCategories: diagnosticCategories
                ).first
            }
            if let mapped = map(
                world: world,
                surfaces: surfaces,
                toleranceM: toleranceM
            ) {
                return MappedPoint(
                    source: point.source,
                    world: world,
                    surfaceID: mapped.surface.identifier,
                    category: mapped.surface.category,
                    u: Double(mapped.local.x),
                    v: Double(mapped.local.y),
                    localZ: Double(mapped.local.z),
                    status: "assigned",
                    raycastResultsCount: point.raycastResultsCount,
                    firstRaycastDistance: point.firstRaycastDistance,
                    raycastAnchorType: point.raycastAnchorType,
                    raycastTarget: point.raycastTarget,
                    raycastTargetAlignment: point.raycastTargetAlignment,
                    existingWorld: point.existingWorld,
                    existingLocalZ: existingCandidate.map { Double($0.local.z) },
                    existingPlaneDistance: existingCandidate.map { Double($0.planeDistance) },
                    candidates: candidates
                )
            }
            return MappedPoint(
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
                existingWorld: point.existingWorld,
                existingLocalZ: existingCandidate.map { Double($0.local.z) },
                existingPlaneDistance: existingCandidate.map { Double($0.planeDistance) },
                candidates: candidates
            )
        }

        // 按连续同面 assigned 点累计 UV 长度（跨面跳变不计入）。
        func computeLengthSegments(
            _ points: [MappedPoint]
        ) -> (segments: [UVLengthSegment], transitions: Int, total: Double?) {
            var segments: [UVLengthSegment] = []
            var transitions = 0
            var segmentSurfaceID: UUID?
            var segmentCategory: CapturedRoom.Surface.Category?
            var segmentLength = 0.0
            var segmentPointCount = 0
            var previousPoint: MappedPoint?

            for point in points {
                guard point.status == "assigned",
                      let surfaceID = point.surfaceID,
                      let u = point.u,
                      let v = point.v else {
                    segmentSurfaceID = nil
                    segmentCategory = nil
                    segmentLength = 0
                    segmentPointCount = 0
                    previousPoint = nil
                    continue
                }

                if segmentSurfaceID == surfaceID {
                    if let previous = previousPoint,
                       let previousU = previous.u,
                       let previousV = previous.v {
                        segmentLength += hypot(u - previousU, v - previousV)
                    }
                    segmentPointCount += 1
                } else {
                    if let previousSurfaceID = segmentSurfaceID {
                        if segmentPointCount >= 2 {
                            segments.append(
                                UVLengthSegment(
                                    surfaceID: previousSurfaceID,
                                    category: segmentCategory,
                                    lengthM: segmentLength,
                                    pointCount: segmentPointCount
                                )
                            )
                        }
                        transitions += 1
                    }
                    segmentSurfaceID = surfaceID
                    segmentCategory = point.category
                    segmentLength = 0
                    segmentPointCount = 1
                }
                previousPoint = point
            }

            if let previousSurfaceID = segmentSurfaceID,
               segmentPointCount >= 2 {
                segments.append(
                    UVLengthSegment(
                        surfaceID: previousSurfaceID,
                        category: segmentCategory,
                        lengthM: segmentLength,
                        pointCount: segmentPointCount
                    )
                )
            }
            let total = segments.isEmpty
                ? nil
                : segments.reduce(0) { $0 + $1.lengthM }
            return (segments, transitions, total)
        }

        for polyline in raycast.polylines {
            var points: [MappedPoint] = []
            var assignedCount = 0
            var counts: [UUID: Int] = [:]
            var uvPoints: [(u: Double, v: Double)] = []

            for (_, point) in polyline.points.enumerated() {
                totalSamples += 1
                let mapped = mappedPoint(
                    from: point,
                    surfaces: surfaces,
                    toleranceM: Float(toleranceM),
                    diagnosticCategories: diagnosticCategories
                )
                points.append(mapped)
                if mapped.world != nil {
                    totalWorldHits += 1
                    worldPoints.append(mapped.world!)
                    if let existingWorld = point.existingWorld {
                        existingWorldPoints.append(existingWorld)
                    }
                    if let target = point.raycastTarget {
                        raycastTargetSummary[target, default: 0] += 1
                    }
                }
                if mapped.status == "assigned",
                   let surfaceID = mapped.surfaceID,
                   let u = mapped.u,
                   let v = mapped.v {
                    assignedCount += 1
                    totalAssigned += 1
                    counts[surfaceID, default: 0] += 1
                    uvPoints.append((u, v))
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

        // 4D.1 长度：优先用每条裂缝的简化折线（≤7 段）UV 长度；
        // 未提供简化折线时（如 4B 路径）回退到密集采样点。
        let lengthPoints: [MappedPoint]
        if raycast.centerlinePolylines.isEmpty {
            lengthPoints = polylines.flatMap { $0.points }
        } else {
            lengthPoints = raycast.centerlinePolylines.flatMap { $0.points }.map {
                mappedPoint(
                    from: $0,
                    surfaces: surfaces,
                    toleranceM: Float(toleranceM),
                    diagnosticCategories: diagnosticCategories
                )
            }
        }
        let lengthResult = computeLengthSegments(lengthPoints)
        let uvLengthSegments = lengthResult.segments
        let crossSurfaceTransitionCount = lengthResult.transitions
        let uvLengthM = lengthResult.total
        let averageWidthM: Double?
        let maxWidthM: Double?
        if let uvLengthM,
           let totalPixelLengthPx, totalPixelLengthPx > 0,
           let averageWidthPx, averageWidthPx > 0,
           let maxWidthPx, maxWidthPx > 0 {
            let scale = uvLengthM / totalPixelLengthPx
            averageWidthM = averageWidthPx * scale
            maxWidthM = maxWidthPx * scale
        } else {
            averageWidthM = nil
            maxWidthM = nil
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

        let targetComparisonRates: [
            (thresholdMm: Int, estimatedRatio: Double, existingRatio: Double)
        ] = [20, 30, 40, 50].map { thresholdMm in
            let toleranceM = Float(thresholdMm) / 1000.0
            let estimatedAssigned = worldPoints.filter {
                map(world: $0, surfaces: surfaces, toleranceM: toleranceM) != nil
            }.count
            let existingAssigned = existingWorldPoints.filter {
                map(world: $0, surfaces: surfaces, toleranceM: toleranceM) != nil
            }.count
            return (
                thresholdMm: thresholdMm,
                estimatedRatio: worldPoints.isEmpty
                    ? 0
                    : Double(estimatedAssigned) / Double(worldPoints.count),
                existingRatio: existingWorldPoints.isEmpty
                    ? 0
                    : Double(existingAssigned) / Double(existingWorldPoints.count)
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
            surfaceInventory: surfaceInventory,
            sessionDiagnosticText: sessionDiagnosticText,
            thresholdRates: thresholdRates,
            raycastTargetSummary: raycastTargetSummary,
            targetComparisonRates: targetComparisonRates,
            uvLengthM: uvLengthM,
            uvLengthSegments: uvLengthSegments,
            crossSurfaceTransitionCount: crossSurfaceTransitionCount,
            averageWidthM: averageWidthM,
            maxWidthM: maxWidthM
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

    private static func targetComparisonRatesText(
        _ rates: [(thresholdMm: Int, estimatedRatio: Double, existingRatio: Double)]
    ) -> String {
        let parts = rates.map { threshold, estimated, existing in
            String(
                format: "%dmm est=%.1f%% exist=%.1f%%",
                threshold,
                estimated * 100,
                existing * 100
            )
        }.joined(separator: " · ")
        return "target A/B（Debug）：\(parts)"
    }

    private static func uvLengthText(
        _ lengthM: Double?,
        segments: [UVLengthSegment],
        crossSurfaceTransitions: Int
    ) -> String {
        guard let lengthM, lengthM > 0 else {
            return "4D.1 UV 长度：无法计算（缺少连续同面 assigned 点）"
        }
        let segmentText = segments.map {
            String(
                format: "%@=%.3fm",
                String($0.surfaceID.uuidString.prefix(8)),
                $0.lengthM
            )
        }.joined(separator: " · ")
        var text = String(
            format: "4D.1 UV 长度：%.3f m · %d 段 · %@ · measurementSource=estimatedPlane · measurementVersion=4C",
            lengthM,
            segments.count,
            segmentText
        )
        if crossSurfaceTransitions > 0 {
            text += " · 跨面跳变 \(crossSurfaceTransitions) 段（未混加 UV）"
        }
        return text
    }

    private static func uvWidthText(
        _ averageWidthM: Double?,
        maxWidthM: Double?
    ) -> String {
        guard let averageWidthM, averageWidthM > 0,
              let maxWidthM, maxWidthM > 0 else {
            return "4D.1 裂缝宽度：无法估算"
        }
        return String(
            format: "4D.1 裂缝宽度（线性近似）：平均 %.3f mm · 最大 %.3f mm",
            averageWidthM * 1000,
            maxWidthM * 1000
        )
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
