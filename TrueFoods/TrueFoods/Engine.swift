import Foundation

enum ScoreRules {
    static let start = 80
    static let addedSugarDV = 50.0
    static let sodiumDV = 2300.0
    static let saturatedFatDV = 20.0
    static let fiberDV = 28.0
    static let proteinDV = 50.0
    static let highShare = 0.20
    static let goodShare = 0.10

    static var highAddedSugar: Double { addedSugarDV * highShare }
    static var highSodium: Double { sodiumDV * highShare }
    static var highSaturatedFat: Double { saturatedFatDV * highShare }
    static var goodFiber: Double { fiberDV * goodShare }
    static var goodProtein: Double { proteinDV * goodShare }
    static let sugarFallback = 12.0
    static let shortList = 5
}

enum IngredientBook {
    static let shared = IngredientBookLoader.load()

    static func matches(in ingredients: String, tags: [String]) -> [IngredientNote] {
        let hay = normalize(ingredients + " " + tags.joined(separator: " "))
        var hits: [(IngredientNote, String)] = []
        for note in shared {
            var best = ""
            for name in note.names {
                let needle = normalize(name)
                let trimmed = needle.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 3, hay.contains(needle), needle.count > best.count else { continue }
                best = needle
            }
            if !best.isEmpty {
                hits.append((note, best))
            }
        }
        let kept = hits.filter { hit in
            !hits.contains { other in
                other.0.id != hit.0.id && other.1.contains(hit.1)
            }
        }.map(\.0)
        return kept.sorted { rank($0) < rank($1) }
    }

    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let spaced = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        let words = String(spaced).split(separator: " ").joined(separator: " ")
        return " \(words) "
    }

    private static func rank(_ note: IngredientNote) -> Int {
        switch note.level {
        case "avoid": return 0
        case "limit": return 1
        default: return 2
        }
    }
}

private enum IngredientBookLoader {
    static func load() -> [IngredientNote] {
        let bundles = [Bundle.main, Bundle(identifier: "com.tradergoods.madewithlove")].compactMap { $0 }
        for bundle in bundles {
            if let url = bundle.url(forResource: "Dictionary", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let notes = try? JSONDecoder().decode([IngredientNote].self, from: data) {
                return notes
            }
        }
        return []
    }
}

enum ScoreEngine {
    static func score(_ product: Product, notes: [IngredientNote]) -> ScoreReport {
        var value = ScoreRules.start
        var reasons: [ScoreReason] = []

        if let added = product.addedSugar, added >= ScoreRules.highAddedSugar {
            value -= 18
            reasons.append(ScoreReason(id: "added-sugar", title: "High added sugar", detail: "A lot of added sugar.", tone: .avoid))
        } else if product.addedSugar == nil, let sugar = product.sugar, sugar >= ScoreRules.sugarFallback {
            value -= 10
            reasons.append(ScoreReason(id: "sugar", title: "A lot of sugar", detail: "A lot of sugar.", tone: .limit))
        }

        if let sodium = product.sodiumMg, sodium >= ScoreRules.highSodium {
            value -= 14
            reasons.append(ScoreReason(id: "sodium", title: "High sodium", detail: "High in sodium.", tone: .avoid))
        }

        if let sat = product.saturatedFat, sat >= ScoreRules.highSaturatedFat {
            value -= 14
            reasons.append(ScoreReason(id: "sat", title: "High saturated fat", detail: "High in saturated fat.", tone: .avoid))
        }

        if product.nova == 4 {
            value -= 12
            reasons.append(ScoreReason(id: "nova", title: "Highly processed", detail: "Many factory steps.", tone: .limit))
        }

        let avoids = notes.filter { $0.level == "avoid" }
        let limits = notes.filter { $0.level == "limit" }
        var avoidPoints = 0
        for note in avoids {
            let take = min(8, max(0, 24 - avoidPoints))
            avoidPoints += take
            value -= take
            reasons.append(ScoreReason(id: "note-\(note.id)", title: note.title, detail: "Worth skipping.", tone: .avoid))
        }
        var limitPoints = 0
        for note in limits {
            let take = min(3, max(0, 12 - limitPoints))
            limitPoints += take
            value -= take
            reasons.append(ScoreReason(id: "note-\(note.id)", title: note.title, detail: "Worth limiting.", tone: .limit))
        }

        if let fiber = product.fiber, fiber >= ScoreRules.goodFiber {
            value += 8
            reasons.append(ScoreReason(id: "fiber", title: "Good source of fiber", detail: "A helpful amount of fiber.", tone: .good))
        }
        if let protein = product.protein, protein >= ScoreRules.goodProtein {
            value += 6
            reasons.append(ScoreReason(id: "protein", title: "Good source of protein", detail: "A helpful amount of protein.", tone: .good))
        }

        let count = ingredientCount(product.ingredients)
        if count > 0, count <= ScoreRules.shortList {
            value += 6
            reasons.append(ScoreReason(id: "short", title: "Short ingredient list", detail: "Only a few ingredients.", tone: .good))
        }

        if avoids.isEmpty, limits.isEmpty, product.nova != 4, !product.ingredients.isEmpty {
            value += 4
            reasons.append(ScoreReason(id: "clean", title: "Simple ingredients", detail: "No ingredients we flag.", tone: .good))
        }

        return ScoreReport(value: min(100, max(0, value)), reasons: reasons)
    }

    static func ingredientCount(_ text: String) -> Int {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

enum FlagEngine {
    static func banners(for product: Product, notes: [IngredientNote], flags: PersonalFlags) -> [String] {
        let hay = IngredientBook.normalize(product.ingredients + " " + product.name)
        var lines: [String] = []
        let selected = Allergen.allCases.filter { flags.allergies.contains($0.rawValue) }
        let hits = selected.filter { allergen in
            allergen.words.contains { word in
                hay.contains(IngredientBook.normalize(word))
            }
        }
        if !hits.isEmpty {
            let names = hits.map(\.title).joined(separator: " and ")
            lines.append("This food mentions \(names). You asked us to flag \(hits.count == 1 ? "that" : "those").")
        }
        let highSugar = (product.addedSugar ?? 0) >= ScoreRules.highAddedSugar
            || (product.addedSugar == nil && (product.sugar ?? 0) >= ScoreRules.sugarFallback)
        if flags.lowSugar && highSugar {
            lines.append("This has a lot of sugar. You asked us to watch sugar.")
        }
        if flags.lowSodium && (product.sodiumMg ?? 0) >= ScoreRules.highSodium {
            lines.append("This is high in sodium. You asked us to watch sodium.")
        }
        if flags.vegan && mentionsAnimal(hay) {
            lines.append("This looks like it is not vegan, based on the words we found.")
        }
        if flags.kids && (highSugar || notes.contains(where: isArtificialColor)) {
            lines.append("You asked us to keep kids in mind. This has a lot of sugar or an artificial color.")
        }
        if flags.pregnancy {
            let watch = pregnancyWords.filter { hay.contains(IngredientBook.normalize($0)) }
            if !watch.isEmpty {
                lines.append("This mentions \(watch.joined(separator: ", ")). Worth a closer look during pregnancy. This is not medical advice.")
            }
        }
        return lines
    }

    private static func isArtificialColor(_ note: IngredientNote) -> Bool {
        ["red-40", "yellow-5", "yellow-6", "blue-1", "blue-2", "green-3", "red-3"].contains(note.id)
    }

    private static let pregnancyWords = [
        "alcohol", "wine", "beer", "unpasteurized", "raw milk", "liver", "pate", "pâté",
        "swordfish", "shark", "king mackerel", "tilefish", "sprouts"
    ]

    private static func mentionsAnimal(_ hay: String) -> Bool {
        let words = [
            "beef", "pork", "chicken", "turkey", "lamb", "bacon", "ham", "lard", "gelatin",
            "honey", "milk", "whey", "casein", "egg", "fish", "anchovy", "tuna", "salmon", "shrimp"
        ]
        return words.contains { hay.contains(IngredientBook.normalize($0)) }
    }
}
