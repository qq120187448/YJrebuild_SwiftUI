import SwiftUI
import UIKit
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
        scnView.allowsCameraControl = true
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
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
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
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuild(scnView)
    }

    final class Coordinator: NSObject {
        var parent: ObjectCropBox3DView

        private enum DragMode {
            case boxResize
            case boxRotate
            case boxMove
            case boxScale
        }

        private var lastPointCount = -1
        private var occupancy: Set<Int64> = []
        private let occupancyCell: Float = 0.05

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

        init(parent: ObjectCropBox3DView) {
            self.parent = parent
        }

        func rebuild(_ scnView: SCNView) {
            guard let scene = scnView.scene else { return }
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
                buildOccupancy()
                positionCamera(scnView)
            }

            scnView.allowsCameraControl = parent.cropVolume == nil

            scene.rootNode.childNodes
                .filter { $0.name == "cropBox" }
                .forEach { $0.removeFromParentNode() }
            guard let volume = parent.cropVolume else { return }

            let root = SCNNode()
            root.name = "cropBox"
            root.simdTransform = volume.transform

            let fill = SCNBox(
                width: CGFloat(volume.extent.x),
                height: CGFloat(volume.extent.y),
                length: CGFloat(volume.extent.z),
                chamferRadius: 0
            )
            let fillMaterial = SCNMaterial()
            fillMaterial.lightingModel = .constant
            fillMaterial.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.10)
            fillMaterial.emission.contents = UIColor.systemGreen.withAlphaComponent(0.14)
            fillMaterial.isDoubleSided = true
            fill.firstMaterial = fillMaterial
            root.addChildNode(SCNNode(geometry: fill))

            let cameraPosition = cameraPosition(of: scnView)
            addEdges(
                to: root,
                extent: volume.extent,
                cameraPosition: cameraPosition,
                isOccupied: { [weak self] world in
                    self?.isOccupied(world) ?? false
                }
            )
            addArrows(to: root, extent: volume.extent)
            scene.rootNode.addChildNode(root)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  parent.isPlacing,
                  let scnView = recognizer.view as? SCNView else {
                return
            }
            placeCropBox(at: recognizer.location(in: scnView), in: scnView)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let scnView = recognizer.view as? SCNView,
                  !parent.isPlacing,
                  parent.cropVolume != nil else {
                return
            }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                if let hit = arrowHit(in: scnView, at: location),
                   let name = axisName(from: hit),
                   let axis = axis(for: name),
                   let volume = parent.cropVolume {
                    dragMode = .boxResize
                    dragAxis = axis
                    dragStartScreen = location
                    dragStartCenter = volume.center
                    dragStartExtent = volume.extent
                    if let cameraNode = scnView.pointOfView {
                        dragDepth = max(
                            simd_length(volume.center - cameraPosition(of: cameraNode)),
                            0.1
                        )
                    }
                } else if let volume = parent.cropVolume {
                    dragMode = .boxRotate
                    rotateStartScreen = location
                    rotateStartTransform = volume.transform
                }

            case .changed:
                if dragMode == .boxResize {
                    handleBoxResize(location: location, scnView: scnView)
                } else if dragMode == .boxRotate {
                    handleBoxRotate(location: location, scnView: scnView)
                }

            case .ended, .cancelled:
                let wasBoxEdit = dragMode == .boxResize || dragMode == .boxRotate
                resetDragState()
                if wasBoxEdit, let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }

            default:
                break
            }
        }

        @objc func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
            guard let scnView = recognizer.view as? SCNView,
                  !parent.isPlacing,
                  parent.cropVolume != nil else {
                return
            }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                guard let volume = parent.cropVolume else { return }
                dragMode = .boxMove
                moveStartScreen = location
                moveStartCenter = volume.center
                if let cameraNode = scnView.pointOfView {
                    moveStartDepth = max(
                        simd_length(volume.center - cameraPosition(of: cameraNode)),
                        0.1
                    )
                }

            case .changed:
                if dragMode == .boxMove {
                    handleBoxMove(location: location, scnView: scnView)
                }

            case .ended, .cancelled:
                let wasBoxEdit = dragMode == .boxMove
                resetDragState()
                if wasBoxEdit, let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }

            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard !parent.isPlacing,
                  parent.cropVolume != nil else {
                return
            }
            switch recognizer.state {
            case .began:
                dragMode = .boxScale
                scaleStartExtent = parent.cropVolume?.extent
            case .changed:
                if dragMode == .boxScale {
                    handleBoxScale(recognizer: recognizer)
                }
            case .ended, .cancelled:
                let wasBoxEdit = dragMode == .boxScale
                resetDragState()
                if wasBoxEdit, let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }
            default:
                break
            }
        }

        // MARK: - Box operations

        private func handleBoxResize(location: CGPoint, scnView: SCNView) {
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
            let worldDelta = worldDeltaFromScreen(
                dx: dx,
                dy: dy,
                cameraNode: cameraNode,
                center: startCenter,
                viewport: scnView.bounds.size,
                depth: dragDepth
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

        private func handleBoxRotate(location: CGPoint, scnView: SCNView) {
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

        private func handleBoxMove(location: CGPoint, scnView: SCNView) {
            guard let start = moveStartScreen,
                  let startCenter = moveStartCenter,
                  let cameraNode = scnView.pointOfView,
                  let volume = parent.cropVolume else {
                return
            }
            let dx = Float(location.x - start.x)
            let dy = Float(location.y - start.y)
            let worldDelta = worldDeltaFromScreen(
                dx: dx,
                dy: dy,
                cameraNode: cameraNode,
                center: startCenter,
                viewport: scnView.bounds.size,
                depth: moveStartDepth
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
        }

        private func handleBoxScale(recognizer: UIPinchGestureRecognizer) {
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
        }

        // MARK: - Placement

        private func placeCropBox(at location: CGPoint, in scnView: SCNView) {
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
            let volume = ObjectCropVolume(
                center: center,
                extent: extent,
                transform: transform
            )
            parent.onCropVolumeChanged(volume)
            parent.onCropBoxEditEnded(volume)
            scnView.allowsCameraControl = false
            rebuild(scnView)
        }

        // MARK: - Occlusion

        private func buildOccupancy() {
            occupancy.removeAll()
            for point in parent.points {
                occupancy.insert(voxelKey(point.position, size: occupancyCell))
            }
        }

        private func isOccupied(_ world: SIMD3<Float>) -> Bool {
            occupancy.contains(voxelKey(world, size: occupancyCell))
        }

        private func voxelKey(_ position: SIMD3<Float>, size: Float) -> Int64 {
            let ix = Int64(floor(position.x / size))
            let iy = Int64(floor(position.y / size))
            let iz = Int64(floor(position.z / size))
            return ((ix + 0x80000) & 0xFFFFF)
                | (((iy + 0x80000) & 0xFFFFF) << 20)
                | (((iz + 0x80000) & 0xFFFFF) << 40)
        }

        private func edgeOccluded(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            cameraPosition: SIMD3<Float>,
            isOccupied: (SIMD3<Float>) -> Bool
        ) -> Bool {
            let samples = 8
            for index in 0...samples {
                let t = Float(index) / Float(samples)
                let point = start + (end - start) * t
                let toPoint = point - cameraPosition
                let distance = simd_length(toPoint)
                guard distance > 0.05 else { continue }
                let direction = toPoint / distance
                var step: Float = 0.04
                while step < distance - 0.06 {
                    let sample = cameraPosition + direction * step
                    if isOccupied(sample) {
                        return true
                    }
                    step += 0.04
                }
            }
            return false
        }

        private func addEdges(
            to root: SCNNode,
            extent: SIMD3<Float>,
            cameraPosition: SIMD3<Float>,
            isOccupied: @escaping (SIMD3<Float>) -> Bool
        ) {
            let half = extent * 0.5
            let solidMaterial = SCNMaterial()
            solidMaterial.lightingModel = .constant
            solidMaterial.diffuse.contents = UIColor.systemGreen
            solidMaterial.emission.contents = UIColor.systemGreen

            let dashedMaterial = SCNMaterial()
            dashedMaterial.lightingModel = .constant
            dashedMaterial.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.55)
            dashedMaterial.emission.contents = UIColor.systemGreen.withAlphaComponent(0.55)

            func addLine(
                axis: SIMD3<Float>,
                length: Float,
                offset: SIMD3<Float>,
                dashed: Bool
            ) {
                let material = dashed ? dashedMaterial : solidMaterial
                if !dashed {
                    let box = SCNBox(
                        width: CGFloat(axis.x != 0 ? length : 0.01),
                        height: CGFloat(axis.y != 0 ? length : 0.01),
                        length: CGFloat(axis.z != 0 ? length : 0.01),
                        chamferRadius: 0
                    )
                    box.firstMaterial = material
                    let node = SCNNode(geometry: box)
                    node.position = SCNVector3(offset.x, offset.y, offset.z)
                    root.addChildNode(node)
                    return
                }

                let dashLength: Float = 0.05
                let gapLength: Float = 0.04
                var cursor: Float = 0
                while cursor < length {
                    let dash = min(dashLength, length - cursor)
                    let box = SCNBox(
                        width: CGFloat(axis.x != 0 ? dash : 0.01),
                        height: CGFloat(axis.y != 0 ? dash : 0.01),
                        length: CGFloat(axis.z != 0 ? dash : 0.01),
                        chamferRadius: 0
                    )
                    box.firstMaterial = material
                    let node = SCNNode(geometry: box)
                    let halfLength = length * 0.5
                    let centerAlongAxis = -halfLength + cursor + dash * 0.5
                    let position = offset + axis * centerAlongAxis
                    node.position = SCNVector3(position.x, position.y, position.z)
                    root.addChildNode(node)
                    cursor += dash + gapLength
                }
            }

            var edges: [(SIMD3<Float>, Float, SIMD3<Float>, Float)] = []

            func edgeList(
                axis: SIMD3<Float>,
                length: Float,
                offsets: [SIMD3<Float>]
            ) {
                for offset in offsets {
                    edges.append((axis, length, offset, length))
                }
            }

            edgeList(
                axis: SIMD3<Float>(1, 0, 0),
                length: extent.x,
                offsets: [
                    SIMD3<Float>(0, -half.y, -half.z),
                    SIMD3<Float>(0, -half.y, half.z),
                    SIMD3<Float>(0, half.y, -half.z),
                    SIMD3<Float>(0, half.y, half.z)
                ]
            )
            edgeList(
                axis: SIMD3<Float>(0, 1, 0),
                length: extent.y,
                offsets: [
                    SIMD3<Float>(-half.x, 0, -half.z),
                    SIMD3<Float>(-half.x, 0, half.z),
                    SIMD3<Float>(half.x, 0, -half.z),
                    SIMD3<Float>(half.x, 0, half.z)
                ]
            )
            edgeList(
                axis: SIMD3<Float>(0, 0, 1),
                length: extent.z,
                offsets: [
                    SIMD3<Float>(-half.x, -half.y, 0),
                    SIMD3<Float>(-half.x, half.y, 0),
                    SIMD3<Float>(half.x, -half.y, 0),
                    SIMD3<Float>(half.x, half.y, 0)
                ]
            )

            for edge in edges {
                let axis = edge.0
                let length = edge.1
                let offset = edge.2
                let start = offset - axis * length * 0.5
                let end = offset + axis * length * 0.5
                let dashed = edgeOccluded(
                    from: start,
                    to: end,
                    cameraPosition: cameraPosition,
                    isOccupied: isOccupied
                )
                addLine(
                    axis: axis,
                    length: length,
                    offset: offset,
                    dashed: dashed
                )
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

        // MARK: - Helpers

        private func resetDragState() {
            dragMode = nil
            dragAxis = nil
            dragStartScreen = nil
            dragStartCenter = nil
            dragStartExtent = nil
            rotateStartScreen = nil
            rotateStartTransform = nil
            moveStartScreen = nil
            moveStartCenter = nil
            scaleStartExtent = nil
        }

        private func cameraPosition(of cameraNode: SCNNode) -> SIMD3<Float> {
            let transform = cameraNode.simdTransform
            return SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
        }

        private func cameraPosition(of scnView: SCNView) -> SIMD3<Float> {
            guard let cameraNode = scnView.pointOfView else { return .zero }
            return cameraPosition(of: cameraNode)
        }

        private func arrowHit(in scnView: SCNView, at location: CGPoint) -> SCNHitTestResult? {
            let results = scnView.hitTest(location, options: nil)
            return results.first { hit in
                if let name = axisName(from: hit) {
                    return axis(for: name) != nil
                }
                return false
            }
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
            viewport: CGSize,
            depth: Float
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
            let distance = max(depth, 0.1)
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
    }
}
