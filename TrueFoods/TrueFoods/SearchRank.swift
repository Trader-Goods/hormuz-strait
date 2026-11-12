import Foundation

struct GroceryCandidate: Equatable {
    var product: Product
    var countries: [String]
    var scans: Double
    var popularity: Double
    var hasImage: Bool
    var englishName: String
}

enum SearchRank {
    static func textQuery(_ query: String) -> String {
        let tokens = words(query)
        let country = "countries_tags:\"en:united-states\""
        guard !tokens.isEmpty else { return country }
        return "\(country) AND " + tokens.joined(separator: " AND ")
    }

    static func categoryQuery(_ query: String) -> String? {
        let tags = categoryTags(for: query)
        guard !tags.isEmpty else { return nil }
        let ors = tags.map { "categories_tags:\"en:\($0)\"" }.joined(separator: " OR ")
        return "(\(ors)) AND countries_tags:\"en:united-states\""
    }

    static func ordered(_ query: String, _ items: [GroceryCandidate]) -> [GroceryCandidate] {
        let tokens = words(query)
        let phrase = tokens.joined(separator: " ")
        let packed = tokens.joined()
        let intents = categoryTags(for: query)
        var seen = Set<String>()
        var ranked: [(Double, GroceryCandidate)] = []
        for item in items {
            guard item.hasImage else { continue }
            guard item.countries.contains("en:united-states") else { continue }
            let name = item.englishName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let brandKey = words(item.product.brand).joined()
            let nameKey = words(name).joined()
            guard seen.insert(brandKey + "|" + nameKey).inserted else { continue }
            let nameWords = Set(words(name))
            let flat = words(name).joined()
            let categories = item.product.categories.map { $0.replacingOccurrences(of: "en:", with: "") }
            var score = log10(item.scans + 1) * 10 + log10(item.popularity + 1) * 2
            let phraseHit = name.lowercased().contains(phrase) || (!packed.isEmpty && flat.contains(packed))
            if phraseHit { score += 80 }
            let hits = tokens.filter { nameWords.contains($0) || flat.contains($0) }.count
            score += Double(24 * hits)
            score -= Double(40 * (tokens.count - hits))
            let categoryHit = intents.contains { intent in
                categories.contains { $0 == intent || $0.contains(intent) }
            }
            if categoryHit { score += 60 }
            let incidental = incidentalWords.filter { word in
                !tokens.contains(word) && (nameWords.contains(word) || categories.contains { $0.contains(word) })
            }
            score -= Double(45 * incidental.count)
            if tokens.count >= 2 && !phraseHit && !categoryHit {
                score -= 80
            }
            let modifiers: Set<String> = [
                "unsweetened", "sweetened", "original", "vanilla", "organic", "plain", "creamy",
                "crunchy", "nonfat", "lowfat", "greek", "whole", "skim", "classic", "regular",
                "natural", "light", "chunky", "smooth"
            ]
            let extra = nameWords.subtracting(tokens).subtracting(modifiers)
            if extra.isEmpty && tokens.allSatisfy({ nameWords.contains($0) || flat.contains($0) }) {
                score += 40
            }
            var copy = item
            copy.product.name = name
            ranked.append((score, copy))
        }
        return ranked.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1.scans > rhs.1.scans }
            return lhs.0 > rhs.0
        }.map(\.1)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func categoryTags(for query: String) -> [String] {
        let key = words(query).joined(separator: " ")
        if let known = knownCategories[key] { return known }
        let tokens = words(query)
        guard !tokens.isEmpty else { return [] }
        var tags = [tokens.joined(separator: "-")]
        if let last = tokens.last, tokens.count > 1 {
            tags.append((tokens.dropLast() + [last + "s"]).joined(separator: "-"))
        }
        return tags
    }

    private static let knownCategories: [String: [String]] = [
        "almond milk": ["almond-based-drinks", "almond-milks", "plant-based-milk-alternatives"],
        "oats": ["rolled-oats", "oat-flakes", "oatmeal", "oats"],
        "yogurt": ["yogurts", "yoghurts"],
        "salsa": ["salsas"],
        "peanut butter": ["peanut-butters"],
        "cereal": ["breakfast-cereals"]
    ]

    private static let incidentalWords = [
        "chocolate", "nougat", "candy", "candies", "cookie", "cookies", "biscuit", "biscuits",
        "cake", "wafer", "flour", "extract", "snack", "chips", "butter", "yogurt", "yoghurt"
    ]
}
