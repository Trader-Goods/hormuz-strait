import XCTest
@testable import TrueFoods

final class ScoreTests: XCTestCase {
    func testDictionaryHasTheCommonIngredients() {
        XCTAssertGreaterThanOrEqual(IngredientBook.shared.count, 150)
        let ids = Set(IngredientBook.shared.map(\.id))
        for id in ["red-40", "aspartame", "hfcs", "sodium-nitrite", "bha", "carrageenan", "partially-hydrogenated"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        for note in IngredientBook.shared {
            XCTAssertTrue(["fine", "limit", "avoid"].contains(note.level))
            XCTAssertTrue(note.sourceURL.hasPrefix("https://"))
            XCTAssertFalse(note.plain.isEmpty)
        }
    }

    func testRed40AndPartialHydrogenation() {
        let hits = IngredientBook.matches(in: "Sugar, Red 40, partially hydrogenated soybean oil", tags: ["en:e129"])
        XCTAssertTrue(hits.contains { $0.id == "red-40" })
        XCTAssertTrue(hits.contains { $0.id == "partially-hydrogenated" })
        XCTAssertFalse(hits.contains { $0.id == "hydrogenated-oil" })
    }

    func testEggplantIsNotEgg() {
        let hay = IngredientBook.normalize("eggplant, oats")
        XCTAssertFalse(hay.contains(IngredientBook.normalize("egg")))
        let flags = PersonalFlags(allergies: [Allergen.eggs.rawValue])
        let product = Product.sampleOats
        var eggplant = product
        eggplant.ingredients = "eggplant, rolled oats"
        XCTAssertTrue(FlagEngine.banners(for: eggplant, notes: [], flags: flags).isEmpty)
    }

    func testMilkFlag() {
        var product = Product.sampleOats
        product.ingredients = "rolled oats, whey protein"
        let flags = PersonalFlags(allergies: [Allergen.milk.rawValue])
        let lines = FlagEngine.banners(for: product, notes: [], flags: flags)
        XCTAssertTrue(lines.contains { $0.contains("Milk") })
    }

    func testScoreColorBoundaries() {
        let zero = ScoreColor.rgb(for: 0)
        let mid = ScoreColor.rgb(for: 50)
        let green = ScoreColor.rgb(for: 94)
        let gold = ScoreColor.rgb(for: 95)
        let top = ScoreColor.rgb(for: 100)

        XCTAssertGreaterThan(zero.red, 0.65)
        XCTAssertLessThan(zero.green, 0.2)
        XCTAssertLessThan(zero.blue, 0.15)

        XCTAssertGreaterThan(mid.red, mid.green)
        XCTAssertGreaterThan(mid.green, zero.green + 0.1)
        XCTAssertEqual(mid.blue, 0)
        XCTAssertGreaterThan(mid.red, 0.55)

        XCTAssertGreaterThan(green.green, green.red)
        XCTAssertGreaterThan(green.green, 0.35)
        XCTAssertNotEqual(green, gold)

        XCTAssertEqual(gold, top)
        XCTAssertEqual(gold, ScoreColor.gold)
        XCTAssertGreaterThan(gold.red, gold.green)
        XCTAssertGreaterThan(gold.green, gold.blue + 0.2)
        XCTAssertGreaterThan(green.green, gold.green)

        for sample in [zero, mid, green, gold] {
            XCTAssertGreaterThanOrEqual(contrast(sample, on: card), 4.5)
        }
    }

    private var card: ScoreColor.RGB {
        ScoreColor.RGB(red: 0.975, green: 0.988, blue: 0.976)
    }

    private func contrast(_ ink: ScoreColor.RGB, on background: ScoreColor.RGB) -> Double {
        let lighter = max(luminance(ink), luminance(background))
        let darker = min(luminance(ink), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: ScoreColor.RGB) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    func testScoreStaysInRangeAndExplainsItself() {
        let crunchNotes = IngredientBook.matches(in: Product.sampleCrunch.ingredients, tags: Product.sampleCrunch.additiveTags)
        let oatNotes = IngredientBook.matches(in: Product.sampleOats.ingredients, tags: [])
        let crunch = ScoreEngine.score(.sampleCrunch, notes: crunchNotes)
        let oats = ScoreEngine.score(.sampleOats, notes: oatNotes)
        XCTAssertGreaterThanOrEqual(crunch.value, 0)
        XCTAssertLessThanOrEqual(crunch.value, 100)
        XCTAssertEqual(ScoreRules.start, 100)
        XCTAssertGreaterThanOrEqual(oats.value, 90)
        XCTAssertLessThanOrEqual(oats.value, 95)
        XCTAssertLessThanOrEqual(ScoreRules.refinedPenalty, 10)
        var eggs = Product.sampleOats
        eggs.name = "Eggs"
        eggs.ingredients = "eggs"
        eggs.fiber = 0
        eggs.protein = 6
        XCTAssertEqual(ScoreEngine.score(eggs, notes: []).value, 100)
        var broccoli = Product.sampleOats
        broccoli.name = "Broccoli"
        broccoli.ingredients = "broccoli"
        broccoli.fiber = 2
        broccoli.protein = 2
        XCTAssertEqual(ScoreEngine.score(broccoli, notes: []).value, 100)
        XCTAssertLessThan(crunch.value, 45)
        XCTAssertGreaterThan(oats.value, crunch.value)
        var processed = Product.sampleOats
        processed.nova = 4
        XCTAssertLessThanOrEqual(ScoreEngine.score(processed, notes: []).value, 80)
        let red = IngredientBook.shared.first { $0.id == "red-40" }
        let yellow = IngredientBook.shared.first { $0.id == "yellow-5" }
        XCTAssertNotNil(red)
        XCTAssertNotNil(yellow)
        let plain = ScoreEngine.score(.sampleOats, notes: [])
        let oneDye = ScoreEngine.score(.sampleOats, notes: [red!])
        let twoDyes = ScoreEngine.score(.sampleOats, notes: [red!, yellow!])
        XCTAssertEqual(plain.value - oneDye.value, ScoreRules.dyePenalty)
        XCTAssertEqual(oneDye.value - twoDyes.value, ScoreRules.dyePenalty)
        XCTAssertFalse(crunch.reasons.isEmpty)
        XCTAssertTrue(crunch.reasons.contains { $0.title.localizedCaseInsensitiveContains("sugar") })
        XCTAssertFalse(crunch.reasons.contains { $0.id == "basis" })
        for reason in crunch.reasons + oats.reasons {
            let line = (reason.title + " " + reason.detail).lowercased()
            XCTAssertFalse(line.contains("subtract"))
            XCTAssertFalse(line.contains("adds"))
            XCTAssertFalse(line.contains("daily value"))
            XCTAssertFalse(line.contains("start at"))
        }
    }
}
