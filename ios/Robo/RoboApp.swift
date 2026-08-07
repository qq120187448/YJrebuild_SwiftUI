import SwiftUI
import SwiftData

@main
struct RoboApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: RoomScanRecord.self,
                ObjectScanRecord.self,
                TextureScanRecord.self
            )
        } catch {
            fatalError("无法创建数据存储：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onOpenURL { url in
                    CrackRecognitionSettings.apply(url: url)
                }
        }
    }
}
