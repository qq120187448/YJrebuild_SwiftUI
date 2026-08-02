import SwiftUI

struct ScanToast: View {
    let code: String
    let symbology: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(code.prefix(30) + (code.count > 30 ? "..." : ""))
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
            }

            Spacer()

            Text(formatSymbology(symbology))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.2))
                .clipShape(Capsule())
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func formatSymbology(_ raw: String) -> String {
        // Convert "VNBarcodeSymbologyEAN13" → "EAN-13"
        raw.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
    }
}

#Preview {
    VStack {
        Spacer()
        ScanToast(code: "4006381333931", symbology: "VNBarcodeSymbologyEAN13")
    }
}
