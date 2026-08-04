import Foundation
import SwiftData

@Model
final class ObjectScanRecord {
    var id: UUID
    var objectName: String
    var capturedAt: Date
    var pointCount: Int
    var processedPointCount: Int
    var targetPointCount: Int = 0
    var clusterCount: Int = 0
    var obbLengthM: Double = 0
    var obbWidthM: Double = 0
    var obbHeightM: Double = 0
    var heightfieldVolumeM3: Double
    var heightfieldSurfaceAreaM2: Double
    var convexHullVolumeM3: Double
    var convexHullSurfaceAreaM2: Double
    var metricsJSON: Data
    var plyData: Data?
    var usdzData: Data?
    var pointsJSON: Data = Data()

    init(
        objectName: String,
        pointCount: Int,
        processedPointCount: Int,
        targetPointCount: Int,
        clusterCount: Int,
        obbLengthM: Double,
        obbWidthM: Double,
        obbHeightM: Double,
        heightfieldVolumeM3: Double,
        heightfieldSurfaceAreaM2: Double,
        convexHullVolumeM3: Double,
        convexHullSurfaceAreaM2: Double,
        metricsJSON: Data,
        plyData: Data?,
        usdzData: Data?,
        pointsJSON: Data
    ) {
        self.id = UUID()
        self.objectName = objectName
        self.capturedAt = Date()
        self.pointCount = pointCount
        self.processedPointCount = processedPointCount
        self.targetPointCount = targetPointCount
        self.clusterCount = clusterCount
        self.obbLengthM = obbLengthM
        self.obbWidthM = obbWidthM
        self.obbHeightM = obbHeightM
        self.heightfieldVolumeM3 = heightfieldVolumeM3
        self.heightfieldSurfaceAreaM2 = heightfieldSurfaceAreaM2
        self.convexHullVolumeM3 = convexHullVolumeM3
        self.convexHullSurfaceAreaM2 = convexHullSurfaceAreaM2
        self.metricsJSON = metricsJSON
        self.plyData = plyData
        self.usdzData = usdzData
        self.pointsJSON = pointsJSON
    }
}
