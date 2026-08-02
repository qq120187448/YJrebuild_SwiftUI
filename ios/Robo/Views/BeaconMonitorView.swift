import SwiftUI
import SwiftData
import CoreLocation
import AudioToolbox

struct BeaconMonitorView: View {
    var captureContext: CaptureContext? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(DeviceService.self) private var deviceService

    @State private var phase: MonitorPhase = .instructions
    @State private var beaconService = BeaconService()
    @State private var error: String?
    @State private var showingDeviceInfo = false
    @State private var eventCount = 0

    private enum MonitorPhase {
        case instructions
        case monitoring
    }

    var body: some View {
        NavigationStack {
            Group {
                switch beaconService.authorizationStatus {
                case .denied, .restricted:
                    permissionDeniedView
                default:
                    switch phase {
                    case .instructions:
                        instructionsView
                    case .monitoring:
                        monitoringView
                    }
                }
            }
            .navigationTitle(phase == .instructions ? "Beacon Monitor" : "Monitoring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .monitoring ? "Done" : "Cancel") {
                        beaconService.stopMonitoring()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingDeviceInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                if let error { Text(error) }
            }
            .sheet(isPresented: $showingDeviceInfo) {
                SupportedDevicesSheet()
            }
        }
    }

    // MARK: - Permission Denied

    private var permissionDeniedView: some View {
        ContentUnavailableView {
            Label("Location Access Required", systemImage: "location.slash")
        } description: {
            Text("Robo needs location access to detect nearby Bluetooth beacons. Enable \"Always\" location access in Settings for background monitoring.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Instructions

    private var instructionsView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Beacon Monitor")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 16) {
                tipRow(icon: "antenna.radiowaves.left.and.right",
                       text: "Detects nearby iBeacon devices automatically")
                tipRow(icon: "bell.badge",
                       text: "Fires webhooks when you enter or exit a beacon's range")
                tipRow(icon: "moon.fill",
                       text: "Works in the background — even when the app is closed")
                tipRow(icon: "lock.shield",
                       text: "Requires location permission for beacon detection")
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                startMonitoring()
            } label: {
                Text("Start Monitoring")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Monitoring (Active)

    private var monitoringView: some View {
        List {
            Section {
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                    Text("Monitoring Active")
                        .font(.headline)
                    Spacer()
                    if eventCount > 0 {
                        Text("\(eventCount) event\(eventCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if beaconService.detectedBeacons.isEmpty {
                Section("Nearby Beacons") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Scanning for beacons...")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Nearby Beacons (\(beaconService.detectedBeacons.count))") {
                    ForEach(beaconService.detectedBeacons, id: \.minor) { beacon in
                        BeaconRow(beacon: beacon, roomName: roomName(for: beacon.minor.intValue))
                    }
                }
            }

            if let lastEvent = beaconService.lastEvent {
                Section("Latest Event") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: lastEvent.type == "enter" ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                                .foregroundStyle(lastEvent.type == "enter" ? .green : .orange)
                            Text(lastEvent.type == "enter" ? "Entered" : "Exited")
                                .font(.headline)
                            Text("ID \(lastEvent.minor)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let proximity = lastEvent.proximity {
                            Text("Proximity: \(proximity)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(lastEvent.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                Button("Stop Monitoring", role: .destructive) {
                    beaconService.stopMonitoring()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Actions

    private func startMonitoring() {
        beaconService.onBeaconEvent = { event in
            handleBeaconEvent(event)
        }

        beaconService.requestPermissionsAndMonitor()

        // Haptic
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        phase = .monitoring

        // Drain any previously failed webhooks
        let secret = UserDefaults.standard.string(forKey: "beaconWebhookSecret")
        Task {
            await WebhookService.retryPending(secret: secret)
        }
    }

    private func handleBeaconEvent(_ event: BeaconService.BeaconEvent) {
        eventCount += 1

        // Haptic + sound
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        AudioServicesPlaySystemSound(1057)

        // Persist to SwiftData
        let record = BeaconEventRecord(
            eventType: event.type,
            beaconMinor: event.minor,
            roomName: roomName(for: event.minor),
            proximity: event.proximity,
            rssi: event.rssi,
            distanceMeters: event.distance,
            durationSeconds: event.durationSeconds,
            source: event.source
        )
        record.agentId = captureContext?.agentId
        record.agentName = captureContext?.agentName
        modelContext.insert(record)
        try? modelContext.save()

        // Fire webhook
        let webhookURL = UserDefaults.standard.string(forKey: "beaconWebhookURL")
        let webhookSecret = UserDefaults.standard.string(forKey: "beaconWebhookSecret")

        if let urlString = webhookURL, let url = URL(string: urlString) {
            let formatter = ISO8601DateFormatter()
            let payload = BeaconWebhookPayload(
                event: event.type,
                beaconMinor: event.minor,
                roomName: roomName(for: event.minor),
                proximity: event.proximity,
                rssi: event.rssi,
                distanceMeters: event.distance,
                durationSeconds: event.durationSeconds,
                timestamp: formatter.string(from: event.timestamp),
                deviceId: deviceService.config.id,
                source: event.source
            )

            record.webhookURL = urlString
            Task {
                let result = await WebhookService.send(payload: payload, to: url, secret: webhookSecret)
                await MainActor.run {
                    switch result {
                    case .success:
                        record.webhookStatus = "sent"
                    case .failure:
                        record.webhookStatus = "failed"
                        WebhookService.enqueue(payload: payload, url: urlString)
                    }
                    try? modelContext.save()
                }
            }
        } else {
            record.webhookStatus = "no_url"
            try? modelContext.save()
        }
    }

    private func roomName(for minor: Int) -> String? {
        let beacons = BeaconConfigStore.loadBeacons()
        return beacons.first(where: { $0.minor == minor })?.roomName
    }
}

// MARK: - Beacon Row

private struct BeaconRow: View {
    let beacon: CLBeacon
    let roomName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                proximityIndicator
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(roomName ?? "Beacon \(beacon.minor)")
                        .font(.subheadline.weight(.medium))
                    Text("ID: \(beacon.minor)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(proximityLabel)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(proximityColor.opacity(0.15))
                    .foregroundStyle(proximityColor)
                    .clipShape(Capsule())
            }

            // Sensor data grid
            HStack(spacing: 16) {
                sensorItem(label: "RSSI", value: "\(beacon.rssi) dBm", icon: "antenna.radiowaves.left.and.right")
                if beacon.accuracy > 0 {
                    sensorItem(label: "Distance", value: String(format: "%.1f ft", beacon.accuracy * 3.281), icon: "ruler")
                }
                sensorItem(label: "Signal", value: signalQuality, icon: "wifi")
            }
            .padding(.leading, 48)

            // Signal strength bar
            HStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.systemGray5))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(signalColor)
                            .frame(width: geo.size.width * signalFraction)
                    }
                }
                .frame(height: 4)
            }
            .padding(.leading, 48)
        }
        .padding(.vertical, 4)
    }

    private func sensorItem(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption2.weight(.medium).monospaced())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var proximityIndicator: some View {
        ZStack {
            Circle()
                .fill(proximityColor.opacity(0.15))
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.caption)
                .foregroundStyle(proximityColor)
        }
    }

    private var proximityLabel: String {
        switch beacon.proximity {
        case .immediate: return "Immediate"
        case .near: return "Near"
        case .far: return "Far"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    private var proximityColor: Color {
        switch beacon.proximity {
        case .immediate: return .green
        case .near: return .blue
        case .far: return .orange
        case .unknown: return .gray
        @unknown default: return .gray
        }
    }

    /// Signal fraction 0.0–1.0 based on RSSI (-100 worst to -30 best).
    /// RSSI of 0 means "unavailable" in CoreLocation — treat as no signal.
    private var signalFraction: CGFloat {
        let rssi = beacon.rssi
        guard rssi < 0 else { return 0 }
        let clamped = min(max(Double(rssi), -100), -30)
        return CGFloat((clamped + 100) / 70)
    }

    private var signalColor: Color {
        let fraction = signalFraction
        if fraction > 0.7 { return .green }
        if fraction > 0.4 { return .orange }
        return .red
    }

    private var signalQuality: String {
        let fraction = signalFraction
        if fraction > 0.7 { return "Strong" }
        if fraction > 0.4 { return "Medium" }
        return "Weak"
    }
}

// MARK: - Supported Devices Sheet

struct SupportedDevicesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Recommended") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ESP32-S3-WROOM-1")
                            .font(.headline)
                        Text("~$5/unit, USB-C powered. Flash with Robo iBeacon firmware.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Also Compatible") {
                    Text("Any iBeacon-compatible device (Estimote, Kontakt, RadBeacon, etc.)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Beacon Configuration") {
                    LabeledContent("Protocol", value: "Apple iBeacon")
                    LabeledContent("UUID") {
                        let uuid = BeaconConfigStore.loadUUIDString()
                        Text(uuid.prefix(8) + "...")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Major", value: "1")
                    LabeledContent("Minor", value: "1-65535 (room ID)")
                }
            }
            .navigationTitle("Supported Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Beacon Config Store (UserDefaults-backed)

enum BeaconConfigStore {
    private static let key = "configuredBeacons"
    private static let uuidKey = "beaconUUID"
    static let defaultUUID = "12345678-9ABC-DEF0-1234-56789ABCDEF0"

    static func loadUUID() -> UUID {
        let stored = UserDefaults.standard.string(forKey: uuidKey) ?? defaultUUID
        return UUID(uuidString: stored) ?? UUID(uuidString: defaultUUID)!
    }

    static func loadUUIDString() -> String {
        UserDefaults.standard.string(forKey: uuidKey) ?? defaultUUID
    }

    static func saveUUID(_ uuidString: String) {
        UserDefaults.standard.set(uuidString, forKey: uuidKey)
    }

    struct BeaconConfig: Codable, Identifiable {
        let id: UUID
        var minor: Int
        var roomName: String
        var isActive: Bool

        init(minor: Int, roomName: String, isActive: Bool = true) {
            self.id = UUID()
            self.minor = minor
            self.roomName = roomName
            self.isActive = isActive
        }
    }

    static func loadBeacons() -> [BeaconConfig] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BeaconConfig].self, from: data)) ?? []
    }

    static func saveBeacons(_ beacons: [BeaconConfig]) {
        if let data = try? JSONEncoder().encode(beacons) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func addBeacon(minor: Int, roomName: String) {
        var beacons = loadBeacons()
        // Don't add duplicate minors
        guard !beacons.contains(where: { $0.minor == minor }) else { return }
        beacons.append(BeaconConfig(minor: minor, roomName: roomName))
        saveBeacons(beacons)
    }

    static func removeBeacon(id: UUID) {
        var beacons = loadBeacons()
        beacons.removeAll(where: { $0.id == id })
        saveBeacons(beacons)
    }

    static func updateBeacon(id: UUID, roomName: String? = nil, isActive: Bool? = nil) {
        var beacons = loadBeacons()
        guard let index = beacons.firstIndex(where: { $0.id == id }) else { return }
        if let roomName { beacons[index].roomName = roomName }
        if let isActive { beacons[index].isActive = isActive }
        saveBeacons(beacons)
    }
}
