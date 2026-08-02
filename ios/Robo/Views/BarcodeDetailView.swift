import SwiftUI

struct BarcodeDetailView: View {
    let scan: ScanRecord

    @State private var copiedToastVisible = false
    @State private var productImage: UIImage?

    private var hasNutrition: Bool { scan.foodName != nil }

    var body: some View {
        List {
            if hasNutrition {
                productHeaderSection
                nutritionFactsSection
                servingSizeSection
            }

            barcodeSection

            Section {
                LabeledContent("Symbology", value: formatSymbology(scan.symbology))
                LabeledContent("Scanned") {
                    Text(scan.capturedAt, format: .dateTime)
                }
            }

            actionsSection

            if hasNutrition {
                nutritionixAttribution
            }
        }
        .navigationTitle(scan.foodName ?? "Barcode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .tabBar)
        .overlay(alignment: .bottom) {
            if copiedToastVisible {
                Text("Copied to clipboard")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copiedToastVisible)
        .task {
            if let urlStr = scan.photoHighresURL ?? scan.photoThumbURL {
                productImage = ImageCacheService.cachedImage(for: urlStr)
                if productImage == nil {
                    await ImageCacheService.prefetch(urlString: urlStr)
                    productImage = ImageCacheService.cachedImage(for: urlStr)
                }
            }
        }
    }

    // MARK: - Product Header

    @ViewBuilder
    private var productHeaderSection: some View {
        Section {
            HStack(spacing: 16) {
                if let productImage {
                    Image(uiImage: productImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.secondary.opacity(0.15))
                        .frame(width: 80, height: 80)
                        .overlay {
                            Image(systemName: "fork.knife")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(scan.foodName ?? "")
                        .font(.title3.bold())

                    if let brand = scan.brandName {
                        Text(brand)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Nutrition Facts

    @ViewBuilder
    private var nutritionFactsSection: some View {
        Section("Nutrition Facts") {
            if let cal = scan.calories {
                HStack {
                    Text("Calories")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(cal))")
                        .font(.headline)
                }
            }

            nutritionRow("Total Fat", value: scan.totalFat, unit: "g")
            nutritionRow("Total Carbs", value: scan.totalCarbs, unit: "g")
            nutritionRow("Dietary Fiber", value: scan.dietaryFiber, unit: "g", indent: true)
            nutritionRow("Sugars", value: scan.sugars, unit: "g", indent: true)
            nutritionRow("Protein", value: scan.protein, unit: "g")
            nutritionRow("Sodium", value: scan.sodium, unit: "mg")
        }
    }

    @ViewBuilder
    private func nutritionRow(_ label: String, value: Double?, unit: String, indent: Bool = false) -> some View {
        if let value {
            HStack {
                Text(label)
                    .padding(.leading, indent ? 16 : 0)
                    .foregroundStyle(indent ? .secondary : .primary)
                Spacer()
                Text(String(format: value == value.rounded() ? "%.0f%@" : "%.1f%@", value, unit))
            }
        }
    }

    // MARK: - Serving Size

    @ViewBuilder
    private var servingSizeSection: some View {
        if scan.servingQty != nil || scan.servingUnit != nil || scan.servingWeightGrams != nil {
            Section("Serving Size") {
                if let qty = scan.servingQty, let unit = scan.servingUnit {
                    LabeledContent("Serving", value: "\(Int(qty)) \(unit)")
                }
                if let weight = scan.servingWeightGrams {
                    LabeledContent("Weight", value: "\(Int(weight))g")
                }
            }
        }
    }

    // MARK: - Barcode

    private var barcodeSection: some View {
        Section {
            Text(scan.barcodeValue)
                .font(.title2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = scan.barcodeValue
                showCopiedToast()
            } label: {
                Label("Copy Barcode", systemImage: "doc.on.doc")
            }

            if scan.nutritionJSON != nil {
                Button {
                    if let json = scan.nutritionJSON,
                       let str = String(data: json, encoding: .utf8) {
                        UIPasteboard.general.string = str
                        showCopiedToast()
                    }
                } label: {
                    Label("Copy Nutrition JSON", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    // MARK: - Nutritionix Attribution

    private var nutritionixAttribution: some View {
        Section {
            Link(destination: URL(string: "https://www.nutritionix.com")!) {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text("Powered by")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image("NutritionixLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 24)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Helpers

    private func showCopiedToast() {
        copiedToastVisible = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedToastVisible = false
        }
    }

    private func formatSymbology(_ raw: String) -> String {
        raw.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
    }
}
