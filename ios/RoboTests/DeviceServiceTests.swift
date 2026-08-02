import Testing
@testable import Robo

// MARK: - Mock

private struct MockRegistrar: DeviceRegistering {
    var result: Result<DeviceConfig, Error>

    func registerDevice(name: String, vendorId: String?, regenerateToken: Bool) async throws -> DeviceConfig {
        try result.get()
    }
}

private enum MockError: Error { case fail }

// MARK: - reRegister Tests

@Test func reRegisterSuccess_persistsNewTokenAndID() async {
    let oldConfig = DeviceConfig(id: "old-id-123", name: "Test", apiBaseURL: "https://api.robo.app", mcpToken: nil)
    let service = DeviceService(config: oldConfig)

    let newConfig = DeviceConfig(id: "new-id-456", name: "Test", apiBaseURL: "https://api.robo.app", mcpToken: "abc123token")
    let mock = MockRegistrar(result: .success(newConfig))

    await service.reRegister(apiService: mock)

    #expect(service.config.id == "new-id-456")
    #expect(service.config.mcpToken == "abc123token")
    #expect(service.isRegistered)
    #expect(service.registrationError == nil)
}

@Test func reRegisterFailure_restoresOldConfig() async {
    let oldConfig = DeviceConfig(id: "old-id-123", name: "Test", apiBaseURL: "https://api.robo.app", mcpToken: nil)
    let service = DeviceService(config: oldConfig)

    let mock = MockRegistrar(result: .failure(MockError.fail))

    await service.reRegister(apiService: mock)

    // Old config should be restored — device ID must NOT be wiped
    #expect(service.config.id == "old-id-123")
    #expect(service.config.name == "Test")
    #expect(service.registrationError != nil)
}

// MARK: - Init / Migration Tests

@Test func initWithConfig_preservesDeviceID() {
    // Simulates the migration path: KeychainHelper.load() returns nil,
    // UserDefaults has config → DeviceService.init(config:) preserves it.
    let existingConfig = DeviceConfig(
        id: "a6fd7c15-1234-5678-abcd-000000000000",
        name: "Matt's iPhone",
        apiBaseURL: "https://api.robo.app",
        mcpToken: "existing-token"
    )
    let service = DeviceService(config: existingConfig)

    #expect(service.config.id == "a6fd7c15-1234-5678-abcd-000000000000")
    #expect(service.config.mcpToken == "existing-token")
    #expect(service.isRegistered)
}

@Test func initWithRegisteredConfig_skipsBootstrap() async {
    // If config is already registered, bootstrap() should be a no-op
    let config = DeviceConfig(
        id: "registered-id",
        name: "Test",
        apiBaseURL: "https://api.robo.app",
        mcpToken: "token"
    )
    let service = DeviceService(config: config)

    // bootstrap with a mock that would fail — but it should never be called
    let mock = MockRegistrar(result: .failure(MockError.fail))
    await service.bootstrap(apiService: mock)

    // ID should be unchanged — bootstrap skipped because already registered
    #expect(service.config.id == "registered-id")
    #expect(service.registrationError == nil)
}

@Test func initWithDefaultConfig_isNotRegistered() {
    // Fresh install: no keychain, no UserDefaults → .default config
    let service = DeviceService(config: .default)

    #expect(!service.isRegistered)
    #expect(service.config.id == DeviceConfig.unregisteredID)
}

@Test func reRegisterFailure_doesNotWipeDeviceID() async {
    // This is the exact bug from issue #139:
    // Before the fix, reRegister would save "unregistered" before bootstrap,
    // so a failed bootstrap left the user with a wiped device ID.
    let oldConfig = DeviceConfig(id: "052fa9ba-9d43-4327-94fb-7687626bb235", name: "Matt's iPhone", apiBaseURL: "https://api.robo.app", mcpToken: nil)
    let service = DeviceService(config: oldConfig)

    let mock = MockRegistrar(result: .failure(MockError.fail))

    await service.reRegister(apiService: mock)

    #expect(service.config.id == "052fa9ba-9d43-4327-94fb-7687626bb235")
    #expect(service.config.id != DeviceConfig.unregisteredID)
}
