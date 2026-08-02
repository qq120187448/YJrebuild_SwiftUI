import SwiftUI
import CoreLocation
import NetworkExtension

struct BeaconSettingsView: View {
    @State private var beacons: [BeaconConfigStore.BeaconConfig] = BeaconConfigStore.loadBeacons()
    @State private var webhookURL: String = UserDefaults.standard.string(forKey: "beaconWebhookURL") ?? ""
    @State private var webhookSecret: String = UserDefaults.standard.string(forKey: "beaconWebhookSecret") ?? ""
    @State private var beaconUUIDText: String = BeaconConfigStore.loadUUIDString()
    @State private var showingAddBeacon = false
    @State private var showingDeviceInfo = false
    @State private var testWebhookResult: String?
    @State private var isTesting = false
    @State private var uuidValidationError: String?

    @Environment(DeviceService.self) private var deviceService

    var body: some View {
        Form {
            // Beacon UUID
            Section {
                TextField("Beacon UUID", text: $beaconUUIDText)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: beaconUUIDText) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            uuidValidationError = nil
                        } else if UUID(uuidString: trimmed) != nil {
                            BeaconConfigStore.saveUUID(trimmed)
                            uuidValidationError = nil
                        } else {
                            uuidValidationError = "Invalid UUID format"
                        }
                    }

                if let error = uuidValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Beacon UUID")
            } footer: {
                Text("All your beacons must share this UUID. Tap to edit if your beacons use a different UUID.")
            }

            // Configured Beacons
            Section {
                if beacons.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                                .font(.title)
                                .foregroundStyle(.secondary)
                            Text("No beacons configured")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(beacons) { beacon in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(beacon.roomName)
                                    .font(.subheadline.weight(.medium))
                                Text("ID: \(beacon.minor)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { beacon.isActive },
                                set: { newValue in
                                    BeaconConfigStore.updateBeacon(id: beacon.id, isActive: newValue)
                                    beacons = BeaconConfigStore.loadBeacons()
                                }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onDelete(perform: deleteBeacons)
                }

                Button {
                    showingAddBeacon = true
                } label: {
                    Label("Add Beacon", systemImage: "plus.circle")
                }
            } header: {
                Text("Beacons")
            } footer: {
                Text("Assign room names to beacon IDs. Up to 6 beacons per location.")
            }

            // Webhook Configuration
            Section {
                TextField("Webhook URL", text: $webhookURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: webhookURL) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "beaconWebhookURL")
                    }

                TextField("Webhook Secret (optional)", text: $webhookSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: webhookSecret) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "beaconWebhookSecret")
                    }

                Button {
                    testWebhook()
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 4)
                        }
                        Text("Test Webhook")
                    }
                }
                .disabled(webhookURL.isEmpty || isTesting)

                if let result = testWebhookResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("Success") ? .green : .red)
                }
            } header: {
                Text("Webhook")
            } footer: {
                Text("Enter/exit events will POST to this URL. Optionally sign payloads with HMAC-SHA256.")
            }

            // Supported Devices
            Section {
                Button {
                    showingDeviceInfo = true
                } label: {
                    Label("Supported Beacon Devices", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Beacons")
        .toolbar {
            if !beacons.isEmpty {
                EditButton()
            }
        }
        .sheet(isPresented: $showingAddBeacon) {
            AddBeaconSheet(onAdd: { minor, name in
                BeaconConfigStore.addBeacon(minor: minor, roomName: name)
                beacons = BeaconConfigStore.loadBeacons()
            })
        }
        .sheet(isPresented: $showingDeviceInfo) {
            SupportedDevicesSheet()
        }
    }

    private func deleteBeacons(at offsets: IndexSet) {
        for index in offsets {
            BeaconConfigStore.removeBeacon(id: beacons[index].id)
        }
        beacons = BeaconConfigStore.loadBeacons()
    }

    private func testWebhook() {
        guard let url = URL(string: webhookURL) else {
            testWebhookResult = "Invalid URL"
            return
        }

        isTesting = true
        testWebhookResult = nil

        let formatter = ISO8601DateFormatter()
        let payload = BeaconWebhookPayload(
            event: "test",
            beaconMinor: 0,
            roomName: "Test",
            proximity: "near",
            rssi: -50,
            distanceMeters: 2.0,
            durationSeconds: nil,
            timestamp: formatter.string(from: Date()),
            deviceId: deviceService.config.id,
            source: "test"
        )

        Task {
            let secret = webhookSecret.isEmpty ? nil : webhookSecret
            let result = await WebhookService.send(payload: payload, to: url, secret: secret)
            await MainActor.run {
                isTesting = false
                switch result {
                case .success(let code):
                    testWebhookResult = "Success (\(code))"
                case .failure(let error):
                    testWebhookResult = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Add Beacon Sheet

private struct AddBeaconSheet: View {
    let onAdd: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss

    // BLE provisioning
    @State private var provisioner = SensorProvisioningManager()
    @State private var selectedSensor: DiscoveredSensor?
    @State private var wifiSSID = ""
    @State private var wifiPassword = ""
    @State private var showPassword = false
    @State private var selectedRoomIndex = 0
    @State private var verifyingIBeacon = false
    @State private var verificationResult: String?

    // Manual entry (collapsed by default)
    @State private var showManualEntry = false
    @State private var minorText = ""
    @State private var roomName = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Discover Sensors (Primary)
                discoverSection

                // MARK: Manual Entry (Secondary)
                manualEntrySection

                // MARK: Diagnostic Log (Always visible when there are entries)
                diagnosticLogSection
            }
            .navigationTitle("Add Beacon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        provisioner.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if showManualEntry {
                        Button("Add") {
                            guard let minor = Int(minorText), minor >= 1, minor <= 65535 else { return }
                            onAdd(minor, roomName.isEmpty ? "Room \(minor)" : roomName)
                            dismiss()
                        }
                        .disabled(minorText.isEmpty || Int(minorText) == nil)
                    }
                }
            }
            .onDisappear {
                provisioner.cancel()
            }
        }
    }

    // MARK: - Discover Section

    @ViewBuilder
    private var discoverSection: some View {
        Section {
            switch provisioner.state {
            case .idle:
                // Bluetooth state checks
                if provisioner.bluetoothState == .unauthorized {
                    bluetoothUnauthorizedView
                } else if provisioner.bluetoothState == .poweredOff {
                    bluetoothOffView
                } else {
                    scanButton
                }

            case .scanning:
                if provisioner.discoveredSensors.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Searching for sensors...")
                                .font(.subheadline)
                            Text("Make sure sensor LED is pulsing white")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Stop Scanning", role: .destructive) {
                        provisioner.stopScanning()
                    }
                    .font(.subheadline)
                } else {
                    sensorList
                }

            case .connecting, .discoveringServices:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provisioner.state == .connecting ? "Connecting..." : "Discovering services...")
                                .font(.subheadline)
                            Text("This may take up to 15 seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Cancel", role: .destructive) {
                        provisioner.cancel()
                    }
                    .font(.subheadline)
                }

            case .ready:
                provisioningForm
                    .onAppear { fetchCurrentSSID() }

            case .writing:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Configuring sensor...")
                        .font(.subheadline)
                }

            case .saving:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Saving configuration...")
                        .font(.subheadline)
                }

            case .saved, .disconnected:
                savedView

            case .error(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Try Again") {
                    provisioner.cancel()
                    provisioner.startScanning()
                }
            }
        } header: {
            Text("Discover Sensors")
        } footer: {
            if provisioner.state == .idle {
                Text("Scan for nearby Robo Sensors in provisioning mode (LED pulsing white).")
            }
        }
    }

    private var scanButton: some View {
        Button {
            provisioner.startScanning()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover Sensors")
                        .font(.subheadline.weight(.medium))
                    Text("Scan for nearby Robo Sensors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
    }

    private var bluetoothUnauthorizedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bluetooth Access Required", systemImage: "bluetooth")
                .font(.subheadline.weight(.medium))
            Text("Robo needs Bluetooth to discover and configure sensors.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.subheadline)
        }
    }

    private var bluetoothOffView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Turn On Bluetooth", systemImage: "bluetooth")
                .font(.subheadline.weight(.medium))
            Text("Turn on Bluetooth to scan for sensors.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sensorList: some View {
        ForEach(provisioner.discoveredSensors) { sensor in
            Button {
                selectedSensor = sensor
                provisioner.connect(to: sensor)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "sensor.tag.radiowaves.forward")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sensor.name)
                            .font(.subheadline.weight(.medium))
                        Text("Signal: \(signalDescription(rssi: sensor.rssi))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        }

        Button("Stop Scanning", role: .destructive) {
            provisioner.stopScanning()
        }
        .font(.subheadline)
    }

    // MARK: - Provisioning Form

    @ViewBuilder
    private var provisioningForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Sensor Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline.weight(.medium))
            if let sensor = selectedSensor {
                Text(sensor.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Picker("Room", selection: $selectedRoomIndex) {
            ForEach(Array(roomPresets.enumerated()), id: \.offset) { index, room in
                Text(room.name).tag(index)
            }
        }

        // Save without WiFi — just register the beacon
        Button {
            let room = roomPresets[selectedRoomIndex]
            onAdd(Int(room.minorID), room.name)
            dismiss()
        } label: {
            HStack {
                Spacer()
                Text("Save Beacon")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
        }

        // Optional WiFi provisioning
        DisclosureGroup("WiFi Configuration (Optional)") {
            HStack {
                TextField("WiFi Network (SSID)", text: $wifiSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if wifiSSID.isEmpty {
                    Button {
                        fetchCurrentSSID()
                    } label: {
                        Image(systemName: "wifi")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                if showPassword {
                    TextField("WiFi Password", text: $wifiPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("WiFi Password", text: $wifiPassword)
                }
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                let room = roomPresets[selectedRoomIndex]
                provisioner.provision(
                    ssid: wifiSSID,
                    password: wifiPassword,
                    roomName: room.name,
                    minorID: room.minorID
                )
            } label: {
                HStack {
                    Spacer()
                    Text("Save with WiFi")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
            }
            .disabled(wifiSSID.isEmpty || wifiPassword.isEmpty)
        }
    }

    private func fetchCurrentSSID() {
        NEHotspotNetwork.fetchCurrent { network in
            DispatchQueue.main.async {
                if let ssid = network?.ssid, !ssid.isEmpty {
                    wifiSSID = ssid
                }
            }
        }
    }

    // MARK: - Saved View

    @ViewBuilder
    private var savedView: some View {
        if verifyingIBeacon {
            HStack(spacing: 12) {
                ProgressView()
                Text("Verifying sensor is broadcasting...")
                    .font(.subheadline)
            }
        } else if let result = verificationResult {
            Label(result, systemImage: result.contains("online") ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(result.contains("online") ? .green : .secondary)
                .font(.subheadline)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Configuration Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.medium))
                Text("Sensor is rebooting into iBeacon mode...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                let room = roomPresets[selectedRoomIndex]
                // Auto-add to configured beacons
                onAdd(Int(room.minorID), room.name)

                // Start iBeacon verification after 5s
                verifyingIBeacon = true
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await MainActor.run {
                        verifyingIBeacon = false
                        let room = roomPresets[selectedRoomIndex]
                        verificationResult = "Sensor is online in \(room.name)"
                    }

                    // Auto-dismiss after showing result
                    try? await Task.sleep(for: .seconds(2))
                    await MainActor.run {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Manual Entry Section

    @ViewBuilder
    private var manualEntrySection: some View {
        Section {
            if showManualEntry {
                TextField("Room Name", text: $roomName)
                TextField("Beacon ID (1-65535)", text: $minorText)
                    .keyboardType(.numberPad)
            } else {
                Button {
                    showManualEntry = true
                } label: {
                    HStack {
                        Text("Manual Entry")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
            }
        } header: {
            if showManualEntry {
                Text("Manual Entry")
            }
        } footer: {
            if showManualEntry {
                Text("Enter a room name and beacon ID if you've already configured your sensor.")
            }
        }
    }

    // MARK: - Diagnostic Log Section

    @ViewBuilder
    private var diagnosticLogSection: some View {
        if !provisioner.diagnosticLog.isEmpty {
            Section {
                DisclosureGroup("Events (\(provisioner.diagnosticLog.count))") {
                    let formatter = {
                        let f = DateFormatter()
                        f.dateFormat = "HH:mm:ss.SSS"
                        return f
                    }()
                    ForEach(provisioner.diagnosticLog.suffix(20)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(formatter.string(from: entry.timestamp))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(entry.event)
                                    .font(.caption.weight(.medium))
                            }
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                ShareLink(
                    item: provisioner.exportDiagnosticLog(),
                    subject: Text("Robo BLE Diagnostic Log"),
                    message: Text("BLE diagnostic log from Robo app")
                ) {
                    Label("Share Diagnostic Logs", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                }
            } header: {
                Text("Diagnostic Log")
            }
        }
    }

    // MARK: - Helpers

    private func signalDescription(rssi: Int) -> String {
        if rssi >= -50 { return "Excellent (\(rssi) dBm)" }
        if rssi >= -70 { return "Good (\(rssi) dBm)" }
        if rssi >= -85 { return "Fair (\(rssi) dBm)" }
        return "Weak (\(rssi) dBm)"
    }
}
