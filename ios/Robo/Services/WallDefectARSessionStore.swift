import ARKit
import Foundation

enum WallDefectARSessionStore {

    private static var fileURL: URL {
        WallDefectStore.rootDirectory().appendingPathComponent("Shared.worldmap")
    }

    static func save(_ worldMap: ARWorldMap) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: worldMap,
            requiringSecureCoding: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    static func load() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: ARWorldMap.self,
            from: data
        )
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
