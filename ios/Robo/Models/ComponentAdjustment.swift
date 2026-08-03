import Foundation

struct ComponentAdjustment: Codable, Identifiable, Hashable {
    var id: String { componentID }
    let componentID: String
    var label: String
    var width: Double?
    var height: Double?
    var depth: Double?
}

struct RoomDimensionOverride: Codable {
    var length: Double?
    var width: Double?
}

struct RoomAdjustments: Codable {
    var components: [String: ComponentAdjustment] = [:]
    var roomDimensions: RoomDimensionOverride?
}

enum AdjustmentStorage {
    static func encode(_ adjustments: RoomAdjustments) -> Data? {
        try? JSONEncoder().encode(adjustments)
    }

    static func decode(_ data: Data?) -> RoomAdjustments {
        guard let data else { return RoomAdjustments() }
        return (try? JSONDecoder().decode(RoomAdjustments.self, from: data)) ?? RoomAdjustments()
    }
}
