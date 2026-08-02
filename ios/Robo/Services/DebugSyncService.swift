import Foundation

#if DEBUG
enum DebugSyncService {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "dev.syncToCloud")
    }

    private static var deviceConfig: DeviceConfig {
        if let data = UserDefaults.standard.data(forKey: "deviceConfig"),
           let config = try? JSONDecoder().decode(DeviceConfig.self, from: data) {
            return config
        }
        return .default
    }

    /// Fire-and-forget sync of barcode scan data.
    static func syncBarcode(value: String, symbology: String) {
        guard isEnabled else { return }
        let config = deviceConfig
        let payload: [String: Any] = [
            "device_id": config.id,
            "type": "barcode",
            "data": [
                "value": value,
                "symbology": symbology,
                "scanned_at": ISO8601DateFormatter().string(from: Date())
            ]
        ]
        post(payload: payload, apiBaseURL: config.apiBaseURL)
    }

    /// Fire-and-forget sync of room scan data.
    static func syncRoom(roomName: String, summaryJSON: Data) {
        guard isEnabled else { return }
        let config = deviceConfig
        let summaryDict = (try? JSONSerialization.jsonObject(with: summaryJSON)) as? [String: Any] ?? [:]
        let payload: [String: Any] = [
            "device_id": config.id,
            "type": "room",
            "data": [
                "room_name": roomName,
                "summary": summaryDict
            ]
        ]
        post(payload: payload, apiBaseURL: config.apiBaseURL)
    }

    private static func post(payload: [String: Any], apiBaseURL: String) {
        guard let url = URL(string: apiBaseURL + "/api/debug/sync") else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let config = deviceConfig
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.id, forHTTPHeaderField: "X-Device-ID")
        request.httpBody = body

        URLSession.shared.dataTask(with: request).resume()
    }
}
#endif
