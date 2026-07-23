import SwiftUI
struct SettingsView: View {
    var body: some View {
        List {
            Section("general") { SettingRow(title: "scan_mode", value: "object"); SettingRow(title: "auto_save", value: "on") }
            Section("storage") { SettingRow(title: "path", value: "/Documents"); SettingRow(title: "cache", value: "128 MB") }
            Section("camera") { SettingRow(title: "fps", value: "30"); SettingRow(title: "lidar_quality", value: "high") }
            Section("about") { SettingRow(title: "version", value: "1.0.0") }
            Section { Button("clear_all", role: .destructive, action: {}) }
        }.listStyle(.insetGrouped)
    }
}
struct SettingRow: View { let title: String; var value: String = ""; var body: some View { HStack { Text(title); Spacer(); Text(value).foregroundColor(Color(hex: "8E8E93")) } } }
