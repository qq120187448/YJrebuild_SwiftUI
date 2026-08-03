import UIKit

enum ImageResizer {
    /// Resizes an image so its longest edge is no larger than `maxDimension`.
    /// Aspect ratio is preserved; images already smaller are returned unchanged.
    static func resized(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let targetSize = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
