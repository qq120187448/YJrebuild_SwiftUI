import UIKit
import CryptoKit

enum ImageCacheService {
    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("nutrition-images", isDirectory: true)
    }

    static func cachedImage(for urlString: String) -> UIImage? {
        let path = filePath(for: urlString)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    static func prefetch(urlString: String) async {
        let path = filePath(for: urlString)
        if FileManager.default.fileExists(atPath: path.path) { return }

        guard let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: path)
    }

    private static func filePath(for urlString: String) -> URL {
        let hash = SHA256.hash(data: Data(urlString.utf8))
        let name = hash.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(name)
    }
}
