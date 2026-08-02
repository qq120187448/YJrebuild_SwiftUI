import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            CaptureHomeView()
                .tabItem {
                    Label(AppStrings.Tabs.capture, systemImage: "camera.metering.spot")
                }
                .tag(0)

            ScanHistoryView()
                .tabItem {
                    Label(AppStrings.Tabs.history, systemImage: "archivebox")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label(AppStrings.Tabs.settings, systemImage: "gearshape")
                }
                .tag(2)
        }
    }
}
