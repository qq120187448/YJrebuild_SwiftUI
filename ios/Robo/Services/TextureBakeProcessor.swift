import CoreGraphics
import Foundation
import SceneKit
import simd
import UIKit

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
    let plyURL: URL
    let jsonURL: URL
    let textureURLs: [URL]
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
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
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

        let scene = SCNScene()
        addLights(to: scene)
        var textureURLs: [URL] = []
        var segmentInfo: [[String: Any]] = []

        for (index, segment) in segments.enumerated() {
            let fraction = 0.08 + 0.78 * Double(index) / Double(segments.count)
            progress(fraction, "烘焙墙面 \(index + 1)/\(segments.count)")
            let textureURL = outputDirectory.appendingPathComponent("wall-\(index + 1).jpg")
            let image = bakeTexture(for: segment, mesh: data.mesh, photos: data.photos)
            if let image, let jpeg = image.jpegData(compressionQuality: 0.9) {
                try jpeg.write(to: textureURL)
                textureURLs.append(textureURL)
            }

            let geometry = makeGeometry(for: segment, mesh: data.mesh, textureImage: image)
            let node = SCNNode(geometry: geometry)
            node.name = "wall-\(index + 1)"
            scene.rootNode.addChildNode(node)

            segmentInfo.append([
                "name": "wall-\(index + 1)",
                "kind": segment.kindName,
                "widthM": segment.width,
                "heightM": segment.height,
                "texture": textureURL.lastPathComponent
            ])
        }

        progress(0.9, "导出 USDZ / PLY / JSON")
        let usdzURL = outputDirectory.appendingPathComponent("texture-model.usdz")
        guard scene.write(to: usdzURL, options: nil, delegate: nil, progressHandler: nil) else {
            throw TextureScanError.exportFailed("USDZ 导出失败")
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
            "version": "0.5.1",
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
            plyURL: plyURL,
            jsonURL: jsonURL,
            textureURLs: textureURLs
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

    private static func makeGeometry(
        for segment: TextureWallSegment,
        mesh: TextureScanMesh,
        textureImage: UIImage?
    ) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var textureCoordinates: [CGPoint] = []
        var indices: [Int32] = []

        let normalVector = SCNVector3(segment.normal.x, segment.normal.y, segment.normal.z)
        for face in segment.faces {
            for offset in 0..<3 {
                let globalIndex = mesh.indices[face * 3 + offset]
                let point = mesh.vertices[globalIndex]
                positions.append(SCNVector3(point.x, point.y, point.z))
                normals.append(normalVector)
                let u = (simd_dot(point, segment.uAxis) - segment.minU) / segment.width
                let v = (simd_dot(point, segment.vAxis) - segment.minV) / segment.height
                textureCoordinates.append(CGPoint(x: CGFloat(u), y: CGFloat(1 - v)))
                indices.append(Int32(positions.count - 1))
            }
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
        if let textureImage {
            material.diffuse.contents = textureImage
        } else {
            material.diffuse.contents = UIColor(red: 0.75, green: 0.8, blue: 0.86, alpha: 1)
        }
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        geometry.materials = [material]
        return geometry
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

    private static func writePLY(
        segments: [TextureWallSegment],
        mesh: TextureScanMesh,
        textureURLs: [URL],
        to url: URL
    ) throws {
        var vertices: [String] = []
        var faces: [String] = []

        for (index, segment) in segments.enumerated() {
            let texture = index < textureURLs.count ? RGBAImage(url: textureURLs[index]) : nil
            for face in segment.faces {
                var local: [Int] = []
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
                    vertices.append(String(
                        format: "%.5f %.5f %.5f %d %d %d",
                        point.x, point.y, point.z, Int32(r), Int32(g), Int32(b)
                    ))
                    local.append(vertices.count - 1)
                }
                faces.append("3 \(local[0]) \(local[1]) \(local[2])")
            }
        }

        guard !vertices.isEmpty else {
            throw TextureScanError.exportFailed("PLY 没有可导出的几何数据")
        }
        var text = "ply\n"
        text += "format ascii 1.0\n"
        text += "comment generated by RoboScan 0.5\n"
        text += "element vertex \(vertices.count)\n"
        text += "property float x\n"
        text += "property float y\n"
        text += "property float z\n"
        text += "property uchar red\n"
        text += "property uchar green\n"
        text += "property uchar blue\n"
        text += "element face \(faces.count)\n"
        text += "property list uchar int vertex_indices\n"
        text += "end_header\n"
        text += vertices.joined(separator: "\n") + "\n"
        text += faces.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
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
