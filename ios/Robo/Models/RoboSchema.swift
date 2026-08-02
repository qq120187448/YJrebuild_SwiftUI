import Foundation
import SwiftData

// MARK: - Schema V1 (initial release)
// All model definitions live here as the single source of truth.
// When you need to change a model, create V2 and add a migration stage.

enum RoboSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self]
    }

    @Model
    final class ScanRecord {
        var barcodeValue: String
        var symbology: String
        var capturedAt: Date

        init(barcodeValue: String, symbology: String) {
            self.barcodeValue = barcodeValue
            self.symbology = symbology
            self.capturedAt = Date()
        }
    }

    @Model
    final class RoomScanRecord {
        var roomName: String
        var capturedAt: Date
        var wallCount: Int
        var floorAreaSqM: Double
        var ceilingHeightM: Double
        var objectCount: Int
        var summaryJSON: Data
        var fullRoomDataJSON: Data

        init(
            roomName: String,
            wallCount: Int,
            floorAreaSqM: Double,
            ceilingHeightM: Double = 0,
            objectCount: Int,
            summaryJSON: Data,
            fullRoomDataJSON: Data
        ) {
            self.roomName = roomName
            self.capturedAt = Date()
            self.wallCount = wallCount
            self.floorAreaSqM = floorAreaSqM
            self.ceilingHeightM = ceilingHeightM
            self.objectCount = objectCount
            self.summaryJSON = summaryJSON
            self.fullRoomDataJSON = fullRoomDataJSON
        }
    }
}

// MARK: - Schema V2 (motion sensor)

enum RoboSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self]
    }

    @Model
    final class ScanRecord {
        var barcodeValue: String
        var symbology: String
        var capturedAt: Date

        init(barcodeValue: String, symbology: String) {
            self.barcodeValue = barcodeValue
            self.symbology = symbology
            self.capturedAt = Date()
        }
    }

    @Model
    final class RoomScanRecord {
        var roomName: String
        var capturedAt: Date
        var wallCount: Int
        var floorAreaSqM: Double
        var ceilingHeightM: Double
        var objectCount: Int
        var summaryJSON: Data
        var fullRoomDataJSON: Data

        init(
            roomName: String,
            wallCount: Int,
            floorAreaSqM: Double,
            ceilingHeightM: Double = 0,
            objectCount: Int,
            summaryJSON: Data,
            fullRoomDataJSON: Data
        ) {
            self.roomName = roomName
            self.capturedAt = Date()
            self.wallCount = wallCount
            self.floorAreaSqM = floorAreaSqM
            self.ceilingHeightM = ceilingHeightM
            self.objectCount = objectCount
            self.summaryJSON = summaryJSON
            self.fullRoomDataJSON = fullRoomDataJSON
        }
    }

    @Model
    final class MotionRecord {
        var capturedAt: Date
        var stepCount: Int
        var distanceMeters: Double
        var floorsAscended: Int
        var floorsDescended: Int
        var activityJSON: Data

        init(
            stepCount: Int,
            distanceMeters: Double,
            floorsAscended: Int,
            floorsDescended: Int,
            activityJSON: Data
        ) {
            self.capturedAt = Date()
            self.stepCount = stepCount
            self.distanceMeters = distanceMeters
            self.floorsAscended = floorsAscended
            self.floorsDescended = floorsDescended
            self.activityJSON = activityJSON
        }
    }
}

// MARK: - Schema V3 (nutrition data on barcodes)

enum RoboSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self]
    }

    @Model
    final class ScanRecord {
        var barcodeValue: String
        var symbology: String
        var capturedAt: Date

        // Nutrition fields (all optional for lightweight migration)
        var foodName: String?
        var brandName: String?
        var calories: Double?
        var protein: Double?
        var totalFat: Double?
        var totalCarbs: Double?
        var dietaryFiber: Double?
        var sugars: Double?
        var sodium: Double?
        var servingQty: Double?
        var servingUnit: String?
        var servingWeightGrams: Double?
        var photoThumbURL: String?
        var photoHighresURL: String?
        var nutritionJSON: Data?
        var nutritionLookedUp: Bool = false

        init(barcodeValue: String, symbology: String) {
            self.barcodeValue = barcodeValue
            self.symbology = symbology
            self.capturedAt = Date()
        }
    }

    @Model
    final class RoomScanRecord {
        var roomName: String
        var capturedAt: Date
        var wallCount: Int
        var floorAreaSqM: Double
        var ceilingHeightM: Double
        var objectCount: Int
        var summaryJSON: Data
        var fullRoomDataJSON: Data

        init(
            roomName: String,
            wallCount: Int,
            floorAreaSqM: Double,
            ceilingHeightM: Double = 0,
            objectCount: Int,
            summaryJSON: Data,
            fullRoomDataJSON: Data
        ) {
            self.roomName = roomName
            self.capturedAt = Date()
            self.wallCount = wallCount
            self.floorAreaSqM = floorAreaSqM
            self.ceilingHeightM = ceilingHeightM
            self.objectCount = objectCount
            self.summaryJSON = summaryJSON
            self.fullRoomDataJSON = fullRoomDataJSON
        }
    }

    @Model
    final class MotionRecord {
        var capturedAt: Date
        var stepCount: Int
        var distanceMeters: Double
        var floorsAscended: Int
        var floorsDescended: Int
        var activityJSON: Data

        init(
            stepCount: Int,
            distanceMeters: Double,
            floorsAscended: Int,
            floorsDescended: Int,
            activityJSON: Data
        ) {
            self.capturedAt = Date()
            self.stepCount = stepCount
            self.distanceMeters = distanceMeters
            self.floorsAscended = floorsAscended
            self.floorsDescended = floorsDescended
            self.activityJSON = activityJSON
        }
    }
}

// MARK: - Schema V4 (agent linkage)

enum RoboSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self]
    }

    @Model
    final class ScanRecord {
        var barcodeValue: String
        var symbology: String
        var capturedAt: Date

        // Nutrition fields
        var foodName: String?
        var brandName: String?
        var calories: Double?
        var protein: Double?
        var totalFat: Double?
        var totalCarbs: Double?
        var dietaryFiber: Double?
        var sugars: Double?
        var sodium: Double?
        var servingQty: Double?
        var servingUnit: String?
        var servingWeightGrams: Double?
        var photoThumbURL: String?
        var photoHighresURL: String?
        var nutritionJSON: Data?
        var nutritionLookedUp: Bool = false

        // Agent linkage (V4)
        var agentId: String?
        var agentName: String?

        init(barcodeValue: String, symbology: String) {
            self.barcodeValue = barcodeValue
            self.symbology = symbology
            self.capturedAt = Date()
        }
    }

    @Model
    final class RoomScanRecord {
        var roomName: String
        var capturedAt: Date
        var wallCount: Int
        var floorAreaSqM: Double
        var ceilingHeightM: Double
        var objectCount: Int
        var summaryJSON: Data
        var fullRoomDataJSON: Data

        // Agent linkage (V4)
        var agentId: String?
        var agentName: String?

        init(
            roomName: String,
            wallCount: Int,
            floorAreaSqM: Double,
            ceilingHeightM: Double = 0,
            objectCount: Int,
            summaryJSON: Data,
            fullRoomDataJSON: Data
        ) {
            self.roomName = roomName
            self.capturedAt = Date()
            self.wallCount = wallCount
            self.floorAreaSqM = floorAreaSqM
            self.ceilingHeightM = ceilingHeightM
            self.objectCount = objectCount
            self.summaryJSON = summaryJSON
            self.fullRoomDataJSON = fullRoomDataJSON
        }
    }

    @Model
    final class MotionRecord {
        var capturedAt: Date
        var stepCount: Int
        var distanceMeters: Double
        var floorsAscended: Int
        var floorsDescended: Int
        var activityJSON: Data

        // Agent linkage (V4)
        var agentId: String?
        var agentName: String?

        init(
            stepCount: Int,
            distanceMeters: Double,
            floorsAscended: Int,
            floorsDescended: Int,
            activityJSON: Data
        ) {
            self.capturedAt = Date()
            self.stepCount = stepCount
            self.distanceMeters = distanceMeters
            self.floorsAscended = floorsAscended
            self.floorsDescended = floorsDescended
            self.activityJSON = activityJSON
        }
    }
}

// MARK: - Schema V5 (agent completion records)

enum RoboSchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self, AgentCompletionRecord.self]
    }

    // Re-export V4 models unchanged
    typealias ScanRecord = RoboSchemaV4.ScanRecord
    typealias RoomScanRecord = RoboSchemaV4.RoomScanRecord
    typealias MotionRecord = RoboSchemaV4.MotionRecord

    @Model
    final class AgentCompletionRecord {
        var agentId: String
        var agentName: String
        var requestId: String
        var skillType: String
        var itemCount: Int
        var completedAt: Date

        init(
            agentId: String,
            agentName: String,
            requestId: String,
            skillType: String,
            itemCount: Int
        ) {
            self.agentId = agentId
            self.agentName = agentName
            self.requestId = requestId
            self.skillType = skillType
            self.itemCount = itemCount
            self.completedAt = Date()
        }
    }
}

// MARK: - Schema V6 (product capture with photos)

enum RoboSchemaV6: VersionedSchema {
    static var versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self,
         AgentCompletionRecord.self, ProductCaptureRecord.self]
    }

    // Re-export V5 models unchanged
    typealias ScanRecord = RoboSchemaV4.ScanRecord
    typealias RoomScanRecord = RoboSchemaV4.RoomScanRecord
    typealias MotionRecord = RoboSchemaV4.MotionRecord
    typealias AgentCompletionRecord = RoboSchemaV5.AgentCompletionRecord

    @Model
    final class ProductCaptureRecord {
        var id: UUID
        var barcodeValue: String?
        var symbology: String?
        var photoFileNamesJSON: String
        var photoCount: Int
        var capturedAt: Date
        var agentId: String?
        var agentName: String?
        var requestId: String?
        var foodName: String?
        var brandName: String?
        var calories: Double?
        var photoThumbURL: String?
        var nutritionLookedUp: Bool

        init(
            barcodeValue: String? = nil,
            symbology: String? = nil,
            photoFileNames: [String],
            agentId: String? = nil,
            agentName: String? = nil,
            requestId: String? = nil
        ) {
            self.id = UUID()
            self.barcodeValue = barcodeValue
            self.symbology = symbology
            self.photoFileNamesJSON = (try? JSONEncoder().encode(photoFileNames))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            self.photoCount = photoFileNames.count
            self.capturedAt = Date()
            self.agentId = agentId
            self.agentName = agentName
            self.requestId = requestId
            self.nutritionLookedUp = false
        }

        var photoFileNames: [String] {
            guard let data = photoFileNamesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
    }
}

// MARK: - Schema V7 (beacon events)

enum RoboSchemaV7: VersionedSchema {
    static var versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self,
         AgentCompletionRecord.self, ProductCaptureRecord.self, BeaconEventRecord.self]
    }

    // Re-export V6 models unchanged
    typealias ScanRecord = RoboSchemaV4.ScanRecord
    typealias RoomScanRecord = RoboSchemaV4.RoomScanRecord
    typealias MotionRecord = RoboSchemaV4.MotionRecord
    typealias AgentCompletionRecord = RoboSchemaV5.AgentCompletionRecord
    typealias ProductCaptureRecord = RoboSchemaV6.ProductCaptureRecord

    @Model
    final class BeaconEventRecord {
        var eventType: String          // "enter" or "exit"
        var beaconMinor: Int           // Minor value (room ID)
        var roomName: String?          // User-assigned name
        var proximity: String?         // "immediate", "near", "far"
        var rssi: Int?                 // Raw signal strength
        var distanceMeters: Double?    // Estimated distance
        var durationSeconds: Int?      // Only on exit events
        var source: String             // "background_monitor" or "foreground_ranging"
        var webhookStatus: String      // "pending", "sent", "failed"
        var webhookURL: String?        // Where it was sent
        var capturedAt: Date
        var agentId: String?
        var agentName: String?

        init(
            eventType: String,
            beaconMinor: Int,
            roomName: String? = nil,
            proximity: String? = nil,
            rssi: Int? = nil,
            distanceMeters: Double? = nil,
            durationSeconds: Int? = nil,
            source: String,
            webhookStatus: String = "pending",
            webhookURL: String? = nil
        ) {
            self.eventType = eventType
            self.beaconMinor = beaconMinor
            self.roomName = roomName
            self.proximity = proximity
            self.rssi = rssi
            self.distanceMeters = distanceMeters
            self.durationSeconds = durationSeconds
            self.source = source
            self.webhookStatus = webhookStatus
            self.webhookURL = webhookURL
            self.capturedAt = Date()
        }
    }
}

// MARK: - Schema V8 (health records)

enum RoboSchemaV8: VersionedSchema {
    static var versionIdentifier = Schema.Version(8, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self,
         AgentCompletionRecord.self, ProductCaptureRecord.self,
         BeaconEventRecord.self, HealthRecord.self]
    }

    // Re-export V7 models unchanged
    typealias ScanRecord = RoboSchemaV4.ScanRecord
    typealias RoomScanRecord = RoboSchemaV4.RoomScanRecord
    typealias MotionRecord = RoboSchemaV4.MotionRecord
    typealias AgentCompletionRecord = RoboSchemaV5.AgentCompletionRecord
    typealias ProductCaptureRecord = RoboSchemaV6.ProductCaptureRecord
    typealias BeaconEventRecord = RoboSchemaV7.BeaconEventRecord

    @Model
    final class HealthRecord {
        var capturedAt: Date
        var dataType: String               // "sleep", "workout", "activity", or "combined"
        var dateRangeStart: Date
        var dateRangeEnd: Date
        var summaryJSON: Data              // Encoded HealthSummaryExport
        var sleepEntryCount: Int
        var workoutCount: Int
        var totalSteps: Int
        var agentId: String?
        var agentName: String?

        init(
            dataType: String,
            dateRangeStart: Date,
            dateRangeEnd: Date,
            summaryJSON: Data,
            sleepEntryCount: Int = 0,
            workoutCount: Int = 0,
            totalSteps: Int = 0
        ) {
            self.capturedAt = Date()
            self.dataType = dataType
            self.dateRangeStart = dateRangeStart
            self.dateRangeEnd = dateRangeEnd
            self.summaryJSON = summaryJSON
            self.sleepEntryCount = sleepEntryCount
            self.workoutCount = workoutCount
            self.totalSteps = totalSteps
        }
    }
}

// MARK: - Schema V9 (USDZ data for 3D room view)

enum RoboSchemaV9: VersionedSchema {
    static var versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self,
         AgentCompletionRecord.self, ProductCaptureRecord.self,
         BeaconEventRecord.self, HealthRecord.self]
    }

    // Re-export V8 models unchanged
    typealias ScanRecord = RoboSchemaV4.ScanRecord
    typealias MotionRecord = RoboSchemaV4.MotionRecord
    typealias AgentCompletionRecord = RoboSchemaV5.AgentCompletionRecord
    typealias ProductCaptureRecord = RoboSchemaV6.ProductCaptureRecord
    typealias BeaconEventRecord = RoboSchemaV7.BeaconEventRecord
    typealias HealthRecord = RoboSchemaV8.HealthRecord

    @Model
    final class RoomScanRecord {
        var roomName: String
        var capturedAt: Date
        var wallCount: Int
        var floorAreaSqM: Double
        var ceilingHeightM: Double
        var objectCount: Int
        var summaryJSON: Data
        var fullRoomDataJSON: Data

        // Agent linkage (V4)
        var agentId: String?
        var agentName: String?

        // USDZ 3D model data (V9)
        var usdzData: Data?

        init(
            roomName: String,
            wallCount: Int,
            floorAreaSqM: Double,
            ceilingHeightM: Double = 0,
            objectCount: Int,
            summaryJSON: Data,
            fullRoomDataJSON: Data
        ) {
            self.roomName = roomName
            self.capturedAt = Date()
            self.wallCount = wallCount
            self.floorAreaSqM = floorAreaSqM
            self.ceilingHeightM = ceilingHeightM
            self.objectCount = objectCount
            self.summaryJSON = summaryJSON
            self.fullRoomDataJSON = fullRoomDataJSON
        }
    }
}

// MARK: - Schema V10 (external upload tracking on agent completions)

enum RoboSchemaV10: VersionedSchema {
    static var versionIdentifier = Schema.Version(10, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ScanRecord.self, RoomScanRecord.self, MotionRecord.self,
         AgentCompletionRecord.self, ProductCaptureRecord.self,
         BeaconEventRecord.self, HealthRecord.self]
    }

    // Re-export V9 models unchanged
    typealias ScanRecord = RoboSchemaV4.ScanRecord
    typealias RoomScanRecord = RoboSchemaV9.RoomScanRecord
    typealias MotionRecord = RoboSchemaV4.MotionRecord
    typealias ProductCaptureRecord = RoboSchemaV6.ProductCaptureRecord
    typealias BeaconEventRecord = RoboSchemaV7.BeaconEventRecord
    typealias HealthRecord = RoboSchemaV8.HealthRecord

    @Model
    final class AgentCompletionRecord {
        var agentId: String
        var agentName: String
        var requestId: String
        var skillType: String
        var itemCount: Int
        var completedAt: Date

        // V10: External service URL and photo filenames for upload tracking
        var albumURL: String?
        var photoFilenamesJSON: String?

        init(
            agentId: String,
            agentName: String,
            requestId: String,
            skillType: String,
            itemCount: Int
        ) {
            self.agentId = agentId
            self.agentName = agentName
            self.requestId = requestId
            self.skillType = skillType
            self.itemCount = itemCount
            self.completedAt = Date()
        }

        var photoFilenames: [String] {
            guard let json = photoFilenamesJSON,
                  let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
    }
}

// MARK: - Migration Plan

enum RoboMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [RoboSchemaV1.self, RoboSchemaV2.self, RoboSchemaV3.self,
         RoboSchemaV4.self, RoboSchemaV5.self, RoboSchemaV6.self,
         RoboSchemaV7.self, RoboSchemaV8.self, RoboSchemaV9.self,
         RoboSchemaV10.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5,
         migrateV5toV6, migrateV6toV7, migrateV7toV8, migrateV8toV9,
         migrateV9toV10]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV1.self,
        toVersion: RoboSchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV2.self,
        toVersion: RoboSchemaV3.self
    )

    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV3.self,
        toVersion: RoboSchemaV4.self
    )

    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV4.self,
        toVersion: RoboSchemaV5.self
    )

    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV5.self,
        toVersion: RoboSchemaV6.self
    )

    static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV6.self,
        toVersion: RoboSchemaV7.self
    )

    static let migrateV7toV8 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV7.self,
        toVersion: RoboSchemaV8.self
    )

    static let migrateV8toV9 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV8.self,
        toVersion: RoboSchemaV9.self
    )

    static let migrateV9toV10 = MigrationStage.lightweight(
        fromVersion: RoboSchemaV9.self,
        toVersion: RoboSchemaV10.self
    )
}

// MARK: - Type Aliases (so the rest of the app uses simple names)

typealias ScanRecord = RoboSchemaV10.ScanRecord
typealias RoomScanRecord = RoboSchemaV10.RoomScanRecord
typealias MotionRecord = RoboSchemaV10.MotionRecord
typealias AgentCompletionRecord = RoboSchemaV10.AgentCompletionRecord
typealias ProductCaptureRecord = RoboSchemaV10.ProductCaptureRecord
typealias BeaconEventRecord = RoboSchemaV10.BeaconEventRecord
typealias HealthRecord = RoboSchemaV10.HealthRecord
