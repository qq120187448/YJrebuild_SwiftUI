import SwiftUI
import VisionKit
import AVFoundation
import AudioToolbox
import SwiftData

struct ProductScanFlowView: View {
    var captureContext: CaptureContext? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(APIService.self) private var apiService

    enum FlowPhase {
        case barcodeScan
        case photoCapture
        case review
    }

    @State private var phase: FlowPhase = .barcodeScan
    @State private var scannedBarcode: String?
    @State private var scannedSymbology: String?
    @State private var capturedPhotos: [(image: UIImage, filename: String)] = []

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .barcodeScan:
                    barcodeScanPhase
                case .photoCapture:
                    photoCapturePhase
                case .review:
                    reviewPhase
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cleanupAndDismiss()
                    }
                }
            }
        }
    }

    // MARK: - Phase 1: Barcode Scan

    private var barcodeScanPhase: some View {
        ZStack {
            if DataScannerViewController.isSupported {
                if DataScannerViewController.isAvailable {
                    SingleScanRepresentable(onScanned: handleBarcodeScan)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView {
                        Label("Camera Access Required", systemImage: "camera.fill")
                    } description: {
                        Text("Robo needs camera access to scan barcodes.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Scanner Not Available",
                    systemImage: "barcode.viewfinder",
                    description: Text("This device does not support barcode scanning.")
                )
            }

            // Overlay: scanned toast or skip button
            VStack {
                Spacer()

                if let code = scannedBarcode {
                    // Show scanned code briefly before auto-advancing
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(code)
                            .font(.subheadline.monospaced())
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 8)
                } else {
                    Button {
                        withAnimation { phase = .photoCapture }
                    } label: {
                        HStack(spacing: 8) {
                            Text("No barcode? Skip")
                            Image(systemName: "arrow.right")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Scan Barcode")
    }

    private func handleBarcodeScan(_ code: String, _ symbology: String) {
        // Single-scan: only accept first barcode
        guard scannedBarcode == nil else { return }

        scannedBarcode = code
        scannedSymbology = symbology

        // Haptic + sound
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        AudioServicesPlaySystemSound(1057)

        // Brief pause then advance to photos
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation { phase = .photoCapture }
        }
    }

    // MARK: - Phase 2: Photo Capture

    private var photoCapturePhase: some View {
        ProductPhotoCaptureView(
            capturedPhotos: $capturedPhotos,
            onDone: {
                if capturedPhotos.isEmpty {
                    // Stay in capture — user needs at least 1 photo
                } else {
                    withAnimation { phase = .review }
                }
            }
        )
    }

    // MARK: - Phase 3: Review

    private var reviewPhase: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Barcode section
                    if let code = scannedBarcode {
                        HStack(spacing: 12) {
                            Image(systemName: "barcode.viewfinder")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Barcode")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(code)
                                    .font(.subheadline.monospaced())
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "barcode.viewfinder")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No barcode scanned")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Photo grid
                    Text("\(capturedPhotos.count) photo\(capturedPhotos.count == 1 ? "" : "s")")
                        .font(.headline)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ], spacing: 8) {
                        ForEach(Array(capturedPhotos.enumerated()), id: \.offset) { _, photo in
                            Image(uiImage: photo.image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }

            // Bottom actions
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button {
                        withAnimation { phase = .photoCapture }
                    } label: {
                        Text("Retake")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        saveAndDismiss()
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
        .navigationTitle("Review Product")
    }

    // MARK: - Save & Dismiss

    private func saveAndDismiss() {
        let filenames = capturedPhotos.map(\.filename)
        let record = ProductCaptureRecord(
            barcodeValue: scannedBarcode,
            symbology: scannedSymbology,
            photoFileNames: filenames,
            agentId: captureContext?.agentId,
            agentName: captureContext?.agentName,
            requestId: captureContext?.requestId.uuidString
        )
        modelContext.insert(record)
        try? modelContext.save()

        // Fire-and-forget nutrition lookup if barcode was scanned
        if let upc = scannedBarcode {
            let capturedApiService = apiService
            let capturedContext = modelContext
            Task {
                await NutritionService.lookupForProduct(
                    upc: upc, record: record,
                    apiService: capturedApiService, modelContext: capturedContext
                )
            }
        }

        dismiss()
    }

    /// Delete any persisted photos on cancel (no orphaned files).
    private func cleanupAndDismiss() {
        if !capturedPhotos.isEmpty {
            PhotoStorageService.delete(capturedPhotos.map(\.filename))
        }
        dismiss()
    }
}

// MARK: - Single-Scan DataScanner (stops after first detection)

private struct SingleScanRepresentable: UIViewControllerRepresentable {
    let onScanned: (String, String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScanned: (String, String) -> Void
        private var hasScanned = false

        init(onScanned: @escaping (String, String) -> Void) {
            self.onScanned = onScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !hasScanned, let first = addedItems.first else { return }
            guard case .barcode(let barcode) = first,
                  let code = barcode.payloadStringValue else { return }
            hasScanned = true
            dataScanner.stopScanning()
            let symbology = barcode.observation.symbology.rawValue
            onScanned(code, symbology)
        }
    }
}

// MARK: - Product Photo Capture View (phase 2 of flow)

private struct ProductPhotoCaptureView: View {
    @Binding var capturedPhotos: [(image: UIImage, filename: String)]
    let onDone: () -> Void

    @State private var showingCapture = false

    var body: some View {
        VStack(spacing: 0) {
            if showingCapture {
                ProductCameraView(onPhotoCaptured: handlePhotoCaptured, capturedPhotos: capturedPhotos)
                    .ignoresSafeArea()

                // Bottom bar with counter and done
                VStack(spacing: 8) {
                    if !capturedPhotos.isEmpty {
                        // Thumbnail strip
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(capturedPhotos.enumerated()), id: \.offset) { _, photo in
                                    Image(uiImage: photo.image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 50, height: 50)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .padding(.horizontal)
                        }
                        .frame(height: 56)
                    }

                    Text(counterText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(capturedPhotos.isEmpty)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .background(.ultraThinMaterial)
            } else {
                // Instructions screen
                instructionsView
            }
        }
        .navigationTitle("Take Photos")
    }

    private var counterText: String {
        if capturedPhotos.isEmpty {
            return "Take 1–3 photos"
        }
        return "\(capturedPhotos.count) photo\(capturedPhotos.count == 1 ? "" : "s") captured"
    }

    private var instructionsView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Product Photos")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 16) {
                tipRow(icon: "1.circle.fill", text: "Front of package")
                tipRow(icon: "2.circle.fill", text: "Nutrition label")
                tipRow(icon: "3.circle", text: "Ingredients list (optional)")
            }
            .padding(.horizontal, 32)

            Text("1–3 photos recommended")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                showingCapture = true
            } label: {
                Text("Start Capturing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
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
                .foregroundStyle(.orange)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }

    private func handlePhotoCaptured(_ image: UIImage) {
        // Save to disk immediately
        guard let filename = PhotoStorageService.save(image) else { return }
        capturedPhotos.append((image: image, filename: filename))

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        AudioServicesPlaySystemSound(1057)
    }
}

// MARK: - Product Camera (AVCaptureSession wrapper for photo capture)

private struct ProductCameraView: UIViewControllerRepresentable {
    let onPhotoCaptured: (UIImage) -> Void
    let capturedPhotos: [(image: UIImage, filename: String)]

    func makeUIViewController(context: Context) -> ProductCameraController {
        let controller = ProductCameraController()
        controller.onPhotoCaptured = onPhotoCaptured
        return controller
    }

    func updateUIViewController(_ controller: ProductCameraController, context: Context) {
        controller.onPhotoCaptured = onPhotoCaptured
    }
}

private class ProductCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let shutterButton = UIButton(type: .system)

    var onPhotoCaptured: ((UIImage) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        checkPermissionAndSetup()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func checkPermissionAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
            setupShutterButton()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                        self?.setupShutterButton()
                    } else {
                        self?.showPermissionDenied()
                    }
                }
            }
        default:
            showPermissionDenied()
        }
    }

    private func setupCamera() {
        captureSession.sessionPreset = .photo
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        if captureSession.canAddOutput(photoOutput) { captureSession.addOutput(photoOutput) }

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        Task.detached { [captureSession] in
            captureSession.startRunning()
        }
    }

    private func setupShutterButton() {
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .light)
        shutterButton.setImage(UIImage(systemName: "circle.inset.filled", withConfiguration: config), for: .normal)
        shutterButton.tintColor = .white
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        view.addSubview(shutterButton)

        NSLayoutConstraint.activate([
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -100)
        ])
    }

    private func showPermissionDenied() {
        let label = UILabel()
        label.text = "Camera access denied.\nOpen Settings to enable."
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40)
        ])
    }

    @objc private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }

        // Compress to JPEG 0.8
        guard let jpegData = image.jpegData(compressionQuality: 0.8),
              let compressed = UIImage(data: jpegData) else {
            DispatchQueue.main.async { [weak self] in
                self?.onPhotoCaptured?(image)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onPhotoCaptured?(compressed)
        }
    }
}
