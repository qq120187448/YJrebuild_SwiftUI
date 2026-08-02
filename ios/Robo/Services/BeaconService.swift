import Foundation
import CoreLocation
import os

private let logger = Logger(subsystem: "com.silv.Robo", category: "BeaconService")

@Observable
class BeaconService: NSObject, CLLocationManagerDelegate {

    // MARK: - Constants

    /// iBeacon UUID — configurable via Settings → Beacons.
    static var beaconUUID: UUID { BeaconConfigStore.loadUUID() }
    static let beaconMajor: CLBeaconMajorValue = 1

    // MARK: - Published State

    private(set) var isMonitoring = false
    private(set) var detectedBeacons: [CLBeacon] = []
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var lastEvent: BeaconEvent?

    struct BeaconEvent {
        let type: String          // "enter" or "exit"
        let minor: Int
        let proximity: String?
        let rssi: Int?
        let distance: Double?
        let durationSeconds: Int? // Only on exit events
        let source: String
        let timestamp: Date
    }

    // MARK: - Callbacks

    /// Called on enter/exit events. Set by the view or app to persist events + fire webhooks.
    var onBeaconEvent: ((BeaconEvent) -> Void)?

    // MARK: - Private

    private let manager = CLLocationManager()
    private var beaconRegion: CLBeaconRegion?
    private var beaconConstraint: CLBeaconIdentityConstraint?

    /// Debounce: last enter time per Minor value. Suppresses duplicate enters within 60s.
    private var lastEnterTimes: [Int: Date] = [:]
    private let debounceInterval: TimeInterval = 60

    /// Track enter timestamps per Minor for duration calculation on exit.
    private var enterTimestamps: [Int: Date] = [:]

    /// When true, startMonitoring() will be called after authorization is granted.
    private var pendingMonitorAfterAuth = false

    // MARK: - Init

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Public API

    func requestPermissions() {
        // Location permissions disabled for now — beacon monitoring requires location
        // but we don't want to prompt users for location access yet.
        logger.info("Location permissions request suppressed")
    }

    /// Requests permissions and starts monitoring once authorized.
    func requestPermissionsAndMonitor() {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            startMonitoring()
        } else {
            // Don't request permissions — just log
            logger.info("Beacon monitoring requires location permission (not requesting)")
        }
    }

    func startMonitoring() {
        guard !isMonitoring else { return }

        let constraint = CLBeaconIdentityConstraint(
            uuid: Self.beaconUUID,
            major: Self.beaconMajor
        )
        let region = CLBeaconRegion(
            beaconIdentityConstraint: constraint,
            identifier: "com.silv.Robo.beacons"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true

        self.beaconConstraint = constraint
        self.beaconRegion = region

        manager.startMonitoring(for: region)
        manager.startRangingBeacons(satisfying: constraint)

        isMonitoring = true
        logger.info("Started beacon monitoring")
    }

    func stopMonitoring() {
        pendingMonitorAfterAuth = false

        guard isMonitoring else { return }

        if let region = beaconRegion {
            manager.stopMonitoring(for: region)
        }
        if let constraint = beaconConstraint {
            manager.stopRangingBeacons(satisfying: constraint)
        }

        isMonitoring = false
        detectedBeacons = []
        logger.info("Stopped beacon monitoring")
    }

    // MARK: - CLLocationManagerDelegate — Authorization

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        logger.info("Authorization changed: \(String(describing: manager.authorizationStatus.rawValue))")

        // Start monitoring if it was deferred pending authorization
        if pendingMonitorAfterAuth,
           manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            pendingMonitorAfterAuth = false
            startMonitoring()
        }
    }

    // MARK: - CLLocationManagerDelegate — Region Monitoring

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == beaconRegion?.identifier else { return }
        logger.info("Entered beacon region")

        // Start ranging to identify specific Minor value
        if let constraint = beaconConstraint {
            manager.startRangingBeacons(satisfying: constraint)
        }

        // Fire a generic enter event (Minor unknown until ranging identifies it)
        // The ranging callback will fire the specific event with Minor value
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == beaconRegion?.identifier else { return }
        logger.info("Exited beacon region")

        // Fire exit events for all beacons we were tracking
        for (minor, enterTime) in enterTimestamps {
            let duration = Int(Date().timeIntervalSince(enterTime))
            let event = BeaconEvent(
                type: "exit",
                minor: minor,
                proximity: nil,
                rssi: nil,
                distance: nil,
                durationSeconds: duration,
                source: "background_monitor",
                timestamp: Date()
            )
            lastEvent = event
            onBeaconEvent?(event)
            logger.info("Exit event: minor=\(minor), duration=\(duration)s")
        }

        enterTimestamps.removeAll()
        detectedBeacons = []
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == beaconRegion?.identifier else { return }
        logger.info("Region state: \(state == .inside ? "inside" : state == .outside ? "outside" : "unknown")")

        if state == .inside {
            // App launched while inside region — start ranging to discover beacons
            if let constraint = beaconConstraint {
                manager.startRangingBeacons(satisfying: constraint)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate — Ranging

    func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying constraint: CLBeaconIdentityConstraint) {
        detectedBeacons = beacons

        // Only fire events for configured+active beacons (or all if none configured)
        let configured = BeaconConfigStore.loadBeacons()
        let activeMinors: Set<Int>? = configured.isEmpty ? nil : Set(configured.filter(\.isActive).map(\.minor))

        for beacon in beacons where beacon.proximity != .unknown {
            let minor = beacon.minor.intValue

            // Skip beacons not in active config (when config exists)
            if let activeMinors, !activeMinors.contains(minor) {
                continue
            }

            // Debounce: suppress duplicate enter events within 60s
            if let lastEnter = lastEnterTimes[minor],
               Date().timeIntervalSince(lastEnter) < debounceInterval {
                continue
            }

            // Only fire enter if we haven't already tracked this beacon
            if enterTimestamps[minor] == nil {
                enterTimestamps[minor] = Date()
                lastEnterTimes[minor] = Date()

                let event = BeaconEvent(
                    type: "enter",
                    minor: minor,
                    proximity: proximityString(beacon.proximity),
                    rssi: beacon.rssi,
                    distance: beacon.accuracy > 0 ? beacon.accuracy : nil,
                    durationSeconds: nil,
                    source: "foreground_ranging",
                    timestamp: Date()
                )
                lastEvent = event
                onBeaconEvent?(event)
                logger.info("Enter event: minor=\(minor), proximity=\(self.proximityString(beacon.proximity)), rssi=\(beacon.rssi)")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailRangingFor constraint: CLBeaconIdentityConstraint, error: Error) {
        logger.error("Ranging failed: \(error.localizedDescription)")
    }

    // MARK: - Helpers

    private func proximityString(_ proximity: CLProximity) -> String {
        switch proximity {
        case .immediate: return "immediate"
        case .near: return "near"
        case .far: return "far"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
