import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.silv.Robo", category: "WebhookService")

// MARK: - Webhook Payload

struct BeaconWebhookPayload: Codable {
    let event: String
    let beaconMinor: Int
    let roomName: String?
    let proximity: String?
    let rssi: Int?
    let distanceMeters: Double?
    let durationSeconds: Int?
    let timestamp: String
    let deviceId: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case event
        case beaconMinor = "beacon_minor"
        case roomName = "room_name"
        case proximity
        case rssi
        case distanceMeters = "distance_meters"
        case durationSeconds = "duration_seconds"
        case timestamp
        case deviceId = "device_id"
        case source
    }
}

// MARK: - Webhook Result

enum WebhookResult {
    case success(statusCode: Int)
    case failure(Error)
}

// MARK: - WebhookService

enum WebhookService {
    private static let pendingQueueKey = "webhookPendingQueue"
    private static let retryDelays: [TimeInterval] = [5, 15, 45]

    /// Send a webhook payload to the given URL. Initial attempt + retries with backoff delays [5s, 15s, 45s].
    static func send(payload: BeaconWebhookPayload, to url: URL, secret: String? = nil) async -> WebhookResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        guard let body = try? encoder.encode(payload) else {
            logger.error("Failed to encode webhook payload")
            return .failure(WebhookError.encodingFailed)
        }

        var lastError: Error = WebhookError.unknown
        let maxAttempts = retryDelays.count + 1 // 1 initial + 3 retries

        for attempt in 0..<maxAttempts {
            // Backoff before retries (not before first attempt)
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(retryDelays[attempt - 1]))
            }

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Robo/1.0", forHTTPHeaderField: "User-Agent")

                if let secret, !secret.isEmpty {
                    let signature = computeHMAC(body: body, secret: secret)
                    request.setValue(signature, forHTTPHeaderField: "X-Robo-Signature")
                }

                request.httpBody = body
                request.timeoutInterval = 10

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw WebhookError.invalidResponse
                }

                if (200...299).contains(httpResponse.statusCode) {
                    logger.info("Webhook sent successfully (attempt \(attempt + 1))")
                    return .success(statusCode: httpResponse.statusCode)
                } else {
                    throw WebhookError.httpError(statusCode: httpResponse.statusCode)
                }
            } catch {
                lastError = error
                logger.warning("Webhook attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }

        logger.error("Webhook failed after \(maxAttempts) attempts")
        return .failure(lastError)
    }

    /// Queue a payload for later retry (persisted to UserDefaults).
    static func enqueue(payload: BeaconWebhookPayload, url: String) {
        var queue = loadPendingQueue()
        queue.append(PendingWebhook(payload: payload, url: url, createdAt: Date()))

        // Cap queue at 100 items
        if queue.count > 100 {
            queue = Array(queue.suffix(100))
        }

        savePendingQueue(queue)
        logger.info("Enqueued webhook, \(queue.count) pending")
    }

    /// Retry all pending webhooks. Removes successful ones.
    static func retryPending(secret: String? = nil) async {
        var queue = loadPendingQueue()
        guard !queue.isEmpty else { return }

        logger.info("Retrying \(queue.count) pending webhooks")
        var remaining: [PendingWebhook] = []

        for item in queue {
            guard let url = URL(string: item.url) else { continue }

            let result = await send(payload: item.payload, to: url, secret: secret)
            switch result {
            case .success:
                break // Remove from queue
            case .failure:
                // Keep if less than 24 hours old
                if Date().timeIntervalSince(item.createdAt) < 86400 {
                    remaining.append(item)
                }
            }
        }

        savePendingQueue(remaining)
    }

    // MARK: - Persistence

    private struct PendingWebhook: Codable {
        let payload: BeaconWebhookPayload
        let url: String
        let createdAt: Date
    }

    private static func loadPendingQueue() -> [PendingWebhook] {
        guard let data = UserDefaults.standard.data(forKey: pendingQueueKey) else { return [] }
        return (try? JSONDecoder().decode([PendingWebhook].self, from: data)) ?? []
    }

    private static func savePendingQueue(_ queue: [PendingWebhook]) {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: pendingQueueKey)
        }
    }

    // MARK: - HMAC

    private static func computeHMAC(body: Data, secret: String) -> String {
        guard let keyData = secret.data(using: .utf8) else { return "" }
        let key = SymmetricKey(data: keyData)
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return "sha256=" + signature.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Errors

    enum WebhookError: LocalizedError {
        case encodingFailed
        case invalidResponse
        case httpError(statusCode: Int)
        case unknown

        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Failed to encode webhook payload"
            case .invalidResponse: return "Invalid response from webhook endpoint"
            case .httpError(let code): return "HTTP error \(code)"
            case .unknown: return "Unknown webhook error"
            }
        }
    }
}
