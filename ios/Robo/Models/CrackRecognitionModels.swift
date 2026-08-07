import Foundation

struct CrackComponentMeasurement: Codable, Equatable {
    let id: Int
    let pixelLength: Double
    let mmLength: Double?
    let lengthM: Double?

    init(id: Int, pixelLength: Double, mmLength: Double?, lengthM: Double?) {
        self.id = id
        self.pixelLength = pixelLength
        self.mmLength = mmLength
        self.lengthM = lengthM
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

    var isEmpty: Bool {
        components.isEmpty
    }
}
