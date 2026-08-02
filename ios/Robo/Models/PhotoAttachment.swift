import UIKit

struct PhotoAttachment: Identifiable {
    let id = UUID()
    let label: String
    let image: UIImage
    let componentID: UUID?

    init(label: String, image: UIImage, componentID: UUID? = nil) {
        self.label = label
        self.image = image
        self.componentID = componentID
    }
}
