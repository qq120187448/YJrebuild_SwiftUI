import CoreGraphics
import Foundation
import ImageIO
import ModelIO
import SceneKit
import simd
import UIKit
import UniformTypeIdentifiers

struct TextureWallSegment {
    let faces: [Int]
    let normal: SIMD3<Float>
    let origin: SIMD3<Float>
    let uAxis: SIMD3<Float>
    let vAxis: SIMD3<Float>
    let minU: Float
    let minV: Float
    let width: Float
    let height: Float
    let kindName: String
}

struct TextureScanResult {
    let scanID: UUID
    let capturedAt: Date
    let deviceModel: String
    let deviceMaxResolution: String
    let photoCount: Int
    let closeUpCount: Int
    let wallCount: Int
    let atlasSize: Int
    let duration: TimeInterval
    let processingDuration: TimeInterval
    let outputDirectory: URL
    let usdzURL: URL
    let objURL: URL
    let plyURL: URL
    let jsonURL: URL
    let textureURLs: [URL]
    let previewScene: SCNScene?
}

enum TextureScanError: LocalizedError {
    case noWallSegments
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWallSegments:
            return "没有识别到可烘焙的墙面/天面网格，请重新扫描。"
        case .exportFailed(let message):
            return message
        }
    }
}

private final class RGBAImage {
    let width: Int
    let height: Int
    private let data: [UInt8]
    private let bytesPerRow: Int

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
              ) else {
            return nil
        }
        width = image.width
        height = image.height
        bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        data = pixels
    }

    func sample(x: Float, y: Float) -> (r: Float, g: Float, b: Float)? {
        let fx = min(max(0, x), Float(width - 1))
        let fy = min(max(0, y), Float(height - 1))
        let x0 = Int(fx)
        let y0 = Int(fy)
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)

        func color(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let offset = y * bytesPerRow + x * 4
            return (
                Float(data[offset]),
                Float(data[offset + 1]),
                Float(data[offset + 2])
            )
        }

        let c00 = color(x0, y0)
        let c10 = color(x1, y0)
        let c01 = color(x0, y1)
        let c11 = color(x1, y1)
        let topR = c00.0 + (c10.0 - c00.0) * tx
        let topG = c00.1 + (c10.1 - c00.1) * tx
        let topB = c00.2 + (c10.2 - c00.2) * tx
        let bottomR = c01.0 + (c11.0 - c01.0) * tx
        let bottomG = c01.1 + (c11.1 - c01.1) * tx
        let bottomB = c01.2 + (c11.2 - c01.2) * tx
        return (
            topR + (bottomR - topR) * ty,
            topG + (bottomG - topG) * ty,
            topB + (bottomB - topB) * ty
        )
    }
}

enum TextureBakeProcessor {
    static let atlasSize = 8192

    static func process(
        data: TextureScanData,
        outputDirectory: URL,
        progress: @escaping (Double, String) -> Void
    ) throws -> TextureScanResult {
        let started = Date()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let photosDirectory = outputDirectory.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)

        progress(0.02, "合并墙面网格")
        let segments = WallSegmentBuilder.segments(from: data.mesh)
        guard !segments.isEmpty else {
            throw TextureScanError.noWallSegments
        }

        var textureURLs: [URL] = []
        var previewURLs: [URL] = []
        var segmentInfo: [[String: Any]] = []

        for (index, segment) in segments.enumerated() {
            autoreleasepool {
                let fraction = 0.08 + 0.78 * Double(index) / Double(segments.count)
                progress(fraction, "烘焙墙面 \(index + 1)/\(segments.count)")
                let textureURL = outputDirectory.appendingPathComponent("wall-\(index + 1).jpg")
                let image = bakeTexture(for: segment, mesh: data.mesh, photos: data.photos)
                var writtenURL: URL?
                if let image, let jpeg = image.jpegData(compressionQuality: 0.9) {
                    try? jpeg.write(to: textureURL)
                    if FileManager.default.fileExists(atPath: textureURL.path) {
                        writtenURL = textureURL
                        textureURLs.append(textureURL)
                        let previewURL = outputDirectory.appendingPathComponent(
                            "wall-preview-\(index + 1).jpg"
                        )
                        if Self.writePreview(from: textureURL, to: previewURL) {
                            previewURLs.append(previewURL)
                        }
                    }
                }

                segmentInfo.append([
                    "name": "wall-\(index + 1)",
                    "kind": segment.kindName,
                    "widthM": segment.width,
                    "heightM": segment.height,
                    "texture": writtenURL?.lastPathComponent ?? ""
                ])
            }
        }

        progress(0.9, "导出 USDZ / PLY / JSON")
        let usdzURL = outputDirectory.appendingPathComponent("texture-model.usdz")
        let objURL = outputDirectory.appendingPathComponent("texture-model.obj")
        try writeOBJ(segments: segments, mesh: data.mesh, textureURLs: textureURLs, to: objURL)

        var usdzExported = false
        let totalFaces = segments.reduce(0) { $0 + $1.faces.count }
        if totalFaces <= 400_000 {
            autoreleasepool {
                let asset = MDLAsset(url: objURL)
                do {
                    try asset.export(to: usdzURL)
                    usdzExported = true
                } catch {
                    usdzExported = false
                }
            }
        }
        if !usdzExported {
            let fallbackScene = makeFallbackScene(
                segments: segments,
                mesh: data.mesh,
                textureURLs: textureURLs
            )
            guard fallbackScene.write(to: usdzURL, options: nil, delegate: nil, progressHandler: nil) else {
                throw TextureScanError.exportFailed("USDZ 导出失败")
            }
        }

        let plyURL = outputDirectory.appendingPathComponent("texture-model.ply")
        try writePLY(segments: segments, mesh: data.mesh, textureURLs: textureURLs, to: plyURL)

        var closeUpIDs: [String] = []
        for photo in data.photos where photo.isCloseUp {
            let destination = photosDirectory.appendingPathComponent(photo.fileURL.lastPathComponent)
            try? FileManager.default.copyItem(at: photo.fileURL, to: destination)
            closeUpIDs.append(photo.id)
        }

        let jsonURL = outputDirectory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "app": "RoboScan",
            "version": "0.5.2",
            "scanID": data.scanID.uuidString,
            "capturedAt": ISO8601DateFormatter().string(from: data.capturedAt),
            "deviceModel": data.deviceModel,
            "maxResolution": data.deviceMaxResolution,
            "photoCount": data.photos.count,
            "closeUpCount": data.photos.filter(\.isCloseUp).count,
            "wallCount": segments.count,
            "atlasSize": Self.atlasSize,
            "segments": segmentInfo,
            "closeUpPhotoIDs": closeUpIDs
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: jsonURL)

        let previewScene = makePreviewScene(
            segments: segments,
            mesh: data.mesh,
            previewURLs: previewURLs
        )

        progress(1, "完成")
        return TextureScanResult(
            scanID: data.scanID,
            capturedAt: data.capturedAt,
            deviceModel: data.deviceModel,
            deviceMaxResolution: data.deviceMaxResolution,
            photoCount: data.photos.count,
            closeUpCount: data.photos.filter(\.isCloseUp).count,
            wallCount: segments.count,
            atlasSize: Self.atlasSize,
            duration: data.duration,
            processingDuration: Date().timeIntervalSince(started),
            outputDirectory: outputDirectory,
            usdzURL: usdzURL,
            objURL: objURL,
            plyURL: plyURL,
            jsonURL: jsonURL,
            textureURLs: textureURLs,
            previewScene: previewScene
        )
    }

    private static func bakeTexture(
        for segment: TextureWallSegment,
        mesh: TextureScanMesh,
        photos: [TexturePhotoFrame]
    ) -> UIImage? {
        if let image = MetalTextureBaker.shared.bake(
            segment: segment,
            mesh: mesh,
            photos: photos,
            size: Self.atlasSize
        ) {
            return image
        }
        return bakeTextureCPU(for: segment, mesh: mesh, photos: photos)
    }

    private static func bakeTextureCPU(
        for segment: TextureWallSegment,
        mesh: TextureScanMesh,
        photos: [TexturePhotoFrame]
    ) -> UIImage? {
        let candidates = selectPhotos(for: segment, mesh: mesh, photos: photos, maxCount: 3)
        var loaded: [(TexturePhotoFrame, RGBAImage)] = []
        for photo in candidates {
            if let image = RGBAImage(url: photo.fileURL) {
                loaded.append((photo, image))
            }
            if loaded.count >= 3 { break }
        }
        guard !loaded.isEmpty else { return nil }

        let size = Self.atlasSize
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)

        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<size {
                let vTex = 1 - (Float(row) + 0.5) / Float(size)
                let worldV = segment.minV + vTex * segment.height
                for col in 0..<size {
                    let uTex = (Float(col) + 0.5) / Float(size)
                    let worldU = segment.minU + uTex * segment.width
                    let world = segment.origin + segment.uAxis * worldU + segment.vAxis * worldV
                    var sumR: Float = 0
                    var sumG: Float = 0
                    var sumB: Float = 0
                    var totalWeight: Float = 0
                    for item in loaded {
                        guard let sample = sample(
                            photo: item.0,
                            image: item.1,
                            world: world,
                            normal: segment.normal
                        ) else {
                            continue
                        }
                        sumR += sample.r * sample.weight
                        sumG += sample.g * sample.weight
                        sumB += sample.b * sample.weight
                        totalWeight += sample.weight
                    }
                    let offset = row * bytesPerRow + col * 4
                    if totalWeight > 0 {
                        pointer[offset] = UInt8(min(255, max(0, sumR / totalWeight)))
                        pointer[offset + 1] = UInt8(min(255, max(0, sumG / totalWeight)))
                        pointer[offset + 2] = UInt8(min(255, max(0, sumB / totalWeight)))
                        pointer[offset + 3] = 255
                    } else {
                        pointer[offset] = 96
                        pointer[offset + 1] = 104
                        pointer[offset + 2] = 118
                        pointer[offset + 3] = 255
                    }
                }
            }
        }

        let pixelData = Data(pixels)
        guard let provider = CGDataProvider(data: pixelData as CFData),
              let cgImage = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func sample(
        photo: TexturePhotoFrame,
        image: RGBAImage,
        world: SIMD3<Float>,
        normal: SIMD3<Float>
    ) -> (r: Float, g: Float, b: Float, weight: Float)? {
        let inverse = simd_inverse(photo.cameraTransform)
        let cameraPoint = inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard cameraPoint.z > 0.05 else { return nil }

        let fx = photo.intrinsics.columns.0.x
        let fy = photo.intrinsics.columns.1.y
        let cx = photo.intrinsics.columns.2.x
        let cy = photo.intrinsics.columns.2.y
        let px = fx * cameraPoint.x / cameraPoint.z + cx
        let py = fy * cameraPoint.y / cameraPoint.z + cy
        guard px >= 0, py >= 0,
              px < Float(photo.imageWidth - 1),
              py < Float(photo.imageHeight - 1) else {
            return nil
        }

        let toCamera = SIMD3<Float>(-cameraPoint.x, -cameraPoint.y, -cameraPoint.z)
        let distance = simd_length(toCamera)
        guard distance > 0.05, distance < 5 else { return nil }
        let cosAngle = simd_dot(normal, simd_normalize(toCamera))
        guard cosAngle > 0.25 else { return nil }
        guard let color = image.sample(x: px, y: py) else { return nil }

        var weight = cosAngle * cosAngle / (1 + distance * distance)
        if photo.isCloseUp {
            weight *= 2.5
        }
        return (color.r, color.g, color.b, weight)
    }

    static func selectPhotos(
        for segment: TextureWallSegment,
        mesh: TextureScanMesh,
        photos: [TexturePhotoFrame],
        maxCount: Int
    ) -> [TexturePhotoFrame] {
        let corners = [
            segment.origin,
            segment.origin + segment.uAxis * segment.width,
            segment.origin + segment.vAxis * segment.height,
            segment.origin + segment.uAxis * segment.width + segment.vAxis * segment.height
        ]
        var scored: [(score: Double, photo: TexturePhotoFrame)] = []

        for photo in photos {
            let inverse = simd_inverse(photo.cameraTransform)
            let fx = photo.intrinsics.columns.0.x
            let fy = photo.intrinsics.columns.1.y
            let cx = photo.intrinsics.columns.2.x
            let cy = photo.intrinsics.columns.2.y
            var visible = 0
            var bestCos: Float = 0

            for corner in corners {
                let cameraPoint = inverse * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
                guard cameraPoint.z > 0.05 else { continue }
                let px = fx * cameraPoint.x / cameraPoint.z + cx
                let py = fy * cameraPoint.y / cameraPoint.z + cy
                if px >= 0, py >= 0,
                   px < Float(photo.imageWidth),
                   py < Float(photo.imageHeight) {
                    visible += 1
                }
                let toCamera = SIMD3<Float>(-cameraPoint.x, -cameraPoint.y, -cameraPoint.z)
                let cosAngle = simd_dot(segment.normal, simd_normalize(toCamera))
                bestCos = max(bestCos, cosAngle)
            }

            guard visible >= 2 else { continue }
            let coverage = Double(visible) / Double(corners.count)
            let angle = Double(max(bestCos, 0.2))
            let closeUpBonus = photo.isCloseUp ? 1.8 : 1.0
            scored.append((coverage * angle * closeUpBonus, photo))
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(maxCount).map(\.photo))
    }

    private struct TextureTriangleSoup {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
    }

    private static func triangleSoup(
        for segment: TextureWallSegment,
        mesh: TextureScanMesh
    ) -> TextureTriangleSoup {
        var soup = TextureTriangleSoup()
        let normal = segment.normal
        for face in segment.faces {
            for offset in 0..<3 {
                let globalIndex = mesh.indices[face * 3 + offset]
                let point = mesh.vertices[globalIndex]
                let u = (simd_dot(point, segment.uAxis) - segment.minU) / segment.width
                let v = (simd_dot(point, segment.vAxis) - segment.minV) / segment.height
                soup.positions.append(point)
                soup.normals.append(normal)
                soup.uvs.append(SIMD2<Float>(u, v))
            }
        }
        return soup
    }

    private static func makeGeometry(
        for segment: TextureWallSegment,
        mesh: TextureScanMesh,
        textureContents: Any?
    ) -> SCNGeometry {
        let soup = triangleSoup(for: segment, mesh: mesh)
        let positions = soup.positions.map {
            SCNVector3($0.x, $0.y, $0.z)
        }
        let normals = soup.normals.map {
            SCNVector3($0.x, $0.y, $0.z)
        }
        let textureCoordinates = soup.uvs.map {
            CGPoint(x: CGFloat($0.x), y: CGFloat(1 - $0.y))
        }
        var indices: [Int32] = []
        indices.reserveCapacity(positions.count)
        for index in 0..<positions.count {
            indices.append(Int32(index))
        }

        let positionSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let textureSource = SCNGeometrySource(textureCoordinates: textureCoordinates)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(
            sources: [positionSource, normalSource, textureSource],
            elements: [element]
        )

        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = true
        if let textureContents {
            material.diffuse.contents = textureContents
        } else {
            material.diffuse.contents = UIColor(red: 0.75, green: 0.8, blue: 0.86, alpha: 1)
        }
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        geometry.materials = [material]
        return geometry
    }

    private static func writeOBJ(
        segments: [TextureWallSegment],
        mesh: TextureScanMesh,
        textureURLs: [URL],
        to objURL: URL
    ) throws {
        let mtlURL = objURL.deletingPathExtension().appendingPathExtension("mtl")
        var mtl = "# RoboScan materials\n"
        for (index, _) in segments.enumerated() {
            mtl += "newmtl wall\(index + 1)\n"
            mtl += "Kd 1 1 1\n"
            if index < textureURLs.count {
                mtl += "map_Kd \(textureURLs[index].lastPathComponent)\n"
            }
            mtl += "\n"
        }
        try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)

        FileManager.default.createFile(atPath: objURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: objURL)
        defer {
            try? handle.close()
        }
        func write(_ text: String) {
            handle.write(Data(text.utf8))
        }
        write("# RoboScan 0.5.2\n")
        write("mtllib \(mtlURL.lastPathComponent)\n")

        var buffer = ""
        var vertexOffset = 0
        for (index, segment) in segments.enumerated() {
            let soup = triangleSoup(for: segment, mesh: mesh)
            guard !soup.positions.isEmpty else { continue }
            buffer += "usemtl wall\(index + 1)\n"

            for position in soup.positions {
                buffer += String(format: "v %.5f %.5f %.5f\n", position.x, position.y, position.z)
            }
            for normal in soup.normals {
                buffer += String(format: "vn %.5f %.5f %.5f\n", normal.x, normal.y, normal.z)
            }
            for uv in soup.uvs {
                buffer += String(format: "vt %.5f %.5f\n", uv.x, 1 - uv.y)
            }

            let faceCount = soup.positions.count / 3
            for face in 0..<faceCount {
                let a = vertexOffset + face * 3 + 1
                let b = vertexOffset + face * 3 + 2
                let c = vertexOffset + face * 3 + 3
                buffer += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
            }
            vertexOffset += soup.positions.count
            if buffer.count > 65_536 {
                write(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            write(buffer)
        }
    }

    private static func addLights(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 900
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 650
        directional.eulerAngles = SCNVector3(-0.6, 0.4, 0)
        scene.rootNode.addChildNode(directional)
    }

    private static func makeFallbackScene(
        segments: [TextureWallSegment],
        mesh: TextureScanMesh,
        textureURLs: [URL]
    ) -> SCNScene {
        let scene = SCNScene()
        addLights(to: scene)
        for (index, segment) in segments.enumerated() {
            let textureURL = index < textureURLs.count ? textureURLs[index] : nil
            let geometry = makeGeometry(for: segment, mesh: mesh, textureContents: textureURL)
            let node = SCNNode(geometry: geometry)
            node.name = "wall-\(index + 1)"
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    private static func makePreviewScene(
        segments: [TextureWallSegment],
        mesh: TextureScanMesh,
        previewURLs: [URL]
    ) -> SCNScene {
        let scene = SCNScene()
        addLights(to: scene)
        for (index, segment) in segments.enumerated() {
            let contents: Any? = index < previewURLs.count
                ? (UIImage(contentsOfFile: previewURLs[index].path) ?? UIColor(red: 0.75, green: 0.8, blue: 0.86, alpha: 1))
                : UIColor(red: 0.75, green: 0.8, blue: 0.86, alpha: 1)
            let geometry = makeGeometry(for: segment, mesh: mesh, textureContents: contents)
            let node = SCNNode(geometry: geometry)
            node.name = "wall-\(index + 1)"
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    private static func writePreview(from sourceURL: URL, to previewURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceCreateThumbnailWithTransform: false
                ] as CFDictionary
              ),
              let destination = CGImageDestinationCreateWithURL(
                previewURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            return false
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func writePLY(
        segments: [TextureWallSegment],
        mesh: TextureScanMesh,
        textureURLs: [URL],
        to url: URL
    ) throws {
        var vertexCount = 0
        var faceCount = 0
        for segment in segments {
            vertexCount += segment.faces.count * 3
            faceCount += segment.faces.count
        }
        guard vertexCount > 0 else {
            throw TextureScanError.exportFailed("PLY 没有可导出的几何数据")
        }

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
        header += "comment generated by RoboScan 0.5.2\n"
        header += "element vertex \(vertexCount)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "property uchar red\n"
        header += "property uchar green\n"
        header += "property uchar blue\n"
        header += "element face \(faceCount)\n"
        header += "property list uchar int vertex_indices\n"
        header += "end_header\n"
        write(header)

        var buffer = ""
        var vertexCursor = 0
        for (index, segment) in segments.enumerated() {
            let texture = index < textureURLs.count ? RGBAImage(url: textureURLs[index]) : nil
            for face in segment.faces {
                for offset in 0..<3 {
                    let globalIndex = mesh.indices[face * 3 + offset]
                    let point = mesh.vertices[globalIndex]
                    let u = (simd_dot(point, segment.uAxis) - segment.minU) / segment.width
                    let v = (simd_dot(point, segment.vAxis) - segment.minV) / segment.height
                    var r: UInt8 = 190
                    var g: UInt8 = 200
                    var b: UInt8 = 210
                    if let texture {
                        let sampleX = min(max(0, Float(u) * Float(texture.width)), Float(texture.width - 1))
                        let sampleY = min(max(0, Float(1 - v) * Float(texture.height)), Float(texture.height - 1))
                        if let color = texture.sample(x: sampleX, y: sampleY) {
                            r = UInt8(min(255, max(0, color.r)))
                            g = UInt8(min(255, max(0, color.g)))
                            b = UInt8(min(255, max(0, color.b)))
                        }
                    }
                    buffer += String(
                        format: "%.5f %.5f %.5f %d %d %d\n",
                        point.x, point.y, point.z, Int32(r), Int32(g), Int32(b)
                    )
                }
                buffer += "3 \(vertexCursor) \(vertexCursor + 1) \(vertexCursor + 2)\n"
                vertexCursor += 3
                if buffer.count > 65_536 {
                    write(buffer)
                    buffer = ""
                }
            }
        }
        if !buffer.isEmpty {
            write(buffer)
        }
    }
}

private enum WallSegmentBuilder {
    private struct Key: Hashable {
        let axis: Int
        let sign: Int
        let offsetBucket: Int
    }

    static func segments(from mesh: TextureScanMesh) -> [TextureWallSegment] {
        guard mesh.faceCount > 0 else { return [] }

        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.faceCount)
        for face in 0..<mesh.faceCount {
            let i0 = mesh.indices[face * 3]
            let i1 = mesh.indices[face * 3 + 1]
            let i2 = mesh.indices[face * 3 + 2]
            let v0 = mesh.vertices[i0]
            let v1 = mesh.vertices[i1]
            let v2 = mesh.vertices[i2]
            let normal = simd_cross(v1 - v0, v2 - v0)
            let length = simd_length(normal)
            if length > 0.0001 {
                normals[face] = normal / length
            }
        }

        var groups: [Key: [Int]] = [:]
        for face in 0..<mesh.faceCount {
            let normal = normals[face]
            if !normal.x.isFinite || !normal.y.isFinite || !normal.z.isFinite { continue }
            let ax = abs(normal.x)
            let ay = abs(normal.y)
            let az = abs(normal.z)
            guard max(ax, max(ay, az)) > 0.6 else { continue }

            var axis = 0
            var value = normal.x
            if ay > abs(value) {
                axis = 1
                value = normal.y
            }
            if az > abs(value) {
                axis = 2
                value = normal.z
            }
            let sign = value >= 0 ? 1 : -1
            let centroid = centroidOfFace(face, mesh: mesh)
            let offset = axis == 0 ? centroid.x : (axis == 1 ? centroid.y : centroid.z)
            let bucket = Int((offset / 0.1).rounded())
            groups[Key(axis: axis, sign: sign, offsetBucket: bucket), default: []].append(face)
        }

        var result: [TextureWallSegment] = []
        for (key, faces) in groups where faces.count >= 3 {
            let normal: SIMD3<Float>
            switch (key.axis, key.sign) {
            case (0, 1): normal = SIMD3(1, 0, 0)
            case (0, -1): normal = SIMD3(-1, 0, 0)
            case (1, 1): normal = SIMD3(0, 1, 0)
            case (1, -1): normal = SIMD3(0, -1, 0)
            case (2, 1): normal = SIMD3(0, 0, 1)
            default: normal = SIMD3(0, 0, -1)
            }

            let uAxis: SIMD3<Float>
            let vAxis: SIMD3<Float>
            if key.axis == 1 {
                uAxis = SIMD3(1, 0, 0)
                vAxis = SIMD3(0, 0, 1)
            } else {
                uAxis = simd_normalize(simd_cross(SIMD3(0, 1, 0), normal))
                vAxis = SIMD3(0, 1, 0)
            }

            var minU = Float.greatestFiniteMagnitude
            var minV = Float.greatestFiniteMagnitude
            var maxU = -Float.greatestFiniteMagnitude
            var maxV = -Float.greatestFiniteMagnitude
            for face in faces {
                for offset in 0..<3 {
                    let point = mesh.vertices[mesh.indices[face * 3 + offset]]
                    minU = min(minU, simd_dot(point, uAxis))
                    maxU = max(maxU, simd_dot(point, uAxis))
                    minV = min(minV, simd_dot(point, vAxis))
                    maxV = max(maxV, simd_dot(point, vAxis))
                }
            }

            let width = maxU - minU
            let height = maxV - minV
            guard width > 0.05, height > 0.05 else { continue }

            var offsetSum: Float = 0
            for face in faces {
                let centroid = centroidOfFace(face, mesh: mesh)
                offsetSum += simd_dot(centroid, normal)
            }
            let planeOrigin = normal * (offsetSum / Float(faces.count))
            let origin = planeOrigin + uAxis * minU + vAxis * minV
            let kindName = majorityKindName(faces: faces, mesh: mesh)
            result.append(TextureWallSegment(
                faces: faces,
                normal: normal,
                origin: origin,
                uAxis: uAxis,
                vAxis: vAxis,
                minU: minU,
                minV: minV,
                width: width,
                height: height,
                kindName: kindName
            ))
        }

        return result.sorted { $0.faces.count > $1.faces.count }
    }

    private static func centroidOfFace(_ face: Int, mesh: TextureScanMesh) -> SIMD3<Float> {
        let i0 = mesh.indices[face * 3]
        let i1 = mesh.indices[face * 3 + 1]
        let i2 = mesh.indices[face * 3 + 2]
        return (mesh.vertices[i0] + mesh.vertices[i1] + mesh.vertices[i2]) / 3
    }

    private static func majorityKindName(faces: [Int], mesh: TextureScanMesh) -> String {
        var votes: [Int: Int] = [:]
        for face in faces {
            if face < mesh.faceClassifications.count {
                votes[mesh.faceClassifications[face], default: 0] += 1
            }
        }
        let kind = votes.max(by: { $0.value < $1.value })?.key ?? 0
        switch kind {
        case 1: return "墙面"
        case 2: return "地面"
        case 3: return "天面"
        default: return "表面"
        }
    }
}
