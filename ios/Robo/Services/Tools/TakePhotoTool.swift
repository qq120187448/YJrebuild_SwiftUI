#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26, *)
struct TakePhotoTool: Tool {
    let name = "take_photo"
    let description = """
        Launches the camera to take photos. \
        Use this when the user wants to capture a photo, take a picture, or photograph something. \
        Returns a confirmation with the number of photos captured.
        """

    @Generable
    struct Arguments {
        @Guide(description: "What the user wants to photograph, e.g. 'my desk' or 'the kitchen'")
        var subject: String
    }

    let captureCoordinator: CaptureCoordinator

    func call(arguments: Arguments) async throws -> String {
        return try await captureCoordinator.requestCapture(type: .photo, subject: arguments.subject)
    }
}

#endif
