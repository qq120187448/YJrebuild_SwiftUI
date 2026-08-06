import Foundation

enum ObjectScanSettings {
    private static let pointSizeKey = "objectScanPointSize"
    private static let previewPointLimitKey = "objectScanPreviewPointLimit"
    private static let previewPointSizeKey = "objectScanPreviewPointSize"

    static var pointSize: Double {
        get {
            UserDefaults.standard.object(forKey: pointSizeKey) as? Double ?? 1.5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: pointSizeKey)
        }
    }

    static var previewPointLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: previewPointLimitKey)
            return stored > 0 ? min(max(stored, 10_000), 200_000) : 80_000
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 10_000), 200_000), forKey: previewPointLimitKey)
        }
    }

    static var previewPointSize: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: previewPointSizeKey)
            return stored > 0 ? min(max(stored, 1), 10) : 4
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 1), 10), forKey: previewPointSizeKey)
        }
    }

    static var boxLineWidth: Double {
        get { 1 }
        set {}
    }
}
