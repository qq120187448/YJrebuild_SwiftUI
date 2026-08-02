import Foundation
import CoreMotion

struct MotionSnapshot: Sendable {
    let stepCount: Int
    let distanceMeters: Double
    let floorsAscended: Int
    let floorsDescended: Int
    let activities: [ActivityPeriod]

    struct ActivityPeriod: Sendable, Codable {
        let startDate: Date
        let endDate: Date
        let type: String
        let confidence: String
        var durationMinutes: Int {
            Int(endDate.timeIntervalSince(startDate) / 60)
        }
    }
}

enum MotionService {

    static let metersToMiles = 0.000621371

    // MARK: - Capture

    /// Captures motion data for the specified number of days back (default: 7).
    /// CoreMotion pedometer is limited to ~7 days on most devices.
    static func capture(daysBack: Int = 7) async throws -> MotionSnapshot {
        let pedometer = CMPedometer()
        let activityManager = CMMotionActivityManager()

        let calendar = Calendar.current
        let now = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) else {
            throw MotionError.invalidDateRange
        }
        let midnight = startDate

        let pedometerData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CMPedometerData, Error>) in
            pedometer.queryPedometerData(from: midnight, to: now) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: MotionError.noData)
                }
            }
        }

        let rawActivities = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CMMotionActivity], Error>) in
            activityManager.queryActivityStarting(from: midnight, to: now, to: .main) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let activities {
                    continuation.resume(returning: activities)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }

        let activities = consolidateActivities(rawActivities, endDate: now)

        return MotionSnapshot(
            stepCount: pedometerData.numberOfSteps.intValue,
            distanceMeters: pedometerData.distance?.doubleValue ?? 0,
            floorsAscended: pedometerData.floorsAscended?.intValue ?? 0,
            floorsDescended: pedometerData.floorsDescended?.intValue ?? 0,
            activities: activities
        )
    }

    // MARK: - Encoding

    static func encodeSnapshot(_ snapshot: MotionSnapshot) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let distanceMiles = snapshot.distanceMeters * metersToMiles

        let activitiesArray: [[String: Any]] = snapshot.activities.map { period in
            [
                "start_time": formatter.string(from: period.startDate),
                "end_time": formatter.string(from: period.endDate),
                "activity_type": period.type,
                "duration_minutes": period.durationMinutes,
                "confidence": period.confidence
            ] as [String: Any]
        }

        let dict: [String: Any] = [
            "captured_at": formatter.string(from: Date()),
            "period": "last 7 days",
            "pedometer": [
                "steps": snapshot.stepCount,
                "distance_meters": round(snapshot.distanceMeters * 100) / 100,
                "distance_miles": round(distanceMiles * 100) / 100,
                "floors_ascended": snapshot.floorsAscended,
                "floors_descended": snapshot.floorsDescended
            ],
            "activities": activitiesArray,
            "activity_count": snapshot.activities.count
        ]

        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Activity Consolidation

    /// Merges consecutive same-type activities and drops periods shorter than 5 minutes.
    private static func consolidateActivities(_ rawActivities: [CMMotionActivity], endDate: Date) -> [MotionSnapshot.ActivityPeriod] {
        guard !rawActivities.isEmpty else { return [] }
        let minDurationSeconds: TimeInterval = 5 * 60 // 5 minutes

        var consolidated: [MotionSnapshot.ActivityPeriod] = []
        var currentType = classifyActivity(rawActivities[0])
        var currentConfidence = confidenceString(rawActivities[0].confidence)
        var currentStart = rawActivities[0].startDate

        for i in 1..<rawActivities.count {
            let actType = classifyActivity(rawActivities[i])
            let actConf = confidenceString(rawActivities[i].confidence)
            let actStart = rawActivities[i].startDate

            if actType == currentType {
                // Merge: extend current period, keep best confidence
                if actConf == "high" || (actConf == "medium" && currentConfidence == "low") {
                    currentConfidence = actConf
                }
            } else {
                // End current period
                let duration = actStart.timeIntervalSince(currentStart)
                if duration >= minDurationSeconds && currentType != "unknown" {
                    consolidated.append(MotionSnapshot.ActivityPeriod(
                        startDate: currentStart,
                        endDate: actStart,
                        type: currentType,
                        confidence: currentConfidence
                    ))
                }
                currentType = actType
                currentConfidence = actConf
                currentStart = actStart
            }
        }

        // Close final period
        let finalDuration = endDate.timeIntervalSince(currentStart)
        if finalDuration >= minDurationSeconds && currentType != "unknown" {
            consolidated.append(MotionSnapshot.ActivityPeriod(
                startDate: currentStart,
                endDate: endDate,
                type: currentType,
                confidence: currentConfidence
            ))
        }

        return consolidated
    }

    // MARK: - Helpers

    private static func classifyActivity(_ activity: CMMotionActivity) -> String {
        if activity.walking { return "walking" }
        if activity.running { return "running" }
        if activity.automotive { return "automotive" }
        if activity.cycling { return "cycling" }
        if activity.stationary { return "stationary" }
        return "unknown"
    }

    private static func confidenceString(_ confidence: CMMotionActivityConfidence) -> String {
        switch confidence {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        @unknown default: return "unknown"
        }
    }
}

enum MotionError: LocalizedError {
    case invalidDateRange
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidDateRange: return "Could not determine today's date range."
        case .noData: return "No motion data available. Make sure Motion & Fitness is enabled in Settings."
        }
    }
}
