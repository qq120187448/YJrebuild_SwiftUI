import Foundation
import UIKit

enum PhotoStorage {
    static func directory() throws -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoomPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save(image: UIImage, label: String) throws -> (label: String, fileName: String) {
        let fileName = "\(UUID().uuidString).jpg"
        let url = try directory().appendingPathComponent(fileName)
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "PhotoStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法压缩照片"])
        }
        try data.write(to: url)
        return (label, fileName)
    }

    static func load(label: String, fileName: String) -> XLSXWriter.ImageAttachment? {
        guard let url = try? directory().appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return XLSXWriter.ImageAttachment(label: label, data: data, fileExtension: "jpg")
    }

    static func delete(fileName: String) {
        guard let url = try? directory().appendingPathComponent(fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
