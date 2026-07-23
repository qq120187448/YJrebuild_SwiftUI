import SwiftUI
import RealityKit

/// LiDAR ??????? - ?? ARKit + mesh ???
/// ?? iPhone 12 Pro ??? (390x844 points, iOS 17.0+)
struct LiDARCameraView: View {
    @StateObject private var engine = LiDAREngine()
    @Environment(\.dismiss) private var dismiss
    @State private var showExitAlert = false
    @State private var scanTimer: String = "00:00"
    @State private var timerRunning = false
    @State private var timerCancellable: Timer?

    var body: some View {
        ZStack {
            // LiDAR AR View - ??
            LiDARARViewContainer(arView: engine.arView)
                .ignoresSafeArea()

            // ???????
            VStack {
                // ?????
                scanningStatusBar
                Spacer()
                // ?????
                controlPanel
            }
        }
        .alert("??????", isPresented: $showExitAlert) {
            Button("????", role: .cancel) {}
            Button("??", role: .destructive) {
                engine.stopScanning()
                dismiss()
            }
        } message: {
            Text("????? \(engine.meshVertexCount) ????????????")
        }
        .onAppear {
            engine.startScanning()
            startTimer()
        }
        .onDisappear {
            engine.stopScanning()
            stopTimer()
        }
        .statusBarHidden()
    }

    // MARK: - ?????
    private var scanningStatusBar: some View {
        VStack(spacing: 4) {
            HStack {
                // ????
                Button(action: {
                    if engine.isScanning && engine.meshVertexCount > 0 {
                        showExitAlert = true
                    } else {
                        engine.stopScanning()
                        dismiss()
                    }
                }) {
                    Circle()
                        .fill(Color(hex: "E74C3C"))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        )
                }

                Spacer()

                // ???????
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .opacity(engine.isScanning ? 1 : 0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: engine.isScanning)
                        Text(engine.isScanning ? "???" : "??")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Text(timerDisplay)
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer()

                // ???
                Button(action: {}) {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "flashlight.off.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)

            // ?????
            if engine.isScanning {
                ProgressView(value: engine.scanProgress)
                    .tint(Color(hex: "E74C3C"))
                    .scaleEffect(x: 1, y: 2, anchor: .center)
                    .padding(.horizontal, 20)
            }

            // ????
            HStack(spacing: 24) {
                StatBadge(icon: "cube", label: "??", value: engine.meshVertexCount)
                StatBadge(icon: "square.grid.3x3", label: "??", value: Int(engine.scannedAreaEstimate * 100))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - ??????
    private var controlPanel: some View {
        VStack(spacing: 16) {
            // ????
            HStack(spacing: 0) {
                ForEach(["??", "??", "??"], id: \.self) { mode in
                    Button(mode) {}
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(mode == "??" ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(mode == "??" ? Color.white : Color.clear)
                        .clipShape(Capsule())
                }
            }
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())

            // ????
            Text(engine.isScanning ? "????????????" : "????????")
                .font(.system(size: 12))
                .foregroundColor(engine.isScanning ? Color.white.opacity(0.7) : Color.white.opacity(0.4))

            // ????
            Button(action: {
                if engine.isScanning {
                    engine.stopScanning()
                    stopTimer()
                } else {
                    engine.startScanning()
                    startTimer()
                }
            }) {
                Circle()
                    .fill(Color(hex: "E74C3C"))
                    .frame(width: 68, height: 68)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.6), lineWidth: 4)
                            .padding(4)
                    )
                    .shadow(color: Color(hex: "E74C3C").opacity(engine.isScanning ? 0.5 : 0),
                            radius: engine.isScanning ? 20 : 0)
                    .scaleEffect(engine.isScanning ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: engine.isScanning)
            }

            // ????
            Text("iPhone 12 Pro+ ? LiDAR ????")
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.3))
        }
        .padding(.bottom, 40)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.95), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }

    // MARK: - ???
    private var timerDisplay: String {
        let minutes = Int(totalScanSeconds) / 60
        let seconds = Int(totalScanSeconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @State private var totalScanSeconds: TimeInterval = 0

    private func startTimer() {
        timerRunning = true
        timerCancellable = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if timerRunning {
                DispatchQueue.main.async { totalScanSeconds += 1 }
            }
        }
    }

    private func stopTimer() {
        timerRunning = false
        timerCancellable?.invalidate()
        timerCancellable = nil
    }
}

// MARK: - ARView SwiftUI ??
struct LiDARARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - ????
struct StatBadge: View {
    let icon: String
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text("\(label): \(formattedValue)")
                .font(.system(size: 10))
        }
        .foregroundColor(Color.white.opacity(0.7))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    private var formattedValue: String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
