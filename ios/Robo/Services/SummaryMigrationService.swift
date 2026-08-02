import Foundation
import SwiftData
import RoomPlan

/// Re-derives summaryJSON from raw CapturedRoom data when the summary format changes.
/// Uses UserDefaults versioning instead of SwiftData schema migration to avoid complexity.
enum SummaryMigrationService {

    static let currentVersion = 1

    static let versionKey = "room.summaryVersion"

    static func needsMigration(defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: versionKey) < currentVersion
    }

    /// Run at app launch. Creates its own ModelContext so it's independent of views.
    static func migrateIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard needsMigration(defaults: defaults) else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RoomScanRecord>()

        do {
            let records = try context.fetch(descriptor)
            var updated = 0
            for record in records {
                if reprocessRecord(record) {
                    updated += 1
                }
            }
            if updated > 0 {
                try context.save()
            }
            defaults.set(currentVersion, forKey: versionKey)
            #if DEBUG
            print("[SummaryMigration] Migrated \(updated)/\(records.count) records to v\(currentVersion)")
            #endif
        } catch {
            #if DEBUG
            print("[SummaryMigration] Migration failed: \(error)")
            #endif
        }
    }

    /// Decode fullRoomDataJSON → CapturedRoom, re-run summarizeRoom, update fields.
    /// Returns true if the record was updated.
    @discardableResult
    static func reprocessRecord(_ record: RoomScanRecord) -> Bool {
        do {
            let room = try JSONDecoder().decode(CapturedRoom.self, from: record.fullRoomDataJSON)
            let summary = RoomDataProcessor.summarizeRoom(room)
            let summaryData = try RoomDataProcessor.encodeSummary(summary)

            record.summaryJSON = summaryData
            record.floorAreaSqM = summary["estimated_floor_area_sqm"] as? Double ?? 0
            record.ceilingHeightM = summary["ceiling_height_m"] as? Double ?? 0
            record.wallCount = summary["wall_count"] as? Int ?? 0
            record.objectCount = summary["object_count"] as? Int ?? 0
            return true
        } catch {
            #if DEBUG
            print("[SummaryMigration] Failed to reprocess '\(record.roomName)': \(error)")
            #endif
            return false
        }
    }
}
