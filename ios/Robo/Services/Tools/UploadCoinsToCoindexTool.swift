#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26, *)
struct UploadCoinsToCoindexTool: Tool {
    let name = "upload_coins_to_coindex"
    let description = """
        Uploads coin photos to the user's Coindex (coindex.app) album. \
        Use when the user wants to upload coins, add coins to their collection, or send photos to Coindex. \
        This will authenticate with Coindex if needed, capture photos, strip location/EXIF metadata, and upload them.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Title for the coin album, e.g. 'Morgan Silver Dollars' or 'Estate Sale Finds'")
        var albumTitle: String?

        @Guide(description: "Number of photos to capture. Defaults to letting the user take as many as they want.")
        var photoCount: Int?
    }

    let coindexService: CoindexService
    let captureCoordinator: CaptureCoordinator

    func call(arguments: Arguments) async throws -> String {
        // Step 1: Authenticate if needed
        let needsAuth = await !coindexService.isAuthenticated
        if needsAuth {
            try await coindexService.authenticate()
        }

        // Step 2: Capture photos via camera
        let subject = arguments.albumTitle ?? "coins"
        let result = try await captureCoordinator.requestCapture(type: .photo, subject: subject)

        // Parse filenames from capture result (format: "Captured N photos: file1.jpg, file2.jpg, ...")
        let filenames = parsePhotoFilenames(from: result)
        guard !filenames.isEmpty else {
            return "No photos were captured. Please try again."
        }

        // Step 3: Upload to Coindex (photos are stripped of EXIF metadata during upload)
        let title = arguments.albumTitle ?? "Robo Coin Upload \(Date().formatted(date: .abbreviated, time: .omitted))"
        let albumURL = try await coindexService.uploadPhotos(title: title, photoFilenames: filenames)

        return "Uploaded \(filenames.count) photo(s) to Coindex! View your album: \(albumURL)"
    }

    private func parsePhotoFilenames(from result: String) -> [String] {
        // The capture result contains filenames like "uuid.jpg"
        let components = result.components(separatedBy: CharacterSet(charactersIn: ",: "))
        return components.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
    }
}

#endif
