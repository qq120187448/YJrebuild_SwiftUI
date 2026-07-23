import SwiftUI
struct SettingsView: View {
    var body: some View {
        List {
            Section("general") { SettingRow("scan_mode", v: "object"); SettingRow("auto_save", v: "on") }
            Section("storage") { SettingRow("path", v: "/Documents"); SettingRow("cache", v: "128 MB") }
            Section("camera") { SettingRow("fps", v: "30"); SettingRow("lidar_quality", v: "high") }
            Section("about") { SettingRow("version", v: "1.0.0") }
            Section { Button("clear_all", role: .destructive, action: {}) }
        }.listStyle(.insetGrouped)
    }
}
struct SettingRow: View { let title: String; var v: String = ""; var body: some View { HStack { Text(title); Spacer(); Text(v).foregroundColor(Color(hex: "8E8E93")) } } }
