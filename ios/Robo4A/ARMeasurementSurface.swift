import ARKit
import simd

/// 0.74D（专家架构变更）：ARKit 成为测量与长期空间层，RoomPlan 降级为语义层。
/// 本文件定义纯 ARKit 测量表面的统一抽象（专家第二阶段协议）：
/// 业务层只认识 ARSurfaceHit（id/category/transform/localPoint/confidence/source），
/// 底层来自 ARPlaneAnchor 还是 ARMeshAnchor 被隐藏，后续可无损切换。

enum ARSurfaceSource {
    case plane
    case mesh
}

enum ARSurfaceCategory {
    case wall
    case floor
    case ceiling
    case unknown
}

/// 测量表面命中：世界点/射线与 ARKit 测量表面的关联结果。
struct ARSurfaceHit {
    let id: UUID
    let category: ARSurfaceCategory
    let transform: simd_float4x4
    /// surface-local 坐标（表面中心为原点，z 为法向）。
    let localPoint: SIMD3<Float>
    let confidence: Float
    let source: ARSurfaceSource

    /// 世界坐标（由 local 与 transform 还原）。
    var worldPoint: SIMD3<Float> {
        let v = transform * SIMD4<Float>(
            localPoint.x,
            localPoint.y,
            localPoint.z,
            1
        )
        return SIMD3<Float>(v.x, v.y, v.z)
    }
}

/// ARKit 测量表面提供者（业务层唯一入口）。
protocol ARMeasurementSurfaceProvider {
    /// 从当前帧刷新表面集合（ARPlaneAnchor / ARMeshAnchor）。
    func refresh(from frame: ARFrame)
    /// 射线求交（Isect 核心）：返回最近的表面命中（localPoint 为交点 local 坐标）。
    func intersect(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        toleranceM: Float
    ) -> ARSurfaceHit?
    /// 点归属（全局校验 / 分配率）：世界点是否落在某表面（含容差）。
    func surface(
        at worldPoint: SIMD3<Float>,
        toleranceM: Float
    ) -> ARSurfaceHit?
    /// 表面数量（诊断）。
    var surfaceCount: Int { get }
}

/// ARPlaneAnchor 主测量实现（专家第三阶段 A：先 ARPlane，不稳定再由 ARMesh 接管）。
final class ARPlaneSurfaceProvider: ARMeasurementSurfaceProvider {

    private var planes: [ARPlaneAnchor] = []
    private(set) var surfaceCount = 0

    func refresh(from frame: ARFrame) {
        planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        surfaceCount = planes.count
    }

    func intersect(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        toleranceM: Float
    ) -> ARSurfaceHit? {
        var best: ARSurfaceHit?
        var bestDistance = Float.greatestFiniteMagnitude
        for plane in planes {
            let inverse = plane.transform.inverse
            let localOrigin4 = inverse
                * SIMD4<Float>(origin.x, origin.y, origin.z, 1)
            let localDir4 = inverse
                * SIMD4<Float>(direction.x, direction.y, direction.z, 0)
            let localOrigin = SIMD3<Float>(
                localOrigin4.x,
                localOrigin4.y,
                localOrigin4.z
            )
            let localDir = SIMD3<Float>(
                localDir4.x,
                localDir4.y,
                localDir4.z
            )
            guard abs(localDir.z) > 0.0001 else { continue }
            let t = -localOrigin.z / localDir.z
            guard t > 0 else { continue }
            let localHit = localOrigin + localDir * t
            let halfX = plane.planeExtent.x * 0.5 + toleranceM
            let halfY = plane.planeExtent.y * 0.5 + toleranceM
            guard abs(localHit.x) <= halfX,
                  abs(localHit.y) <= halfY,
                  abs(localHit.z) <= toleranceM else {
                continue
            }
            let world4 = plane.transform
                * SIMD4<Float>(localHit.x, localHit.y, localHit.z, 1)
            let world = SIMD3<Float>(world4.x, world4.y, world4.z)
            let distance = simd_length(world - origin)
            if distance < bestDistance {
                bestDistance = distance
                best = ARSurfaceHit(
                    id: plane.identifier,
                    category: Self.category(for: plane),
                    transform: plane.transform,
                    localPoint: localHit,
                    confidence: 1,
                    source: .plane
                )
            }
        }
        return best
    }

    func surface(
        at worldPoint: SIMD3<Float>,
        toleranceM: Float
    ) -> ARSurfaceHit? {
        var best: ARSurfaceHit?
        var bestAbsZ = Float.greatestFiniteMagnitude
        for plane in planes {
            let inverse = plane.transform.inverse
            let local4 = inverse
                * SIMD4<Float>(
                    worldPoint.x,
                    worldPoint.y,
                    worldPoint.z,
                    1
                )
            let local = SIMD3<Float>(local4.x, local4.y, local4.z)
            let halfX = plane.planeExtent.x * 0.5 + toleranceM
            let halfY = plane.planeExtent.y * 0.5 + toleranceM
            guard abs(local.x) <= halfX,
                  abs(local.y) <= halfY,
                  abs(local.z) <= toleranceM else {
                continue
            }
            if abs(local.z) < bestAbsZ {
                bestAbsZ = abs(local.z)
                best = ARSurfaceHit(
                    id: plane.identifier,
                    category: Self.category(for: plane),
                    transform: plane.transform,
                    localPoint: local,
                    confidence: 1,
                    source: .plane
                )
            }
        }
        return best
    }

    private static func category(
        for plane: ARPlaneAnchor
    ) -> ARSurfaceCategory {
        switch plane.alignment {
        case .vertical:
            return .wall
        case .horizontal:
            return .floor
        @unknown default:
            return .unknown
        }
    }
}
