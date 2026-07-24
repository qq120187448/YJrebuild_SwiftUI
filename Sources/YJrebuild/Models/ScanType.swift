import Foundation

enum ScanType: String, CaseIterable, Identifiable {
    case object
    case radar
    case pointCloud
    case floorPlan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: return "物体"
        case .radar: return "雷达"
        case .pointCloud: return "点云"
        case .floorPlan: return "户型扫描"
        }
    }

    var subtitle: String {
        switch self {
        case .object: return "小物体，家具，文物"
        case .radar: return "房间，建筑，室外景点"
        case .pointCloud: return "大空间的点云"
        case .floorPlan: return "3D 户型图"
        }
    }

    var icon: String {
        switch self {
        case .object: return "chair.fill"
        case .radar: return "house.fill"
        case .pointCloud: return "circle.dotted"
        case .floorPlan: return "square.grid.3x3"
        }
    }
}
