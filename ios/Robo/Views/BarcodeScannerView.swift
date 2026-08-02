import SwiftUI
import VisionKit
import AudioToolbox
import SwiftData

struct BarcodeScannerView: View {
    var captureContext: CaptureContext? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(APIService.self) private var apiService
    @AppStorage("scanQuality") private var scanQuality: String = "balanced"

    @State private var lastScannedCode: String?
    @State private var lastScanTime: Date = .distantPast
    @State private var currentToast: ToastItem?
    @State private var error: String?

    private struct ToastItem: Identifiable {
        let id = UUID()
        let code: String
        let symbology: String
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if DataScannerViewController.isSupported {
                    if DataScannerViewController.isAvailable {
                        DataScannerRepresentable(
                            recognizedDataTypes: [.barcode()],
                            qualityLevel: scanQuality == "fast" ? .fast : .balanced,
                            onScan: handleScan
                        )
                        .ignoresSafeArea()
                    } else {
                        ContentUnavailableView {
                            Label("Camera Access Required", systemImage: "camera.fill")
                        } description: {
                            Text("Robo needs camera access to scan barcodes. Open Settings to enable it.")
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
                        description: Text("This device does not support barcode scanning")
                    )
                }

                // Toast overlay
                VStack {
                    Spacer()
                    if let toast = currentToast {
                        ScanToast(code: toast.code, symbology: toast.symbology)
                            .padding(.bottom, 20)
                    }
                }
                .animation(.spring(duration: 0.3), value: currentToast?.id)
            }
            .navigationTitle("Barcode Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") {
                    error = nil
                }
            } message: {
                if let error {
                    Text(error)
                }
            }
        }
    }

    private func handleScan(_ result: RecognizedItem) {
        guard case .barcode(let barcode) = result,
              let code = barcode.payloadStringValue else { return }

        // 3-second deduplication for same barcode
        let now = Date()
        if code == lastScannedCode && now.timeIntervalSince(lastScanTime) < 3 {
            return
        }

        lastScannedCode = code
        lastScanTime = now

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // System sound
        AudioServicesPlaySystemSound(1057)

        let symbology = barcode.observation.symbology.rawValue

        // Save to SwiftData (explicit save — autosave is unreliable during dismiss)
        let record = ScanRecord(barcodeValue: code, symbology: symbology)
        record.agentId = captureContext?.agentId
        record.agentName = captureContext?.agentName
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            self.error = "Failed to save scan: \(error.localizedDescription)"
        }

        // Fire-and-forget nutrition lookup
        let capturedApiService = apiService
        let capturedContext = modelContext
        Task {
            await NutritionService.lookup(
                upc: code, record: record,
                apiService: capturedApiService, modelContext: capturedContext
            )
        }

        #if DEBUG
        DebugSyncService.syncBarcode(value: code, symbology: symbology)
        #endif

        // Show toast (replaces previous)
        currentToast = ToastItem(code: code, symbology: symbology)

        // Auto-dismiss toast after 2 seconds
        let toastId = currentToast?.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if currentToast?.id == toastId {
                currentToast = nil
            }
        }
    }
}

// MARK: - DataScannerViewController Wrapper

struct DataScannerRepresentable: UIViewControllerRepresentable {
    let recognizedDataTypes: Set<DataScannerViewController.RecognizedDataType>
    let qualityLevel: DataScannerViewController.QualityLevel
    let onScan: (RecognizedItem) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: recognizedDataTypes,
            qualityLevel: qualityLevel,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // Restart scanning if needed (e.g., after backgrounding)
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (RecognizedItem) -> Void

        init(onScan: @escaping (RecognizedItem) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            onScan(item)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            if let first = addedItems.first {
                onScan(first)
            }
        }
    }
}

#Preview {
    BarcodeScannerView()
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
