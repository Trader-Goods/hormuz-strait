import Foundation

struct IngredientNote: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var names: [String]
    var level: String
    var plain: String
    var sourceName: String
    var sourceURL: String

    var tone: ScoreTone {
        switch level {
        case "avoid": return .avoid
        case "limit": return .limit
        default: return .good
        }
    }
}

enum ScoreTone: String {
    case good, limit, avoid, note
}

struct ScoreReason: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var tone: ScoreTone
}

struct ScoreReport: Equatable {
    var value: Int
    var reasons: [ScoreReason]
}

struct Product: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var brand: String
    var barcode: String
    var ingredients: String
    var additiveTags: [String]
    var categories: [String]
    var nova: Int?
    var kcal: Double?
    var sugar: Double?
    var addedSugar: Double?
    var sodiumMg: Double?
    var saturatedFat: Double?
    var fiber: Double?
    var protein: Double?
    var basis: String
    var serving: String
    var source: String
    var sourceDetail: String
    var isSample: Bool

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed food" : trimmed
    }
}

struct RecallNote: Equatable {
    var summary: String
    var detail: String
    var link: URL?
}

struct PersonalFlags: Codable, Equatable {
    var allergies: [String] = []
    var lowSugar: Bool = false
    var lowSodium: Bool = false
    var vegan: Bool = false
    var kids: Bool = false
    var pregnancy: Bool = false
}

enum Allergen: String, CaseIterable, Identifiable {
    case milk, eggs, fish, shellfish, treeNuts, peanuts, wheat, soy, sesame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .milk: return "Milk"
        case .eggs: return "Eggs"
        case .fish: return "Fish"
        case .shellfish: return "Shellfish"
        case .treeNuts: return "Tree nuts"
        case .peanuts: return "Peanuts"
        case .wheat: return "Wheat"
        case .soy: return "Soy"
        case .sesame: return "Sesame"
        }
    }

    var words: [String] {
        switch self {
        case .milk:
            return ["milk", "cream", "butter", "cheese", "whey", "casein", "lactose", "ghee", "yogurt"]
        case .eggs:
            return ["egg", "eggs", "albumin", "mayonnaise"]
        case .fish:
            return ["fish", "anchovy", "cod", "tuna", "salmon", "sardine", "tilapia"]
        case .shellfish:
            return ["shrimp", "crab", "lobster", "oyster", "clam", "mussel", "prawn", "crayfish", "shellfish"]
        case .treeNuts:
            return ["almond", "cashew", "walnut", "pecan", "pistachio", "hazelnut", "macadamia", "brazil nut", "pine nut"]
        case .peanuts:
            return ["peanut", "peanuts"]
        case .wheat:
            return ["wheat", "semolina", "durum", "spelt", "farro", "bulgur"]
        case .soy:
            return ["soy", "soya", "tofu", "edamame", "miso"]
        case .sesame:
            return ["sesame", "tahini"]
        }
    }
}

enum Copy {
    static let disclaimer = "TrueFoods shares public information in plain words. It is not medical advice, not a diagnosis, and not a reason to start or stop a food. Talk with a clinician about your own health."
    static let support = "support@tradergoods.us"
    static let userAgent = "TrueFoods/1.0 (support@tradergoods.us)"
}

extension Product {
    static let sampleEggs = Product(
        id: "sample-eggs",
        name: "Eggs",
        brand: "Pasture",
        barcode: "",
        ingredients: "eggs",
        additiveTags: [],
        categories: ["en:eggs"],
        nova: 1,
        kcal: 70,
        sugar: 0,
        addedSugar: 0,
        sodiumMg: 70,
        saturatedFat: 1.5,
        fiber: 0,
        protein: 6,
        basis: "per serving",
        serving: "1 large",
        source: "Sample",
        sourceDetail: "A practice food so you can see the screen. Not a real product.",
        isSample: true
    )

    static let sampleOats = Product(
        id: "sample-oats",
        name: "Sample rolled oats",
        brand: "Sample pantry",
        barcode: "",
        ingredients: "whole grain rolled oats",
        additiveTags: [],
        categories: ["en:breakfast-cereals"],
        nova: 1,
        kcal: 150,
        sugar: 1,
        addedSugar: 0,
        sodiumMg: 0,
        saturatedFat: 1,
        fiber: 4,
        protein: 5,
        basis: "per serving",
        serving: "40 g",
        source: "Sample",
        sourceDetail: "A practice food so you can see the screen. Not a real product.",
        isSample: true
    )

    static let sampleCrunch = Product(
        id: "sample-crunch",
        name: "Sample berry crunch",
        brand: "Sample pantry",
        barcode: "",
        ingredients: "whole grain rolled oats, sugar, high fructose corn syrup, red 40, salt, palm oil, natural flavors",
        additiveTags: ["en:e129"],
        categories: ["en:breakfast-cereals"],
        nova: 4,
        kcal: 180,
        sugar: 16,
        addedSugar: 14,
        sodiumMg: 180,
        saturatedFat: 1.5,
        fiber: 4,
        protein: 3,
        basis: "per serving",
        serving: "40 g",
        source: "Sample",
        sourceDetail: "A practice food so you can see the screen. Not a real product.",
        isSample: true
    )

    static let sampleLabel = "Ingredients: sugar, red 40, high fructose corn syrup, whole grain rolled oats"
}
