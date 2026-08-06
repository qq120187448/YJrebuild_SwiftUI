import Foundation
import SwiftData

@Model
final class TextureScanRecord {
    var scanID: UUID
    var capturedAt: Date
    var deviceModel: String
    var deviceMaxResolution: String
    var photoCount: Int
    var closeUpCount: Int
    var wallCount: Int
    var atlasSize: Int
    var duration: Double
    var outputDirectoryPath: String
    var usdzPath: String
    var objPath: String
    var plyPath: String
    var jsonPath: String
    var texturePaths: [String]

    init(
        scanID: UUID,
        capturedAt: Date,
        deviceModel: String,
        deviceMaxResolution: String,
        photoCount: Int,
        closeUpCount: Int,
        wallCount: Int,
        atlasSize: Int,
        duration: Double,
        outputDirectoryPath: String,
        usdzPath: String,
        objPath: String,
        plyPath: String,
        jsonPath: String,
        texturePaths: [String]
    ) {
        self.scanID = scanID
        self.capturedAt = capturedAt
        self.deviceModel = deviceModel
        self.deviceMaxResolution = deviceMaxResolution
        self.photoCount = photoCount
        self.closeUpCount = closeUpCount
        self.wallCount = wallCount
        self.atlasSize = atlasSize
        self.duration = duration
        self.outputDirectoryPath = outputDirectoryPath
        self.usdzPath = usdzPath
        self.objPath = objPath
        self.plyPath = plyPath
        self.jsonPath = jsonPath
        self.texturePaths = texturePaths
    }
}
