import SwiftUI

struct ChatTabView: View {
    var body: some View {
        if #available(iOS 26, *) {
            FoundationModelsChatGate()
        } else {
            ChatUnavailableView(reason: .osNotSupported)
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
private struct FoundationModelsChatGate: View {
    @State private var availabilityCheckId = UUID()

    var body: some View {
        let model = SystemLanguageModel.default
        let _ = availabilityCheckId // force re-evaluation when ID changes
        switch model.availability {
        case .available:
            ChatView()
        case .unavailable(.deviceNotEligible):
            ChatUnavailableView(reason: .hardwareNotSupported)
        case .unavailable(.appleIntelligenceNotEnabled):
            ChatUnavailableView(reason: .appleIntelligenceDisabled)
        case .unavailable(.modelNotReady):
            ChatUnavailableView(reason: .modelDownloading)
                .task {
                    await pollForAvailability()
                }
        default:
            ChatUnavailableView(reason: .unknown)
        }
    }

    private func pollForAvailability() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                availabilityCheckId = UUID()
                return
            }
        }
    }
}
#endif
