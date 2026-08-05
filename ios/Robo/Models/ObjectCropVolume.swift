import Foundation
import simd

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
}
