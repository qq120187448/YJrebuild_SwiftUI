import SwiftUI
import SceneKit
import simd

struct ObjectPointCloud3DView: UIViewRepresentable {
    let points: [ObjectPoint]

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)

        let scene = SCNScene()
        scnView.scene = scene

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.name = "orbitCamera"
        let distance = max(boundingDiagonal(points) * 1.6, 0.9)
        cameraNode.position = SCNVector3(0, boundingDiagonal(points) * 0.45, distance)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .ambient
        lightNode.light?.color = UIColor(white: 0.75, alpha: 1)
        scene.rootNode.addChildNode(lightNode)

        rebuild(in: scnView)
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        rebuild(in: scnView)
    }

    private func rebuild(in scnView: SCNView) {
        guard let scene = scnView.scene else { return }
        scene.rootNode.childNodes
            .filter { $0.name == "objectPoints" }
            .forEach { $0.removeFromParentNode() }
        guard !points.isEmpty else { return }

        let geometry = SCNGeometry.objectPointCloud(points: points)
        let node = SCNNode(geometry: geometry)
        node.name = "objectPoints"
        let centroid = points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(points.count)
        node.position = SCNVector3(-centroid.x, -centroid.y, -centroid.z)
        scene.rootNode.addChildNode(node)
    }

    private func boundingDiagonal(_ points: [ObjectPoint]) -> Float {
        guard !points.isEmpty else { return 1 }
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            minZ = min(minZ, point.z)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
            maxZ = max(maxZ, point.z)
        }
        let dx = maxX - minX
        let dy = maxY - minY
        let dz = maxZ - minZ
        return max(sqrt(dx * dx + dy * dy + dz * dz), 0.3)
    }
}

extension SCNGeometry {
    static func objectPointCloud(
        points: [ObjectPoint],
        pointSize: CGFloat = 6,
        material overrideMaterial: SCNMaterial? = nil
    ) -> SCNGeometry {
        let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        var colorValues: [Float] = []
        colorValues.reserveCapacity(points.count * 4)
        for point in points {
            colorValues.append(point.r)
            colorValues.append(point.g)
            colorValues.append(point.b)
            colorValues.append(1)
        }
        let colorData = colorValues.withUnsafeBytes { rawBuffer in
            Data(bytes: rawBuffer.baseAddress!, count: rawBuffer.count)
        }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: 4,
            dataOffset: 0,
            dataStride: 16
        )

        let indices = (0..<Int32(points.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = overrideMaterial ?? SCNMaterial()
        material.lightingModel = .constant
        if overrideMaterial == nil {
            material.diffuse.contents = UIColor.white
        }
        material.shaderModifiers = [
            .geometry: "#pragma body\n_geometry.pointSize = \(pointSize);"
        ]
        geometry.materials = [material]
        return geometry
    }
}
