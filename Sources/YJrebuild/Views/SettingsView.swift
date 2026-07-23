import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("??") {
                SettingRow(title: "??????", value: "??")
                SettingRow(title: "??????", value: "??")
                SettingRow(title: "???????", value: "??")
            }
            Section("??") {
                SettingRow(title: "??????", value: "/Documents/????")
                SettingRow(title: "????", value: "128 MB")
                SettingRow(title: "????3D??", value: "")
            }
            Section("??? LiDAR") {
                SettingRow(title: "???????", value: "??")
                SettingRow(title: "????", value: "30 fps")
                SettingRow(title: "LiDAR ????", value: "?")
            }
            Section("?????") {
                SettingRow(title: "????", value: "???")
                SettingRow(title: "????", value: "???")
            }
            Section("??") {
                SettingRow(title: "App ??", value: "1.0.0")
                SettingRow(title: "????", value: "")
                SettingRow(title: "????", value: "")
            }
            Section {
                Button("????????", role: .destructive) {}
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(hex: "F2F2F7"))
    }
}

struct SettingRow: View {
    let title: String
    var value: String = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 15))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "8E8E93"))
        }
    }
}
