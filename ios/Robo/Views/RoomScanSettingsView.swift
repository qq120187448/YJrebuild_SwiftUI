import SwiftUI

struct RoomScanSettingsView: View {
    var body: some View {
        Form {
            Section("说明") {
                LabeledContent("扫描引擎", value: "RoomPlan + LiDAR")
                Text("房间尺寸、墙厚和构件参数在扫描结果页直接调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("房间工程扫描设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
