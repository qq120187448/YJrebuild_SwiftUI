import SwiftUI
import RealityKit
import AVFoundation

struct LiDARCameraView: View {
    @StateObject private var engine = LiDAREngine()
    @StateObject private var camera = CameraManager()
    @Environment(\.dismiss) private var dismiss
    @State private var showExitAlert = false
    @State private var totalSeconds: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            // Real camera preview behind AR
            CameraPreviewView(session: camera.session).ignoresSafeArea()
            LiDARARViewContainer(arView: engine.arView).ignoresSafeArea().opacity(0.5)

            VStack {
                HStack {
                    Button(action: {
                        if engine.isScanning && engine.meshVertexCount > 0 { showExitAlert = true }
                        else { stopAll(); dismiss() }
                    }) {
                        Circle().fill(Color(hex: "E74C3C")).frame(width: 36)
                            .overlay(Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(engine.isScanning ? Color.green : Color.gray).frame(width: 8, height: 8)
                            Text(engine.isScanning ? "扫描中" : "就绪").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        }
                        Text(timeString).font(.system(size: 28, weight: .medium, design: .monospaced)).foregroundColor(.white)
                    }
                    Spacer()
                    Circle().fill(Color.white.opacity(0.15)).frame(width: 36)
                }.padding(.horizontal, 20).padding(.top, 56)

                HStack(spacing: 20) {
                    StatBadge(icon: "cube", label: "顶点", value: engine.meshVertexCount)
                    StatBadge(icon: "triangle", label: "面", value: engine.meshFaceCount)
                }.padding(.top, 4)

                if engine.isScanning {
                    ProgressView(value: engine.scanProgress).tint(Color(hex: "E74C3C")).padding(.horizontal, 40).padding(.top, 8)
                }

                Spacer()

                VStack(spacing: 16) {
                    Text(engine.isScanning ? "缓慢移动手机扫描周围环境" : "点击按钮开始扫描")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.6))

                    Button(action: toggleScan) {
                        Circle().fill(Color(hex: "E74C3C")).frame(width: 68)
                            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 4).padding(4))
                    }

                    Text("iPhone 12 Pro+ · LiDAR 增强扫描")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.3))
                }.padding(.bottom, 40)
                .background(LinearGradient(colors: [.black.opacity(0.9), .clear], startPoint: .bottom, endPoint: .top))
            }
        }
        .alert("确认退出扫描", isPresented: $showExitAlert) {
            Button("继续扫描", role: .cancel) {}
            Button("退出", role: .destructive) { stopAll(); dismiss() }
        } message: { Text("退出将丢失 \(engine.meshVertexCount) 个顶点的扫描数据") }
        .onAppear { engine.startScanning(); camera.start(); startTimer() }
        .onDisappear { stopAll() }
        .statusBarHidden()
    }

    private func toggleScan() {
        if engine.isScanning { engine.stopScanning(); stopTimer() }
        else { engine.startScanning(); startTimer() }
    }

    private func stopAll() { engine.stopScanning(); camera.stop(); stopTimer() }

    private func startTimer() {
        totalSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { totalSeconds += 1 }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private var timeString: String {
        String(format: "%02d:%02d", Int(totalSeconds)/60, Int(totalSeconds)%60)
    }
}

struct LiDARARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct StatBadge: View {
    let icon: String; let label: String; let value: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label + ": " + formattedValue).font(.system(size: 10))
        }.foregroundColor(.white.opacity(0.7)).padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(0.08)).clipShape(Capsule())
    }
    private var formattedValue: String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value)/1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value)/1_000) }
        return String(value)
    }
}
