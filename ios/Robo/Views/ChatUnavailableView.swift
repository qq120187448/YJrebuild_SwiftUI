import SwiftUI

enum ChatUnavailableReason {
    case osNotSupported
    case hardwareNotSupported
    case appleIntelligenceDisabled
    case modelDownloading
    case unknown
}

struct ChatUnavailableView: View {
    let reason: ChatUnavailableReason

    var body: some View {
        NavigationStack {
            contentView
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch reason {
        case .osNotSupported:
            ContentUnavailableView {
                Label("Chat Requires iOS 26", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            } description: {
                Text("On-device AI chat needs iOS 26 or later. Update your iPhone to get started.")
            }

        case .hardwareNotSupported:
            ContentUnavailableView {
                Label("Device Not Supported", systemImage: "iphone.slash")
            } description: {
                Text("On-device AI chat requires iPhone 15 Pro or later with Apple Intelligence.")
            }

        case .appleIntelligenceDisabled:
            ContentUnavailableView {
                Label("Enable Apple Intelligence", systemImage: "apple.intelligence")
            } description: {
                Text("Turn on Apple Intelligence to use on-device chat.")
            } actions: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .buttonStyle(.borderedProminent)
                }
            }

        case .modelDownloading:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing AI Model...")
                    .font(.headline)
                Text("The on-device model is downloading. This usually takes a few minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

        case .unknown:
            ContentUnavailableView {
                Label("Chat Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            } description: {
                Text("On-device AI chat is not available on this device.")
            }
        }
    }
}
