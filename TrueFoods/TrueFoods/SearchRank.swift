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

    /// Specific category first, then its parent. Open Food Facts lists the broad group first.
    static func categoryLadder(_ tags: [String]) -> [String] {
        let skip: Set<String> = [
            "plant-based-foods-and-beverages", "plant-based-foods", "foods", "beverages"
        ]
        let cleaned = tags
            .map { $0.lowercased().replacingOccurrences(of: "en:", with: "") }
            .filter { !$0.isEmpty && !skip.contains($0) }
        var ladder: [String] = []
        for tag in cleaned.reversed() where !ladder.contains(tag) {
            ladder.append(tag)
            if ladder.count == 2 { break }
        }
        return ladder
    }

    static func swapQuery(_ tag: String) -> String {
        let clean = tag.replacingOccurrences(of: "en:", with: "")
        return "categories_tags:\"en:\(clean)\" AND countries_tags:\"en:united-states\""
    }

    static func isUSGrocery(_ item: GroceryCandidate) -> Bool {
        guard item.hasImage else { return false }
        guard item.countries.contains("en:united-states") else { return false }
        return !item.englishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func popularity(_ item: GroceryCandidate) -> Double {
        log10(item.scans + 1) * 10 + log10(item.popularity + 1) * 2
    }

    /// Higher-scoring foods from the same group. Pools are specific category, then parent.
    /// A short US list may use the parent. A product that is not sold in the US is never returned.
    static func higherSwaps(
        current: Product,
        currentScore: Int,
        pools: [[GroceryCandidate]],
        score: (Product) -> Int,
        limit: Int = 3
    ) -> [GroceryCandidate] {
        let own = current.barcode.isEmpty ? current.id : current.barcode
        var gathered: [GroceryCandidate] = []
        for (index, pool) in pools.enumerated() {
            gathered.append(contentsOf: pool)
            let picked = rankSwaps(own: own, currentScore: currentScore, pool: gathered, score: score, limit: limit)
            if picked.count >= limit || index == pools.count - 1 {
                return picked
            }
        }
        return []
    }

    private static func rankSwaps(
        own: String,
        currentScore: Int,
        pool: [GroceryCandidate],
        score: (Product) -> Int,
        limit: Int
    ) -> [GroceryCandidate] {
        var seen = Set<String>()
        let eligible = pool.filter { item in
            guard isUSGrocery(item) else { return false }
            let code = item.product.barcode.isEmpty ? item.product.id : item.product.barcode
            guard code != own else { return false }
            guard score(item.product) > currentScore else { return false }
            return seen.insert(code).inserted
        }.sorted { lhs, rhs in
            let left = popularity(lhs)
            let right = popularity(rhs)
            if left == right { return lhs.scans > rhs.scans }
            return left > right
        }
        return eligible.prefix(limit).map { item in
            var copy = item
            copy.product.name = item.englishName
            return copy
        }
    }

    static func ordered(_ query: String, _ items: [GroceryCandidate]) -> [GroceryCandidate] {
        let tokens = words(query)
        let phrase = tokens.joined(separator: " ")
        let packed = tokens.joined()
        let intents = categoryTags(for: query)
        var seen = Set<String>()
        var ranked: [(Double, GroceryCandidate)] = []
        for item in items {
            guard isUSGrocery(item) else { continue }
            let name = item.englishName.trimmingCharacters(in: .whitespacesAndNewlines)
            let brandKey = words(item.product.brand).joined()
            let nameKey = words(name).joined()
            guard seen.insert(brandKey + "|" + nameKey).inserted else { continue }
            let nameWords = Set(words(name))
            let flat = words(name).joined()
            let categories = item.product.categories.map { $0.replacingOccurrences(of: "en:", with: "") }
            var score = popularity(item)
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
            if !incidental.isEmpty && !categoryHit {
                continue
            }
            if tokens.count >= 2 && !phraseHit && !categoryHit {
                continue
            }
            score -= Double(45 * incidental.count)
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
