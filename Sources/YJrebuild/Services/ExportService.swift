import Foundation
import SceneKit

/// 3D file format export service
class ExportService {
    enum Format: String, CaseIterable {
        case obj = "OBJ"
        case stl = "STL"
        case ply = "PLY"
        case usdz = "USDZ"
    }

    /// Export mesh data to file
    static func export(meshData: Data, format: Format, includeTextures: Bool = true) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let filename = "YJrebuild_\(Date().timeIntervalSince1970).\(format.fileExtension)"
        let fileURL = docs.appendingPathComponent(filename)

        switch format {
        case .obj: return writeOBJ(meshData, to: fileURL)
        case .stl: return writeSTL(meshData, to: fileURL)
        case .ply: return writePLY(meshData, to: fileURL)
        case .usdz: return writeUSDZ(meshData, to: fileURL)
        }
    }

    private static func writeOBJ(_ data: Data, to url: URL) -> URL? {
        do {
            try data.write(to: url)
            return url
        } catch { return nil }
    }

    private static func writeSTL(_ data: Data, to url: URL) -> URL? {
        guard let objStr = String(data: data, encoding: .utf8) else { return nil }
        var vertices: [SIMD3<Float>] = []
        var faces: [(Int, Int, Int)] = []

        for line in objStr.components(separatedBy: "\n") {
            if line.hasPrefix("v ") {
                let p = line.components(separatedBy: " ").compactMap { Float($0) }
                if p.count >= 3 { vertices.append(SIMD3(p[0], p[1], p[2])) }
            } else if line.hasPrefix("f ") {
                let f = line.components(separatedBy: " ").compactMap { Int($0) }
                if f.count >= 3 { faces.append((f[0] - 1, f[1] - 1, f[2] - 1)) }
            }
        }

        guard !vertices.isEmpty, !faces.isEmpty else { return nil }

        var stlStr = "solid YJrebuild_Model\n"
        for face in faces {
            let v0 = vertices[face.0], v1 = vertices[face.1], v2 = vertices[face.2]
            let normal = normalize(cross(v1 - v0, v2 - v0))
            stlStr += "  facet normal \(normal.x) \(normal.y) \(normal.z)\n"
            stlStr += "    outer loop\n"
            stlStr += "      vertex \(v0.x) \(v0.y) \(v0.z)\n"
            stlStr += "      vertex \(v1.x) \(v1.y) \(v1.z)\n"
            stlStr += "      vertex \(v2.x) \(v2.y) \(v2.z)\n"
            stlStr += "    endloop\n"
            stlStr += "  endfacet\n"
        }
        stlStr += "endsolid YJrebuild_Model\n"

        do { try stlStr.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    private static func writePLY(_ data: Data, to url: URL) -> URL? {
        do { try data.write(to: url); return url } catch { return nil }
    }

    private static func writeUSDZ(_ data: Data, to url: URL) -> URL? {
        guard let objStr = String(data: data, encoding: .utf8) else { return nil }
        var vertices: [SCNVector3] = []
        var faces: [(Int, Int, Int)] = []
        for line in objStr.components(separatedBy: "\n") {
            if line.hasPrefix("v ") {
                let p = line.components(separatedBy: " ").compactMap { Float($0) }
                if p.count >= 3 { vertices.append(SCNVector3(p[0], p[1], p[2])) }
            } else if line.hasPrefix("f ") {
                let f = line.components(separatedBy: " ").compactMap { Int($0) }
                if f.count >= 3 { faces.append((f[0] - 1, f[1] - 1, f[2] - 1)) }
            }
        }
        guard !vertices.isEmpty else { return nil }
        let scene = SCNScene()
        let node = SCNNode()
        var idx: [Int32] = []
        for f in faces { idx += [Int32(f.0), Int32(f.1), Int32(f.2)] }
        let src = SCNGeometrySource(vertices: vertices)
        let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        node.geometry = SCNGeometry(sources: [src], elements: [el])
        scene.rootNode.addChildNode(node)
        scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        return url
    }
}

extension ExportService.Format {
    var fileExtension: String {
        switch self {
        case .obj: return "obj"
        case .stl: return "stl"
        case .ply: return "ply"
        case .usdz: return "usdz"
        }
    }
}
