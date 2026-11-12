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

    func testScoreStaysInRangeAndExplainsItself() {
        let crunchNotes = IngredientBook.matches(in: Product.sampleCrunch.ingredients, tags: Product.sampleCrunch.additiveTags)
        let oatNotes = IngredientBook.matches(in: Product.sampleOats.ingredients, tags: [])
        let crunch = ScoreEngine.score(.sampleCrunch, notes: crunchNotes)
        let oats = ScoreEngine.score(.sampleOats, notes: oatNotes)
        XCTAssertGreaterThanOrEqual(crunch.value, 0)
        XCTAssertLessThanOrEqual(crunch.value, 100)
        XCTAssertGreaterThan(oats.value, crunch.value)
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
