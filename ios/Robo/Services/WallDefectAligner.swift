import Foundation
import simd

/// Estimates the rigid transform from RoomPlan room coordinates to ARKit world
/// coordinates. RoomPlan can rebase or setWorldOrigin during a scan, so the
/// transform is re-estimated from ARKit depth samples on walls and floors.
enum WallDefectAligner {

    struct Sample {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    /// Returns a matrix mapping RoomPlan coords to AR world: world = R * room + t.
    static func estimateRoomToWorld(
        samples: [Sample],
        surfaces: [WallDefectSurface]
    ) -> simd_float4x4? {
        guard samples.count >= 4, !surfaces.isEmpty else { return nil }

        let wallNormals = surfaces
            .filter { $0.kind == .wall }
            .compactMap { surface -> SIMD3<Double>? in
                let normal = WallDefectGeometry.planeNormal(for: surface)
                let length = simd_length(normal)
                guard length > 0.0001 else { return nil }
                return normal / length
            }
        guard !wallNormals.isEmpty else { return nil }

        let wallSamples = samples.filter { abs(Double($0.normal.y)) < 0.75 }
        guard wallSamples.count >= 2 else { return nil }

        var deltas: [Double] = []
        for sample in wallSamples {
            let nAr = simd_normalize(sample.normal)
            let ax = Double(nAr.x)
            let az = Double(nAr.z)
            let lengthA = (ax * ax + az * az).squareRoot()
            guard lengthA > 0.05 else { continue }
            let naX = ax / lengthA
            let naZ = az / lengthA
            for normal in wallNormals {
                let bx = normal.x
                let bz = normal.z
                let lengthB = (bx * bx + bz * bz).squareRoot()
                guard lengthB > 0.05 else { continue }
                let nbX = bx / lengthB
                let nbZ = bz / lengthB
                var delta = atan2(
                    naX * nbZ - naZ * nbX,
                    naX * nbX + naZ * nbZ
                )
                while delta < 0 { delta += Double.pi }
                delta = delta.truncatingRemainder(dividingBy: Double.pi)
                deltas.append(delta)
            }
        }
        guard !deltas.isEmpty else { return nil }
        let baseYaw = circularMean(deltas) ?? 0
        let fitted = [baseYaw, baseYaw + .pi].compactMap { yaw in
            fit(samples: samples, surfaces: surfaces, yaw: yaw)
        }
        return fitted.min { $0.residual < $1.residual }?.transform
    }

    /// Maps RoomPlan-frame surfaces into AR world coordinates.
    static func applyRoomToWorld(
        _ transform: simd_float4x4,
        to surfaces: [WallDefectSurface]
    ) -> [WallDefectSurface] {
        surfaces.map { surface in
            let origin = transform * SIMD4<Float>(
                Float(surface.origin[0]),
                Float(surface.origin[1]),
                Float(surface.origin[2]),
                1
            )
            let uAxis = transform * SIMD4<Float>(
                Float(surface.uAxis[0]),
                Float(surface.uAxis[1]),
                Float(surface.uAxis[2]),
                0
            )
            let vAxis = transform * SIMD4<Float>(
                Float(surface.vAxis[0]),
                Float(surface.vAxis[1]),
                Float(surface.vAxis[2]),
                0
            )
            let normal = transform * SIMD4<Float>(
                Float(surface.normal[0]),
                Float(surface.normal[1]),
                Float(surface.normal[2]),
                0
            )
            return WallDefectSurface(
                id: surface.id,
                kind: surface.kind,
                label: surface.label,
                width: surface.width,
                height: surface.height,
                area: surface.area,
                origin: [Double(origin.x), Double(origin.y), Double(origin.z)],
                uAxis: [Double(uAxis.x), Double(uAxis.y), Double(uAxis.z)],
                vAxis: [Double(vAxis.x), Double(vAxis.y), Double(vAxis.z)],
                normal: [Double(normal.x), Double(normal.y), Double(normal.z)]
            )
        }
    }

    static func yawDegrees(from transform: simd_float4x4) -> Double {
        Double(atan2(transform.columns.2.x, transform.columns.2.z) * 180 / .pi)
    }

    private static func fit(
        samples: [Sample],
        surfaces: [WallDefectSurface],
        yaw: Double
    ) -> (transform: simd_float4x4, residual: Double)? {
        let rotation = simd_float4x4(simd_quatf(
            angle: Float(yaw),
            axis: SIMD3<Float>(0, 1, 0)
        ))
        let inverseRotation = simd_float4x4(simd_quatf(
            angle: -Float(yaw),
            axis: SIMD3<Float>(0, 1, 0)
        ))

        var translations: [SIMD3<Float>] = []
        var matches: [(sample: SIMD3<Float>, roomPoint: SIMD3<Double>, normal: SIMD3<Double>)] = []
        for sample in samples {
            let nAr = simd_normalize(sample.normal)
            let roomPos4 = inverseRotation * SIMD4<Float>(
                sample.position.x,
                sample.position.y,
                sample.position.z,
                1
            )
            let roomPos = SIMD3<Float>(roomPos4.x, roomPos4.y, roomPos4.z)
            let rotatedNormal = inverseRotation * SIMD4<Float>(
                nAr.x,
                nAr.y,
                nAr.z,
                0
            )
            let nArRoom = SIMD3<Float>(
                rotatedNormal.x,
                rotatedNormal.y,
                rotatedNormal.z
            )
            for surface in surfaces {
                let origin = WallDefectGeometry.planeOrigin(for: surface)
                let normal = WallDefectGeometry.planeNormal(for: surface)
                let length = simd_length(normal)
                guard length > 0.0001 else { continue }
                let n = normal / length
                let nFloat = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
                guard abs(simd_dot(nArRoom, nFloat)) > 0.7 else { continue }

                let pRoom = SIMD3<Double>(
                    Double(roomPos.x),
                    Double(roomPos.y),
                    Double(roomPos.z)
                )
                let distance = simd_dot(pRoom - origin, n)
                let closest = pRoom - n * distance
                let world4 = rotation * SIMD4<Float>(
                    Float(closest.x),
                    Float(closest.y),
                    Float(closest.z),
                    1
                )
                let worldPoint = SIMD3<Float>(world4.x, world4.y, world4.z)
                translations.append(sample.position - worldPoint)
                matches.append((sample.position, closest, n))
            }
        }
        guard !translations.isEmpty else { return nil }
        let translation = median(translations)

        var transform = rotation
        transform.columns.3 = SIMD4<Float>(
            translation.x,
            translation.y,
            translation.z,
            1
        )

        var residualSum = 0.0
        var residualCount = 0
        for match in matches {
            let worldOrigin4 = transform * SIMD4<Float>(
                Float(match.roomPoint.x),
                Float(match.roomPoint.y),
                Float(match.roomPoint.z),
                1
            )
            let worldPoint = SIMD3<Float>(
                worldOrigin4.x,
                worldOrigin4.y,
                worldOrigin4.z
            )
            let distance = simd_distance(match.sample, worldPoint)
            residualSum += Double(distance)
            residualCount += 1
        }
        let residual = residualCount > 0 ? residualSum / Double(residualCount) : .greatestFiniteMagnitude
        return (transform, residual)
    }

    private static func circularMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var sumX = 0.0
        var sumY = 0.0
        for value in values {
            sumX += cos(value)
            sumY += sin(value)
        }
        return atan2(sumY, sumX)
    }

    private static func median(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
        func middle(_ array: [Float]) -> Float {
            let count = array.count
            guard count > 0 else { return 0 }
            if count % 2 == 1 { return array[count / 2] }
            return (array[count / 2 - 1] + array[count / 2]) / 2
        }
        return SIMD3<Float>(
            middle(values.map { $0.x }.sorted()),
            middle(values.map { $0.y }.sorted()),
            middle(values.map { $0.z }.sorted())
        )
    }
}
