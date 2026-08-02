//
//  CapturedRoom+JSONExport.swift
//  RoomPlanDemo
//
//  Exports a CapturedRoom as JSON for quantity takeoff.
//

import Foundation
import RoomPlan
import simd

extension CapturedRoom {
    func jsonExport() throws -> Data {
        let document = RoomExportDocument(room: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }
}

private extension CapturedRoom {
    var allSurfaces: [Surface] {
        walls + doors + windows + openings + floors
    }

    var boundingSize: simd_float3 {
        guard !allSurfaces.isEmpty else { return .zero }

        var minPoint = SIMD3<Float>(x: .greatestFiniteMagnitude,
                                    y: .greatestFiniteMagnitude,
                                    z: .greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(x: -.greatestFiniteMagnitude,
                                    y: -.greatestFiniteMagnitude,
                                    z: -.greatestFiniteMagnitude)

        for surface in allSurfaces {
            let size = surface.dimensions
            let columns = surface.transform.columns
            let center = SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
            let axisX = SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z)
            let axisY = SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z)
            let offsetX = axisX * (size.x * 0.5)
            let offsetY = axisY * (size.y * 0.5)

            for signX in [Float(-1), Float(1)] {
                for signY in [Float(-1), Float(1)] {
                    let point = center + offsetX * signX + offsetY * signY
                    minPoint.x = min(minPoint.x, point.x)
                    minPoint.y = min(minPoint.y, point.y)
                    minPoint.z = min(minPoint.z, point.z)
                    maxPoint.x = max(maxPoint.x, point.x)
                    maxPoint.y = max(maxPoint.y, point.y)
                    maxPoint.z = max(maxPoint.z, point.z)
                }
            }
        }

        return maxPoint - minPoint
    }
}

struct RoomExportDocument: Encodable {
    let schemaVersion: Int
    let createdAt: Date
    let dimensions: RoomExportRoomSize
    let surfaces: [RoomExportSurface]
    let objects: [RoomExportObject]
    let summary: RoomExportSummary

    init(room: CapturedRoom) {
        schemaVersion = 1
        createdAt = Date()
        dimensions = RoomExportRoomSize(size: room.boundingSize)
        surfaces = room.allSurfaces.map(RoomExportSurface.init)
        objects = room.objects.map(RoomExportObject.init)
        summary = RoomExportSummary(surfaces: room.allSurfaces, objects: room.objects)
    }
}

struct RoomExportRoomSize: Encodable {
    let width: Double
    let length: Double
    let height: Double

    init(size: simd_float3) {
        width = Double(size.x)
        length = Double(size.y)
        height = Double(size.z)
    }
}

struct RoomExportElementSize: Encodable {
    let width: Double
    let height: Double
    let depth: Double

    init(size: simd_float3) {
        width = Double(size.x)
        height = Double(size.y)
        depth = Double(size.z)
    }
}

struct RoomExportSurface: Encodable {
    let id: String
    let category: String
    let dimensions: RoomExportElementSize
    let area: Double
    let transform: RoomExportTransform

    init(surface: CapturedRoom.Surface) {
        id = surface.identifier.uuidString
        category = Self.categoryName(surface.category)
        dimensions = RoomExportElementSize(size: surface.dimensions)
        area = Double(surface.dimensions.x * surface.dimensions.y)
        transform = RoomExportTransform(transform: surface.transform)
    }

    static func categoryName(_ category: CapturedRoom.Surface.Category) -> String {
        switch category {
        case .wall: return "wall"
        case .door: return "door"
        case .window: return "window"
        case .opening: return "opening"
        case .floor: return "floor"
        @unknown default: return "unknown"
        }
    }
}

struct RoomExportObject: Encodable {
    let id: String
    let category: String
    let dimensions: RoomExportElementSize
    let volume: Double
    let transform: RoomExportTransform

    init(object: CapturedRoom.Object) {
        id = object.identifier.uuidString
        category = Self.categoryName(object.category)
        dimensions = RoomExportElementSize(size: object.dimensions)
        volume = Double(object.dimensions.x * object.dimensions.y * object.dimensions.z)
        transform = RoomExportTransform(transform: object.transform)
    }

    static func categoryName(_ category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage: return "storage"
        case .refrigerator: return "refrigerator"
        case .stove: return "stove"
        case .bed: return "bed"
        case .sink: return "sink"
        case .washerDryer: return "washerDryer"
        case .toilet: return "toilet"
        case .bathtub: return "bathtub"
        case .oven: return "oven"
        case .dishwasher: return "dishwasher"
        case .table: return "table"
        case .sofa: return "sofa"
        case .chair: return "chair"
        case .fireplace: return "fireplace"
        case .television: return "television"
        case .stairs: return "stairs"
        @unknown default: return "unknown"
        }
    }
}

struct RoomExportTransform: Encodable {
    let matrix: [[Float]]

    init(transform: simd_float4x4) {
        let c = transform.columns
        matrix = [
            [c.0.x, c.1.x, c.2.x, c.3.x],
            [c.0.y, c.1.y, c.2.y, c.3.y],
            [c.0.z, c.1.z, c.2.z, c.3.z],
            [c.0.w, c.1.w, c.2.w, c.3.w]
        ]
    }
}

struct RoomExportSummary: Encodable {
    let surfaceCount: Int
    let wallCount: Int
    let doorCount: Int
    let windowCount: Int
    let openingCount: Int
    let wallArea: Double
    let doorArea: Double
    let windowArea: Double
    let objectCount: Int
    let objectCounts: [String: Int]

    init(surfaces: [CapturedRoom.Surface], objects: [CapturedRoom.Object]) {
        let walls = surfaces.filter { $0.category == .wall }
        let doors = surfaces.filter {
            if case .door = $0.category { return true }
            return false
        }
        let windows = surfaces.filter {
            if case .window = $0.category { return true }
            return false
        }
        let openings = surfaces.filter { $0.category == .opening }

        surfaceCount = surfaces.count
        wallCount = walls.count
        doorCount = doors.count
        windowCount = windows.count
        openingCount = openings.count
        wallArea = Double(walls.reduce(0) { $0 + $1.dimensions.x * $1.dimensions.y })
        doorArea = Double(doors.reduce(0) { $0 + $1.dimensions.x * $1.dimensions.y })
        windowArea = Double(windows.reduce(0) { $0 + $1.dimensions.x * $1.dimensions.y })
        objectCount = objects.count
        objectCounts = Dictionary(grouping: objects, by: { RoomExportObject.categoryName($0.category) })
            .mapValues { $0.count }
    }
}
