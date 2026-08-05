import Foundation
import simd

struct ObjectCropVolumeSnapshot: Codable {
    var originX: Float
    var originY: Float
    var originZ: Float
    var extentX: Float
    var extentY: Float
    var extentZ: Float
    var m00: Float
    var m01: Float
    var m02: Float
    var m10: Float
    var m11: Float
    var m12: Float
    var m20: Float
    var m21: Float
    var m22: Float
    var m30: Float
    var m31: Float
    var m32: Float
}

struct ObjectCropVolume {
    let origin: SIMD3<Float>
    let extent: SIMD3<Float>
    let transform: simd_float4x4

    init(
        center: SIMD3<Float>,
        extent: SIMD3<Float>,
        transform: simd_float4x4
    ) {
        var rotationOnly = transform
        rotationOnly.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        let localCenter = SIMD4<Float>(
            extent.x * 0.5,
            extent.y * 0.5,
            extent.z * 0.5,
            1
        )
        let rotated = rotationOnly * localCenter
        self.origin = center - SIMD3<Float>(rotated.x, rotated.y, rotated.z)
        self.extent = extent
        var originTransform = transform
        originTransform.columns.3 = SIMD4<Float>(
            self.origin.x,
            self.origin.y,
            self.origin.z,
            1
        )
        self.transform = originTransform
    }

    init(
        origin: SIMD3<Float>,
        extent: SIMD3<Float>,
        transform: simd_float4x4
    ) {
        self.origin = origin
        self.extent = extent
        self.transform = transform
    }

    var center: SIMD3<Float> {
        let localCenter = SIMD4<Float>(
            extent.x * 0.5,
            extent.y * 0.5,
            extent.z * 0.5,
            1
        )
        let world = transform * localCenter
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    var snapshot: ObjectCropVolumeSnapshot {
        ObjectCropVolumeSnapshot(
            originX: origin.x,
            originY: origin.y,
            originZ: origin.z,
            extentX: extent.x,
            extentY: extent.y,
            extentZ: extent.z,
            m00: transform.columns.0.x,
            m01: transform.columns.0.y,
            m02: transform.columns.0.z,
            m10: transform.columns.1.x,
            m11: transform.columns.1.y,
            m12: transform.columns.1.z,
            m20: transform.columns.2.x,
            m21: transform.columns.2.y,
            m22: transform.columns.2.z,
            m30: transform.columns.3.x,
            m31: transform.columns.3.y,
            m32: transform.columns.3.z
        )
    }

    init?(snapshot: ObjectCropVolumeSnapshot) {
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(snapshot.m00, snapshot.m01, snapshot.m02, 0)
        transform.columns.1 = SIMD4<Float>(snapshot.m10, snapshot.m11, snapshot.m12, 0)
        transform.columns.2 = SIMD4<Float>(snapshot.m20, snapshot.m21, snapshot.m22, 0)
        transform.columns.3 = SIMD4<Float>(snapshot.m30, snapshot.m31, snapshot.m32, 1)
        self.origin = SIMD3<Float>(snapshot.originX, snapshot.originY, snapshot.originZ)
        self.extent = SIMD3<Float>(snapshot.extentX, snapshot.extentY, snapshot.extentZ)
        self.transform = transform
    }
    var halfExtent: SIMD3<Float> { extent * 0.5 }
    var inverseTransform: simd_float4x4 { simd_inverse(transform) }

    func contains(worldPoint: SIMD3<Float>) -> Bool {
        let local4 = inverseTransform * SIMD4<Float>(
            worldPoint.x,
            worldPoint.y,
            worldPoint.z,
            1
        )
        let local = SIMD3<Float>(local4.x, local4.y, local4.z)
        return local.x >= -0.01
            && local.x <= extent.x + 0.01
            && local.y >= -0.01
            && local.y <= extent.y + 0.01
            && local.z >= -0.01
            && local.z <= extent.z + 0.01
    }

    func alignedExtents(points: [ObjectPoint]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        var minLocal = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxLocal = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for point in points {
            let local4 = inverseTransform * SIMD4<Float>(
                point.x,
                point.y,
                point.z,
                1
            )
            let local = SIMD3<Float>(local4.x, local4.y, local4.z)
            minLocal = simd_min(minLocal, local)
            maxLocal = simd_max(maxLocal, local)
        }
        return SIMD3<Float>(
            min(max(maxLocal.x - minLocal.x, 0), extent.x),
            min(max(maxLocal.y - minLocal.y, 0), extent.y),
            min(max(maxLocal.z - minLocal.z, 0), extent.z)
        )
    }
}
