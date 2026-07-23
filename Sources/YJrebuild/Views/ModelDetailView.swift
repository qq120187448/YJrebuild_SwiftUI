import SwiftUI
import SceneKit

struct ModelDetailView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isFavorite = false
    @State private var showExport = false
    let scan: ScanModel
    var meshData: Data? = nil

    let tools = [("编辑", "pencil"), ("滤镜", "camera.filters"), ("清理", "sparkles"),
                 ("测量", "ruler"), ("OCR", "text.viewfinder"), ("重构", "arrow.triangle.2.circlepath"),
                 ("导出", "square.and.arrow.down"), ("删除", "trash")]

    var body: some View {
        ZStack {
            Color(hex: "1A1A1A").ignoresSafeArea()

            // 3D preview or placeholder
            if let data = meshData {
                SceneKitPreviewView(scene: SceneKitPreviewView.buildScene(from: data))
            } else {
                VStack {
                    Image(systemName: "view.3d").font(.system(size: 80)).foregroundColor(.white.opacity(0.12))
                    Text(scan.formattedDate).foregroundColor(.white.opacity(0.2)).font(.system(size: 12))
                }
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
                            Button(action: { handleTool(title) }) {
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12))
                                        .frame(width: 40, height: 38)
                                        .overlay(Image(systemName: icon).foregroundColor(.white))
                                    Text(title).font(.system(size: 9)).foregroundColor(.white)
                                }.frame(width: 56)
                            }
                        }
                    }.padding(.horizontal, 8)
                }.frame(height: 72).padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showExport) {
            ExportModal(scan: scan, meshData: meshData)
        }
    }

    func handleTool(_ tool: String) {
        switch tool {
        case "导出": showExport = true
        default: break
        }
    }
}
