import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case appleOnDevice = "apple"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter (Cloud)"
        case .appleOnDevice: return "Apple On-Device"
        }
    }
}
