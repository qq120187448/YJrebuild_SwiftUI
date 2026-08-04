import SwiftUI
import Voxels
import iTriangle
import Euclid
import Manifold3D

@main
struct Feature2VerifyApp: App {
    init() {
        var voxels = VoxelArray<Float>(edge: 8, value: 0)
        voxels.set(VoxelIndex(1, 1, 1), newValue: 1)
        _ = voxels.value(VoxelIndex(1, 1, 1))

        _ = Delaunay.self

        let cube = Euclid.Mesh.cube(size: 1)
        _ = cube

        struct V: Vector3 {
            let x: Double
            let y: Double
            let z: Double
        }
        let solid = Manifold.cube(size: V(x: 1, y: 2, z: 3))
        _ = solid.meshGL()
    }

    var body: some Scene {
        WindowGroup {
            Text("Feature 2 verification")
        }
    }
}
