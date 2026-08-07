import SwiftUI

struct WallDefectPhotoCaptureView: View {
    let surface: WallDefectSurface
    let onPhoto: (DefectCameraCapture) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraModel = DefectCameraModel()
    @State private var photoCount = 0
    @State private var showHint = true

    var body: some View {
        NavigationStack {
            ZStack {
                ARKitDefectCameraView(model: cameraModel)
                    .ignoresSafeArea()

                VStack {
                    topBar
                    Spacer()

                    if showHint {
                        hintBar
                    }

                    captureButton
                }
            }
            .navigationTitle(surface.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert(
                "拍摄失败",
                isPresented: Binding(
                    get: { cameraModel.lastError != nil },
                    set: { if !$0 { cameraModel.lastError = nil } }
                )
            ) {
                Button("好") {
                    cameraModel.lastError = nil
                }
            } message: {
                Text(cameraModel.lastError ?? "")
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Label(surface.label, systemImage: surface.kind == .wall ? "square.split.2x1" : "rectangle.split.2x1")
                .font(.subheadline.bold())
                .foregroundStyle(.white)

            Spacer()

            Text("已拍 \(photoCount) 张")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.5))
    }

    private var hintBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("把缺陷放在画面中央，靠近后对焦")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Text("发丝裂缝建议拉近到 20-40cm 特写，保持画面稳定")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
    }

    private var captureButton: some View {
        Button {
            guard let capture = cameraModel.capture() else { return }
            photoCount += 1
            showHint = false
            onPhoto(capture)
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(.white)
                    .frame(width: 56, height: 56)
            }
        }
        .padding(.bottom, 28)
    }
}
