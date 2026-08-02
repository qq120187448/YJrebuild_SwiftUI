import Foundation

struct NutritionResponse: Codable {
    let found: Bool
    let foodName: String?
    let brandName: String?
    let calories: Double?
    let protein: Double?
    let fat: Double?
    let carbs: Double?
    let fiber: Double?
    let sugars: Double?
    let sodium: Double?
    let servingQty: Double?
    let servingUnit: String?
    let servingWeightGrams: Double?
    let photoThumb: String?
    let photoHighres: String?

    enum CodingKeys: String, CodingKey {
        case found
        case foodName = "food_name"
        case brandName = "brand_name"
        case calories, protein, fat, carbs, fiber, sugars, sodium
        case servingQty = "serving_qty"
        case servingUnit = "serving_unit"
        case servingWeightGrams = "serving_weight_grams"
        case photoThumb = "photo_thumb"
        case photoHighres = "photo_highres"
    }
}
