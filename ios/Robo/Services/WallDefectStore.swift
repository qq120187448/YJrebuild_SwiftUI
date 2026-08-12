import Foundation
import UIKit

enum WallDefectStore {

    static func save(document: WallDefectScanDocument) throws -> URL {
        let root = rootDirectory()
        let directory = root.appendingPathComponent(document.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        let fileURL = directory.appendingPathComponent("scan.json")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func savePhoto(
        documentID: UUID,
        image: UIImage,
        depth: Data?,
        photoID: UUID
    ) throws -> (imageFileName: String, depthFileName: String?) {
        let directory = rootDirectory()
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
            .appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let jpeg = image.jpegData(compressionQuality: 0.88) else {
            throw WallDefectStoreError.imageEncodingFailed
        }
        let imageName = "\(photoID.uuidString).jpg"
        try jpeg.write(to: directory.appendingPathComponent(imageName))

        var depthName: String?
        if let depth {
            depthName = "\(photoID.uuidString).depth.bin"
            try depth.write(to: directory.appendingPathComponent(depthName ?? ""))
        }
        return (imageName, depthName)
    }

    static func saveAnnotatedPhoto(
        documentID: UUID,
        photoID: UUID,
        image: UIImage
    ) throws -> String {
        let directory = rootDirectory()
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
            .appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let jpeg = image.jpegData(compressionQuality: 0.82) else {
            throw WallDefectStoreError.imageEncodingFailed
        }
        let fileName = "\(photoID.uuidString)-annotated.jpg"
        try jpeg.write(to: directory.appendingPathComponent(fileName))
        return fileName
    }

    static func loadDocument(at url: URL) throws -> WallDefectScanDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WallDefectScanDocument.self, from: data)
    }

    static func allDocuments() -> [WallDefectScanDocument] {
        let root = rootDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return entries.compactMap { directory in
            let fileURL = directory.appendingPathComponent("scan.json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try? loadDocument(at: fileURL)
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: - 真值标定（P0：已知长度误差统计）

    static func saveCalibration(_ record: CalibrationRecord) throws {
        let url = rootDirectory().appendingPathComponent("calibration.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(record)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    static func loadCalibrations() -> [CalibrationRecord] {
        let url = rootDirectory().appendingPathComponent("calibration.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(CalibrationRecord.self, from: Data(line))
        }
    }

    static func calibrationCount() -> Int {
        loadCalibrations().count
    }

    static func delete(documentID: UUID) {
        let directory = rootDirectory().appendingPathComponent(documentID.uuidString)
        try? FileManager.default.removeItem(at: directory)
    }

    static func rootDirectory() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let root = documents.appendingPathComponent("WallDefectScans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private enum WallDefectStoreError: LocalizedError {
        case imageEncodingFailed

        var errorDescription: String? {
            switch self {
            case .imageEncodingFailed:
                return "照片编码失败"
            }
        }
    }
}
