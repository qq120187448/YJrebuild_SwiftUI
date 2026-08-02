import Foundation
import CoreBluetooth
import UIKit
import os

private let logger = Logger(subsystem: "com.silv.Robo", category: "SensorProvisioning")

// MARK: - UUID Constants

enum SensorUUID {
    static let provisioningService = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000001")
    static let ssid     = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000002")
    static let password = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000003")
    static let roomName = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000004")
    static let minorID  = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000005")
    static let command  = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000006")
    static let status   = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000007")
    static let wifiScan = CBUUID(string: "12345678-9ABC-DEF0-1234-000000000008")
}

// MARK: - Provisioning State

enum ProvisioningState: Equatable {
    case idle
    case scanning
    case connecting
    case discoveringServices
    case ready
    case writing
    case saving
    case saved
    case error(String)
    case disconnected
}

// MARK: - Discovered Sensor

struct DiscoveredSensor: Identifiable {
    let id: UUID  // CBPeripheral identifier
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int

    static func == (lhs: DiscoveredSensor, rhs: DiscoveredSensor) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Room Presets

struct RoomPreset: Identifiable {
    let id = UUID()
    let name: String
    let minorID: UInt16
}

let roomPresets: [RoomPreset] = [
    RoomPreset(name: "Office",      minorID: 1),
    RoomPreset(name: "Kitchen",     minorID: 2),
    RoomPreset(name: "Bedroom",     minorID: 3),
    RoomPreset(name: "Living Room", minorID: 4),
    RoomPreset(name: "Garage",      minorID: 5),
    RoomPreset(name: "Bathroom",    minorID: 6),
]

// MARK: - Timeout Configuration

private enum BLETimeout {
    static let connection: TimeInterval = 15
    static let serviceDiscovery: TimeInterval = 10
    static let characteristicDiscovery: TimeInterval = 10
    static let saveCommand: TimeInterval = 10
}

// MARK: - Diagnostic Log

struct BLEDiagnosticEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let event: String
    let detail: String?
}

// MARK: - Discovered WiFi Network

struct DiscoveredWiFiNetwork: Identifiable, Comparable {
    let id = UUID()
    let ssid: String
    let rssi: Int

    static func < (lhs: DiscoveredWiFiNetwork, rhs: DiscoveredWiFiNetwork) -> Bool {
        lhs.rssi > rhs.rssi  // Stronger signal first
    }
}

// MARK: - SensorProvisioningManager

@Observable
class SensorProvisioningManager: NSObject {

    private(set) var state: ProvisioningState = .idle
    private(set) var discoveredSensors: [DiscoveredSensor] = []
    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var diagnosticLog: [BLEDiagnosticEntry] = []
    private(set) var wifiNetworks: [DiscoveredWiFiNetwork] = []
    private(set) var isScannningWiFi = false

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    // Pending scan request before Bluetooth is powered on
    private var pendingScan = false

    // Write tracking
    private var pendingWriteCount = 0
    private var completedWriteCount = 0

    // Timeout tasks
    private var connectionTimeoutTask: Task<Void, Never>?
    private var discoveryTimeoutTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var saveTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        log("Initialized", detail: "CBCentralManager created on main queue")
    }

    // MARK: - Diagnostic Logging

    private func log(_ event: String, detail: String? = nil) {
        let entry = BLEDiagnosticEntry(timestamp: Date(), event: event, detail: detail)
        diagnosticLog.append(entry)
        if let detail {
            logger.info("[\(event)] \(detail)")
        } else {
            logger.info("[\(event)]")
        }
    }

    /// Returns all diagnostic entries as a shareable string.
    func exportDiagnosticLog() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines = ["Robo BLE Diagnostic Log", "=======================", ""]
        for entry in diagnosticLog {
            let ts = formatter.string(from: entry.timestamp)
            if let detail = entry.detail {
                lines.append("[\(ts)] \(entry.event): \(detail)")
            } else {
                lines.append("[\(ts)] \(entry.event)")
            }
        }
        lines.append("")
        lines.append("iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Public API

    func startScanning() {
        discoveredSensors = []

        guard centralManager.state == .poweredOn else {
            pendingScan = true
            state = .scanning
            log("Scan deferred", detail: "Bluetooth state: \(centralManager.state.rawValue), will scan when powered on")
            return
        }

        state = .scanning
        // Scan with nil services — engineer confirmed service UUID not in advertisement data
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log("Scan started", detail: "Scanning for 'Robo Sensor' devices")
    }

    func stopScanning() {
        centralManager.stopScan()
        if state == .scanning {
            state = .idle
        }
        pendingScan = false
        log("Scan stopped")
    }

    func connect(to sensor: DiscoveredSensor) {
        centralManager.stopScan()
        connectedPeripheral = sensor.peripheral
        sensor.peripheral.delegate = self
        state = .connecting
        centralManager.connect(sensor.peripheral, options: nil)
        log("Connecting", detail: "Peripheral: \(sensor.name), ID: \(sensor.id), RSSI: \(sensor.rssi)")

        // Start connection timeout
        startConnectionTimeout()
    }

    func provision(ssid: String, password: String, roomName: String, minorID: UInt16) {
        guard let peripheral = connectedPeripheral else {
            state = .error("No connected sensor")
            log("Provision failed", detail: "No connected peripheral")
            return
        }

        state = .writing
        pendingWriteCount = 0
        completedWriteCount = 0

        // Write SSID
        if let char = characteristics[SensorUUID.ssid],
           let data = ssid.data(using: .utf8) {
            peripheral.writeValue(data, for: char, type: .withResponse)
            pendingWriteCount += 1
        }

        // Write password
        if let char = characteristics[SensorUUID.password],
           let data = password.data(using: .utf8) {
            peripheral.writeValue(data, for: char, type: .withResponse)
            pendingWriteCount += 1
        }

        // Write room name
        if let char = characteristics[SensorUUID.roomName],
           let data = roomName.data(using: .utf8) {
            peripheral.writeValue(data, for: char, type: .withResponse)
            pendingWriteCount += 1
        }

        // Write minor ID (big-endian uint16)
        if let char = characteristics[SensorUUID.minorID] {
            var bigEndian = minorID.bigEndian
            let data = Data(bytes: &bigEndian, count: MemoryLayout<UInt16>.size)
            peripheral.writeValue(data, for: char, type: .withResponse)
            pendingWriteCount += 1
        }

        log("Provisioning", detail: "Writing \(pendingWriteCount) characteristics (room: \(roomName), minor: \(minorID))")
    }

    func cancel() {
        cancelAllTimeouts()
        centralManager.stopScan()
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        log("Cancelled")
        cleanup()
    }

    // MARK: - Timeout Management

    private func startConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(BLETimeout.connection))
            guard !Task.isCancelled, let self else { return }
            guard case .connecting = self.state else { return }
            self.log("Connection timeout", detail: "No response after \(Int(BLETimeout.connection))s. Try toggling Bluetooth off/on in iOS Settings.")
            self.state = .error("Connection timed out (\(Int(BLETimeout.connection))s). Try toggling Bluetooth off/on in Settings.")
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func startServiceDiscoveryTimeout() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(BLETimeout.serviceDiscovery))
            guard !Task.isCancelled, let self else { return }
            guard case .discoveringServices = self.state else { return }
            self.log("Service discovery timeout", detail: "No services found after \(Int(BLETimeout.serviceDiscovery))s. iOS may have cached stale GATT data — toggle Bluetooth off/on.")
            self.state = .error("Service discovery timed out. Try toggling Bluetooth off/on in Settings.")
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func startReadyTimeout() {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(BLETimeout.characteristicDiscovery))
            guard !Task.isCancelled, let self else { return }
            guard case .discoveringServices = self.state else { return }
            self.log("Ready timeout", detail: "No 'ready' status after \(Int(BLETimeout.characteristicDiscovery))s — proceeding anyway (characteristics already discovered)")
            // Transition to ready anyway — we have the characteristics, the status notification is optional
            self.state = .ready
        }
    }

    private func startSaveTimeout() {
        saveTimeoutTask?.cancel()
        saveTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(BLETimeout.saveCommand))
            guard !Task.isCancelled, let self else { return }
            guard case .saving = self.state else { return }
            self.log("Save timeout", detail: "No save confirmation after \(Int(BLETimeout.saveCommand))s")
            self.state = .error("Save command timed out. The sensor may not have received the configuration.")
        }
    }

    private func cancelAllTimeouts() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        saveTimeoutTask?.cancel()
        saveTimeoutTask = nil
    }

    // MARK: - Private

    func scanWiFiNetworks() {
        guard let peripheral = connectedPeripheral,
              let wifiChar = characteristics[SensorUUID.wifiScan],
              let data = "SCAN".data(using: .utf8) else {
            log("WiFi scan unavailable", detail: "Characteristic not found — use manual entry")
            return
        }

        isScannningWiFi = true
        wifiNetworks = []
        peripheral.setNotifyValue(true, for: wifiChar)
        peripheral.writeValue(data, for: wifiChar, type: .withResponse)
        log("WiFi scan requested", detail: "Waiting for sensor to scan nearby networks")

        // 5s timeout for WiFi scan
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isScannningWiFi else { return }
            self.isScannningWiFi = false
            if self.wifiNetworks.isEmpty {
                self.log("WiFi scan timeout", detail: "No networks returned in 5s")
            }
        }
    }

    var hasWiFiScanSupport: Bool {
        characteristics[SensorUUID.wifiScan] != nil
    }

    private func sendSaveCommand() {
        guard let peripheral = connectedPeripheral,
              let cmdChar = characteristics[SensorUUID.command],
              let data = "SAVE".data(using: .utf8) else { return }

        // Subscribe to status notifications before sending SAVE
        if let statusChar = characteristics[SensorUUID.status] {
            peripheral.setNotifyValue(true, for: statusChar)
        }

        state = .saving
        peripheral.writeValue(data, for: cmdChar, type: .withResponse)
        log("Save command sent", detail: "Waiting for sensor confirmation")
        startSaveTimeout()
    }

    private func parseWiFiScanResponse(_ response: String) {
        let lines = response.split(separator: "\n")
        var networks: [DiscoveredWiFiNetwork] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "MORE" || trimmed == "END" || trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: ",", maxSplits: 1)
            guard let ssid = parts.first.map(String.init), !ssid.isEmpty else { continue }
            let rssi = parts.count > 1 ? Int(parts[1]) ?? -100 : -100
            networks.append(DiscoveredWiFiNetwork(ssid: ssid, rssi: rssi))
        }

        wifiNetworks = networks.sorted()
        isScannningWiFi = false
        log("WiFi networks found", detail: "\(networks.count) networks: \(networks.map(\.ssid).joined(separator: ", "))")
    }

    private func cleanup() {
        cancelAllTimeouts()
        connectedPeripheral = nil
        characteristics.removeAll()
        pendingWriteCount = 0
        completedWriteCount = 0
        pendingScan = false
        state = .idle
    }
}

// MARK: - CBCentralManagerDelegate

extension SensorProvisioningManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        log("Bluetooth state changed", detail: "State: \(central.state.rawValue)")

        if central.state == .poweredOn, pendingScan {
            pendingScan = false
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            log("Deferred scan started", detail: "Bluetooth now powered on")
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        // Filter by name "Robo Sensor"
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
        guard let name = advName, name == "Robo Sensor" else { return }

        // Don't add duplicates
        guard !discoveredSensors.contains(where: { $0.id == peripheral.identifier }) else { return }

        let sensor = DiscoveredSensor(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue
        )
        discoveredSensors.append(sensor)
        log("Sensor discovered", detail: "\(name), RSSI: \(RSSI.intValue) dBm, ID: \(peripheral.identifier)")
    }

    func centralManager(_ central: CBCentralManager,
                         didConnect peripheral: CBPeripheral) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        state = .discoveringServices
        peripheral.discoverServices([SensorUUID.provisioningService])
        log("Connected", detail: "Starting service discovery for \(SensorUUID.provisioningService.uuidString)")
        startServiceDiscoveryTimeout()
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let msg = error?.localizedDescription ?? "unknown"
        state = .error("Failed to connect: \(msg)")
        log("Connection failed", detail: msg)
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        cancelAllTimeouts()
        // After SAVE, the device reboots — disconnection is expected
        if case .saving = state {
            state = .disconnected
            log("Disconnected (expected)", detail: "Sensor rebooting after save")
        } else if case .saved = state {
            state = .disconnected
            log("Disconnected (expected)", detail: "After saved state")
        } else {
            let msg = error?.localizedDescription ?? "none"
            state = .error("Sensor disconnected unexpectedly")
            log("Unexpected disconnect", detail: "Error: \(msg), state was: \(String(describing: self.state))")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension SensorProvisioningManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverServices error: Error?) {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil

        if let error {
            state = .error("Service discovery failed: \(error.localizedDescription)")
            log("Service discovery failed", detail: "\(error.localizedDescription). This can happen if iOS cached stale GATT data — toggle Bluetooth off/on in Settings.")
            return
        }

        let serviceUUIDs = peripheral.services?.map(\.uuid.uuidString) ?? []
        log("Services discovered", detail: "Found: \(serviceUUIDs.joined(separator: ", "))")

        guard let service = peripheral.services?.first(where: { $0.uuid == SensorUUID.provisioningService }) else {
            state = .error("Provisioning service not found on sensor")
            log("Service not found", detail: "Expected \(SensorUUID.provisioningService.uuidString) but got: \(serviceUUIDs.joined(separator: ", "))")
            return
        }

        // Reuse discovery timeout for characteristic discovery
        startServiceDiscoveryTimeout()

        peripheral.discoverCharacteristics([
            SensorUUID.ssid,
            SensorUUID.password,
            SensorUUID.roomName,
            SensorUUID.minorID,
            SensorUUID.command,
            SensorUUID.status,
            SensorUUID.wifiScan,
        ], for: service)
        log("Discovering characteristics", detail: "For service \(service.uuid.uuidString)")
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil

        if let error {
            state = .error("Characteristic discovery failed: \(error.localizedDescription)")
            log("Characteristic discovery failed", detail: error.localizedDescription)
            return
        }

        guard let chars = service.characteristics else {
            state = .error("No characteristics found")
            log("No characteristics", detail: "Service \(service.uuid.uuidString) returned nil characteristics")
            return
        }

        for char in chars {
            characteristics[char.uuid] = char
        }

        // Subscribe to status notifications
        if let statusChar = characteristics[SensorUUID.status] {
            peripheral.setNotifyValue(true, for: statusChar)
            peripheral.readValue(for: statusChar)
        }

        let charUUIDs = chars.map(\.uuid.uuidString)
        log("Characteristics ready", detail: "Found \(chars.count): \(charUUIDs.joined(separator: ", "))")

        // Start timeout for "ready" status notification — if sensor doesn't report ready,
        // we proceed anyway since we already have all characteristics
        startReadyTimeout()
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        // Handle WiFi scan response
        if characteristic.uuid == SensorUUID.wifiScan,
           let data = characteristic.value,
           let response = String(data: data, encoding: .utf8) {
            log("WiFi scan response", detail: "\(response.count) bytes")
            parseWiFiScanResponse(response)
            return
        }

        guard characteristic.uuid == SensorUUID.status,
              let data = characteristic.value,
              let statusString = String(data: data, encoding: .utf8) else { return }

        log("Status update", detail: "Value: \(statusString)")

        switch statusString {
        case "ready":
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            state = .ready
        case "saved":
            saveTimeoutTask?.cancel()
            saveTimeoutTask = nil
            state = .saved
        default:
            if statusString.hasPrefix("error:") {
                state = .error(statusString)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didWriteValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error {
            state = .error("Write failed: \(error.localizedDescription)")
            log("Write failed", detail: "Characteristic \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        // Don't count command or WiFi scan writes
        guard characteristic.uuid != SensorUUID.wifiScan else {
            log("WiFi scan write confirmed")
            return
        }
        guard characteristic.uuid != SensorUUID.command else {
            log("Save command write confirmed")
            return
        }

        completedWriteCount += 1
        log("Write completed", detail: "\(completedWriteCount)/\(pendingWriteCount) — \(characteristic.uuid.uuidString)")

        // All config writes done — send SAVE
        if completedWriteCount >= pendingWriteCount {
            sendSaveCommand()
        }
    }
}
