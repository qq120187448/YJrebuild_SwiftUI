import Foundation
import SwiftData

enum NutritionService {
    @MainActor
    static func lookup(
        upc: String,
        record: ScanRecord,
        apiService: APIService,
        modelContext: ModelContext
    ) async {
        guard !record.nutritionLookedUp else { return }

        do {
            let response = try await apiService.lookupNutrition(upc: upc)

            record.nutritionLookedUp = true

            guard response.found else {
                try? modelContext.save()
                return
            }

            record.foodName = response.foodName
            record.brandName = response.brandName
            record.calories = response.calories
            record.protein = response.protein
            record.totalFat = response.fat
            record.totalCarbs = response.carbs
            record.dietaryFiber = response.fiber
            record.sugars = response.sugars
            record.sodium = response.sodium
            record.servingQty = response.servingQty
            record.servingUnit = response.servingUnit
            record.servingWeightGrams = response.servingWeightGrams
            record.photoThumbURL = response.photoThumb
            record.photoHighresURL = response.photoHighres

            // Store raw JSON for export
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            record.nutritionJSON = try? encoder.encode(response)

            try? modelContext.save()

            // Prefetch thumbnail
            if let thumb = response.photoThumb {
                await ImageCacheService.prefetch(urlString: thumb)
            }
        } catch {
            // Mark as looked up even on failure to prevent re-fetching
            record.nutritionLookedUp = true
            try? modelContext.save()
        }
    }

    /// Lookup nutrition for a ProductCaptureRecord (used by Chef agent flow).
    @MainActor
    static func lookupForProduct(
        upc: String,
        record: ProductCaptureRecord,
        apiService: APIService,
        modelContext: ModelContext
    ) async {
        guard !record.nutritionLookedUp else { return }

        do {
            let response = try await apiService.lookupNutrition(upc: upc)

            record.nutritionLookedUp = true

            guard response.found else {
                try? modelContext.save()
                return
            }

            record.foodName = response.foodName
            record.brandName = response.brandName
            record.calories = response.calories
            record.photoThumbURL = response.photoThumb

            try? modelContext.save()

            if let thumb = response.photoThumb {
                await ImageCacheService.prefetch(urlString: thumb)
            }
        } catch {
            record.nutritionLookedUp = true
            try? modelContext.save()
        }
    }
}
