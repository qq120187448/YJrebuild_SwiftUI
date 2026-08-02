import Foundation
import HealthKit

/// Captures sleep, workout, and activity data from HealthKit.
/// Requests only non-medical data types (no heart rate, blood pressure, etc.).
enum HealthKitService {

    static let store = HKHealthStore()

    // MARK: - Authorization

    /// Types we read from HealthKit. No write access requested.
    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        types.insert(HKObjectType.workoutType())
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(energy)
        }
        if let exercise = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) {
            types.insert(exercise)
        }
        return types
    }

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    static func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    // MARK: - Data Capture

    /// Captures all health data for the last `days` days.
    static func capture(daysBack: Int = 30) async throws -> HealthSnapshot {
        let calendar = Calendar.current
        let now = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) else {
            throw HealthError.invalidDateRange
        }

        async let sleepData = querySleep(from: startDate, to: now)
        async let workoutData = queryWorkouts(from: startDate, to: now)
        async let activityData = queryActivity(from: startDate, to: now)

        return try await HealthSnapshot(
            sleep: sleepData,
            workouts: workoutData,
            activity: activityData,
            dateRangeStart: startDate,
            dateRangeEnd: now
        )
    }

    // MARK: - Sleep

    private static func querySleep(from start: Date, to end: Date) async throws -> [HealthSnapshot.SleepEntry] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let entries = (samples as? [HKCategorySample] ?? []).compactMap { sample -> HealthSnapshot.SleepEntry? in
                    let value = HKCategoryValueSleepAnalysis(rawValue: sample.value)
                    let stage: String
                    switch value {
                    case .inBed: stage = "in_bed"
                    case .asleepUnspecified: stage = "asleep"
                    case .asleepCore: stage = "core_sleep"
                    case .asleepDeep: stage = "deep_sleep"
                    case .asleepREM: stage = "rem_sleep"
                    case .awake: stage = "awake"
                    default: stage = "unknown"
                    }
                    return HealthSnapshot.SleepEntry(
                        startDate: sample.startDate,
                        endDate: sample.endDate,
                        stage: stage,
                        durationMinutes: sample.endDate.timeIntervalSince(sample.startDate) / 60
                    )
                }
                continuation.resume(returning: entries)
            }
            store.execute(query)
        }
    }

    // MARK: - Workouts

    private static func queryWorkouts(from start: Date, to end: Date) async throws -> [HealthSnapshot.WorkoutEntry] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let entries = (samples as? [HKWorkout] ?? []).map { workout in
                    HealthSnapshot.WorkoutEntry(
                        startDate: workout.startDate,
                        endDate: workout.endDate,
                        activityType: workoutTypeName(workout.workoutActivityType),
                        durationMinutes: workout.duration / 60,
                        totalEnergyBurnedKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter())
                    )
                }
                continuation.resume(returning: entries)
            }
            store.execute(query)
        }
    }

    // MARK: - Activity (Steps, Calories, Exercise)

    private static func queryActivity(from start: Date, to end: Date) async throws -> [HealthSnapshot.DailyActivity] {
        let calendar = Calendar.current
        var dailyData: [Date: HealthSnapshot.DailyActivity] = [:]

        // Initialize all days in range
        var current = calendar.startOfDay(for: start)
        while current <= end {
            dailyData[current] = HealthSnapshot.DailyActivity(
                date: current,
                steps: 0,
                activeCalories: 0,
                exerciseMinutes: 0
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        // Query steps
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let steps = try await queryDailySums(type: stepType, unit: .count(), from: start, to: end)
            for (date, value) in steps {
                dailyData[date]?.steps = Int(value)
            }
        }

        // Query active calories
        if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let cals = try await queryDailySums(type: energyType, unit: .kilocalorie(), from: start, to: end)
            for (date, value) in cals {
                dailyData[date]?.activeCalories = value
            }
        }

        // Query exercise minutes
        if let exerciseType = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) {
            let mins = try await queryDailySums(type: exerciseType, unit: .minute(), from: start, to: end)
            for (date, value) in mins {
                dailyData[date]?.exerciseMinutes = value
            }
        }

        return dailyData.values.sorted { $0.date > $1.date }
    }

    private static func queryDailySums(type: HKQuantityType, unit: HKUnit, from start: Date, to end: Date) async throws -> [(Date, Double)] {
        let calendar = Calendar.current
        let interval = DateComponents(day: 1)
        let anchorDate = calendar.startOfDay(for: start)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var sums: [(Date, Double)] = []
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let value = stats.sumQuantity()?.doubleValue(for: unit) ?? 0
                    sums.append((calendar.startOfDay(for: stats.startDate), value))
                }
                continuation.resume(returning: sums)
            }

            store.execute(query)
        }
    }

    // MARK: - Helpers

    private static func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .hiking: return "Hiking"
        case .dance: return "Dance"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stair Climbing"
        case .coreTraining: return "Core Training"
        case .pilates: return "Pilates"
        default: return "Workout"
        }
    }
}

// MARK: - Health Snapshot

struct HealthSnapshot: Sendable {
    let sleep: [SleepEntry]
    let workouts: [WorkoutEntry]
    let activity: [DailyActivity]
    let dateRangeStart: Date
    let dateRangeEnd: Date

    struct SleepEntry: Sendable, Codable {
        let startDate: Date
        let endDate: Date
        let stage: String
        let durationMinutes: Double
    }

    struct WorkoutEntry: Sendable, Codable {
        let startDate: Date
        let endDate: Date
        let activityType: String
        let durationMinutes: Double
        let totalEnergyBurnedKcal: Double?
        let totalDistanceMeters: Double?
    }

    struct DailyActivity: Sendable, Codable {
        let date: Date
        var steps: Int
        var activeCalories: Double
        var exerciseMinutes: Double
    }
}

enum HealthError: LocalizedError {
    case invalidDateRange
    case notAvailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .invalidDateRange: return "Could not determine date range for health data."
        case .notAvailable: return "HealthKit is not available on this device."
        case .authorizationDenied: return "Health data access was denied. Enable it in Settings > Privacy > Health."
        }
    }
}
