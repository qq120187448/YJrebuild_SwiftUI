import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Error)
    case invalidResponse
    case decodingError(Error)
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL. Check your API settings."
        case .requestFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "Unexpected server response. Please try again."
        case .decodingError:
            return "Could not read server response. The app may need updating."
        case .httpError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

@Observable
class APIService {
    let deviceService: DeviceService

    init(deviceService: DeviceService) {
        self.deviceService = deviceService
    }

    var baseURL: String {
        deviceService.config.apiBaseURL
    }

    var deviceId: String {
        deviceService.config.id
    }

    // MARK: - Device Registration

    func registerDevice(name: String, vendorId: String?, regenerateToken: Bool = false) async throws -> DeviceConfig {
        let url = try makeURL(path: "/api/devices/register")
        var payload: [String: Any] = ["name": name]
        if let vendorId { payload["vendor_id"] = vendorId }
        if regenerateToken { payload["regenerate_token"] = true }

        let response: RegisterResponse = try await post(url: url, body: payload)
        return DeviceConfig(
            id: response.id,
            name: response.name,
            apiBaseURL: baseURL,
            mcpToken: response.mcpToken
        )
    }

    // MARK: - Sensor Data

    func submitSensorData(
        sensorType: SensorData.SensorType,
        data: [String: Any]
    ) async throws -> SensorData {
        let url = try makeURL(path: "/api/sensors/data")
        let payload: [String: Any] = [
            "device_id": deviceId,
            "sensor_type": sensorType.rawValue,
            "data": data
        ]

        let response: SensorDataResponse = try await post(url: url, body: payload)
        return response.toSensorData()
    }

    // MARK: - Inbox

    func fetchInbox() async throws -> [InboxCard] {
        let url = try makeURL(path: "/api/inbox/\(deviceId)")
        let response: InboxResponse = try await get(url: url)
        return response.cards
    }

    func respondToCard(cardId: String, response: String) async throws -> InboxCard {
        let url = try makeURL(path: "/api/inbox/\(cardId)/respond")
        let payload = ["response": response]
        return try await post(url: url, body: payload)
    }

    // MARK: - Nutrition Lookup

    func lookupNutrition(upc: String) async throws -> NutritionResponse {
        let url = try makeURL(path: "/api/nutrition/lookup?upc=\(upc)")
        return try await get(url: url)
    }

    // MARK: - APNs Token

    func registerAPNsToken(_ token: String) async throws {
        let url = try makeURL(path: "/api/devices/\(deviceId)/apns-token")
        let payload = ["token": token]
        let _: APNsTokenResponse = try await post(url: url, body: payload)
    }

    // MARK: - Device (with MCP status)

    func fetchDevice() async throws -> DeviceStatusResponse {
        let url = try makeURL(path: "/api/devices/\(deviceId)")
        return try await get(url: url)
    }

    // MARK: - HITs

    func createHit(
        recipientName: String,
        taskDescription: String,
        hitType: String? = nil,
        config: [String: Any]? = nil,
        groupId: String? = nil,
        senderName: String? = nil
    ) async throws -> HitCreateResponse {
        let url = try makeURL(path: "/api/hits")
        var payload: [String: Any] = [
            "recipient_name": recipientName,
            "task_description": taskDescription,
        ]
        if let hitType { payload["hit_type"] = hitType }
        if let config { payload["config"] = config }
        if let groupId { payload["group_id"] = groupId }
        if let senderName { payload["sender_name"] = senderName }
        return try await post(url: url, body: payload)
    }

    func createHitWithMode(
        distributionMode: String,
        taskDescription: String,
        participants: [String]?,
        senderName: String? = nil,
        hitType: String? = nil,
        config: [String: Any]? = nil
    ) async throws -> HitCreateWithModeResponse {
        let url = try makeURL(path: "/api/hits")
        var payload: [String: Any] = [
            "distribution_mode": distributionMode,
            "task_description": taskDescription,
        ]
        if let participants { payload["participants"] = participants }
        if let senderName { payload["sender_name"] = senderName }
        if let hitType { payload["hit_type"] = hitType }
        if let config { payload["config"] = config }
        return try await post(url: url, body: payload)
    }

    func fetchHits() async throws -> [HitSummary] {
        let url = try makeURL(path: "/api/hits")
        let response: HitListResponse = try await get(url: url)
        return response.hits
    }

    func fetchHitsByGroup(groupId: String) async throws -> [HitSummary] {
        let url = try makeURL(path: "/api/hits?group_id=\(groupId)")
        let response: HitListResponse = try await get(url: url)
        return response.hits
    }

    func fetchHit(id: String) async throws -> HitSummary {
        let url = try makeURL(path: "/api/hits/\(id)")
        return try await get(url: url)
    }

    func fetchHitPhotos(hitId: String) async throws -> [HitPhotoItem] {
        let url = try makeURL(path: "/api/hits/\(hitId)/photos")
        let response: HitPhotoListResponse = try await get(url: url)
        return response.photos
    }

    func fetchHitResponses(hitId: String) async throws -> [HitResponseItem] {
        let url = try makeURL(path: "/api/hits/\(hitId)/responses")
        let response: HitResponseListResponse = try await get(url: url)
        return response.responses
    }

    func deleteHit(id: String) async throws {
        let url = try makeURL(path: "/api/hits/\(id)")
        let _: DeleteResponse = try await delete(url: url)
    }

    func bulkDeleteHits(ids: [String]) async throws -> BulkDeleteResponse {
        let url = try makeURL(path: "/api/hits/bulk-delete")
        let payload: [String: Any] = ["ids": ids]
        return try await post(url: url, body: payload)
    }

    func deleteOldHits(olderThanDays: Int, status: String? = nil) async throws -> BulkDeleteResponse {
        let url = try makeURL(path: "/api/hits/bulk-delete")
        var payload: [String: Any] = ["older_than_days": olderThanDays]
        if let status { payload["status"] = status }
        return try await post(url: url, body: payload)
    }

    // MARK: - API Keys (require MCP token auth)

    func fetchAPIKeys() async throws -> [APIKeyMeta] {
        let url = try makeURL(path: "/api/keys")
        let response: APIKeyListResponse = try await authenticatedGet(url: url)
        return response.keys
    }

    func createAPIKey(label: String?) async throws -> APIKeyCreated {
        let url = try makeURL(path: "/api/keys")
        var payload: [String: Any] = [:]
        if let label { payload["label"] = label }
        return try await authenticatedPost(url: url, body: payload)
    }

    func deleteAPIKey(id: String) async throws {
        let url = try makeURL(path: "/api/keys/\(id)")
        let _: DeleteResponse = try await authenticatedDelete(url: url)
    }

    // MARK: - Health Check

    func checkHealth() async -> Bool {
        guard let url = try? makeURL(path: "/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return false }
        return true
    }

    // MARK: - Authenticated HTTP Methods (with MCP token)

    private var bearerToken: String? {
        deviceService.config.mcpToken
    }

    private func authenticatedGet<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await performRequest(request)
    }

    private func authenticatedPost<T: Decodable>(url: URL, body: Any) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await performRequest(request)
    }

    private func authenticatedDelete<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await performRequest(request)
    }

    // MARK: - HTTP Methods

    private func get<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        return try await performRequest(request)
    }

    private func post<T: Decodable>(url: URL, body: Any) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performRequest(request)
    }

    private func delete<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        return try await performRequest(request)
    }

    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                #if DEBUG
                let body = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
                print("[APIService] invalidResponse — URL: \(request.url?.absoluteString ?? "nil"), body preview: \(String(body.prefix(200)))")
                #endif
                throw APIError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                #if DEBUG
                print("[APIService] httpError — \(httpResponse.statusCode) for \(request.url?.absoluteString ?? "nil"): \(String(message.prefix(200)))")
                #endif
                throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            #if DEBUG
            print("[APIService] decodingError for \(request.url?.absoluteString ?? "nil") — \(error)")
            #endif
            throw APIError.decodingError(error)
        } catch let error as APIError {
            throw error
        } catch {
            #if DEBUG
            print("[APIService] requestFailed for \(request.url?.absoluteString ?? "nil") — \(error)")
            #endif
            throw APIError.requestFailed(error)
        }
    }

    private func makeURL(path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        return url
    }
}

// MARK: - Response Models

private struct RegisterResponse: Decodable {
    let id: String
    let name: String
    let mcpToken: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case mcpToken = "mcp_token"
    }
}

private struct SensorDataResponse: Decodable {
    let id: Int
    let deviceId: String
    let sensorType: String
    let data: [String: AnyCodable]
    let capturedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case sensorType = "sensor_type"
        case data
        case capturedAt = "captured_at"
    }

    func toSensorData() -> SensorData {
        let type = SensorData.SensorType(rawValue: sensorType) ?? .barcode
        let date = ISO8601DateFormatter().date(from: capturedAt) ?? Date()
        return SensorData(
            id: id,
            deviceId: deviceId,
            sensorType: type,
            data: data,
            capturedAt: date
        )
    }
}

private struct InboxResponse: Decodable {
    let cards: [InboxCard]
    let count: Int
}

private struct APNsTokenResponse: Decodable {
    let status: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case updatedAt = "updated_at"
    }
}

// MARK: - Device Status Response

struct DeviceStatusResponse: Decodable {
    let id: String
    let name: String
    let registeredAt: String
    let lastSeenAt: String?
    let lastMcpCallAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case registeredAt = "registered_at"
        case lastSeenAt = "last_seen_at"
        case lastMcpCallAt = "last_mcp_call_at"
    }
}

// MARK: - HIT Response Models

struct HitCreateResponse: Decodable {
    let id: String
    let url: String
    let recipientName: String
    let taskDescription: String
    let status: String
    let hitType: String?
    let groupId: String?

    enum CodingKeys: String, CodingKey {
        case id, url, status
        case recipientName = "recipient_name"
        case taskDescription = "task_description"
        case hitType = "hit_type"
        case groupId = "group_id"
    }
}

struct HitCreateWithModeResponse: Decodable {
    let distributionMode: String?
    let id: String?
    let url: String?
    let groupId: String?
    let hits: [HitLink]?
    let count: Int?
    let senderName: String?
    let taskDescription: String?

    struct HitLink: Decodable {
        let name: String
        let id: String
        let url: String
    }

    enum CodingKeys: String, CodingKey {
        case id, url, hits, count
        case distributionMode = "distribution_mode"
        case groupId = "group_id"
        case senderName = "sender_name"
        case taskDescription = "task_description"
    }
}

struct HitSummary: Decodable, Identifiable {
    let id: String
    let senderName: String?
    let recipientName: String
    let taskDescription: String
    let status: String
    let photoCount: Int
    let createdAt: String
    let completedAt: String?
    let hitType: String?
    let groupId: String?
    let config: String?
    let responseCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, config
        case senderName = "sender_name"
        case recipientName = "recipient_name"
        case taskDescription = "task_description"
        case photoCount = "photo_count"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case hitType = "hit_type"
        case groupId = "group_id"
        case responseCount = "response_count"
    }
}

struct HitPhotoItem: Decodable, Identifiable {
    let id: String
    let hitId: String
    let r2Key: String
    let fileSize: Int?
    let uploadedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case hitId = "hit_id"
        case r2Key = "r2_key"
        case fileSize = "file_size"
        case uploadedAt = "uploaded_at"
    }
}

private struct HitListResponse: Decodable {
    let hits: [HitSummary]
    let count: Int
}

private struct HitPhotoListResponse: Decodable {
    let photos: [HitPhotoItem]
    let count: Int
}

struct HitResponseItem: Decodable, Identifiable {
    let id: String
    let hitId: String
    let respondentName: String
    let responseData: [String: AnyCodable]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case hitId = "hit_id"
        case respondentName = "respondent_name"
        case responseData = "response_data"
        case createdAt = "created_at"
    }
}

private struct HitResponseListResponse: Decodable {
    let responses: [HitResponseItem]
    let count: Int
}

private struct DeleteResponse: Decodable {
    let deleted: Bool
}

struct BulkDeleteResponse: Decodable {
    let deleted: Int
    let ids: [String]
}
