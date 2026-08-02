import UIKit

enum PhotoStorageService {
    private static let photosDir = "ProductPhotos"
    private static let thumbsDir = "ProductThumbs"
    private static let thumbMaxDimension: CGFloat = 400
    private static let jpegQuality: CGFloat = 0.8

    // MARK: - Save

    /// Save full-res JPEG to disk, returns filename (UUID.jpg) or nil on failure.
    static func save(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: jpegQuality) else { return nil }
        let filename = "\(UUID().uuidString).jpg"

        guard let dir = photosDirectory() else { return nil }
        let url = dir.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        // Generate thumbnail alongside
        saveThumbnail(image, filename: filename)
        return filename
    }

    /// Generate and save a thumbnail.
    @discardableResult
    static func saveThumbnail(_ image: UIImage, filename: String) -> Bool {
        guard let dir = thumbsDirectory() else { return false }

        let scale = min(thumbMaxDimension / image.size.width, thumbMaxDimension / image.size.height, 1.0)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let data = thumb.jpegData(compressionQuality: 0.7) else { return false }
        let url = dir.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Load

    static func load(_ filename: String) -> UIImage? {
        guard let dir = photosDirectory() else { return nil }
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func loadThumbnail(_ filename: String) -> UIImage? {
        guard let dir = thumbsDirectory() else { return nil }
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Delete

    static func delete(_ filenames: [String]) {
        let fm = FileManager.default
        if let photoDir = photosDirectory() {
            for name in filenames {
                try? fm.removeItem(at: photoDir.appendingPathComponent(name))
            }
        }
        if let thumbDir = thumbsDirectory() {
            for name in filenames {
                try? fm.removeItem(at: thumbDir.appendingPathComponent(name))
            }
        }
    }

    // MARK: - List All Photos

    static func listAll() -> [(filename: String, date: Date)] {
        guard let dir = photosDirectory() else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files
            .filter { $0.hasSuffix(".jpg") }
            .compactMap { filename -> (String, Date)? in
                let url = dir.appendingPathComponent(filename)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                return (filename, date)
            }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: - Directories

    private static func photosDirectory() -> URL? {
        ensureDirectory(named: photosDir)
    }

    private static func thumbsDirectory() -> URL? {
        ensureDirectory(named: thumbsDir)
    }

    private static func ensureDirectory(named name: String) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
