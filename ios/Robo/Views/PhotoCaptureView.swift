import SwiftUI
import AVFoundation
import AudioToolbox

struct PhotoCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var captureContext: CaptureContext? = nil
    let agentName: String
    let checklist: [PhotoTask]
    @Binding var photoCapturedCount: Int
    @Binding var capturedFilenames: [String]

    @State private var phase: CapturePhase = .instructions
    @State private var capturedPhotos: [CapturedPhoto] = []
    @State private var checklistState: [PhotoTask]
    @State private var currentChecklistIndex = 0

    private enum CapturePhase {
        case instructions
        case capturing
        case review
    }

    struct CapturedPhoto: Identifiable {
        let id = UUID()
        let image: UIImage
        let label: String?
        let capturedAt: Date
    }

    init(captureContext: CaptureContext? = nil, agentName: String, checklist: [PhotoTask], photoCapturedCount: Binding<Int> = .constant(0), capturedFilenames: Binding<[String]> = .constant([])) {
        self.captureContext = captureContext
        self.agentName = agentName
        self.checklist = checklist
        self._photoCapturedCount = photoCapturedCount
        self._capturedFilenames = capturedFilenames
        self._checklistState = State(initialValue: checklist)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .instructions:
                    instructionsView
                case .capturing:
                    captureView
                case .review:
                    reviewView
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .capturing ? "Done" : "Cancel") {
                        if phase == .capturing && !capturedPhotos.isEmpty {
                            phase = .review
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .instructions: return "Photo Task"
        case .capturing: return currentLabel ?? "Capture Photos"
        case .review: return "Review Photos"
        }
    }

    private var currentLabel: String? {
        guard !checklistState.isEmpty, currentChecklistIndex < checklistState.count else { return nil }
        return checklistState[currentChecklistIndex].label
    }

    private var hasChecklist: Bool {
        !checklist.isEmpty
    }

    // MARK: - Instructions

    private var instructionsView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Photos for \(agentName)")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            if hasChecklist {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Photos needed:")
                        .font(.headline)
                    ForEach(checklist) { task in
                        HStack(spacing: 10) {
                            Image(systemName: "circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(task.label)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    tipRow(icon: "camera.fill", text: "Capture multiple photos without leaving the camera")
                    tipRow(icon: "hand.tap", text: "Tap the shutter button for each photo")
                    tipRow(icon: "checkmark.circle", text: "Tap Done when you've captured everything")
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                phase = .capturing
            } label: {
                Text("Start Capturing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Capture

    private var captureView: some View {
        CameraSessionView(
            currentLabel: currentLabel,
            photoCount: capturedPhotos.count,
            totalExpected: hasChecklist ? checklist.count : nil,
            capturedPhotos: capturedPhotos,
            onPhotoCaptured: handlePhotoCaptured
        )
        .ignoresSafeArea()
    }

    private func handlePhotoCaptured(_ image: UIImage) {
        let label = currentLabel
        let photo = CapturedPhoto(image: image, label: label, capturedAt: Date())
        capturedPhotos.append(photo)
        photoCapturedCount = capturedPhotos.count

        // Persist to disk so filenames are available for upload tools
        if let filename = PhotoStorageService.save(image) {
            capturedFilenames.append(filename)
        }

        // Haptic
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        AudioServicesPlaySystemSound(1057)

        // Advance checklist
        if hasChecklist && currentChecklistIndex < checklistState.count {
            checklistState[currentChecklistIndex].isCompleted = true
            currentChecklistIndex += 1

            // Auto-transition to review when checklist complete
            if currentChecklistIndex >= checklistState.count {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    phase = .review
                }
            }
        }
    }

    // MARK: - Persistence

    private func persistCompletion() {
        guard let ctx = captureContext, !capturedPhotos.isEmpty else { return }
        let record = AgentCompletionRecord(
            agentId: ctx.agentId,
            agentName: ctx.agentName,
            requestId: ctx.requestId.uuidString,
            skillType: "camera",
            itemCount: capturedPhotos.count
        )
        modelContext.insert(record)
        try? modelContext.save()
    }

    // MARK: - Review

    private var reviewView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(capturedPhotos) { photo in
                        VStack(spacing: 4) {
                            Image(uiImage: photo.image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            if let label = photo.label {
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }

            VStack(spacing: 12) {
                Text("\(capturedPhotos.count) photo\(capturedPhotos.count == 1 ? "" : "s") captured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Button {
                        phase = .capturing
                    } label: {
                        Text("Take More")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        persistCompletion()
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Camera Session View (AVCaptureSession-based)

private struct CameraSessionView: UIViewControllerRepresentable {
    let currentLabel: String?
    let photoCount: Int
    let totalExpected: Int?
    let capturedPhotos: [PhotoCaptureView.CapturedPhoto]
    let onPhotoCaptured: (UIImage) -> Void

    func makeUIViewController(context: Context) -> CameraSessionController {
        let controller = CameraSessionController()
        controller.onPhotoCaptured = onPhotoCaptured
        return controller
    }

    func updateUIViewController(_ controller: CameraSessionController, context: Context) {
        controller.updateOverlay(
            label: currentLabel,
            count: photoCount,
            total: totalExpected,
            thumbnails: capturedPhotos.map { $0.image }
        )
        controller.onPhotoCaptured = onPhotoCaptured
    }
}

class CameraSessionController: UIViewController, AVCapturePhotoCaptureDelegate {
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private let shutterButton = UIButton(type: .system)
    private let counterLabel = UILabel()
    private let currentLabelView = UILabel()
    private let thumbnailStack = UIStackView()
    private let thumbnailScroll = UIScrollView()

    var onPhotoCaptured: ((UIImage) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        checkCameraPermission()
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
            setupUI()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                        self?.setupUI()
                    } else {
                        self?.showPermissionDenied()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDenied()
        @unknown default:
            showPermissionDenied()
        }
    }

    private func showPermissionDenied() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let icon = UIImageView(image: UIImage(systemName: "camera.fill"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let title = UILabel()
        title.text = "Camera Access Required"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Robo needs camera access to capture photos for your agent."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let button = UIButton(type: .system)
        button.setTitle("Open Settings", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(openSettings), for: .touchUpInside)

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.addArrangedSubview(button)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40)
        ])
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCamera() {
        captureSession.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        Task.detached { [captureSession] in
            captureSession.startRunning()
        }
    }

    private func setupUI() {
        // Current label overlay (top)
        currentLabelView.textColor = .white
        currentLabelView.font = .systemFont(ofSize: 18, weight: .semibold)
        currentLabelView.textAlignment = .center
        currentLabelView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        currentLabelView.layer.cornerRadius = 8
        currentLabelView.clipsToBounds = true
        currentLabelView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(currentLabelView)

        // Counter label
        counterLabel.textColor = .white
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(counterLabel)

        // Thumbnail scroll area
        thumbnailScroll.showsHorizontalScrollIndicator = false
        thumbnailScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailScroll)

        thumbnailStack.axis = .horizontal
        thumbnailStack.spacing = 6
        thumbnailStack.translatesAutoresizingMaskIntoConstraints = false
        thumbnailScroll.addSubview(thumbnailStack)

        // Shutter button
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .light)
        shutterButton.setImage(UIImage(systemName: "circle.inset.filled", withConfiguration: config), for: .normal)
        shutterButton.tintColor = .white
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        view.addSubview(shutterButton)

        NSLayoutConstraint.activate([
            currentLabelView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            currentLabelView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            currentLabelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            currentLabelView.heightAnchor.constraint(equalToConstant: 36),

            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),

            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            counterLabel.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -16),

            thumbnailScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            thumbnailScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            thumbnailScroll.bottomAnchor.constraint(equalTo: counterLabel.topAnchor, constant: -12),
            thumbnailScroll.heightAnchor.constraint(equalToConstant: 56),

            thumbnailStack.topAnchor.constraint(equalTo: thumbnailScroll.topAnchor),
            thumbnailStack.leadingAnchor.constraint(equalTo: thumbnailScroll.leadingAnchor),
            thumbnailStack.trailingAnchor.constraint(equalTo: thumbnailScroll.trailingAnchor),
            thumbnailStack.bottomAnchor.constraint(equalTo: thumbnailScroll.bottomAnchor),
            thumbnailStack.heightAnchor.constraint(equalTo: thumbnailScroll.heightAnchor)
        ])
    }

    func updateOverlay(label: String?, count: Int, total: Int?, thumbnails: [UIImage]) {
        if let label {
            currentLabelView.text = "  \(label)  "
            currentLabelView.isHidden = false
        } else {
            currentLabelView.isHidden = true
        }

        if let total {
            counterLabel.text = "\(count) of \(total) photos"
        } else if count > 0 {
            counterLabel.text = "\(count) photo\(count == 1 ? "" : "s")"
        } else {
            counterLabel.text = nil
        }

        // Update thumbnails
        thumbnailStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for thumb in thumbnails.suffix(10) {
            let imageView = UIImageView(image: thumb)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 6
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 50).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 50).isActive = true
            thumbnailStack.addArrangedSubview(imageView)
        }

        // Scroll to end
        if !thumbnails.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let offset = CGPoint(x: max(0, self.thumbnailScroll.contentSize.width - self.thumbnailScroll.bounds.width), y: 0)
                self.thumbnailScroll.setContentOffset(offset, animated: true)
            }
        }
    }

    @objc private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }

        // Compress to JPEG 0.8
        guard let jpegData = image.jpegData(compressionQuality: 0.8),
              let compressed = UIImage(data: jpegData) else {
            onPhotoCaptured?(image)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onPhotoCaptured?(compressed)
        }
    }
}
