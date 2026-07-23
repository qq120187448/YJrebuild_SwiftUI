import SwiftUI
struct MyScansView: View {
    @State private var viewMode = 0; @State private var scans: [ScanModel] = []
    var body: some View {
        VStack(spacing: 0) {
            HStack { Circle().fill(Color(hex: "1C1C1E")).frame(width: 34).overlay(Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundColor(.white)); Spacer(); Text("youjiscan").font(.system(size: 18, weight: .semibold)); Spacer(); Circle().fill(Color(hex: "1C1C1E")).frame(width: 34).overlay(Image(systemName: "questionmark").foregroundColor(.white)) }.padding(.horizontal, 16).padding(.vertical, 8)
            HStack(spacing: 0) { ForEach(0..<3) { i in Button(action: { viewMode = i }) { Image(systemName: ["list.bullet","square.grid.2x2","square.grid.3x3"][i]).foregroundColor(viewMode==i ? .white : Color(hex: "8E8E93")).frame(width: 44, height: 30).background(viewMode==i ? Color(hex: "3A3A3C") : Color.clear).clipShape(Capsule()) } }.background(Color(hex: "1C1C1E")).clipShape(Capsule()); Spacer() }.padding(.horizontal, 16).padding(.vertical, 6)
            List { ForEach(scans) { s in HStack { RoundedRectangle(cornerRadius: 10).fill(Color(hex: "E8E8ED")).frame(width: 56, height: 56).overlay(Image(systemName: "view.3d").foregroundColor(.secondary.opacity(0.3))); Text(s.formattedDate).font(.system(size: 15)).foregroundColor(Color(hex: "007AFF")); Spacer(); Image(systemName: "chevron.right").foregroundColor(Color(hex: "8E8E93")) }.padding(.vertical, 4) } }.listStyle(.plain)
        }.background(Color(hex: "F2F2F7")).onAppear { for i in 0..<12 { scans.append(ScanModel(id: "ms_\(i)", likeCount: Int.random(in: 0...1200), viewCount: Int.random(in: 0...8000), createdAt: Date().addingTimeInterval(Double(-i*86400*2)), isFavorite: false)) } }
    }
}
