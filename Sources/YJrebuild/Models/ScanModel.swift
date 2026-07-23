import Foundation
struct ScanModel: Identifiable {
    let id: String
    var likeCount: Int
    var viewCount: Int
    var createdAt: Date
    var isFavorite: Bool
    var formattedDate: String {
        let f = DateFormatter(); f.dateFormat = "yyyy_MM_dd_HH_mm_ss"; return f.string(from: createdAt)
    }
}
