import Foundation
import simd

struct ObjectCropVolume {
    let center: SIMD3<Float>
    let extent: SIMD3<Float>
    let transform: simd_float4x4

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
        let half = halfExtent
        return abs(local.x) <= half.x
            && local.y >= (-half.y + 0.01)
            && local.y <= half.y
            && abs(local.z) <= half.z
    }
}
