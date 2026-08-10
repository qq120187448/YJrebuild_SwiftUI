import CoreLocation
import Foundation

final class WallDefectHeadingService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var headingDeg: Double?

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.headingOrientation = .portrait
        locationManager.headingFilter = 1
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.requestWhenInUseAuthorization()
    }

    func start() {
        locationManager.startUpdatingHeading()
    }

    func stop() {
        locationManager.stopUpdatingHeading()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        let value = newHeading.trueHeading > 0
            ? newHeading.trueHeading
            : newHeading.magneticHeading
        if value >= 0 {
            DispatchQueue.main.async {
                self.headingDeg = value
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingHeading()
        default:
            break
        }
    }
}
