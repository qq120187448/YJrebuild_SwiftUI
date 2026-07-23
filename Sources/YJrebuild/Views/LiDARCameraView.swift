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
                    Button(action: {
                        if engine.isScanning && engine.meshVertexCount > 0 { showExitAlert = true }
                        else { engine.stopScanning(); dismiss() }
                    }) {
                        Circle().fill(Color(hex: "E74C3C")).frame(width: 36)
                            .overlay(Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(engine.isScanning ? "SCANNING" : "READY").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text(timeString).font(.system(size: 28, weight: .medium, design: .monospaced)).foregroundColor(.white)
                    }
                    Spacer()
                    Circle().fill(Color.white.opacity(0.15)).frame(width: 36).overlay(Image(systemName: "flashlight.off.fill").foregroundColor(.white))
                }.padding(.horizontal, 20).padding(.top, 56)
                HStack(spacing: 24) {
                    StatBadge(icon: "cube", label: "VERTS", value: engine.meshVertexCount)
                }.padding(.top, 4)
                Spacer()
                VStack(spacing: 16) {
                    Text(engine.isScanning ? "MOVE PHONE SLOWLY" : "TAP TO START").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                    Button(action: toggleScan) {
                        Circle().fill(Color(hex: "E74C3C")).frame(width: 68).overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 4).padding(4))
                    }
                    Text("iPhone 12 Pro+ LiDAR").font(.system(size: 10)).foregroundColor(.white.opacity(0.3))
                }.padding(.bottom, 40).background(LinearGradient(colors: [.black.opacity(0.95), .clear], startPoint: .bottom, endPoint: .top))
            }
            if let err = engine.errorMessage {
                VStack { Spacer(); Text(err).font(.system(size: 13)).foregroundColor(.white).padding(12).background(Color.red.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.bottom, 100) }
            }
        }
        .alert("EXIT SCAN?", isPresented: $showExitAlert) {
            Button("CONTINUE", role: .cancel) {}
            Button("EXIT", role: .destructive) { engine.stopScanning(); dismiss() }
        } message: { Text("\(engine.meshVertexCount) vertices captured. Exit will lose data.") }
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

struct StatBadge: View {
    let icon: String; let label: String; let value: Int
    var body: some View {
        HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 10)); Text("\(label): \(formattedValue)").font(.system(size: 10)) }
            .foregroundColor(.white.opacity(0.7)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.08)).clipShape(Capsule())
    }
    private var formattedValue: String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value)/1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value)/1_000) }
        return "\(value)"
    }
}
