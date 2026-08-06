import Foundation
import simd

struct TextureScanMesh {
    var vertices: [SIMD3<Float>] = []
    var indices: [Int] = []
    var faceClassifications: [Int] = []

    var faceCount: Int {
        indices.count / 3
    }
}

struct TexturePhotoFrame {
    let id: String
    let fileURL: URL
    let timestamp: TimeInterval
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageWidth: Int
    let imageHeight: Int
    let isCloseUp: Bool
    let distance: Float
}

struct TextureScanDefectMarker {
    let id: UUID
    let position: SIMD3<Float>
    let capturedAt: Date
    var state: Int
    var photoID: String?
}

struct TextureScanData {
    let scanID: UUID
    let capturedAt: Date
    let deviceModel: String
    let deviceMaxResolution: String
    let duration: TimeInterval
    var mesh: TextureScanMesh
    var photos: [TexturePhotoFrame]
    var defectMarkers: [TextureScanDefectMarker]
}

struct TextureScanStatus {
    var photoCount = 0
    var closeUpCount = 0
    var distance: Float = 0
    var isCloseUp = false
    var meshFaceCount = 0
    var maxResolution = "自动"
    var photoResolution = "自动"
    var coverage: Double = 0
    var speed: Float = 0
    var defectCount = 0
    var defectCapturedCount = 0
    var defectMode = false
}
