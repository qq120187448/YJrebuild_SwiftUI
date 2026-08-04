import Foundation

enum ObjectScanSettings {
    private static let pointSizeKey = "objectScanPointSize"

    static var pointSize: Double {
        get {
            UserDefaults.standard.object(forKey: pointSizeKey) as? Double ?? 1.5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: pointSizeKey)
        }
    }
}
