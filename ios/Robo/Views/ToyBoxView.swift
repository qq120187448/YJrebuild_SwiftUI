import SwiftUI

struct ToyBoxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingObjectMode = false
    @State private var showingAreaMode = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.06, blue: 0.11),
                        Color(red: 0.08, green: 0.12, blue: 0.2)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        toyCard(
                            title: "趣味物体建模",
                            subtitle: "围绕单个物体扫描，生成带纹理 USDZ，不输出工程量",
                            icon: "viewfinder",
                            action: {
                                showingObjectMode = true
                            }
                        )

                        toyCard(
                            title: "区域实景建模",
                            subtitle: "扫描墙面、天面或地面，本机生成带纹理 USDZ",
                            icon: "square.dashed",
                            action: {
                                showingAreaMode = true
                            }
                        )
                    }
                    .padding(16)
                }
            }
            .navigationTitle("玩具箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: $showingObjectMode) {
                ObjectCaptureTextureScanView(mode: .object)
            }
            .fullScreenCover(isPresented: $showingAreaMode) {
                ObjectCaptureTextureScanView(mode: .area)
            }
        }
    }

    private func toyCard(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.85), Color.blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Button(action: action) {
                Label("打开", systemImage: icon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [Color.teal, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .background(Color(red: 0.08, green: 0.11, blue: 0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.teal.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
