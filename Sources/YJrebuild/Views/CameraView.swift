import SwiftUI
struct CameraView: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedMode = 1; @State private var isFlashOn = false; @State private var isRecording = false
    let modes = ["point_cloud", "model", "floor_plan"]
    var body: some View {
        ZStack {
            Color(hex: "1A1A1A").ignoresSafeArea()
            VStack { Image(systemName: "camera.fill").font(.system(size: 60)).foregroundColor(.white.opacity(0.15)); Text("camera preview").foregroundColor(.white.opacity(0.3)) }
            VStack {
                HStack { Button(action: { dismiss() }) { Circle().fill(Color(hex: "E74C3C")).frame(width: 40).overlay(Image(systemName: "xmark").foregroundColor(.white)) }; Spacer() }.padding(.top, 50)
                Spacer()
                VStack(spacing: 16) {
                    HStack { HStack(spacing: 4) { Image(systemName: "chevron.down"); Text("default") }.foregroundColor(.white); Spacer(); Button(action: { isFlashOn.toggle() }) { Circle().fill(isFlashOn ? Color(hex: "E74C3C").opacity(0.3) : Color.white.opacity(0.15)).frame(width: 40).overlay(Image(systemName: isFlashOn ? "flashlight.on.fill" : "flashlight.off.fill").foregroundColor(isFlashOn ? Color(hex: "E74C3C") : .white)) } }.padding(.horizontal, 16)
                    HStack(spacing: 20) {
                        HStack(spacing: 0) { ForEach(0..<modes.count, id:\.self) { i in Button(modes[i]) { selectedMode = i }.font(.system(size: 13, weight: .medium)).foregroundColor(selectedMode == i ? .black : .white).padding(.horizontal, 14).padding(.vertical, 4).background(selectedMode == i ? Color.white : Color.clear).clipShape(Capsule()) } }.background(Color.white.opacity(0.12)).clipShape(Capsule())
                        Button(action: { isRecording.toggle() }) { Circle().fill(Color(hex: "E74C3C")).frame(width: 64).overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 3)) }
                        Spacer().frame(width: 40)
                    }
                }.padding(.bottom, 40).background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .bottom, endPoint: .top))
            }
        }
    }
}
