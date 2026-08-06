import UIKit
import SceneKit
import simd

enum ObjectBoxVisual {
    struct Edge {
        let axis: SIMD3<Float>
        let length: Float
        let offset: SIMD3<Float>

        var start: SIMD3<Float> {
            offset - axis * length * 0.5
        }

        var end: SIMD3<Float> {
            offset + axis * length * 0.5
        }
    }

    static func edges(extent: SIMD3<Float>) -> [Edge] {
        let half = extent * 0.5
        var result: [Edge] = []

        func add(axis: SIMD3<Float>, length: Float, offsets: [SIMD3<Float>]) {
            for offset in offsets {
                result.append(Edge(axis: axis, length: length, offset: offset))
            }
        }

        add(
            axis: SIMD3<Float>(1, 0, 0),
            length: extent.x,
            offsets: [
                SIMD3<Float>(half.x, 0, 0),
                SIMD3<Float>(half.x, 0, extent.z),
                SIMD3<Float>(half.x, extent.y, 0),
                SIMD3<Float>(half.x, extent.y, extent.z)
            ]
        )
        add(
            axis: SIMD3<Float>(0, 1, 0),
            length: extent.y,
            offsets: [
                SIMD3<Float>(0, half.y, 0),
                SIMD3<Float>(0, half.y, extent.z),
                SIMD3<Float>(extent.x, half.y, 0),
                SIMD3<Float>(extent.x, half.y, extent.z)
            ]
        )
        add(
            axis: SIMD3<Float>(0, 0, 1),
            length: extent.z,
            offsets: [
                SIMD3<Float>(0, 0, half.z),
                SIMD3<Float>(0, extent.y, half.z),
                SIMD3<Float>(extent.x, 0, half.z),
                SIMD3<Float>(extent.x, extent.y, half.z)
            ]
        )
        return result
    }

    static func addEdgeGeometry(
        to root: SCNNode,
        extent: SIMD3<Float>,
        cameraPosition: SIMD3<Float>,
        isOccupied: (SIMD3<Float>) -> Bool,
        pixelLineWidth: CGFloat,
        viewportHeight: CGFloat,
        fovYDegrees: CGFloat
    ) {
        let solidMaterial = makeMaterial(color: UIColor.white)
        let dashedMaterial = makeMaterial(color: UIColor.white.withAlphaComponent(0.65))
        let transform = root.simdTransform

        for edge in edges(extent: extent) {
            let dashed = edgeOccluded(
                edge: edge,
                transform: transform,
                cameraPosition: cameraPosition,
                isOccupied: isOccupied
            )
            let worldOffset = worldPosition(edge.offset, transform: transform)
            let distance = simd_length(cameraPosition - worldOffset)
            let worldRadius = lineWorldRadius(
                distance: distance,
                pixelLineWidth: pixelLineWidth,
                viewportHeight: viewportHeight,
                fovYDegrees: fovYDegrees
            )
            addLine(
                to: root,
                edge: edge,
                dashed: dashed,
                solidMaterial: solidMaterial,
                dashedMaterial: dashedMaterial,
                radius: max(worldRadius, 0.0005)
            )
        }
        let flowCenter = SIMD3<Float>(
            extent.x * 0.5,
            extent.y * 0.5,
            extent.z * 0.5
        )
        let flowRadius = lineWorldRadius(
            distance: simd_length(
                cameraPosition - worldPosition(flowCenter, transform: transform)
            ),
            pixelLineWidth: pixelLineWidth,
            viewportHeight: viewportHeight,
            fovYDegrees: fovYDegrees
        )
        addFlow(to: root, extent: extent, radius: max(flowRadius, 0.0005))
    }

    static func addAxes(
        to root: SCNNode,
        extent: SIMD3<Float>,
        cameraPosition: SIMD3<Float>,
        pixelLineWidth: CGFloat,
        viewportHeight: CGFloat,
        fovYDegrees: CGFloat
    ) {
        let definitions: [(SIMD3<Float>, UIColor, String, Float)] = [
            (SIMD3<Float>(1, 0, 0), .systemRed, "X", extent.x),
            (SIMD3<Float>(0, 0, 1), .systemGreen, "Y", extent.z),
            (SIMD3<Float>(0, 1, 0), .systemBlue, "Z", extent.y)
        ]

        var axisEdges: [Edge] = []
        let transform = root.simdTransform
        for (axis, color, label, lengthValue) in definitions {
            let length = max(lengthValue, 0.01)
            guard length > 0.01 else { continue }

            let lineRadius = max(
                lineWorldRadius(
                    distance: simd_length(
                        cameraPosition - worldPosition(axis * length * 0.5, transform: transform)
                    ),
                    pixelLineWidth: pixelLineWidth,
                    viewportHeight: viewportHeight,
                    fovYDegrees: fovYDegrees
                ),
                0.0005
            )
            let cylinder = SCNCylinder(radius: CGFloat(lineRadius), height: CGFloat(length))
            cylinder.firstMaterial = makeMaterial(color: color)
            let lineNode = SCNNode(geometry: cylinder)
            lineNode.position = SCNVector3(
                axis.x * length * 0.5,
                axis.y * length * 0.5,
                axis.z * length * 0.5
            )
            lineNode.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: axis
            )
            root.addChildNode(lineNode)

            let coneRadius = max(lineRadius * 6, 0.0008)
            let coneHeight = max(coneRadius * 3, 0.002)
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(coneRadius), height: CGFloat(coneHeight))
            cone.firstMaterial = makeMaterial(color: color)
            let coneNode = SCNNode(geometry: cone)
            let head = axis * (length + coneHeight * 0.5)
            coneNode.position = SCNVector3(head.x, head.y, head.z)
            coneNode.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: axis
            )
            root.addChildNode(coneNode)
            axisEdges.append(
                Edge(
                    axis: axis,
                    length: length,
                    offset: axis * length * 0.5
                )
            )

            let valueText = SCNText(
                string: "\(label) \(String(format: "%.2f", length))",
                extrusionDepth: 0.01
            )
            valueText.font = UIFont.systemFont(ofSize: 0.08, weight: .semibold)
            valueText.firstMaterial = makeMaterial(color: color)
            let textNode = SCNNode(geometry: valueText)
            let labelPosition = axis * (length + coneHeight + 0.06) + SIMD3<Float>(0, 0.04, 0)
            textNode.position = SCNVector3(
                labelPosition.x,
                labelPosition.y,
                labelPosition.z
            )
            textNode.scale = SCNVector3(0.5, 0.5, 0.5)
            textNode.constraints = [SCNBillboardConstraint()]
            root.addChildNode(textNode)
        }
        let flowRadius = max(
            lineWorldRadius(
                distance: simd_length(
                    cameraPosition - worldPosition(SIMD3<Float>.zero, transform: transform)
                ),
                pixelLineWidth: pixelLineWidth,
                viewportHeight: viewportHeight,
                fovYDegrees: fovYDegrees
            ),
            0.0005
        )
        addFlowEdges(to: root, edges: axisEdges, radius: flowRadius)
    }

    static func makeGroundShadowNode(
        extent: SIMD3<Float>,
        transform: simd_float4x4,
        groundY: Float
    ) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(extent.x), height: CGFloat(extent.z))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(white: 0, alpha: 0.35)
        material.emission.contents = UIColor(white: 0, alpha: 0.35)
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        plane.firstMaterial = material

        let node = SCNNode(geometry: plane)
        node.name = "cropBoxShadow"
        let xAxis = SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        )
        let yaw = atan2(xAxis.z, xAxis.x)
        node.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        node.position = SCNVector3(
            transform.columns.3.x,
            groundY + 0.001,
            transform.columns.3.z
        )
        return node
    }

    static func addFlow(
        to root: SCNNode,
        extent: SIMD3<Float>,
        radius: Float
    ) {
        addFlowEdges(to: root, edges: edges(extent: extent), radius: radius)
    }

    private static func addFlowEdges(
        to root: SCNNode,
        edges: [Edge],
        radius: Float
    ) {
        let duration: TimeInterval = 3.0
        let segmentCount = 24
        for edge in edges {
            let bandSpan = min(
                max(edge.length * 0.42, 0.10),
                edge.length
            )
            let segmentHeight = CGFloat(bandSpan) / CGFloat(segmentCount)
            let travel = max(edge.length - bandSpan, 0)
            let offsets: [Float] = (0..<segmentCount).map { index in
                -bandSpan * 0.5 + bandSpan * (Float(index) + 0.5) / Float(segmentCount)
            }
            for index in 0..<segmentCount {
                let localOffset = offsets[index]
                let u = (localOffset + bandSpan * 0.5) / bandSpan
                let smooth = Float(sin(Double(u) * .pi))
                let gray = 0.12 + 0.88 * smooth
                let material = makeMaterial(color: UIColor(white: CGFloat(gray), alpha: 1))
                let segment = SCNCylinder(radius: CGFloat(radius), height: segmentHeight)
                segment.firstMaterial = material
                let node = SCNNode(geometry: segment)
                node.simdOrientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0),
                    to: edge.axis
                )
                root.addChildNode(node)

                let action = SCNAction.repeatForever(
                    SCNAction.customAction(duration: duration) { animatedNode, elapsed in
                        let elapsedSeconds = TimeInterval(elapsed)
                        let t = elapsedSeconds.truncatingRemainder(dividingBy: duration) / duration
                        let centerOffset = Float(t - 0.5) * travel
                        let position = edge.offset + edge.axis * (centerOffset + localOffset)
                        animatedNode.position = SCNVector3(position.x, position.y, position.z)
                    }
                )
                node.runAction(action)
            }
        }
    }

    private static func lineWorldRadius(
        distance: Float,
        pixelLineWidth: CGFloat,
        viewportHeight: CGFloat,
        fovYDegrees: CGFloat
    ) -> Float {
        let fovRadians = fovYDegrees * .pi / 180
        return Float(max(pixelLineWidth, 0.5))
            / Float(max(viewportHeight, 1))
            * 2
            * distance
            * tan(Float(fovRadians) / 2)
    }

    private static func worldPosition(
        _ local: SIMD3<Float>,
        transform: simd_float4x4
    ) -> SIMD3<Float> {
        let vector = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
        return SIMD3<Float>(vector.x, vector.y, vector.z)
    }

    private static func makeMaterial(color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        return material
    }

    private static func addLine(
        to root: SCNNode,
        edge: Edge,
        dashed: Bool,
        solidMaterial: SCNMaterial,
        dashedMaterial: SCNMaterial,
        radius: Float
    ) {
        func addCylinder(
            axis: SIMD3<Float>,
            length: Float,
            offset: SIMD3<Float>,
            material: SCNMaterial,
            radius: Float
        ) {
            let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
            cylinder.firstMaterial = material
            let node = SCNNode(geometry: cylinder)
            node.position = SCNVector3(offset.x, offset.y, offset.z)
            node.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: axis
            )
            root.addChildNode(node)
        }

        if !dashed {
            addCylinder(
                axis: edge.axis,
                length: edge.length,
                offset: edge.offset,
                material: solidMaterial,
                radius: radius
            )
            return
        }

        let dashLength: Float = 0.05
        let gapLength: Float = 0.04
        var cursor: Float = 0
        while cursor < edge.length {
            let dash = min(dashLength, edge.length - cursor)
            let centerAlongAxis = -edge.length * 0.5 + cursor + dash * 0.5
            let position = edge.offset + edge.axis * centerAlongAxis
            addCylinder(
                axis: edge.axis,
                length: dash,
                offset: position,
                material: dashedMaterial,
                radius: radius
            )
            cursor += dash + gapLength
        }
    }

    private static func edgeOccluded(
        edge: Edge,
        transform: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        isOccupied: (SIMD3<Float>) -> Bool
    ) -> Bool {
        let start = worldPosition(edge.start, transform: transform)
        let end = worldPosition(edge.end, transform: transform)
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
}
