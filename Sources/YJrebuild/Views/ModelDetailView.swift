import SwiftUI

struct ModelDetailView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isFavorite = false
    let scan: ScanModel

    let tools = [("??", "pencil"), ("??", "camera.filters"), ("??", "sparkles"),
                 ("??", "ruler"), ("OCR", "text.viewfinder"), ("??", "arrow.triangle.2.circlepath"),
                 ("??", "square.and.arrow.down"), ("??", "trash")]

    var body: some View {
        ZStack {
            Color(hex: "1A1A1A").ignoresSafeArea()
            VStack {
                Image(systemName: "view.3d").font(.system(size: 80)).foregroundColor(.white.opacity(0.12))
                Text(scan.formattedDate).foregroundColor(.white.opacity(0.2)).font(.system(size: 12))
            }
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Circle().fill(Color.white.opacity(0.15)).frame(width: 38)
                            .overlay(Image(systemName: "arrow.left").foregroundColor(.white))
                    }
                    Spacer()
                    Text(scan.formattedDate).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                    Spacer()
                    Button(action: { isFavorite.toggle() }) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundColor(isFavorite ? Color(hex: "E74C3C") : .white)
                    }
                    Button(action: {}) {
                        Image(systemName: "square.and.arrow.up").foregroundColor(.white)
                    }
                    Button(action: {}) {
                        Image(systemName: "ellipsis").foregroundColor(.white)
                    }
                }.padding(.horizontal, 12).padding(.top, 50)
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tools, id: \.0) { title, icon in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 40, height: 38)
                                    .overlay(Image(systemName: icon).foregroundColor(.white))
                                Text(title).font(.system(size: 9)).foregroundColor(.white)
                            }.frame(width: 56)
                        }
                    }.padding(.horizontal, 8)
                }.frame(height: 72).padding(.bottom, 16)
            }
        }
    }
}
