import SwiftUI
import RealityKit

struct LiDARCameraView: View {
    @StateObject private var engine = LiDAREngine()
    @Environment(\.dismiss) private var dismiss
    @State private var showExitAlert = false
    @State private var totalSeconds: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            LiDARARViewContainer(arView: engine.arView).ignoresSafeArea()
            VStack {
                HStack {
                    Button(action: { engine.stopScanning(); dismiss() }) {
                        Circle().fill(Color(hex: "E74C3C")).frame(width: 36)
                            .overlay(Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(engine.isScanning ? "SCANNING" : "READY")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text(timeString).font(.system(size: 28, weight: .medium, design: .monospaced)).foregroundColor(.white)
                    }
                    Spacer()
                    Circle().fill(Color.white.opacity(0.15)).frame(width: 36)
                }.padding(.horizontal, 20).padding(.top, 56)
                Spacer()
                Button(action: toggleScan) {
                    Circle().fill(Color(hex: "E74C3C")).frame(width: 68)
                }
                Text("iPhone 12 Pro+ LiDAR").font(.system(size: 10)).foregroundColor(.white.opacity(0.3)).padding(.bottom, 40).padding(.top, 16)
            }
        }
        .alert("EXIT SCAN", isPresented: $showExitAlert) {
            Button("CONTINUE", role: .cancel) {}
            Button("EXIT", role: .destructive) { engine.stopScanning(); dismiss() }
        } message: { Text("Exit will lose scan data.") }
        .onAppear { engine.startScanning(); startTimer() }
        .onDisappear { engine.stopScanning(); stopTimer() }
        .statusBarHidden()
    }

    private func toggleScan() { engine.isScanning ? (engine.stopScanning(), stopTimer()) : (engine.startScanning(), startTimer()) }
    private func startTimer() { totalSeconds = 0; timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in DispatchQueue.main.async { totalSeconds += 1 } } }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private var timeString: String { String(format: "%02d:%02d", Int(totalSeconds)/60, Int(totalSeconds)%60) }
}

struct LiDARARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
