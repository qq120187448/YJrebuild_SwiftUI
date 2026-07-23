import SwiftUI
struct ScanTypeModal: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12); Capsule().fill(Color(hex: "E5E5EA")).frame(width: 36, height: 4)
            Text("select_scan_type").font(.system(size: 20, weight: .bold)).padding(.vertical, 12)
            ForEach(ScanType.allCases) { t in
                Button(action: { dismiss() }) {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 10).fill(Color(hex: "007AFF").opacity(0.1)).frame(width: 40, height: 40).overlay(Image(systemName: t.icon).foregroundColor(Color(hex: "007AFF")))
                        VStack(alignment: .leading, spacing: 2) { Text(t.title).font(.system(size: 17, weight: .semibold)); Text(t.subtitle).font(.system(size: 13)).foregroundColor(Color(hex: "8E8E93")) }
                        Spacer(); Image(systemName: "chevron.right").foregroundColor(Color(hex: "8E8E93"))
                    }.padding(.horizontal, 20).padding(.vertical, 14)
                }
            }
            Spacer().frame(height: 24)
        }.presentationDetents([.medium])
    }
}
