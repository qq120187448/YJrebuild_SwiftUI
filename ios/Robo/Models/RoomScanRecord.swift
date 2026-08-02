import Foundation
import SwiftData

@Model
final class RoomScanRecord {
    var roomName: String
    var capturedAt: Date
    var wallCount: Int
    var doorCount: Int
    var windowCount: Int
    var openingCount: Int
    var objectCount: Int
    var floorAreaSqM: Double
    var ceilingHeightM: Double
    var totalWallAreaSqM: Double
    var volumeM3: Double
    var roomType: String = "其他"
    var summaryJSON: Data
    var fullRoomDataJSON: Data
    var quantityJSON: Data
    var usdzData: Data?
    var photoLabels: [String] = []
    var photoFileNames: [String] = []

    init(
        roomName: String,
        wallCount: Int,
        doorCount: Int,
        windowCount: Int,
        openingCount: Int,
        objectCount: Int,
        floorAreaSqM: Double,
        ceilingHeightM: Double,
        totalWallAreaSqM: Double,
        volumeM3: Double,
        roomType: String,
        summaryJSON: Data,
        fullRoomDataJSON: Data,
        quantityJSON: Data,
        usdzData: Data? = nil,
        photoLabels: [String] = [],
        photoFileNames: [String] = []
    ) {
        self.roomName = roomName
        self.capturedAt = Date()
        self.wallCount = wallCount
        self.doorCount = doorCount
        self.windowCount = windowCount
        self.openingCount = openingCount
        self.objectCount = objectCount
        self.floorAreaSqM = floorAreaSqM
        self.ceilingHeightM = ceilingHeightM
        self.totalWallAreaSqM = totalWallAreaSqM
        self.volumeM3 = volumeM3
        self.roomType = roomType
        self.summaryJSON = summaryJSON
        self.fullRoomDataJSON = fullRoomDataJSON
        self.quantityJSON = quantityJSON
        self.usdzData = usdzData
        self.photoLabels = photoLabels
        self.photoFileNames = photoFileNames
    }
}
