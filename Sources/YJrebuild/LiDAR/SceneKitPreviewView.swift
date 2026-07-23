import SwiftUI
import SceneKit
import ARKit

/// 3D model preview using SceneKit
struct SceneKitPreviewView: UIViewRepresentable {
    let scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func buildScene(from meshData: Data) -> SCNScene {
        let scene = SCNScene()
        let node = SCNNode()

        guard let string = String(data: meshData, encoding: .utf8) else { return scene }

        var vertices: [SCNVector3] = []
        var faces: [(Int, Int, Int)] = []

        for line in string.components(separatedBy: "\n") {
            if line.hasPrefix("v ") {
                let parts = line.components(separatedBy: " ").compactMap { Float($0) }
                if parts.count >= 3 { vertices.append(SCNVector3(parts[0], parts[1], parts[2])) }
            } else if line.hasPrefix("f ") {
                let parts = line.components(separatedBy: " ").compactMap { Int($0) }
                if parts.count >= 3 { faces.append((parts[0] - 1, parts[1] - 1, parts[2] - 1)) }
            }
        }

        guard !vertices.isEmpty, !faces.isEmpty else { return scene }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        var indices: [Int32] = []
        for f in faces { indices += [Int32(f.0), Int32(f.1), Int32(f.2)] }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        geometry.firstMaterial?.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.7)
        geometry.firstMaterial?.isDoubleSided = true

        node.geometry = geometry
        scene.rootNode.addChildNode(node)
        return scene
    }
}

