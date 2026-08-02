import Testing
import simd
@testable import Robo

// MARK: - Polygon Area (Shoelace Formula)
// RoomPlan floor polygonCorners are in the surface's local coordinate system
// where the floor lies in the X-Y plane (Z is always 0).

@Test func polygonAreaSquare10x10() {
    let corners: [simd_float3] = [
        simd_float3(0, 0, 0),
        simd_float3(10, 0, 0),
        simd_float3(10, 10, 0),
        simd_float3(0, 10, 0)
    ]
    let area = RoomDataProcessor.polygonArea(corners)
    #expect(abs(area - 100.0) < 0.01)
}

@Test func polygonAreaRectangle3x4() {
    let corners: [simd_float3] = [
        simd_float3(0, 0, 0),
        simd_float3(3, 0, 0),
        simd_float3(3, 4, 0),
        simd_float3(0, 4, 0)
    ]
    let area = RoomDataProcessor.polygonArea(corners)
    #expect(abs(area - 12.0) < 0.01)
}

@Test func polygonAreaTriangle() {
    // Right triangle with legs 3 and 4 = area 6
    let corners: [simd_float3] = [
        simd_float3(0, 0, 0),
        simd_float3(3, 0, 0),
        simd_float3(0, 4, 0)
    ]
    let area = RoomDataProcessor.polygonArea(corners)
    #expect(abs(area - 6.0) < 0.01)
}

@Test func polygonAreaLShaped() {
    // L-shape: 10x10 square minus 5x5 corner = 75 sqm
    let corners: [simd_float3] = [
        simd_float3(0, 0, 0),
        simd_float3(10, 0, 0),
        simd_float3(10, 5, 0),
        simd_float3(5, 5, 0),
        simd_float3(5, 10, 0),
        simd_float3(0, 10, 0)
    ]
    let area = RoomDataProcessor.polygonArea(corners)
    #expect(abs(area - 75.0) < 0.01)
}

@Test func polygonAreaWithNonZeroZCoordinates() {
    // Z coordinate should be ignored (it's the surface normal direction)
    let corners: [simd_float3] = [
        simd_float3(0, 0, 1.5),
        simd_float3(5, 0, 1.5),
        simd_float3(5, 4, 1.5),
        simd_float3(0, 4, 1.5)
    ]
    let area = RoomDataProcessor.polygonArea(corners)
    #expect(abs(area - 20.0) < 0.01)
}

@Test func polygonAreaTwoPointsReturnsZero() {
    let corners: [simd_float3] = [
        simd_float3(0, 0, 0),
        simd_float3(5, 0, 0)
    ]
    let area = RoomDataProcessor.polygonArea(corners)
    #expect(area == 0.0)
}

@Test func polygonAreaEmptyReturnsZero() {
    let area = RoomDataProcessor.polygonArea([])
    #expect(area == 0.0)
}

@Test func polygonAreaRealRoomPlanData() {
    // Actual polygonCorners from a real LiDAR scan export (X-Y plane, Z=0)
    let corners: [simd_float3] = [
        simd_float3(2.273669, -1.8077334, 0),
        simd_float3(-2.302082, -1.8077334, 0),
        simd_float3(-2.3020816, 1.8189566, 0),
        simd_float3(1.5687221, 1.8189569, 0),
        simd_float3(1.5687222, 0.18942255, 0),
        simd_float3(2.2736692, 0.18942225, 0)
    ]
    let area = RoomDataProcessor.polygonArea(corners)
    // Expected: ~15.3 sqm (irregular L-shape room)
    #expect(area > 14.0 && area < 17.0)
}

// MARK: - Transform Corner to World

@Test func transformCornerToWorldIdentity() {
    let identity = simd_float4x4(1.0) // identity matrix
    let corner = simd_float3(2.0, 3.0, 0.0)
    let world = RoomDataProcessor.transformCornerToWorld(corner, transform: identity)
    #expect(abs(world.x - 2.0) < 0.001)
    #expect(abs(world.y - 3.0) < 0.001)
    #expect(abs(world.z - 0.0) < 0.001)
}

@Test func transformCornerToWorldWithTranslation() {
    var transform = simd_float4x4(1.0)
    transform.columns.3 = SIMD4<Float>(5.0, 0.0, 10.0, 1.0) // translate by (5, 0, 10)
    let corner = simd_float3(1.0, 2.0, 0.0)
    let world = RoomDataProcessor.transformCornerToWorld(corner, transform: transform)
    #expect(abs(world.x - 6.0) < 0.001)
    #expect(abs(world.y - 2.0) < 0.001)
    #expect(abs(world.z - 10.0) < 0.001)
}

// MARK: - Bounding Box Dimensions

@Test func boundingBoxSimpleRectangle() {
    // 4 wall positions forming a rectangle
    let positions: [(x: Double, z: Double)] = [
        (x: 0, z: 0),
        (x: 5, z: 0),
        (x: 5, z: 3),
        (x: 0, z: 3)
    ]
    let dims = RoomDataProcessor.boundingBoxDimensions(positions)
    #expect(dims != nil)
    #expect(abs(dims!.length - 5.0) < 0.01)
    #expect(abs(dims!.width - 3.0) < 0.01)
}

@Test func boundingBoxTooFewPositionsReturnsNil() {
    let positions: [(x: Double, z: Double)] = [
        (x: 0, z: 0),
        (x: 5, z: 0)
    ]
    let dims = RoomDataProcessor.boundingBoxDimensions(positions)
    #expect(dims == nil)
}

@Test func boundingBoxLengthAlwaysGreaterOrEqualToWidth() {
    let positions: [(x: Double, z: Double)] = [
        (x: 0, z: 0),
        (x: 2, z: 0),
        (x: 2, z: 8),
        (x: 0, z: 8)
    ]
    let dims = RoomDataProcessor.boundingBoxDimensions(positions)
    #expect(dims != nil)
    #expect(dims!.length >= dims!.width)
    #expect(abs(dims!.length - 8.0) < 0.01)
    #expect(abs(dims!.width - 2.0) < 0.01)
}

// MARK: - Perimeter Square Area

@Test func perimeterSquareAreaFourEqualWalls() {
    // 4 walls of 5m each = 20m perimeter, side = 5m, area = 25 sqm
    let widths = [5.0, 5.0, 5.0, 5.0]
    let area = RoomDataProcessor.perimeterSquareArea(widths)
    #expect(abs(area - 25.0) < 0.01)
}

@Test func perimeterSquareAreaUnequalWalls() {
    // Perimeter = 3+7+3+7 = 20m, side = 5m, area = 25 sqm
    let widths = [3.0, 7.0, 3.0, 7.0]
    let area = RoomDataProcessor.perimeterSquareArea(widths)
    #expect(abs(area - 25.0) < 0.01)
}

@Test func perimeterSquareAreaEmptyReturnsZero() {
    let area = RoomDataProcessor.perimeterSquareArea([])
    #expect(area == 0.0)
}

// MARK: - Conversion Constants

@Test func metersToFeetConversion() {
    #expect(abs(RoomDataProcessor.metersToFeet - 3.28084) < 0.0001)
}

@Test func sqmToSqftConversion() {
    // 1 sqm = 10.7639 sqft
    let sqm = 100.0
    let sqft = sqm * RoomDataProcessor.sqmToSqft
    #expect(abs(sqft - 1076.39) < 0.01)
}
