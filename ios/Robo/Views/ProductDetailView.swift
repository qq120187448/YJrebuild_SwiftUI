import SwiftUI
import SwiftData

struct ProductDetailView: View {
    let product: ProductCaptureRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [UIImage] = []
    @State private var selectedPhotoIndex: Int?

    var body: some View {
        List {
            // Photo gallery
            Section {
                if photos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                                Image(uiImage: photo)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 200, height: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .onTapGesture {
                                        selectedPhotoIndex = index
                                    }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            } header: {
                Text("\(product.photoCount) Photo\(product.photoCount == 1 ? "" : "s")")
            }

            // Product info
            Section("Product") {
                if let name = product.foodName {
                    HStack {
                        Text("Name")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(name)
                    }
                }
                if let brand = product.brandName {
                    HStack {
                        Text("Brand")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(brand)
                    }
                }
                if let cal = product.calories {
                    HStack {
                        Text("Calories")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(cal))")
                    }
                }
            }

            // Barcode info
            Section("Barcode") {
                if let barcode = product.barcodeValue {
                    HStack {
                        Text("Value")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(barcode)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                    if let symbology = product.symbology {
                        HStack {
                            Text("Type")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(symbology.replacingOccurrences(of: "VNBarcodeSymbology", with: ""))
                        }
                    }
                } else {
                    Text("No barcode scanned")
                        .foregroundStyle(.secondary)
                }
            }

            // Metadata
            Section("Details") {
                HStack {
                    Text("Captured")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(product.capturedAt, style: .date)
                    Text(product.capturedAt, style: .time)
                }
                if let agentName = product.agentName {
                    HStack {
                        Text("Agent")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(agentName)
                    }
                }
            }

            // Delete
            Section {
                Button("Delete Product", role: .destructive) {
                    PhotoStorageService.delete(product.photoFileNames)
                    modelContext.delete(product)
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
        .navigationTitle(product.foodName ?? "Product")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadPhotos()
        }
        .fullScreenCover(item: Binding(
            get: { selectedPhotoIndex.map { IdentifiableIndex(index: $0) } },
            set: { selectedPhotoIndex = $0?.index }
        )) { item in
            PhotoFullScreenView(image: photos[item.index], onDismiss: { selectedPhotoIndex = nil })
        }
    }

    private func loadPhotos() {
        photos = product.photoFileNames.compactMap { PhotoStorageService.load($0) }
    }
}

// MARK: - Helpers

private struct IdentifiableIndex: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct PhotoFullScreenView: View {
    let image: UIImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        }
        .onTapGesture {
            onDismiss()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
            }
        }
    }
}
