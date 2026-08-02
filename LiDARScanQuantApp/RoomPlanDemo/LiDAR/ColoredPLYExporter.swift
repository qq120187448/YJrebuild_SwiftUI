//
//  ColoredPLYExporter.swift
//  RoomPlanDemo
//
//  Writes an ARKit mesh as an ASCII PLY with per-vertex colors.
//

import ARKit
import CoreVideo
import Foundation
import simd

enum LiDARScanError: LocalizedError {
    case noData

    var errorDescription: String? {
        switch self {
        case .noData:
            return "No mesh data captured yet."
        }
    }
}

enum ColoredPLYExporter {
    static func writeColoredMeshPLY(
        anchors: [ARMeshAnchor],
        frame: ARFrame,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let totalVertices = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let totalFaces = anchors.reduce(0) { $0 + $1.geometry.faces.count / 3 }
        guard totalVertices > 0 else {
            throw LiDARScanError.noData
        }

        let fileURL = directory.appendingPathComponent("mesh_\(UUID().uuidString).ply")
        let header = """
        ply
        format ascii 1.0
        element vertex \(totalVertices)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property uchar alpha
        element face \(totalFaces)
        property list uchar int vertex_indices
        end_header

        """
        try header.write(to: fileURL, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        var chunk = ""

        for anchor in anchors {
            let transform = anchor.transform
            let vertices = anchor.geometry.vertices
            let vertexPointer = vertices.buffer.contents().assumingMemoryBound(to: SIMD3<Float>.self)

            for index in 0..<vertices.count {
                let local = vertexPointer.advanced(by: index).pointee
                let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let color = colorForWorldPosition(SIMD3<Float>(world.x, world.y, world.z), frame: frame)
                chunk.append("\(world.x) \(world.y) \(world.z) \(color.r) \(color.g) \(color.b) 255\n")
                if chunk.count > 1 << 20 {
                    try handle.write(contentsOf: Data(chunk.utf8))
                    chunk.removeAll(keepingCapacity: true)
                }
            }

            let faces = anchor.geometry.faces
            let facePointer = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
            for index in 0..<(faces.count / 3) {
                let i0 = Int(facePointer.advanced(by: index * 3).pointee)
                let i1 = Int(facePointer.advanced(by: index * 3 + 1).pointee)
                let i2 = Int(facePointer.advanced(by: index * 3 + 2).pointee)
                chunk.append("3 \(i0) \(i1) \(i2)\n")
                if chunk.count > 1 << 20 {
                    try handle.write(contentsOf: Data(chunk.utf8))
                    chunk.removeAll(keepingCapacity: true)
                }
            }
        }

        try handle.write(contentsOf: Data(chunk.utf8))
        return fileURL
    }
}

private extension ColoredPLYExporter {
    struct VertexColor {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    static func colorForWorldPosition(_ worldPosition: SIMD3<Float>, frame: ARFrame) -> VertexColor {
        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
        let imageSize = CGSize(width: imageWidth, height: imageHeight)
        let viewportSize = CGSize(width: min(imageWidth, imageHeight), height: max(imageWidth, imageHeight))

        let viewportPoint = frame.camera.projectPoint(worldPosition, orientation: .portrait, viewportSize: viewportSize)
        let normalized = CGPoint(x: viewportPoint.x / viewportSize.width, y: viewportPoint.y / viewportSize.height)
        let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        let transformed = normalized.applying(displayTransform)

        let x = Int(transformed.x * imageSize.width)
        let y = Int(transformed.y * imageSize.height)
        return samplePixel(in: frame.capturedImage, x: x, y: y)
    }

    static func samplePixel(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> VertexColor {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if format == kCVPixelFormatType_32BGRA,
           let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let offset = clampedY * bytesPerRow + clampedX * 4
            let raw = baseAddress.load(fromByteOffset: offset, as: UInt32.self)
            return VertexColor(
                r: UInt8((raw >> 16) & 0xFF),
                g: UInt8((raw >> 8) & 0xFF),
                b: UInt8(raw & 0xFF)
            )
        }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return VertexColor(r: 128, g: 128, b: 128)
        }

        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yValue = yPlane.load(fromByteOffset: clampedY * yRowBytes + clampedX, as: UInt8.self)
        let uvOffset = (clampedY / 2) * uvRowBytes + (clampedX / 2) * 2
        let uValue = uvPlane.load(fromByteOffset: uvOffset, as: UInt8.self)
        let vValue = uvPlane.load(fromByteOffset: uvOffset + 1, as: UInt8.self)
        return yuvToRGB(y: yValue, u: uValue, v: vValue)
    }

    static func yuvToRGB(y: UInt8, u: UInt8, v: UInt8) -> VertexColor {
        let yy = Double(y)
        let uu = Double(u) - 128
        let vv = Double(v) - 128

        func clamp(_ value: Double) -> UInt8 {
            UInt8(min(max(value.rounded(), 0), 255))
        }

        return VertexColor(
            r: clamp(yy + 1.402 * vv),
            g: clamp(yy - 0.344136 * uu - 0.714136 * vv),
            b: clamp(yy + 1.772 * uu)
        )
    }
}
