import Foundation

enum WallDefectSurfaceKind: String, Codable, CaseIterable, Equatable {
    case wall
    case floor

    var displayName: String {
        switch self {
        case .wall: return "墙面"
        case .floor: return "地面"
        }
    }
}

struct WallDefectSurface: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: WallDefectSurfaceKind
    let label: String
    let width: Double
    let height: Double
    let area: Double
    let origin: [Double]
    let uAxis: [Double]
    let vAxis: [Double]
    let normal: [Double]

    init(
        id: UUID,
        kind: WallDefectSurfaceKind,
        label: String,
        width: Double,
        height: Double,
        area: Double,
        origin: [Double],
        uAxis: [Double],
        vAxis: [Double],
        normal: [Double]
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.width = width
        self.height = height
        self.area = area
        self.origin = origin
        self.uAxis = uAxis
        self.vAxis = vAxis
        self.normal = normal
    }

    var uvDescription: String {
        String(
            format: "U %.2fm × V %.2fm · %.2f m²",
            width,
            height,
            area
        )
    }
}

struct WallDefectPhoto: Identifiable, Codable, Equatable {
    let id: UUID
    let wallID: UUID
    let capturedAt: Date
    let imageFileName: String
    let pose: [Float]
    let intrinsics: [Float]
    let depthFileName: String?
    let depthWidth: Int?
    let depthHeight: Int?
    var detectedClass: String?
    var note: String

    init(
        id: UUID = UUID(),
        wallID: UUID,
        capturedAt: Date = Date(),
        imageFileName: String,
        pose: [Float],
        intrinsics: [Float],
        depthFileName: String?,
        depthWidth: Int? = nil,
        depthHeight: Int? = nil,
        detectedClass: String? = nil,
        note: String = ""
    ) {
        self.id = id
        self.wallID = wallID
        self.capturedAt = capturedAt
        self.imageFileName = imageFileName
        self.pose = pose
        self.intrinsics = intrinsics
        self.depthFileName = depthFileName
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.detectedClass = detectedClass
        self.note = note
    }
}

struct WallDefectScanDocument: Identifiable, Codable {
    let id: UUID
    let capturedAt: Date
    let name: String
    let roomJSON: Data
    let surfaces: [WallDefectSurface]
    var photos: [WallDefectPhoto]

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        name: String,
        roomJSON: Data,
        surfaces: [WallDefectSurface],
        photos: [WallDefectPhoto] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.name = name
        self.roomJSON = roomJSON
        self.surfaces = surfaces
        self.photos = photos
    }
}
