import Foundation
import UIKit

struct DeviceConfig: Codable {
    var id: String
    var name: String
    var apiBaseURL: String
    var mcpToken: String?

    static let unregisteredID = "unregistered"

    static let `default` = DeviceConfig(
        id: unregisteredID,
        name: UIDevice.current.name,
        apiBaseURL: "https://api.robo.app"
    )

    var isRegistered: Bool {
        id != Self.unregisteredID
    }
}
