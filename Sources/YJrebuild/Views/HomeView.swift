import SwiftUI
struct HomeView: View {
    @State private var selectedTab = 0; @State private var showModal = false
    @State private var scans: [ScanModel] = []
    let tabs = ["latest", "most_viewed", "favorites"]
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(hex: "F2F2F7").ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Circle().fill(Color(hex: "1C1C1E")).frame(width: 34, height: 34).overlay(Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundColor(.white))
                    Spacer(); Text("youjiscan").font(.system(size: 18, weight: .semibold)); Spacer()
                    Circle().fill(Color(hex: "1C1C1E")).frame(width: 34, height: 34).overlay(Image(systemName: "questionmark").font(.system(size: 14)).foregroundColor(.white))
                }.padding(.horizontal, 16).padding(.vertical, 8)
                HStack(spacing: 0) {
                    ForEach(0..<tabs.count, id: \.self) { i in
                        Button(tabs[i]) { selectedTab = i }.font(.system(size: 14, weight: .medium))
                            .foregroundColor(selectedTab == i ? .white : Color(hex: "8E8E93")).frame(maxWidth: .infinity, minHeight: 30)
                            .background(selectedTab == i ? Color(hex: "3A3A3C") : Color.clear).clipShape(Capsule())
                    }
                }.frame(height: 36).background(Color(hex: "1C1C1E")).clipShape(Capsule()).padding(.horizontal, 50).padding(.vertical, 8)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(filteredScans) { scan in DocumentCard(scan: scan) }
                    }.padding(12)
                }
                BottomNavBar(showModal: $showModal)
            }
        }.onAppear { for i in 0..<8 { scans.append(ScanModel(id: "s_\(i)", likeCount: Int.random(in: 0...3200), viewCount: Int.random(in: 0...15000), createdAt: Date().addingTimeInterval(Double(-i*86400*3)), isFavorite: i%3==0)) } }
        .sheet(isPresented: $showModal) { ScanTypeModal() }
    }
    var filteredScans: [ScanModel] {
        switch selectedTab { case 0: return scans; case 1: return scans.sorted{$0.viewCount>$1.viewCount}; case 2: return scans.filter{$0.isFavorite}; default: return scans }
    }
}
struct DocumentCard: View {
    let scan: ScanModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 0).fill(Color(hex: "E8E8ED")).aspectRatio(1, contentMode: .fit).overlay(Image(systemName: "view.3d").font(.system(size: 36)).foregroundColor(.secondary.opacity(0.3)))
            HStack(spacing: 8) { Label("\(scan.likeCount)", systemImage: "heart").font(.system(size: 11)).foregroundColor(Color(hex: "8E8E93")); Label("\(scan.viewCount)", systemImage: "eye").font(.system(size: 11)).foregroundColor(Color(hex: "8E8E93")) }.padding(.horizontal, 10).padding(.vertical, 6)
            Text(scan.formattedDate).font(.system(size: 11)).foregroundColor(Color(hex: "007AFF")).padding(.horizontal, 10).padding(.bottom, 10)
        }.background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}
struct BottomNavBar: View {
    @Binding var showModal: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button(action: {}) { VStack(spacing: 2) { Image(systemName: "globe"); Text("share") }.font(.system(size: 10)).foregroundColor(.white) }
            Spacer(); Button(action: { showModal = true }) { Circle().fill(Color(hex: "E74C3C")).frame(width: 52).overlay(Image(systemName: "plus").font(.system(size: 26)).foregroundColor(.white)) }
            Spacer(); Button(action: {}) { VStack(spacing: 2) { Image(systemName: "folder"); Text("scans") }.font(.system(size: 10)).foregroundColor(.white) }
        }.padding(.horizontal, 30).padding(.bottom, 28).frame(height: 92).background(Color(hex: "1C1C1E")).clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
