import Foundation
import UIKit

/// Protocol for device registration — enables testing without network.
protocol DeviceRegistering {
    func registerDevice(name: String, vendorId: String?, regenerateToken: Bool) async throws -> DeviceConfig
}

extension APIService: DeviceRegistering {}

@Observable
class DeviceService {
    private let userDefaultsKey = "deviceConfig"
    var config: DeviceConfig
    var registrationError: String?
    var registrationErrorDetail: String?

    init() {
        if var saved = KeychainHelper.load() {
            // Keychain is primary — migrate stale API URLs
            if saved.apiBaseURL != DeviceConfig.default.apiBaseURL {
                saved.apiBaseURL = DeviceConfig.default.apiBaseURL
            }
            self.config = saved
        } else if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  var saved = try? JSONDecoder().decode(DeviceConfig.self, from: data) {
            // Migrate from UserDefaults → Keychain (existing installs)
            if saved.apiBaseURL != DeviceConfig.default.apiBaseURL {
                saved.apiBaseURL = DeviceConfig.default.apiBaseURL
            }
            self.config = saved
        } else {
            self.config = .default
        }
        save()
    }

    /// Testable initializer — skips UserDefaults.
    init(config: DeviceConfig) {
        self.config = config
    }

    var isRegistered: Bool { config.isRegistered }

    func bootstrap(apiService: DeviceRegistering) async {
        guard !isRegistered else { return }

        var lastError: Error?
        for attempt in 1...3 {
            do {
                let vendorId = UIDevice.current.identifierForVendor?.uuidString
                let registered = try await apiService.registerDevice(name: UIDevice.current.name, vendorId: vendorId, regenerateToken: false)
                self.config = registered
                self.registrationError = nil
                self.registrationErrorDetail = nil
                save()
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            }
        }

        self.registrationError = "Registration failed: \(lastError?.localizedDescription ?? "Unknown error")"
        self.registrationErrorDetail = buildErrorDetail(lastError, baseURL: config.apiBaseURL)
    }

    private func buildErrorDetail(_ error: Error?, baseURL: String) -> String {
        guard let error else { return "No error captured" }
        var lines = [
            "URL: \(baseURL)/api/devices/register",
            "Error type: \(type(of: error))",
            "Description: \(error.localizedDescription)",
        ]
        if let apiError = error as? APIError {
            switch apiError {
            case .httpError(let code, let message):
                lines.append("HTTP status: \(code)")
                lines.append("Response: \(String(message.prefix(500)))")
            case .requestFailed(let underlying):
                lines.append("Underlying: \(type(of: underlying)) — \(underlying.localizedDescription)")
                lines.append("Debug: \(String(describing: underlying))")
            case .decodingError(let underlying):
                lines.append("Decoding: \(underlying)")
            default:
                break
            }
        } else {
            lines.append("Raw: \(String(describing: error))")
        }
        lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
        return lines.joined(separator: "\n")
    }

    func save() {
        KeychainHelper.save(config)
        // Keep UserDefaults as fallback for older code paths
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    /// Re-register to get a fresh MCP token while preserving device identity.
    func reRegister(apiService: DeviceRegistering) async {
        self.registrationError = nil
        self.registrationErrorDetail = nil

        // Quick connectivity check before wiping config
        if let api = apiService as? APIService, !(await api.checkHealth()) {
            self.registrationError = "Cannot reach server. Check your internet connection and try again."
            return
        }

        do {
            let vendorId = UIDevice.current.identifierForVendor?.uuidString
            let registered = try await apiService.registerDevice(
                name: UIDevice.current.name,
                vendorId: vendorId,
                regenerateToken: true
            )
            self.config = registered
            self.registrationError = nil
            self.registrationErrorDetail = nil
            save()
        } catch {
            self.registrationError = "Re-registration failed: \(error.localizedDescription)"
            self.registrationErrorDetail = buildErrorDetail(error, baseURL: config.apiBaseURL)
        }
    }
}
