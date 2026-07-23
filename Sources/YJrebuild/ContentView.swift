import SwiftUI
import ARKit

struct ContentView: View {
    @State private var selectedTab = 0
    @StateObject private var permissions = PermissionManager()
    @State private var showLaunch = true

    var body: some View {
        ZStack {
            if showLaunch {
                LaunchScreen(permissions: permissions, showLaunch: $showLaunch)
            } else {
                TabView(selection: $selectedTab) {
                    HomeView().tabItem { Label("首页", systemImage: "house.fill") }.tag(0)
                    CameraPlaceholderView(permissions: permissions)
                        .tabItem { Label("扫描", systemImage: "camera.fill") }.tag(1)
                    MyScansView().tabItem { Label("文件", systemImage: "folder.fill") }.tag(2)
                    SettingsView().tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(3)
                }
                .tint(Color(hex: "E74C3C"))
                .ignoresSafeArea()
            }
        }
    }
}

struct LaunchScreen: View {
    @ObservedObject var permissions: PermissionManager
    @Binding var showLaunch: Bool

    var body: some View {
        ZStack {
            Color(hex: "F2F2F7").ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64))
                    .foregroundColor(Color(hex: "E74C3C"))
                Text("优记扫描").font(.system(size: 28, weight: .bold))
                Text("3D LiDAR 扫描建模工具").font(.system(size: 15)).foregroundColor(.secondary)

                ProgressView().padding(.top, 8)

                Text("正在申请必要权限...").font(.system(size: 13)).foregroundColor(.secondary)
                Text("需要相机和相册权限进行 3D 扫描").font(.system(size: 11)).foregroundColor(.secondary)

                Spacer().frame(height: 20)

                if permissions.allGranted {
                    Button("进入应用") {
                        withAnimation { showLaunch = false }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 40).padding(.vertical, 14)
                    .background(Color(hex: "E74C3C")).clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .onAppear { permissions.requestAllPermissions() }
    }
}

struct CameraPlaceholderView: View {
    @ObservedObject var permissions: PermissionManager
    @State private var showRealCamera = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showRealCamera && permissions.cameraGranted {
                LiDARCameraView()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill").font(.system(size: 60)).foregroundColor(.white.opacity(0.3))
                    Text("相机预览区域").font(.system(size: 15)).foregroundColor(.white.opacity(0.5))
                    if !permissions.cameraGranted {
                        Text("请在系统设置中允许相机权限").font(.system(size: 12)).foregroundColor(.red.opacity(0.7))
                    } else {
                        Text("LiDAR 扫描需要 iPhone 12 Pro 及以上机型").font(.system(size: 12)).foregroundColor(.white.opacity(0.3))
                        Button("启动扫描") {
                            showRealCamera = true
                        }
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 40).padding(.vertical, 14)
                        .background(Color(hex: "E74C3C")).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.top, 8)
                    }
                }
            }
        }
    }
}
