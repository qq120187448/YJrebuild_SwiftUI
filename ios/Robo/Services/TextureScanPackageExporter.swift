import Foundation
import simd

enum TextureScanPackageExporter {
    static func export(data: TextureScanData, outputDirectory: URL) throws -> URL {
        let packageDirectory = outputDirectory.appendingPathComponent("scan-package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let photosDirectory = packageDirectory.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)

        var poseItems: [[String: Any]] = []
        for photo in data.photos {
            let destination = photosDirectory.appendingPathComponent(photo.fileURL.lastPathComponent)
            try? FileManager.default.copyItem(at: photo.fileURL, to: destination)
            poseItems.append([
                "id": photo.id,
                "file": photo.fileURL.lastPathComponent,
                "timestamp": photo.timestamp,
                "isCloseUp": photo.isCloseUp,
                "distance": photo.distance,
                "imageWidth": photo.imageWidth,
                "imageHeight": photo.imageHeight,
                "cameraTransform": flatten4x4(photo.cameraTransform),
                "intrinsics": flatten3x3(photo.intrinsics)
            ])
        }

        let posesURL = packageDirectory.appendingPathComponent("poses.json")
        let posesData = try JSONSerialization.data(withJSONObject: poseItems, options: [.prettyPrinted, .sortedKeys])
        try posesData.write(to: posesURL)

        let meshURL = packageDirectory.appendingPathComponent("mesh.ply")
        try writeMeshPLY(mesh: data.mesh, to: meshURL)

        let manifest: [String: Any] = [
            "format": "RoboScanTexturePackage",
            "version": "1.0",
            "scanID": data.scanID.uuidString,
            "capturedAt": ISO8601DateFormatter().string(from: data.capturedAt),
            "deviceModel": data.deviceModel,
            "maxResolution": data.deviceMaxResolution,
            "photoCount": data.photos.count,
            "closeUpCount": data.photos.filter(\.isCloseUp).count,
            "meshVertexCount": data.mesh.vertices.count,
            "meshFaceCount": data.mesh.faceCount,
            "coordinateSystem": "ARKit world coordinates, meters, y-up"
        ]
        let manifestURL = packageDirectory.appendingPathComponent("manifest.json")
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: manifestURL)

        let zipURL = outputDirectory.appendingPathComponent("scan-package-\(data.scanID.uuidString).zip")
        guard let zip = ZipWriter(url: zipURL) else {
            throw TextureScanError.exportFailed("无法创建扫描包 ZIP")
        }
        let photoFiles = try FileManager.default.contentsOfDirectory(
            at: photosDirectory,
            includingPropertiesForKeys: nil
        )
        for file in photoFiles {
            try zip.addFile(at: file, path: "photos/\(file.lastPathComponent)")
        }
        try zip.addFile(at: posesURL, path: "poses.json")
        try zip.addFile(at: meshURL, path: "mesh.ply")
        try zip.addFile(at: manifestURL, path: "manifest.json")
        try zip.finish()
        return zipURL
    }

    private static func writeMeshPLY(mesh: TextureScanMesh, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        func write(_ text: String) {
            handle.write(Data(text.utf8))
        }

        var header = "ply\n"
        header += "format ascii 1.0\n"
        header += "comment RoboScan scan package\n"
        header += "element vertex \(mesh.vertices.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "element face \(mesh.faceCount)\n"
        header += "property list uchar int vertex_indices\n"
        header += "end_header\n"
        write(header)

        var buffer = ""
        for vertex in mesh.vertices {
            buffer += String(format: "%.5f %.5f %.5f\n", vertex.x, vertex.y, vertex.z)
            if buffer.count > 65_536 {
                write(buffer)
                buffer = ""
            }
        }
        for face in 0..<mesh.faceCount {
            let i0 = mesh.indices[face * 3]
            let i1 = mesh.indices[face * 3 + 1]
            let i2 = mesh.indices[face * 3 + 2]
            buffer += "3 \(i0) \(i1) \(i2)\n"
            if buffer.count > 65_536 {
                write(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            write(buffer)
        }
    }

    private static func flatten4x4(_ matrix: simd_float4x4) -> [Double] {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        return columns.flatMap { column in
            [
                Double(column.x),
                Double(column.y),
                Double(column.z),
                Double(column.w)
            ]
        }
    }

    private static func flatten3x3(_ matrix: simd_float3x3) -> [Double] {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2]
        return columns.flatMap { column in
            [
                Double(column.x),
                Double(column.y),
                Double(column.z)
            ]
        }
    }
}
