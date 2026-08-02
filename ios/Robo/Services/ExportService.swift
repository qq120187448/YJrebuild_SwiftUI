import Foundation
import RoomPlan

struct ExportableScan: Sendable {
    let barcodeValue: String
    let symbology: String
    let capturedAt: Date
    let foodName: String?
    let brandName: String?
    let calories: Double?
    let protein: Double?
    let totalFat: Double?
    let totalCarbs: Double?
    let dietaryFiber: Double?
    let sugars: Double?
    let sodium: Double?
    let servingQty: Double?
    let servingUnit: String?
    let servingWeightGrams: Double?
}

enum ExportService {
    /// Creates a ZIP file containing scans.json and scans.csv.
    static func createExportZip(scans: [ExportableScan]) throws -> URL {
        let fm = FileManager.default
        let exportDir = fm.temporaryDirectory
            .appendingPathComponent("robo-export-\(UUID().uuidString)")
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Write scans.json
        let jsonRecords: [[String: Any]] = scans.map { scan in
            var record: [String: Any] = [
                "value": scan.barcodeValue,
                "symbology": formatSymbology(scan.symbology),
                "scanned_at": formatter.string(from: scan.capturedAt)
            ]
            if let name = scan.foodName { record["food_name"] = name }
            if let brand = scan.brandName { record["brand_name"] = brand }
            if let cal = scan.calories { record["calories"] = cal }
            if let p = scan.protein { record["protein_g"] = p }
            if let f = scan.totalFat { record["total_fat_g"] = f }
            if let c = scan.totalCarbs { record["total_carbs_g"] = c }
            if let fiber = scan.dietaryFiber { record["dietary_fiber_g"] = fiber }
            if let s = scan.sugars { record["sugars_g"] = s }
            if let na = scan.sodium { record["sodium_mg"] = na }
            if let qty = scan.servingQty { record["serving_qty"] = qty }
            if let unit = scan.servingUnit { record["serving_unit"] = unit }
            if let wt = scan.servingWeightGrams { record["serving_weight_g"] = wt }
            return record
        }
        let jsonData = try JSONSerialization.data(
            withJSONObject: jsonRecords,
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: exportDir.appendingPathComponent("scans.json"))

        // Write scans.csv
        var csv = "value,symbology,scanned_at,food_name,brand_name,calories,protein_g,total_fat_g,total_carbs_g,dietary_fiber_g,sugars_g,sodium_mg,serving_qty,serving_unit,serving_weight_g\n"
        for scan in scans {
            let value = scan.barcodeValue.contains(",")
                ? "\"\(scan.barcodeValue)\""
                : scan.barcodeValue
            let name = csvField(scan.foodName)
            let brand = csvField(scan.brandName)
            let cal = scan.calories.map { String($0) } ?? ""
            let pro = scan.protein.map { String($0) } ?? ""
            let fat = scan.totalFat.map { String($0) } ?? ""
            let carb = scan.totalCarbs.map { String($0) } ?? ""
            let fiber = scan.dietaryFiber.map { String($0) } ?? ""
            let sugar = scan.sugars.map { String($0) } ?? ""
            let na = scan.sodium.map { String($0) } ?? ""
            let sQty = scan.servingQty.map { String($0) } ?? ""
            let sUnit = csvField(scan.servingUnit)
            let sWt = scan.servingWeightGrams.map { String($0) } ?? ""
            csv += "\(value),\(formatSymbology(scan.symbology)),\(formatter.string(from: scan.capturedAt)),\(name),\(brand),\(cal),\(pro),\(fat),\(carb),\(fiber),\(sugar),\(na),\(sQty),\(sUnit),\(sWt)\n"
        }
        try csv.write(
            to: exportDir.appendingPathComponent("scans.csv"),
            atomically: true,
            encoding: .utf8
        )

        // ZIP using NSFileCoordinator (zero dependencies)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let zipName = "robo-scans-\(dateFormatter.string(from: Date())).zip"
        let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)

        // Remove existing zip if present
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }

        var coordinatorError: NSError?
        var moveError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: exportDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                try fm.copyItem(at: tempZipURL, to: zipURL)
            } catch {
                moveError = error
            }
        }

        // Clean up export directory
        try? fm.removeItem(at: exportDir)

        if let coordinatorError {
            throw coordinatorError
        }
        if let moveError {
            throw moveError
        }

        return zipURL
    }

    // MARK: - Room Export

    /// Creates a ZIP file containing room_summary.json and room_full.json.
    static func createRoomExportZip(room: ExportableRoom) throws -> URL {
        let fm = FileManager.default
        let exportDir = fm.temporaryDirectory
            .appendingPathComponent("robo-room-\(UUID().uuidString)")
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        // Write room_summary.json
        let summaryData = try JSONSerialization.data(
            withJSONObject: room.summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        try summaryData.write(to: exportDir.appendingPathComponent("room_summary.json"))

        // Write room_full.json
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fullData = try encoder.encode(room.fullRoom)
        try fullData.write(to: exportDir.appendingPathComponent("room_full.json"))

        // Generate 2D floor plan SVG
        if let svg = FloorPlanSVGGenerator.generateSVG(from: room.summary, roomName: "") {
            try svg.write(
                to: exportDir.appendingPathComponent("floor_plan.svg"),
                atomically: true,
                encoding: .utf8
            )
        }

        // ZIP
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let zipName = "robo-room-\(dateFormatter.string(from: Date())).zip"
        let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)

        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }

        var coordinatorError: NSError?
        var moveError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: exportDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                try fm.copyItem(at: tempZipURL, to: zipURL)
            } catch {
                moveError = error
            }
        }

        try? fm.removeItem(at: exportDir)

        if let coordinatorError {
            throw coordinatorError
        }
        if let moveError {
            throw moveError
        }

        return zipURL
    }

    /// Creates a ZIP from already-serialized room data (for exporting from history).
    static func createRoomExportZipFromData(
        roomName: String,
        summaryJSON: Data,
        fullRoomDataJSON: Data
    ) throws -> URL {
        let fm = FileManager.default
        let exportDir = fm.temporaryDirectory
            .appendingPathComponent("robo-room-\(UUID().uuidString)")
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        // Enrich summary JSON with room_name for AI agent context
        if var summaryDict = try? JSONSerialization.jsonObject(with: summaryJSON) as? [String: Any] {
            summaryDict["room_name"] = roomName
            let enriched = try JSONSerialization.data(withJSONObject: summaryDict, options: [.prettyPrinted, .sortedKeys])
            try enriched.write(to: exportDir.appendingPathComponent("room_summary.json"))
        } else {
            try summaryJSON.write(to: exportDir.appendingPathComponent("room_summary.json"))
        }
        try fullRoomDataJSON.write(to: exportDir.appendingPathComponent("room_full.json"))

        // Generate 2D floor plan SVG if polygon data is available
        if let summaryDict = try? JSONSerialization.jsonObject(with: summaryJSON) as? [String: Any],
           let svg = FloorPlanSVGGenerator.generateSVG(from: summaryDict, roomName: roomName) {
            try svg.write(
                to: exportDir.appendingPathComponent("floor_plan.svg"),
                atomically: true,
                encoding: .utf8
            )
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let safeName = roomName.isEmpty ? "room" : sanitizeFilename(roomName)
        let zipName = "robo-\(safeName)-\(dateFormatter.string(from: Date())).zip"
        let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)

        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }

        var coordinatorError: NSError?
        var moveError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: exportDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                try fm.copyItem(at: tempZipURL, to: zipURL)
            } catch {
                moveError = error
            }
        }

        try? fm.removeItem(at: exportDir)

        if let coordinatorError { throw coordinatorError }
        if let moveError { throw moveError }

        return zipURL
    }

    // MARK: - Motion Export

    /// Creates a ZIP file containing motion_data.json.
    static func createMotionExportZip(activityJSON: Data) throws -> URL {
        let fm = FileManager.default
        let exportDir = fm.temporaryDirectory
            .appendingPathComponent("robo-motion-\(UUID().uuidString)")
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        try activityJSON.write(to: exportDir.appendingPathComponent("motion_data.json"))

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let zipName = "robo-motion-\(dateFormatter.string(from: Date())).zip"
        let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)

        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }

        var coordinatorError: NSError?
        var moveError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: exportDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                try fm.copyItem(at: tempZipURL, to: zipURL)
            } catch {
                moveError = error
            }
        }

        try? fm.removeItem(at: exportDir)

        if let coordinatorError { throw coordinatorError }
        if let moveError { throw moveError }

        return zipURL
    }

    // MARK: - Combined Export

    /// Creates a ZIP containing all barcodes, rooms, motion, and beacon data in subdirectories.
    static func createCombinedExportZip(
        scans: [ExportableScan],
        rooms: [(name: String, summaryJSON: Data, fullRoomDataJSON: Data)],
        motionRecords: [Data] = [],
        beaconEvents: [ExportableBeaconEvent] = []
    ) throws -> URL {
        let fm = FileManager.default
        let exportDir = fm.temporaryDirectory
            .appendingPathComponent("robo-combined-\(UUID().uuidString)")
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Barcodes subdirectory
        if !scans.isEmpty {
            let barcodesDir = exportDir.appendingPathComponent("barcodes")
            try fm.createDirectory(at: barcodesDir, withIntermediateDirectories: true)

            let jsonRecords: [[String: Any]] = scans.map { scan in
                var record: [String: Any] = [
                    "value": scan.barcodeValue,
                    "symbology": formatSymbology(scan.symbology),
                    "scanned_at": formatter.string(from: scan.capturedAt)
                ]
                if let name = scan.foodName { record["food_name"] = name }
                if let brand = scan.brandName { record["brand_name"] = brand }
                if let cal = scan.calories { record["calories"] = cal }
                if let p = scan.protein { record["protein_g"] = p }
                if let f = scan.totalFat { record["total_fat_g"] = f }
                if let c = scan.totalCarbs { record["total_carbs_g"] = c }
                if let fiber = scan.dietaryFiber { record["dietary_fiber_g"] = fiber }
                if let s = scan.sugars { record["sugars_g"] = s }
                if let na = scan.sodium { record["sodium_mg"] = na }
                if let qty = scan.servingQty { record["serving_qty"] = qty }
                if let unit = scan.servingUnit { record["serving_unit"] = unit }
                if let wt = scan.servingWeightGrams { record["serving_weight_g"] = wt }
                return record
            }
            let jsonData = try JSONSerialization.data(
                withJSONObject: jsonRecords,
                options: [.prettyPrinted, .sortedKeys]
            )
            try jsonData.write(to: barcodesDir.appendingPathComponent("scans.json"))

            var csv = "value,symbology,scanned_at,food_name,brand_name,calories,protein_g,total_fat_g,total_carbs_g,dietary_fiber_g,sugars_g,sodium_mg,serving_qty,serving_unit,serving_weight_g\n"
            for scan in scans {
                let value = scan.barcodeValue.contains(",")
                    ? "\"\(scan.barcodeValue)\""
                    : scan.barcodeValue
                let name = csvField(scan.foodName)
                let brand = csvField(scan.brandName)
                let cal = scan.calories.map { String($0) } ?? ""
                let pro = scan.protein.map { String($0) } ?? ""
                let fat = scan.totalFat.map { String($0) } ?? ""
                let carb = scan.totalCarbs.map { String($0) } ?? ""
                let fiber = scan.dietaryFiber.map { String($0) } ?? ""
                let sugar = scan.sugars.map { String($0) } ?? ""
                let na = scan.sodium.map { String($0) } ?? ""
                let sQty = scan.servingQty.map { String($0) } ?? ""
                let sUnit = csvField(scan.servingUnit)
                let sWt = scan.servingWeightGrams.map { String($0) } ?? ""
                csv += "\(value),\(formatSymbology(scan.symbology)),\(formatter.string(from: scan.capturedAt)),\(name),\(brand),\(cal),\(pro),\(fat),\(carb),\(fiber),\(sugar),\(na),\(sQty),\(sUnit),\(sWt)\n"
            }
            try csv.write(
                to: barcodesDir.appendingPathComponent("scans.csv"),
                atomically: true,
                encoding: .utf8
            )
        }

        // Rooms subdirectory
        if !rooms.isEmpty {
            let roomsDir = exportDir.appendingPathComponent("rooms")
            try fm.createDirectory(at: roomsDir, withIntermediateDirectories: true)

            var usedNames = Set<String>()
            for room in rooms {
                var safeName = room.name.isEmpty ? "room" : sanitizeFilename(room.name)

                // Handle duplicate names (keep within 60-char limit)
                let baseName = safeName
                var counter = 2
                while usedNames.contains(safeName) {
                    let suffix = "-\(counter)"
                    let maxBase = 60 - suffix.count
                    safeName = "\(String(baseName.prefix(maxBase)))\(suffix)"
                    counter += 1
                }
                usedNames.insert(safeName)

                let roomDir = roomsDir.appendingPathComponent(safeName)
                try fm.createDirectory(at: roomDir, withIntermediateDirectories: true)

                // Enrich summary JSON with room_name
                if var summaryDict = try? JSONSerialization.jsonObject(with: room.summaryJSON) as? [String: Any] {
                    summaryDict["room_name"] = room.name
                    let enriched = try JSONSerialization.data(withJSONObject: summaryDict, options: [.prettyPrinted, .sortedKeys])
                    try enriched.write(to: roomDir.appendingPathComponent("room_summary.json"))
                } else {
                    try room.summaryJSON.write(to: roomDir.appendingPathComponent("room_summary.json"))
                }
                try room.fullRoomDataJSON.write(to: roomDir.appendingPathComponent("room_full.json"))

                if let summaryDict = try? JSONSerialization.jsonObject(with: room.summaryJSON) as? [String: Any],
                   let svg = FloorPlanSVGGenerator.generateSVG(from: summaryDict, roomName: room.name) {
                    try svg.write(
                        to: roomDir.appendingPathComponent("floor_plan.svg"),
                        atomically: true,
                        encoding: .utf8
                    )
                }
            }
        }

        // Motion subdirectory
        if !motionRecords.isEmpty {
            let motionDir = exportDir.appendingPathComponent("motion")
            try fm.createDirectory(at: motionDir, withIntermediateDirectories: true)

            for (index, json) in motionRecords.enumerated() {
                let filename = motionRecords.count == 1
                    ? "motion_data.json"
                    : "motion_data_\(index + 1).json"
                try json.write(to: motionDir.appendingPathComponent(filename))
            }
        }

        // Beacons subdirectory
        if !beaconEvents.isEmpty {
            let beaconsDir = exportDir.appendingPathComponent("beacons")
            try fm.createDirectory(at: beaconsDir, withIntermediateDirectories: true)

            let jsonRecords: [[String: Any]] = beaconEvents.map { event in
                var record: [String: Any] = [
                    "event_type": event.eventType,
                    "beacon_minor": event.beaconMinor,
                    "source": event.source,
                    "webhook_status": event.webhookStatus,
                    "captured_at": formatter.string(from: event.capturedAt)
                ]
                if let name = event.roomName { record["room_name"] = name }
                if let prox = event.proximity { record["proximity"] = prox }
                if let rssi = event.rssi { record["rssi"] = rssi }
                if let dist = event.distanceMeters { record["distance_meters"] = dist }
                if let dur = event.durationSeconds { record["duration_seconds"] = dur }
                return record
            }
            let jsonData = try JSONSerialization.data(
                withJSONObject: jsonRecords,
                options: [.prettyPrinted, .sortedKeys]
            )
            try jsonData.write(to: beaconsDir.appendingPathComponent("beacon_events.json"))

            var csv = "event_type,beacon_minor,room_name,proximity,rssi,distance_meters,duration_seconds,source,webhook_status,captured_at\n"
            for event in beaconEvents {
                let room = csvField(event.roomName)
                let prox = csvField(event.proximity)
                let rssi = event.rssi.map { String($0) } ?? ""
                let dist = event.distanceMeters.map { String($0) } ?? ""
                let dur = event.durationSeconds.map { String($0) } ?? ""
                csv += "\(event.eventType),\(event.beaconMinor),\(room),\(prox),\(rssi),\(dist),\(dur),\(event.source),\(event.webhookStatus),\(formatter.string(from: event.capturedAt))\n"
            }
            try csv.write(
                to: beaconsDir.appendingPathComponent("beacon_events.csv"),
                atomically: true,
                encoding: .utf8
            )
        }

        // ZIP
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let zipName = "robo-export-\(dateFormatter.string(from: Date())).zip"
        let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)

        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }

        var coordinatorError: NSError?
        var moveError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: exportDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                try fm.copyItem(at: tempZipURL, to: zipURL)
            } catch {
                moveError = error
            }
        }

        try? fm.removeItem(at: exportDir)

        if let coordinatorError { throw coordinatorError }
        if let moveError { throw moveError }

        return zipURL
    }

    /// Sanitize a name for use in file/directory paths.
    /// Strips path traversal sequences, filesystem-hostile characters, and limits length.
    static func sanitizeFilename(_ name: String) -> String {
        // Strip control characters (NUL, tabs, newlines, DEL, etc.)
        var safe = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        safe = safe
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        safe = safe.replacingOccurrences(of: "/", with: "-")
        safe = safe.replacingOccurrences(of: "\\", with: "-")
        safe = safe.replacingOccurrences(of: ":", with: "-")
        safe = safe.replacingOccurrences(of: "*", with: "")
        safe = safe.replacingOccurrences(of: "?", with: "")
        safe = safe.replacingOccurrences(of: "\"", with: "")
        safe = safe.replacingOccurrences(of: "<", with: "")
        safe = safe.replacingOccurrences(of: ">", with: "")
        safe = safe.replacingOccurrences(of: "|", with: "")
        while safe.hasPrefix(".") { safe = String(safe.dropFirst()) }
        while safe.contains("--") {
            safe = safe.replacingOccurrences(of: "--", with: "-")
        }
        if safe.count > 60 { safe = String(safe.prefix(60)) }
        if safe.trimmingCharacters(in: .punctuationCharacters).isEmpty { safe = "room" }
        return safe
    }

    private static func formatSymbology(_ raw: String) -> String {
        raw.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
            .lowercased()
    }

    private static func csvField(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if value.contains(",") || value.contains("\"") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

struct ExportableRoom {
    let summary: [String: Any]
    let fullRoom: CapturedRoom
}

struct ExportableBeaconEvent: Sendable {
    let eventType: String
    let beaconMinor: Int
    let roomName: String?
    let proximity: String?
    let rssi: Int?
    let distanceMeters: Double?
    let durationSeconds: Int?
    let source: String
    let webhookStatus: String
    let capturedAt: Date
}
