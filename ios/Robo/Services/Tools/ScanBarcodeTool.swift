#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26, *)
struct ScanBarcodeTool: Tool {
    let name = "scan_barcode"
    let description = """
        Launches the barcode scanner to scan a product barcode or QR code. \
        Use this when the user wants to scan a barcode, look up a product, or scan a QR code. \
        Returns the barcode value, symbology type, and nutrition info if available.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Optional description of what the user wants to scan, or 'product' by default")
        var productDescription: String
    }

    let captureCoordinator: CaptureCoordinator

    func call(arguments: Arguments) async throws -> String {
        return try await captureCoordinator.requestCapture(type: .barcode)
    }
}

#endif
