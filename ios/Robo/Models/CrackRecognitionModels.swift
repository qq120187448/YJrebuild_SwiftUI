import Foundation

struct CrackComponentMeasurement: Codable, Equatable {
    let id: Int
    let pixelLength: Double
    let mmLength: Double?
    let lengthM: Double?
    /// 墙面展开图 UV 折线（米）。旧数据无该字段时解码为 nil。
    let uvPolyline: [[Double]]?
    let measurementVersion: String?
    /// 所属表面（缺陷长期坐标的 surfaceID）。
    let surfaceID: UUID?

    init(
        id: Int,
        pixelLength: Double,
        mmLength: Double?,
        lengthM: Double?,
        uvPolyline: [[Double]]? = nil,
        measurementVersion: String? = nil,
        surfaceID: UUID? = nil
    ) {
        self.id = id
        self.pixelLength = pixelLength
        self.mmLength = mmLength
        self.lengthM = lengthM
        self.uvPolyline = uvPolyline
        self.measurementVersion = measurementVersion
        self.surfaceID = surfaceID
    }
}

struct CrackSurfaceSummary: Codable, Equatable, Identifiable {
    let surfaceID: UUID
    let label: String
    let pixelArea: Int
    let areaM2: Double
    let totalLengthM: Double
    let longestLengthM: Double
    let componentCount: Int
    let uvPolygon: [[Double]]

    var id: UUID { surfaceID }

    init(
        surfaceID: UUID,
        label: String,
        pixelArea: Int,
        areaM2: Double,
        totalLengthM: Double,
        longestLengthM: Double,
        componentCount: Int,
        uvPolygon: [[Double]]
    ) {
        self.surfaceID = surfaceID
        self.label = label
        self.pixelArea = pixelArea
        self.areaM2 = areaM2
        self.totalLengthM = totalLengthM
        self.longestLengthM = longestLengthM
        self.componentCount = componentCount
        self.uvPolygon = uvPolygon
    }
}

struct CrackRecognitionResult: Codable, Equatable {
    let detectedClass: String
    let confidence: Double
    let totalPixelLength: Double
    let totalMMLength: Double?
    let totalLengthM: Double
    let totalAreaM2: Double
    let components: [CrackComponentMeasurement]
    let surfaceSummaries: [CrackSurfaceSummary]
    let mode: String
    let modelSize: String
    let engine: String
    /// 测量算法版本（如 0.66-mesh-uv-1）。旧数据为 nil。
    let measurementVersion: String?
    /// 本次使用的测量引擎：nearest（旧）/ meshuv（新）。
    let measurementEngine: String?

    var isEmpty: Bool {
        components.isEmpty
    }
}
