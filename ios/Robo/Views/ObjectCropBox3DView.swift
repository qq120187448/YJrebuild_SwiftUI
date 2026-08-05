import SwiftUI
import UIKit
import SceneKit
import simd

struct ObjectCropBox3DView: UIViewRepresentable {
    let points: [ObjectPoint]
    let targetPoints: [ObjectPoint]
    let previewMode: ObjectPreviewMode
    let cropVolume: ObjectCropVolume?
    let placeRequested: Bool
    let axisMoveCommand: AxisMoveCommand
    let onCropVolumeChanged: (ObjectCropVolume?) -> Void
    let onCropBoxEditEnded: (ObjectCropVolume) -> Void
    let onCommandHandled: () -> Void

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

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        scnView.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        scnView.addGestureRecognizer(pinch)
        context.coordinator.pinch = pinch

        let movePan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMovePan(_:))
        )
        movePan.minimumNumberOfTouches = 2
        movePan.maximumNumberOfTouches = 2
        movePan.cancelsTouchesInView = false
        scnView.addGestureRecognizer(movePan)
        context.coordinator.movePan = movePan

        context.coordinator.parent = self
        context.coordinator.rebuild(scnView)
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        context.coordinator.parent = self
        if placeRequested {
            context.coordinator.placeCropBoxAutomatically(in: scnView)
            onCommandHandled()
        }
        switch axisMoveCommand {
        case .none:
            break
        case .xMinus:
            context.coordinator.moveBox(axis: SIMD3<Float>(-1, 0, 0))
            onCommandHandled()
        case .xPlus:
            context.coordinator.moveBox(axis: SIMD3<Float>(1, 0, 0))
            onCommandHandled()
        case .yMinus:
            context.coordinator.moveBox(axis: SIMD3<Float>(0, 0, -1))
            onCommandHandled()
        case .yPlus:
            context.coordinator.moveBox(axis: SIMD3<Float>(0, 0, 1))
            onCommandHandled()
        case .zMinus:
            context.coordinator.moveBox(axis: SIMD3<Float>(0, -1, 0))
            onCommandHandled()
        case .zPlus:
            context.coordinator.moveBox(axis: SIMD3<Float>(0, 1, 0))
            onCommandHandled()
        case .sizeXMinus:
            context.coordinator.resizeBox(index: 0, delta: -0.05)
            onCommandHandled()
        case .sizeXPlus:
            context.coordinator.resizeBox(index: 0, delta: 0.05)
            onCommandHandled()
        case .sizeYMinus:
            context.coordinator.resizeBox(index: 2, delta: -0.05)
            onCommandHandled()
        case .sizeYPlus:
            context.coordinator.resizeBox(index: 2, delta: 0.05)
            onCommandHandled()
        case .sizeZMinus:
            context.coordinator.resizeBox(index: 1, delta: -0.05)
            onCommandHandled()
        case .sizeZPlus:
            context.coordinator.resizeBox(index: 1, delta: 0.05)
            onCommandHandled()
        case .rotateZMinus:
            context.coordinator.rotateBox(axis: SIMD3<Float>(0, 1, 0), degrees: -1)
            onCommandHandled()
        case .rotateZPlus:
            context.coordinator.rotateBox(axis: SIMD3<Float>(0, 1, 0), degrees: 1)
            onCommandHandled()
        case .none:
            break
        }
        context.coordinator.rebuild(scnView)
    }

    final class Coordinator: NSObject {
        var parent: ObjectCropBox3DView

        private var lastPointCount = -1
        private var lastPreviewSignature = ""
        private var didPositionCamera = false
        fileprivate var pan: UIPanGestureRecognizer?
        fileprivate var pinch: UIPinchGestureRecognizer?
        fileprivate var movePan: UIPanGestureRecognizer?
        private var occupancy: Set<Int64> = []
        private let occupancyCell: Float = 0.05

        private var moveStartScreen: CGPoint?
        private var moveStartCenter: SIMD3<Float>?
        private var moveStartDepth: Float = 0
        private var rotateStartTransform: simd_float4x4?
        private var scaleStartExtent: SIMD3<Float>?

        private var isMoving = false
        private var isScaling = false

        init(parent: ObjectCropBox3DView) {
            self.parent = parent
        }

        func rebuild(_ scnView: SCNView) {
            guard let scene = scnView.scene else { return }
            let previewSignature = parent.previewMode.rawValue + "|" + String(parent.targetPoints.count)
            if parent.points.count != lastPointCount || previewSignature != lastPreviewSignature {
                lastPointCount = parent.points.count
                lastPreviewSignature = previewSignature
                scene.rootNode.childNodes
                    .filter { $0.name == "objectPoints" }
                    .forEach { $0.removeFromParentNode() }
                if !parent.points.isEmpty {
                    let targetSet = Set(parent.targetPoints)
                    let displayPoints: [ObjectPoint]
                    let colorTransform: ((ObjectPoint) -> SIMD4<Float>)?
                    switch parent.previewMode {
                    case .all:
                        displayPoints = parent.points
                        colorTransform = nil
                    case .highlightTarget:
                        displayPoints = parent.points
                        colorTransform = { point in
                            if targetSet.contains(point) {
                                return SIMD4(point.r, point.g, point.b, 1)
                            }
                            return SIMD4(0.45, 0.48, 0.52, 0.16)
                        }
                    case .targetOnly:
                        displayPoints = parent.points.filter { targetSet.contains($0) }
                        colorTransform = nil
                    }
                    let geometry = SCNGeometry.objectPointCloud(
                        points: displayPoints,
                        minScreenRadius: CGFloat(ObjectScanSettings.previewPointSize),
                        maxScreenRadius: CGFloat(ObjectScanSettings.previewPointSize),
                        colorTransform: colorTransform
                    )
                    let node = SCNNode(geometry: geometry)
                    node.name = "objectPoints"
                    scene.rootNode.addChildNode(node)
                }
                buildOccupancy()
                if !didPositionCamera {
                    positionCamera(scnView)
                    didPositionCamera = true
                }
            }

            scnView.allowsCameraControl = true
            pan?.isEnabled = false
            pinch?.isEnabled = false
            movePan?.isEnabled = false

            scene.rootNode.childNodes
                .filter { $0.name == "cropBox" || $0.name == "cropBoxShadow" }
                .forEach { $0.removeFromParentNode() }
            guard let volume = parent.cropVolume else { return }

            let root = SCNNode()
            root.name = "cropBox"
            root.simdTransform = volume.transform

            let cameraPosition = cameraPosition(of: scnView)
            ObjectBoxVisual.addEdgeGeometry(
                to: root,
                extent: volume.extent,
                cameraPosition: cameraPosition,
                isOccupied: { [weak self] world in
                    self?.isOccupied(world) ?? false
                },
                pixelLineWidth: CGFloat(ObjectScanSettings.boxLineWidth),
                viewportHeight: scnView.bounds.height,
                fovYDegrees: CGFloat(scnView.pointOfView?.camera?.fieldOfView ?? 60)
            )
            ObjectBoxVisual.addAxes(to: root, extent: volume.extent)
            scene.rootNode.addChildNode(root)
            let groundY = parent.points.map { $0.y }.min() ?? volume.origin.y
            scene.rootNode.addChildNode(
                ObjectBoxVisual.makeGroundShadowNode(
                    extent: volume.extent,
                    transform: volume.transform,
                    groundY: groundY
                )
            )
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let scnView = recognizer.view as? SCNView,
                  parent.cropVolume != nil else {
                return
            }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                guard let volume = parent.cropVolume,
                      let cameraNode = scnView.pointOfView else {
                    return
                }
                isMoving = true
                moveStartScreen = location
                moveStartCenter = volume.center
                moveStartDepth = max(
                    simd_length(volume.center - cameraPosition(of: cameraNode)),
                    0.1
                )
                rotateStartTransform = volume.transform

            case .changed:
                guard isMoving,
                      let start = moveStartScreen,
                      let startCenter = moveStartCenter,
                      let cameraNode = scnView.pointOfView,
                      let startTransform = rotateStartTransform,
                      let volume = parent.cropVolume else {
                    return
                }
                let dx = Float(location.x - start.x)
                let dy = Float(location.y - start.y)
                let yaw = dx * 0.006
                let yawQuat = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                let newQuat = simd_normalize(yawQuat * simd_quatf(startTransform))
                var newTransform = simd_float4x4(newQuat)

                let verticalDelta = worldDeltaFromScreen(
                    dx: 0,
                    dy: dy,
                    cameraNode: cameraNode,
                    center: startCenter,
                    viewport: scnView.bounds.size,
                    depth: moveStartDepth
                )
                let newCenter = SIMD3<Float>(
                    startCenter.x,
                    startCenter.y + verticalDelta.y,
                    startCenter.z
                )
                newTransform.columns.3 = SIMD4<Float>(
                    newCenter.x,
                    newCenter.y,
                    newCenter.z,
                    1
                )
                parent.onCropVolumeChanged(
                    ObjectCropVolume(
                        center: newCenter,
                        extent: volume.extent,
                        transform: newTransform
                    )
                )

            case .ended, .cancelled:
                isMoving = false
                moveStartScreen = nil
                moveStartCenter = nil
                rotateStartTransform = nil
                snapToGround()
                if let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }

            default:
                break
            }
        }

        @objc func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
            guard let scnView = recognizer.view as? SCNView,
                  parent.cropVolume != nil else {
                return
            }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                guard let volume = parent.cropVolume,
                      let cameraNode = scnView.pointOfView else {
                    return
                }
                isMoving = true
                moveStartScreen = location
                moveStartCenter = volume.center
                moveStartDepth = max(
                    simd_length(volume.center - cameraPosition(of: cameraNode)),
                    0.1
                )

            case .changed:
                guard isMoving,
                      let start = moveStartScreen,
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
                let horizontalDelta = SIMD3<Float>(worldDelta.x, 0, worldDelta.z)
                let newCenter = startCenter + horizontalDelta
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
                isMoving = false
                moveStartScreen = nil
                moveStartCenter = nil
                snapToGround()
                if let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }

            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard parent.cropVolume != nil else { return }
            switch recognizer.state {
            case .began:
                isScaling = true
                scaleStartExtent = parent.cropVolume?.extent
            case .changed:
                guard isScaling,
                      let startExtent = scaleStartExtent,
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
                        origin: volume.origin,
                        extent: newExtent,
                        transform: transform
                    )
                )
            case .ended, .cancelled:
                isScaling = false
                scaleStartExtent = nil
                snapToGround()
                if let volume = parent.cropVolume {
                    parent.onCropBoxEditEnded(volume)
                }
            default:
                break
            }
        }

        func placeCropBoxAutomatically(in scnView: SCNView) {
            let extent = parent.cropVolume?.extent ?? SIMD3<Float>(repeating: 1.0)
            let groundY = parent.points.map { $0.y }.min() ?? 0
            let centroid = parent.points.reduce(SIMD3<Float>.zero) {
                $0 + $1.position
            } / Float(max(parent.points.count, 1))
            let origin = SIMD3<Float>(
                centroid.x,
                groundY,
                centroid.z
            )
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4<Float>(origin.x, origin.y, origin.z, 1)
            let volume = ObjectCropVolume(
                origin: origin,
                extent: extent,
                transform: transform
            )
            parent.onCropVolumeChanged(volume)
            parent.onCropBoxEditEnded(volume)
            rebuild(scnView)
        }

        func moveBox(axis: SIMD3<Float>) {
            guard let volume = parent.cropVolume else { return }
            let delta: Float = 0.05
            let rotation = simd_float3x3(
                SIMD3<Float>(
                    volume.transform.columns.0.x,
                    volume.transform.columns.0.y,
                    volume.transform.columns.0.z
                ),
                SIMD3<Float>(
                    volume.transform.columns.1.x,
                    volume.transform.columns.1.y,
                    volume.transform.columns.1.z
                ),
                SIMD3<Float>(
                    volume.transform.columns.2.x,
                    volume.transform.columns.2.y,
                    volume.transform.columns.2.z
                )
            )
            let newOrigin = volume.origin + rotation * (axis * delta)
            var transform = volume.transform
            transform.columns.3 = SIMD4<Float>(
                newOrigin.x,
                newOrigin.y,
                newOrigin.z,
                1
            )
            let updated = ObjectCropVolume(
                origin: newOrigin,
                extent: volume.extent,
                transform: transform
            )
            parent.onCropVolumeChanged(updated)
            parent.onCropBoxEditEnded(updated)
        }

        func resizeBox(index: Int, delta: Float) {
            guard let volume = parent.cropVolume else { return }
            var extent = volume.extent
            if index == 0 {
                extent.x = min(max(extent.x + delta, 0.2), 10)
            } else if index == 1 {
                extent.y = min(max(extent.y + delta, 0.2), 10)
            } else {
                extent.z = min(max(extent.z + delta, 0.2), 10)
            }
            let updated = ObjectCropVolume(
                origin: volume.origin,
                extent: extent,
                transform: volume.transform
            )
            parent.onCropVolumeChanged(updated)
            parent.onCropBoxEditEnded(updated)
        }

        func rotateBox(axis: SIMD3<Float>, degrees: Float) {
            guard let volume = parent.cropVolume else { return }
            let length = simd_length(axis)
            guard length > 1e-6 else { return }
            let normalized = axis / length
            let quat = simd_quatf(angle: degrees * Float.pi / 180, axis: normalized)
            let rotation = simd_float4x4(quat)
            let origin = volume.origin
            var toOrigin = matrix_identity_float4x4
            toOrigin.columns.3 = SIMD4<Float>(-origin.x, -origin.y, -origin.z, 1)
            var back = matrix_identity_float4x4
            back.columns.3 = SIMD4<Float>(origin.x, origin.y, origin.z, 1)
            let updated = ObjectCropVolume(
                origin: origin,
                extent: volume.extent,
                transform: back * rotation * toOrigin * volume.transform
            )
            parent.onCropVolumeChanged(updated)
            parent.onCropBoxEditEnded(updated)
        }

        private func snapToGround() {
            guard let volume = parent.cropVolume else { return }
            let groundY = parent.points.map { $0.y }.min() ?? 0
            guard abs(volume.origin.y - groundY) < 0.1 else { return }
            let newOrigin = SIMD3<Float>(volume.origin.x, groundY, volume.origin.z)
            var transform = volume.transform
            transform.columns.3 = SIMD4<Float>(
                newOrigin.x,
                newOrigin.y,
                newOrigin.z,
                1
            )
            let updated = ObjectCropVolume(
                origin: newOrigin,
                extent: volume.extent,
                transform: transform
            )
            parent.onCropVolumeChanged(updated)
            parent.onCropBoxEditEnded(updated)
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

        private let lineColor = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1)

        private func addEdges(
            to root: SCNNode,
            extent: SIMD3<Float>,
            cameraPosition: SIMD3<Float>,
            isOccupied: @escaping (SIMD3<Float>) -> Bool
        ) {
            let half = extent * 0.5

            func addCylinder(
                axis: SIMD3<Float>,
                length: Float,
                offset: SIMD3<Float>,
                material: SCNMaterial
            ) {
                let cylinder = SCNCylinder(radius: 0.008, height: CGFloat(length))
                cylinder.firstMaterial = material
                let node = SCNNode(geometry: cylinder)
                node.position = SCNVector3(offset.x, offset.y, offset.z)
                node.simdOrientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0),
                    to: axis
                )
                root.addChildNode(node)
            }

            let solidMaterial = SCNMaterial()
            solidMaterial.lightingModel = .constant
            solidMaterial.diffuse.contents = lineColor
            solidMaterial.emission.contents = lineColor

            let dashedMaterial = SCNMaterial()
            dashedMaterial.lightingModel = .constant
            dashedMaterial.diffuse.contents = lineColor.withAlphaComponent(0.5)
            dashedMaterial.emission.contents = lineColor.withAlphaComponent(0.5)

            func addLine(
                axis: SIMD3<Float>,
                length: Float,
                offset: SIMD3<Float>,
                dashed: Bool
            ) {
                if !dashed {
                    addCylinder(
                        axis: axis,
                        length: length,
                        offset: offset,
                        material: solidMaterial
                    )
                    return
                }
                let dashLength: Float = 0.05
                let gapLength: Float = 0.04
                var cursor: Float = 0
                while cursor < length {
                    let dash = min(dashLength, length - cursor)
                    let halfLength = length * 0.5
                    let centerAlongAxis = -halfLength + cursor + dash * 0.5
                    let position = offset + axis * centerAlongAxis
                    addCylinder(
                        axis: axis,
                        length: dash,
                        offset: position,
                        material: dashedMaterial
                    )
                    cursor += dash + gapLength
                }
            }

            var edges: [(SIMD3<Float>, Float, SIMD3<Float>, Float)] = []
            func edgeList(axis: SIMD3<Float>, length: Float, offsets: [SIMD3<Float>]) {
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

        private func addCorners(to root: SCNNode, extent: SIMD3<Float>) {
            let half = extent * 0.5
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = lineColor
            material.emission.contents = lineColor
            let corners: [SIMD3<Float>] = [
                SIMD3<Float>(-half.x, -half.y, -half.z),
                SIMD3<Float>(-half.x, -half.y, half.z),
                SIMD3<Float>(-half.x, half.y, -half.z),
                SIMD3<Float>(-half.x, half.y, half.z),
                SIMD3<Float>(half.x, -half.y, -half.z),
                SIMD3<Float>(half.x, -half.y, half.z),
                SIMD3<Float>(half.x, half.y, -half.z),
                SIMD3<Float>(half.x, half.y, half.z)
            ]
            for corner in corners {
                let sphere = SCNSphere(radius: 0.012)
                sphere.firstMaterial = material
                let node = SCNNode(geometry: sphere)
                node.position = SCNVector3(corner.x, corner.y, corner.z)
                root.addChildNode(node)
            }
        }

        private func animateFlow(on root: SCNNode) {
            root.removeAllActions()
            let action = SCNAction.repeatForever(
                SCNAction.customAction(duration: 1.6) { node, elapsed in
                    let phase = (sin(elapsed / 1.6 * 2 * .pi) + 1) / 2
                    let alpha = 0.55 + 0.45 * phase
                    node.childNodes.forEach { child in
                        child.geometry?.firstMaterial?.emission.contents =
                            UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: alpha)
                    }
                }
            )
            root.runAction(action)
        }

        // MARK: - Helpers

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
