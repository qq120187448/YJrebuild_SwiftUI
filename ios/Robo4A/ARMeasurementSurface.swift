import ARKit
import simd

/// 0.74D（专家架构变更）：ARKit 成为测量与长期空间层，RoomPlan 降级为语义层。
/// 遵守"只写胶水"原则：本文件不做自研几何，只把 Apple 官方 raycast 结果
/// 包装成统一的测量表面数据（ARSurfaceHit），供 Isect/UV/长度/持久化使用。

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

/// 测量表面命中：由官方 ARRaycastResult 包装而来。
struct ARSurfaceHit {
    let id: UUID?
    let category: ARSurfaceCategory
    let transform: simd_float4x4
    /// surface-local 坐标（表面中心为原点，z 为法向）。
    let localPoint: SIMD3<Float>
    let confidence: Float
    let source: ARSurfaceSource

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

enum ARMeasurementSurface {

    /// 胶水：官方 ARView.raycast 命中 → ARSurfaceHit（无自研几何）。
    /// 命中 anchor 为 ARPlaneAnchor 时给出 surface-local 坐标与分类；否则仅 world 点。
    static func hit(
        from result: ARRaycastResult
    ) -> ARSurfaceHit {
        let world = result.worldTransform.position
        if let plane = result.anchor as? ARPlaneAnchor {
            let local4 = plane.transform.inverse
                * SIMD4<Float>(world.x, world.y, world.z, 1)
            let local = SIMD3<Float>(local4.x, local4.y, local4.z)
            return ARSurfaceHit(
                id: plane.identifier,
                category: plane.alignment == .vertical
                    ? .wall
                    : .floor,
                transform: plane.transform,
                localPoint: local,
                confidence: 1,
                source: .plane
            )
        }
        return ARSurfaceHit(
            id: result.anchor?.identifier,
            category: .unknown,
            transform: matrix_identity_float4x4,
            localPoint: world,
            confidence: 0.5,
            source: .mesh
        )
    }
}
