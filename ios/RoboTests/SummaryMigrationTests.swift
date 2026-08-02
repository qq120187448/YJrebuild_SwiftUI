import Testing
import Foundation
import SwiftData
import RoomPlan
@testable import Robo

// MARK: - Version Checks (always run, no fixture needed)

@Test func migrationNeededWhenVersionIsZero() {
    let defaults = UserDefaults(suiteName: "test.migration.\(UUID().uuidString)")!
    #expect(SummaryMigrationService.needsMigration(defaults: defaults) == true)
}

@Test func migrationNotNeededWhenVersionIsCurrent() {
    let defaults = UserDefaults(suiteName: "test.migration.\(UUID().uuidString)")!
    defaults.set(SummaryMigrationService.currentVersion, forKey: SummaryMigrationService.versionKey)
    #expect(SummaryMigrationService.needsMigration(defaults: defaults) == false)
}

// MARK: - Fixture-Dependent Tests (skip gracefully if no fixture)

private class BundleToken {}

private func loadFixture() -> Data? {
    let bundle = Bundle(for: BundleToken.self)
    guard let url = bundle.url(forResource: "captured_room_fixture", withExtension: "json") else {
        return nil
    }
    return try? Data(contentsOf: url)
}

@Test func capturedRoomRoundTripEncodeDecode() throws {
    guard let fixtureData = loadFixture() else {
        print("Skipping: no captured_room_fixture.json in test bundle")
        return
    }

    let room = try JSONDecoder().decode(CapturedRoom.self, from: fixtureData)
    let summary = RoomDataProcessor.summarizeRoom(room)

    let floorArea = summary["estimated_floor_area_sqm"] as? Double ?? 0
    #expect(floorArea > 0, "Floor area should be non-zero after bug fix")

    let wallCount = summary["wall_count"] as? Int ?? 0
    #expect(wallCount > 0, "Should detect at least one wall")
}

@Test func migrationReprocessesStaleRecords() throws {
    guard let fixtureData = loadFixture() else {
        print("Skipping: no captured_room_fixture.json in test bundle")
        return
    }

    // Isolated UserDefaults for this test
    let defaults = UserDefaults(suiteName: "test.migration.\(UUID().uuidString)")!

    // Set up in-memory container
    let schema = Schema(versionedSchema: RoboSchemaV1.self)
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let context = ModelContext(container)

    // Insert a record with stale summary (zero floor area)
    let staleSummary: [String: Any] = ["estimated_floor_area_sqm": 0.0, "wall_count": 0]
    let staleSummaryData = try JSONSerialization.data(withJSONObject: staleSummary)

    let record = RoomScanRecord(
        roomName: "Test Room",
        wallCount: 0,
        floorAreaSqM: 0,
        objectCount: 0,
        summaryJSON: staleSummaryData,
        fullRoomDataJSON: fixtureData
    )
    context.insert(record)
    try context.save()

    // Run migration (version is 0 in fresh defaults → triggers migration)
    SummaryMigrationService.migrateIfNeeded(container: container, defaults: defaults)

    // Fetch and verify
    let fetched = try context.fetch(FetchDescriptor<RoomScanRecord>())
    let migrated = fetched.first!
    #expect(migrated.floorAreaSqM > 0, "Floor area should be updated after migration")
    #expect(migrated.wallCount > 0, "Wall count should be updated after migration")
}
