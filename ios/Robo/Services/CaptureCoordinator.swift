import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.silv.Robo", category: "CaptureCoordinator")

#if canImport(FoundationModels)

enum CaptureType {
    case lidar
    case barcode
    case photo
}

struct PendingCapture: Identifiable {
    let id = UUID()
    let type: CaptureType
    let roomName: String?
    let subject: String?
    let continuation: CheckedContinuation<String, Error>
}

@available(iOS 26, *)
@MainActor
@Observable
class CaptureCoordinator {
    var pendingCapture: PendingCapture?

    func requestCapture(type: CaptureType, roomName: String? = nil, subject: String? = nil) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            pendingCapture = PendingCapture(
                type: type,
                roomName: roomName,
                subject: subject,
                continuation: continuation
            )
            logger.info("Pending capture set: \(String(describing: type))")
        }
    }

    func completeCapture(result: String) {
        guard let capture = pendingCapture else {
            logger.warning("completeCapture called with no pending capture")
            return
        }
        pendingCapture = nil
        capture.continuation.resume(returning: result)
    }

    func cancelCapture() {
        guard let capture = pendingCapture else { return }
        pendingCapture = nil
        capture.continuation.resume(throwing: CancellationError())
    }
}

/// ViewModifier that injects CaptureCoordinator into the environment on iOS 26+.
@available(iOS 26, *)
private struct CaptureCoordinatorInjector: ViewModifier {
    @State private var coordinator = CaptureCoordinator()

    func body(content: Content) -> some View {
        content.environment(coordinator)
    }
}

#endif

/// ViewModifier safe to use unconditionally. Injects CaptureCoordinator on iOS 26+, no-op otherwise.
struct CaptureCoordinatorModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            content.modifier(CaptureCoordinatorInjector())
        } else {
            content
        }
        #else
        content
        #endif
    }
}
