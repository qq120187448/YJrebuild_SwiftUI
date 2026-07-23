import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView() }
                .tabItem { Label("??", systemImage: "house.fill") }.tag(0)

            NavigationStack { LiDARCameraView() }
                .tabItem { Label("??", systemImage: "camera.fill") }.tag(1)

            NavigationStack { MyScansView() }
                .tabItem { Label("??", systemImage: "folder.fill") }.tag(2)

            NavigationStack { SettingsView() }
                .tabItem { Label("??", systemImage: "gearshape.fill") }.tag(3)
        }
        .tint(Color(hex: "E74C3C"))
    }
}
