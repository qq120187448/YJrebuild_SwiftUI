import SwiftUI
import ARKit

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }.tag(0)

            CameraPlaceholderView()
                .tabItem { Label("扫描", systemImage: "camera.fill") }.tag(1)

            MyScansView()
                .tabItem { Label("文件", systemImage: "folder.fill") }.tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(3)
        }
        .tint(Color(hex: "E74C3C"))
        .ignoresSafeArea()
    }
}

/// Safe camera view with LiDAR availability check
struct CameraPlaceholderView: View {
    @State private var showRealCamera = false
    @State private var lidarAvailable = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showRealCamera {
                LiDARCameraView()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.3))

                    Text("相机预览区域")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.5))

                    Text("LiDAR 扫描需要 iPhone 12 Pro 及以上机型")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.3))

                    Button("启动扫描") {
                        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                            showRealCamera = true
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(Color(hex: "E74C3C"))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 8)
                }
            }
        }
        .onAppear {
            lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }
}

