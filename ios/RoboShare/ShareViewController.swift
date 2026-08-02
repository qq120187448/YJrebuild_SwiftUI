import UIKit
import UniformTypeIdentifiers
import ImageIO

class ShareViewController: UIViewController {

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Sending to Robo..."
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.startAnimating()
        return s
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        view.addSubview(spinner)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        processShareInput()
    }

    private func processShareInput() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            finish(error: "No image found")
            return
        }

        let imageType = UTType.image.identifier
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(imageType) }) else {
            finish(error: "Only images are supported")
            return
        }

        provider.loadItem(forTypeIdentifier: imageType, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                self.finish(error: error.localizedDescription)
                return
            }

            let jpegData: Data?

            if let url = item as? URL {
                // Memory-efficient path: downsample directly from file URL
                jpegData = self.downsample(imageAt: url)
            } else if let data = item as? Data {
                jpegData = self.downsampleFromData(data)
            } else if let image = item as? UIImage {
                // Fallback: already in memory, just resize and compress
                jpegData = self.downsampleUIImage(image)
            } else {
                self.finish(error: "Could not load image")
                return
            }

            guard let jpegData, jpegData.count <= 1_000_000 else {
                self.finish(error: jpegData == nil ? "Could not process image" : "Image too large")
                return
            }

            self.uploadImage(jpegData)
        }
    }

    // MARK: - Memory-Efficient Image Downsampling

    /// Downsample directly from file URL — never loads full image into memory.
    /// This is critical for staying under the 120MB extension memory limit.
    private func downsample(imageAt url: URL, maxDimension: CGFloat = 1536) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7)
    }

    /// Downsample from in-memory Data via CGImageSource.
    private func downsampleFromData(_ data: Data, maxDimension: CGFloat = 1536) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7)
    }

    /// Fallback for when we already have a UIImage in memory.
    private func downsampleUIImage(_ image: UIImage, maxDimension: CGFloat = 1536) -> Data? {
        guard let pngData = image.pngData() else {
            return image.jpegData(compressionQuality: 0.7)
        }
        return downsampleFromData(pngData, maxDimension: maxDimension)
    }

    // MARK: - Upload

    private func uploadImage(_ jpegData: Data) {
        guard let config = SharedKeychainHelper.load(), config.id != "unregistered" else {
            finish(error: "Open Robo to set up first")
            return
        }

        let urlString = "\(config.apiBaseURL)/api/screenshots"
        guard let url = URL(string: urlString) else {
            finish(error: "Invalid API URL")
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(config.id, forHTTPHeaderField: "X-Device-ID")
        if let token = config.mcpToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"screenshot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error {
                self?.finish(error: error.localizedDescription)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...201).contains(status) {
                self?.finish(error: nil)
            } else {
                self?.finish(error: "Upload failed (\(status))")
            }
        }.resume()
    }

    // MARK: - Completion

    private func finish(error: String?) {
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            if let error {
                self.statusLabel.text = error
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.extensionContext?.cancelRequest(
                        withError: NSError(domain: "com.silv.RoboShare", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: error]))
                }
            } else {
                self.statusLabel.text = "Sent to Robo \u{2713}"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            }
        }
    }
}
