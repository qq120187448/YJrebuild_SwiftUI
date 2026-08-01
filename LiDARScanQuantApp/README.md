# LiDAR Scan Quant

SwiftUI iOS app built on the RoomPlanDemo open source project. It scans rooms
and objects with iPhone/iPad LiDAR and exports data for engineering quantity
takeoff.

## Features

- RoomPlan room scanning with 2D floor plan editing
- Export room model as USDZ
- Export room semantics and measurements as JSON
- ARKit mesh scanning with colored PLY export

## Hardware

- iPhone 12 Pro or newer
- iPad Pro 2020 or newer
- iOS 17.0+

## Build

1. Open `RoomPlanDemo.xcodeproj` with Xcode 16 or newer.
2. Select your development team and change the bundle identifier.
3. Run on a physical LiDAR device. Simulators do not support LiDAR.

## Scan Modes

- `Start Scanning` scans a room with RoomPlan. After finishing, `Share Room`
  exports USDZ and `JSON` exports the semantic room data.
- `LiDAR Point Cloud Scan` builds an ARKit mesh. `Export PLY` writes an ASCII
  PLY file with mesh faces and per-vertex RGB colors sampled from the camera.

## JSON Schema

The JSON export contains room dimensions, surfaces (walls, doors, windows,
openings) with category/area/transform, objects with category/volume/transform,
and a summary with counts and total areas. The schema version is stored in
`schemaVersion`.

## Based On

- [BaidetskyiYurii/RoomPlanDemo](https://github.com/BaidetskyiYurii/RoomPlanDemo)
- [pjessesco/iPad-PLY-scanner](https://github.com/pjessesco/iPad-PLY-scanner)
