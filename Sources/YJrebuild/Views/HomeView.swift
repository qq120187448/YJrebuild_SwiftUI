import SwiftUI

struct HomeView: View {
    @State private var selectedTab = 0
    @State private var showScanModal = false
    @State private var scans: [ScanModel] = []
    let tabs = ["最新", "观看最多", "最喜欢"]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(hex: "F2F2F7").ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear.frame(height: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.statusBarManager?.statusBarFrame.height ?? 44)

                HStack {
                    Button(action: {}) {
                        Circle().fill(Color(hex: "1C1C1E")).frame(width: 34, height: 34)
                            .overlay(Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundColor(.white))
                    }
                    Spacer()
                    Text("优记扫描")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(hex: "1C1C1E"))
                    Spacer()
                    Button(action: {}) {
                        Circle().fill(Color(hex: "1C1C1E")).frame(width: 34, height: 34)
                            .overlay(Image(systemName: "questionmark").font(.system(size: 14)).foregroundColor(.white))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)

                HStack(spacing: 0) {
                    ForEach(0..<tabs.count, id: \.self) { i in
                        Button(tabs[i]) { withAnimation { selectedTab = i } }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(selectedTab == i ? .white : Color(hex: "8E8E93"))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(selectedTab == i ? Color(hex: "3A3A3C") : Color.clear)
                            .clipShape(Capsule())
                    }
                }
                .frame(height: 36)
                .background(Color(hex: "1C1C1E"))
                .clipShape(Capsule())
                .padding(.horizontal, 50).padding(.vertical, 8)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(filteredScans) { scan in
                            DocumentCard(scan: scan)
                        }
                    }.padding(12)
                }
            }

            BottomNavBar(showModal: $showScanModal)
        }
        .ignoresSafeArea(.container)
        .onAppear { generateMockData() }
        .sheet(isPresented: $showScanModal) { ScanTypeModal() }
        .ignoresSafeArea(edges: .bottom)
    }

    var filteredScans: [ScanModel] {
        switch selectedTab {
        case 0: return scans
        case 1: return scans.sorted { $0.viewCount > $1.viewCount }
        case 2: return scans.filter { $0.isFavorite }
        default: return scans
        }
    }

    func generateMockData() {
        for i in 0..<8 {
            scans.append(ScanModel(id: "s_\(i)", likeCount: Int.random(in: 0...3200), viewCount: Int.random(in: 0...15000), createdAt: Date().addingTimeInterval(Double(-i * 86400 * 3)), isFavorite: i % 3 == 0))
        }
    }
}

struct BottomNavBar: View {
    @Binding var showModal: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button(action: {}) {
                VStack(spacing: 2) {
                    Image(systemName: "globe").font(.system(size: 20))
                    Text("分享").font(.system(size: 10))
                }.foregroundColor(.white)
            }
            Spacer()
            Button(action: { showModal = true }) {
                Circle().fill(Color(hex: "E74C3C")).frame(width: 52, height: 52)
                    .overlay(Image(systemName: "plus").font(.system(size: 26)).foregroundColor(.white))
            }
            Spacer()
            Button(action: {}) {
                VStack(spacing: 2) {
                    Image(systemName: "folder").font(.system(size: 20))
                    Text("我的扫描").font(.system(size: 10))
                }.foregroundColor(.white)
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 34)
        .padding(.top, 12)
        .frame(height: 92)
        .background(Color(hex: "1C1C1E"))
    }
}

struct DocumentCard: View {
    let scan: ScanModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(hex: "E8E8ED"))
                .aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: "view.3d").font(.system(size: 36)).foregroundColor(.secondary.opacity(0.3)))
            HStack(spacing: 8) {
                Label(String(scan.likeCount), systemImage: "heart")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "8E8E93"))
                Label(String(scan.viewCount), systemImage: "eye")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "8E8E93"))
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Text(scan.formattedDate)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "007AFF"))
                .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}
