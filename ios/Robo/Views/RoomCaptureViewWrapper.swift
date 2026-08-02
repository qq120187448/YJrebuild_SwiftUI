import SwiftUI
import RoomPlan

struct RoomCaptureViewWrapper: UIViewRepresentable {
    @Binding var stopRequested: Bool
    let onCaptureComplete: (CapturedRoom) -> Void
    let onCaptureError: (Error) -> Void
    var onRoomUpdate: (CapturedRoom) -> Void = { _ in }

    func makeUIView(context: Context) -> RoomCaptureView {
        let captureView = RoomCaptureView(frame: .zero)
        captureView.captureSession.delegate = context.coordinator
        captureView.delegate = context.coordinator
        captureView.captureSession.run(configuration: .init())
        return captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        if stopRequested {
            uiView.captureSession.stop()
            DispatchQueue.main.async {
                stopRequested = false
            }
        }
    }

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        uiView.captureSession.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCaptureComplete: onCaptureComplete,
            onCaptureError: onCaptureError,
            onRoomUpdate: onRoomUpdate
        )
    }

    @objc(RoboScanRoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, NSCoding {
        let onCaptureComplete: (CapturedRoom) -> Void
        let onCaptureError: (Error) -> Void
        let onRoomUpdate: (CapturedRoom) -> Void

        init(
            onCaptureComplete: @escaping (CapturedRoom) -> Void,
            onCaptureError: @escaping (Error) -> Void,
            onRoomUpdate: @escaping (CapturedRoom) -> Void
        ) {
            self.onCaptureComplete = onCaptureComplete
            self.onCaptureError = onCaptureError
            self.onRoomUpdate = onRoomUpdate
            super.init()
        }

        required init?(coder: NSCoder) {
            fatalError("Not implemented")
        }

        func encode(with coder: NSCoder) {}

        func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {}

        func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
            DispatchQueue.main.async {
                self.onRoomUpdate(room)
            }
        }

        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
            true
        }

        func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
            if let error {
                onCaptureError(error)
                return
            }
            onCaptureComplete(processedResult)
        }
    }
}
