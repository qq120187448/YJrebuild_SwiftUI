import SwiftUI
extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0; scanner.scanHexInt64(&rgb)
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
    static let accentRed = Color(hex: "E74C3C")
    static let textBlue = Color(hex: "007AFF")
    static let textSecondary = Color(hex: "8E8E93")
    static let textPrimary = Color(hex: "1C1C1E")
    static let navBarBg = Color(hex: "1C1C1E")
    static let tabActiveBg = Color(hex: "3A3A3C")
    static let tabInactiveBg = Color(hex: "1C1C1E")
    static let dividerGray = Color(hex: "E5E5EA")
    static let primaryGray = Color(hex: "F2F2F7")
    static let iconDark = Color(hex: "1C1C1E")
}
