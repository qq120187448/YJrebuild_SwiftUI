import Foundation
enum ScanType: String, CaseIterable, Identifiable {
    case object, radar, pointCloud, floorPlan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .object: return "object"; case .radar: return "radar"; case .pointCloud: return "point_cloud"; case .floorPlan: return "floor_plan"
        }
    }
    var subtitle: String {
        switch self {
        case .object: return "small objects"; case .radar: return "rooms"; case .pointCloud: return "large spaces"; case .floorPlan: return "3D floor plans"
        }
    }
    var icon: String {
        switch self {
        case .object: return "chair.fill"; case .radar: return "house.fill"; case .pointCloud: return "circle.dotted"; case .floorPlan: return "square.grid.3x3"
        }
    }
}
