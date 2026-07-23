import Foundation
import AVFoundation
import Photos
import ARKit
import UIKit

/// Manages all app permissions. Requests camera, photo library, and LiDAR access.
class PermissionManager: ObservableObject {
    @Published var cameraGranted = false
    @Published var photoGranted = false
    @Published var lidarAvailable = false
    @Published var allGranted = false

    func requestAllPermissions() {
        requestCamera { [weak self] camOk in
            self?.cameraGranted = camOk
            self?.requestPhotoLibrary { [weak self] photoOk in
                self?.photoGranted = photoOk
                self?.lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
                self?.allGranted = camOk && photoOk
            }
        }
    }

    private func requestCamera(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func requestPhotoLibrary(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async { completion(newStatus == .authorized || newStatus == .limited) }
            }
        default:
            completion(false)
        }
    }
}
