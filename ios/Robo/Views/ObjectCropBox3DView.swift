import SwiftUI
import SceneKit
import simd

struct ObjectCropBox3DView: UIViewRepresentable {
    let points: [ObjectPoint]
    let cropVolume: ObjectCropVolume?
    let isPlacing: Bool
    let onCropVolumeChanged: (ObjectCropVolume?) -> Void
    let onCropBoxEditEnded: (ObjectCropVolume) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = !parent.isPlacing
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        scnView.scene = SCNScene()

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.name = "previewCamera"
        scnView.scene?.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .ambient
        lightNode.light?.color = UIColor(white: 0.75, alpha: 1)
        scnView.scene?.rootNode.addChildNode(lightNode)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        scnView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.cancelsTouchesInView = false
        scnView.addGestureRecognizer(pan)

        let movePan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMovePan(_:))
        )
        movePan.minimumNumberOfTouches = 2
        movePan.maximumNumberOfTouches = 2
        movePan.cancelsTouchesInView = false
        scnView.addGestureRecognizer(movePan)

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        scnView.addGestureRecognizer(pinch)

        context.coordinator.parent = self
        context.coordinator.rebuild(scnView)
        context.coordinator.updateSelection(scnView)
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuild(scnView)
        context.coordinator.updateSelection(scnView)
    }

    final class Coordinator: NSObject {
        var parent: ObjectCropBox3DView

        private enum DragMode {
            case resize
            case rotate
        }

        private var lastPointCount = -1
        private var dragMode: DragMode?
        private var dragAxis: SIMD3<Float>?
        private var dragStartScreen: CGPoint?
        private var dragStartCenter: SIMD3<Float>?
        private var dragStartExtent: SIMD3<Float>?
        private var dragDepth: Float = 0
        private var rotateStartScreen: CGPoint?
        private var rotateStartTransform: simd_float4x4?
        private var moveStartScreen: CGPoint?
        private var moveStartCenter: SIMD3<Float>?
        private var moveStartDepth: Float = 0
        private var scaleStartExtent: SIMD3<Float>?
        private var isBoxSelected = false

        init(parent: ObjectCropBox3DView) {
            self.parent = parent
        }

        func rebuild(_ scnView: SCNView) {
            guard let scene = scnView.scene else { return }
            if parent.cropVolume == nil {
                isBoxSelected = false
            }
            if parent.points.count != lastPointCount {
                lastPointCount = parent.points.count
                scene.rootNode.childNodes
                    .filter { $0.name == "objectPoints" }
                    .forEach { $0.removeFromParentNode() }
                if !parent.points.isEmpty {
                    let geometry = SCNGeometry.objectPointCloud(points: parent.points)
                    let node = SCNNode(geometry: geometry)
                    node.name = "objectPoints"
                    scene.rootNode.addChildNode(node)
                }
                positionCamera(scnView)
            }

            scene.rootNode.childNodes
                .filter { $0.name == "cropBox" }
                .forEach { $0.removeFromParentNode() }
            guard let volume = parent.cropVolume else { return }

            let root = SCNNode()
            root.name = "cropBox"
            root.simdTransform = volume.transform
            let boxColor = isBoxSelected ? UIColor.systemOrange : UIColor.systemGreen

            let fill = SCNBox(
                width: CGFloat(volume.extent.x),
                height: CGFloat(volume.extent.y),
                length: CGFloat(volume.extent.z),
                chamferRadius: 0
            )
            let fillMaterial = SCNMaterial()
            fillMaterial.lightingModel = .constant
            fillMaterial.diffuse.contents = boxColor.withAlphaComponent(0.14)
            fillMaterial.emission.contents = boxColor.withAlphaComponent(0.18)
            fillMaterial.isDoubleSided = true
            fill.firstMaterial = fillMaterial
            root.addChildNode(SCNNode(geometry: fill))

            addEdges(to: root, extent: volume.extent, color: boxColor)
            addArrows(to: root, extent: volume.extent)
            scene.rootNode.addChildNode(root)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let scnView = recognizer.view as? SCNView else {
                return
            }
            let location = recognizer.location(in: scnView)
            if !parent.isPlacing {
                if let hit = scnView.hitTest(location).first, isCropBoxHit(hit) {
                    isBoxSelected = true
                } else {
                    isBoxSelected = false
                }
                updateSelection(scnView)
                return
            }
            let near = scnView.unprojectPoint(SCNVector3(location.x, location.y, 0))
            let far = scnView.unprojectPoint(SCNVector3(location.x, location.y, 1))
            let origin = SIMD3<Float>(near.x, near.y, near.z)
            let direction = simd_normalize(SIMD3<Float>(
                far.x - near.x,
                far.y - near.y,
                far.z - near.z
            ))
            guard abs(direction.y) > 0.0001 else { return }
            let groundY = parent.points.map { $0.y }.min() ?? 0
            let t = (groundY - origin.y) / direction.y
            guard t > 0 else { return }
            let hit = origin + direction * t
            let extent = parent.cropVolume?.extent ?? SIMD3<Float>(repeating: 1.0)
            let center = hit + SIMD3<Float>(0, extent.y * 0.5, 0)
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
            parent.onCropVolumeChanged(
                ObjectCropVolume(center: center, extent: extent, transform: transform)
            )
            parent.onCropBoxEditEnded(
                ObjectCropVolume(center: center, extent: extent, transform: transform)
            )
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard isBoxSelected,
                  parent.cropVolume != nil,
                  let scnView = recognizer.view as? SCNView else {
                return
            }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                guard let hit = scnView.hitTest(
                    location,
                    options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]
                ).first,
                let volume = parent.cropVolume else {
                    return
                }
                if let name = axisName(from: hit), let axis = axis(for: name) {
                    dragMode = .resize
                    dragAxis = axis
                    dragStartScreen = location
                    dragStartCenter = volume.center
                    dragStartExtent = volume.extent
                    if let cameraNode = scnView.pointOfView {
                        let cameraPosition = SIMD3<Float>(
                            cameraNode.simdTransform.columns.3.x,
                            cameraNode.simdTransform.columns.3.y,
                            cameraNode.simdTransform.columns.3.z
                        )
                        dragDepth = max(simd_length(volume.center - cameraPosition), 0.1)
                    }
                } else if isCropBoxHit(hit) {
                    dragMode = .rotate
                    rotateStartScreen = location
                    rotateStartTransform = volume.transform
                }

            case .changed:
                if dragMode == .resize {
                    handleResizeChange(location: location, scnView: scnView)
                } else if dragMode == .rotate {
                    handleRotateChange(location: location, scnView: scnView)
                }

            case .ended, .cancelled:
                dragAxis = nil
                dragStartScreen = nil
                dragStartCenter = nil
                dragStartExtent = nil
                dragMode = nil
                rotateStartScreen = nil
                rotateStartTransform = nil
                if let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }

            default:
                break
            }
        }

        @objc func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
            guard isBoxSelected,
                  parent.cropVolume != nil,
                  let scnView = recognizer.view as? SCNView else {
                return
            }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                guard let volume = parent.cropVolume else { return }
                moveStartScreen = location
                moveStartCenter = volume.center
                if let cameraNode = scnView.pointOfView {
                    let cameraPosition = SIMD3<Float>(
                        cameraNode.simdTransform.columns.3.x,
                        cameraNode.simdTransform.columns.3.y,
                        cameraNode.simdTransform.columns.3.z
                    )
                    moveStartDepth = max(simd_length(volume.center - cameraPosition), 0.1)
                }

            case .changed:
                guard let start = moveStartScreen,
                      let startCenter = moveStartCenter,
                      let cameraNode = scnView.pointOfView,
                      let volume = parent.cropVolume else {
                    return
                }
                let dx = Float(location.x - start.x)
                let dy = Float(location.y - start.y)
                let viewport = scnView.bounds.size
                let worldDelta = worldDeltaFromScreen(
                    dx: dx,
                    dy: dy,
                    cameraNode: cameraNode,
                    center: startCenter,
                    viewport: viewport
                )
                let newCenter = startCenter + worldDelta
                var transform = volume.transform
                transform.columns.3 = SIMD4<Float>(
                    newCenter.x,
                    newCenter.y,
                    newCenter.z,
                    1
                )
                parent.onCropVolumeChanged(
                    ObjectCropVolume(
                        center: newCenter,
                        extent: volume.extent,
                        transform: transform
                    )
                )

            case .ended, .cancelled:
                moveStartScreen = nil
                moveStartCenter = nil
                if let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }

            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard isBoxSelected,
                  parent.cropVolume != nil else {
                return
            }
            switch recognizer.state {
            case .began:
                scaleStartExtent = parent.cropVolume?.extent
            case .changed:
                guard let startExtent = scaleStartExtent,
                      let volume = parent.cropVolume else {
                    return
                }
                let scale = Float(recognizer.scale)
                let newExtent = SIMD3<Float>(
                    min(max(startExtent.x * scale, 0.2), 10),
                    min(max(startExtent.y * scale, 0.2), 10),
                    min(max(startExtent.z * scale, 0.2), 10)
                )
                var transform = volume.transform
                transform.columns.3 = SIMD4<Float>(
                    volume.center.x,
                    volume.center.y,
                    volume.center.z,
                    1
                )
                parent.onCropVolumeChanged(
                    ObjectCropVolume(
                        center: volume.center,
                        extent: newExtent,
                        transform: transform
                    )
                )
            case .ended, .cancelled:
                scaleStartExtent = nil
                if let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }
            default:
                break
            }
        }

        private func handleResizeChange(location: CGPoint, scnView: SCNView) {
            guard let axis = dragAxis,
                  let start = dragStartScreen,
                  let startCenter = dragStartCenter,
                  let startExtent = dragStartExtent,
                  let cameraNode = scnView.pointOfView,
                  let volume = parent.cropVolume else {
                return
            }
            let dx = Float(location.x - start.x)
            let dy = Float(location.y - start.y)
            let viewport = scnView.bounds.size
            let worldDelta = worldDeltaFromScreen(
                dx: dx,
                dy: dy,
                cameraNode: cameraNode,
                center: startCenter,
                viewport: viewport
            )
            let amount = simd_dot(worldDelta, axis)
            var extent = startExtent
            if axis.x != 0 {
                extent.x = min(max(startExtent.x + amount * 2, 0.2), 10)
            }
            if axis.y != 0 {
                extent.y = min(max(startExtent.y + amount * 2, 0.2), 10)
            }
            if axis.z != 0 {
                extent.z = min(max(startExtent.z + amount * 2, 0.2), 10)
            }
            var transform = volume.transform
            transform.columns.3 = SIMD4<Float>(
                startCenter.x,
                startCenter.y,
                startCenter.z,
                1
            )
            parent.onCropVolumeChanged(
                ObjectCropVolume(
                    center: startCenter,
                    extent: extent,
                    transform: transform
                )
            )
        }

        private func handleRotateChange(location: CGPoint, scnView: SCNView) {
            guard let start = rotateStartScreen,
                  let startTransform = rotateStartTransform,
                  let cameraNode = scnView.pointOfView,
                  let volume = parent.cropVolume else {
                return
            }
            let dx = Float(location.x - start.x)
            let dy = Float(location.y - start.y)
            let yaw = dx * 0.006
            let pitch = dy * 0.006
            let yawQuat = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            let cameraRight = SIMD3<Float>(
                cameraNode.simdTransform.columns.0.x,
                cameraNode.simdTransform.columns.0.y,
                cameraNode.simdTransform.columns.0.z
            )
            let pitchQuat = simd_quatf(angle: pitch, axis: cameraRight)
            let rotation = simd_normalize(yawQuat * pitchQuat)
            let newQuat = simd_normalize(rotation * simd_quatf(startTransform))
            var newTransform = simd_float4x4(newQuat)
            newTransform.columns.3 = startTransform.columns.3
            parent.onCropVolumeChanged(
                ObjectCropVolume(
                    center: volume.center,
                    extent: volume.extent,
                    transform: newTransform
                )
            )
        }

        func updateSelection(_ scnView: SCNView) {
            scnView.allowsCameraControl = !parent.isPlacing && !isBoxSelected
            if let scene = scnView.scene {
                scene.rootNode.childNodes
                    .filter { $0.name == "cropBox" }
                    .forEach { $0.removeFromParentNode() }
            }
            rebuild(scnView)
        }

        private func isCropBoxHit(_ hit: SCNHitTestResult) -> Bool {
            var node: SCNNode? = hit.node
            while let current = node {
                if current.name == "cropBox" || isAxisName(current.name ?? "") {
                    return true
                }
                node = current.parent
            }
            return false
        }

        private func axisName(from hit: SCNHitTestResult) -> String? {
            if let name = hit.node.name, isAxisName(name) {
                return name
            }
            return hit.node.parent?.name
        }

        private func isAxisName(_ name: String) -> Bool {
            name == "axisX" || name == "axisY" || name == "axisZ"
        }

        private func axis(for name: String) -> SIMD3<Float>? {
            switch name {
            case "axisX": return SIMD3<Float>(1, 0, 0)
            case "axisY": return SIMD3<Float>(0, 1, 0)
            case "axisZ": return SIMD3<Float>(0, 0, 1)
            default: return nil
            }
        }

        private func worldDeltaFromScreen(
            dx: Float,
            dy: Float,
            cameraNode: SCNNode,
            center: SIMD3<Float>,
            viewport: CGSize
        ) -> SIMD3<Float> {
            guard viewport.width > 0, viewport.height > 0,
                  let camera = cameraNode.camera else {
                return .zero
            }
            let transform = cameraNode.simdTransform
            let cameraPosition = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
            let forward = simd_normalize(center - cameraPosition)
            let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            let up = simd_cross(right, forward)
            let distance = simd_length(center - cameraPosition)
            let fovY = Float(camera.fieldOfView) * .pi / 180
            let aspect = Float(viewport.width / max(viewport.height, 1))
            let fovX = 2 * atan(tan(fovY / 2) * aspect)
            let worldPerPixelX = 2 * distance * tan(fovX / 2) / Float(viewport.width)
            let worldPerPixelY = 2 * distance * tan(fovY / 2) / Float(viewport.height)
            return right * dx * worldPerPixelX + up * (-dy) * worldPerPixelY
        }

        private func positionCamera(_ scnView: SCNView) {
            guard let cameraNode = scnView.pointOfView else { return }
            let centroid = parent.points.reduce(SIMD3<Float>.zero) {
                $0 + $1.position
            } / Float(max(parent.points.count, 1))
            let diagonal = boundingDiagonal(parent.points)
            let distance = max(diagonal * 1.6, 0.9)
            cameraNode.position = SCNVector3(
                centroid.x,
                centroid.y + diagonal * 0.45,
                centroid.z + distance
            )
            cameraNode.look(at: SCNVector3(centroid.x, centroid.y, centroid.z))
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

        private func addEdges(to root: SCNNode, extent: SIMD3<Float>, color: UIColor) {
            let half = extent * 0.5
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.emission.contents = color

            func addLine(size: SIMD3<Float>, position: SIMD3<Float>) {
                let box = SCNBox(
                    width: CGFloat(size.x),
                    height: CGFloat(size.y),
                    length: CGFloat(size.z),
                    chamferRadius: 0
                )
                box.firstMaterial = material
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(position.x, position.y, position.z)
                root.addChildNode(node)
            }

            for y in [-half.y, half.y] {
                for z in [-half.z, half.z] {
                    addLine(
                        size: SIMD3<Float>(extent.x, 0.02, 0.02),
                        position: SIMD3<Float>(0, y, z)
                    )
                }
            }
            for x in [-half.x, half.x] {
                for z in [-half.z, half.z] {
                    addLine(
                        size: SIMD3<Float>(0.02, extent.y, 0.02),
                        position: SIMD3<Float>(x, 0, z)
                    )
                }
            }
            for x in [-half.x, half.x] {
                for y in [-half.y, half.y] {
                    addLine(
                        size: SIMD3<Float>(0.02, 0.02, extent.z),
                        position: SIMD3<Float>(x, y, 0)
                    )
                }
            }
        }

        private func addArrows(to root: SCNNode, extent: SIMD3<Float>) {
            let half = extent * 0.5
            let definitions: [(SIMD3<Float>, UIColor, String)] = [
                (SIMD3<Float>(1, 0, 0), .systemRed, "axisX"),
                (SIMD3<Float>(0, 1, 0), .systemGreen, "axisY"),
                (SIMD3<Float>(0, 0, 1), .systemBlue, "axisZ")
            ]

            for (axis, color, name) in definitions {
                let group = SCNNode()
                group.name = name

                let shaft = SCNBox(
                    width: CGFloat(axis.x != 0 ? half.x : 0.018),
                    height: CGFloat(axis.y != 0 ? half.y : 0.018),
                    length: CGFloat(axis.z != 0 ? half.z : 0.018),
                    chamferRadius: 0
                )
                let shaftMaterial = SCNMaterial()
                shaftMaterial.lightingModel = .constant
                shaftMaterial.diffuse.contents = color
                shaftMaterial.emission.contents = color
                shaft.firstMaterial = shaftMaterial
                let shaftNode = SCNNode(geometry: shaft)
                shaftNode.position = SCNVector3(
                    axis.x * half.x * 0.5,
                    axis.y * half.y * 0.5,
                    axis.z * half.z * 0.5
                )
                group.addChildNode(shaftNode)

                let cone = SCNCone(topRadius: 0, bottomRadius: 0.045, height: 0.14)
                let coneMaterial = SCNMaterial()
                coneMaterial.lightingModel = .constant
                coneMaterial.diffuse.contents = color
                coneMaterial.emission.contents = color
                cone.firstMaterial = coneMaterial
                let coneNode = SCNNode(geometry: cone)
                let headPosition = half + axis * 0.07
                coneNode.position = SCNVector3(
                    headPosition.x,
                    headPosition.y,
                    headPosition.z
                )
                coneNode.simdOrientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0),
                    to: axis
                )
                group.addChildNode(coneNode)

                root.addChildNode(group)
            }
        }
    }
}
