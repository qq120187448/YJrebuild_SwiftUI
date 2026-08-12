import Foundation

enum WallDefectSurfaceKind: String, Codable, CaseIterable, Equatable {
    case wall
    case floor
    case ceiling

    var displayName: String {
        switch self {
        case .wall: return "墙面"
        case .floor: return "地面"
        case .ceiling: return "天面"
        }
    }
}

/// 缺陷类别：当前主线为裂缝，区域类缺陷为后续扩展预留。
enum DefectType: String, Codable, CaseIterable, Equatable {
    case crack
    case waterStain
    case mold
    case pollution
    case efflorescence
    case peelingSpalling
    case rust
    case unknown

    var displayName: String {
        switch self {
        case .crack: return "裂缝"
        case .waterStain: return "水渍"
        case .mold: return "发霉"
        case .pollution: return "污染"
        case .efflorescence: return "泛碱"
        case .peelingSpalling: return "起皮/剥落"
        case .rust: return "锈蚀"
        case .unknown: return "未知"
        }
    }
}

/// 测量算法版本。历史数据必须记录该值，算法升级后仍能区分旧结果。
enum MeasurementEngineVersion {
    static let current = "0.66-mesh-uv-1"
    static let legacy = "0.65-legacy-nearest"
}

/// 缺陷业务记录：长期坐标 = surfaceID + Surface UV（米制），不依赖单一 ARWorld。
/// 后续 P2/P4/P5/P6 均以此记录为持久化基础。
struct DefectRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let type: DefectType
    let surfaceID: UUID
    let confidence: Double
    /// 墙面展开图上的折线，单位为米（U=水平，V=垂直）。
    let uvPolyline: [[Double]]
    let lengthMeters: Double?
    let areaSquareMeters: Double?
    let photoID: UUID
    let createdAt: Date
    let measurementVersion: String

    init(
        id: UUID = UUID(),
        type: DefectType,
        surfaceID: UUID,
        confidence: Double,
        uvPolyline: [[Double]],
        lengthMeters: Double?,
        areaSquareMeters: Double?,
        photoID: UUID,
        createdAt: Date = Date(),
        measurementVersion: String = MeasurementEngineVersion.current
    ) {
        self.id = id
        self.type = type
        self.surfaceID = surfaceID
        self.confidence = confidence
        self.uvPolyline = uvPolyline
        self.lengthMeters = lengthMeters
        self.areaSquareMeters = areaSquareMeters
        self.photoID = photoID
        self.createdAt = createdAt
        self.measurementVersion = measurementVersion
    }
}

/// 原始观测：保存拍摄瞬间的空间信息与识别中间产物，
/// 供未来换模型后离线“重识别重算”（P3/P4 接口预留）。
struct DefectObservation: Codable, Equatable {
    let frameTimestamp: Date
    let cameraTransform: [Float]
    let intrinsics: [Float]
    let cropRect: [Double]
    let sensorImageSize: [Double]
    let analysisToCaptureRatio: Double
    let depthFileName: String?
    let depthWidth: Int?
    let depthHeight: Int?
    let pointCloudSampleCount: Int
    let meshAnchorCount: Int
    let meshVertexCount: Int
    let meshFaceCount: Int
    let confidence: Double
    let skeletonPixelCount: Int
    let measurementVersion: String

    init(
        frameTimestamp: Date,
        cameraTransform: [Float],
        intrinsics: [Float],
        cropRect: [Double],
        sensorImageSize: [Double],
        analysisToCaptureRatio: Double,
        depthFileName: String?,
        depthWidth: Int?,
        depthHeight: Int?,
        pointCloudSampleCount: Int,
        meshAnchorCount: Int,
        meshVertexCount: Int,
        meshFaceCount: Int,
        confidence: Double,
        skeletonPixelCount: Int,
        measurementVersion: String = MeasurementEngineVersion.current
    ) {
        self.frameTimestamp = frameTimestamp
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.cropRect = cropRect
        self.sensorImageSize = sensorImageSize
        self.analysisToCaptureRatio = analysisToCaptureRatio
        self.depthFileName = depthFileName
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.pointCloudSampleCount = pointCloudSampleCount
        self.meshAnchorCount = meshAnchorCount
        self.meshVertexCount = meshVertexCount
        self.meshFaceCount = meshFaceCount
        self.confidence = confidence
        self.skeletonPixelCount = skeletonPixelCount
        self.measurementVersion = measurementVersion
    }
}

/// 已知长度真值标定记录（P0：500/1000/2000mm 误差统计）。
struct CalibrationRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let knownLengthMM: Double
    let measuredLengthMM: Double
    let measurementEngine: String
    let measurementVersion: String?
    let pixelLength: Double
    let confidence: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        knownLengthMM: Double,
        measuredLengthMM: Double,
        measurementEngine: String,
        measurementVersion: String?,
        pixelLength: Double,
        confidence: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.knownLengthMM = knownLengthMM
        self.measuredLengthMM = measuredLengthMM
        self.measurementEngine = measurementEngine
        self.measurementVersion = measurementVersion
        self.pixelLength = pixelLength
        self.confidence = confidence
        self.createdAt = createdAt
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
    var surfaceAssociations: [WallDefectSurfaceAssociation]
    var annotatedFileName: String?
    var crackResult: CrackRecognitionResult?
    var planeSurface: WallDefectSurface?
    var arSkeleton3D: [[Double]]?
    var isDuplicate: Bool = false
    /// 缺陷业务记录（surfaceID + UV 米制），为长期测量坐标。
    var defectRecords: [DefectRecord]?
    /// 原始观测（P3 接口：用于未来重识别重算）。
    var observation: DefectObservation?

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
        note: String = "",
        surfaceAssociations: [WallDefectSurfaceAssociation] = [],
        annotatedFileName: String? = nil,
        crackResult: CrackRecognitionResult? = nil,
        planeSurface: WallDefectSurface? = nil,
        arSkeleton3D: [[Double]]? = nil,
        isDuplicate: Bool = false,
        defectRecords: [DefectRecord]? = nil,
        observation: DefectObservation? = nil
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
        self.surfaceAssociations = surfaceAssociations
        self.annotatedFileName = annotatedFileName
        self.crackResult = crackResult
        self.planeSurface = planeSurface
        self.arSkeleton3D = arSkeleton3D
        self.isDuplicate = isDuplicate
        self.defectRecords = defectRecords
        self.observation = observation
    }
}

struct WallDefectSurfaceAssociation: Codable, Equatable, Identifiable {
    var id: UUID { surfaceID }
    let surfaceID: UUID
    var label: String?
    var coverageRatio: Double
    var uvPolygon: [[Double]]?
    var detectedClass: String?
    var areaM2: Double?
    var lengthM: Double?

    init(
        surfaceID: UUID,
        label: String? = nil,
        coverageRatio: Double = 0,
        uvPolygon: [[Double]]? = nil,
        detectedClass: String? = nil,
        areaM2: Double? = nil,
        lengthM: Double? = nil
    ) {
        self.surfaceID = surfaceID
        self.label = label
        self.coverageRatio = coverageRatio
        self.uvPolygon = uvPolygon
        self.detectedClass = detectedClass
        self.areaM2 = areaM2
        self.lengthM = lengthM
    }
}

struct WallDefectScanDocument: Identifiable, Codable {
    let id: UUID
    let capturedAt: Date
    let name: String
    let roomJSON: Data?
    let surfaces: [WallDefectSurface]
    var photos: [WallDefectPhoto]

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        name: String,
        roomJSON: Data? = nil,
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
