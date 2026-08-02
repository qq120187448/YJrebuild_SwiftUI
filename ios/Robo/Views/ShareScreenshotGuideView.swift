import SwiftUI

struct ShareScreenshotGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingAlert = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 56))
                .foregroundStyle(.cyan)

            Text("Screenshot to AI")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 16) {
                tipRow(number: "1.circle.fill", icon: "camera.viewfinder", text: "Take a screenshot — press Side + Volume Up")
                tipRow(number: "2.circle.fill", icon: "square.and.arrow.up", text: "Tap the preview, then tap Share → Robo")
                tipRow(number: "3.circle.fill", icon: "sparkles", text: "Claude Code sees it via get_screenshot MCP tool")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                showingAlert = true
            } label: {
                Text("Try It Now")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.cyan)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .alert("Ready?", isPresented: $showingAlert) {
            Button("Got It") { dismiss() }
        } message: {
            Text("Take a screenshot now, then tap Share → Robo")
        }
        .navigationTitle("Screenshot to AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tipRow(number: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: number)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 28)
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    NavigationStack {
        ShareScreenshotGuideView()
    }
}
