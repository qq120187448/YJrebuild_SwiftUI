//
//  LiDARScanEngine.swift
//  RoomPlanDemo
//
//  ARKit mesh scanning and colored PLY export.
//

import ARKit
import Combine
import Foundation
import SceneKit
import UIKit

final class LiDARScanEngine: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var isExporting = false
    @Published var meshVertexCount = 0
    @Published var meshFaceCount = 0
    @Published var isShowingError = false
    @Published var errorMessage = ""

    let sceneView = ARSCNView(frame: .zero)
    private let session = ARSession()
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private let updateQueue = DispatchQueue(label: "com.lidar.scan.engine.update")

    override init() {
        super.init()
        sceneView.session = session
        sceneView.automaticallyUpdatesLighting = false
        session.delegate = self
    }

    var supportsSceneReconstruction: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func startScanning() {
        guard supportsSceneReconstruction else {
            reportError("This device does not support LiDAR scene reconstruction.")
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        session.run(configuration)
        isScanning = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stopScanning() {
        session.pause()
        isScanning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resetScanning() {
        meshAnchors.removeAll()
        updateCounts()

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        session.run(configuration, options: [.resetSceneReconstruction, .removeExistingAnchors])
        isScanning = true
    }

    func exportColoredPLY(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isExporting else { return }

        let anchors: [ARMeshAnchor] = updateQueue.sync { Array(self.meshAnchors.values) }
        guard !anchors.isEmpty, let frame = session.currentFrame else {
            completion(.failure(LiDARScanError.noData))
            return
        }

        isExporting = true
        updateQueue.async { [weak self] in
            guard let self else { return }
            do {
                let url = try ColoredPLYExporter.writeColoredMeshPLY(anchors: anchors, frame: frame)
                DispatchQueue.main.async {
                    self.isExporting = false
                    completion(.success(url))
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExporting = false
                    completion(.failure(error))
                }
            }
        }
    }

    func reportError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }

    private func updateCounts() {
        let vertices = meshAnchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
        let faces = meshAnchors.values.reduce(0) { $0 + $1.geometry.faces.count / 3 }
        meshVertexCount = vertices
        meshFaceCount = faces
    }
}

extension LiDARScanEngine: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateQueue.async { [weak self] in
            guard let self else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    self.meshAnchors[mesh.identifier] = mesh
                }
            }
            DispatchQueue.main.async { self.updateCounts() }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateQueue.async { [weak self] in
            guard let self else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    self.meshAnchors[mesh.identifier] = mesh
                }
            }
            DispatchQueue.main.async { self.updateCounts() }
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        updateQueue.async { [weak self] in
            guard let self else { return }
            for anchor in anchors {
                self.meshAnchors.removeValue(forKey: anchor.identifier)
            }
            DispatchQueue.main.async { self.updateCounts() }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.reportError(error.localizedDescription)
        }
    }
}
