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
        for score in [0, 30, 50, 62, 80, 94] {
            let color = ScoreColor.hsb(for: score)
            XCTAssertGreaterThanOrEqual(color.saturation, 0.85, "score \(score) saturation")
            XCTAssertGreaterThanOrEqual(color.brightness, 0.90, "score \(score) brightness")
            let degrees = color.hue * 360
            XCTAssertFalse((20...70).contains(degrees), "score \(score) hue \(degrees) is yellow or orange")
        }

        for score in [0, 30] {
            let degrees = ScoreColor.hsb(for: score).hue * 360
            XCTAssertTrue(degrees <= 15 || degrees >= 345, "score \(score) hue \(degrees)")
            let rgb = ScoreColor.rgb(for: score)
            XCTAssertGreaterThan(rgb.red, 0.8)
            XCTAssertGreaterThan(rgb.red, rgb.green + 0.4)
            XCTAssertGreaterThan(rgb.red, rgb.blue + 0.4)
        }

        let fifty = ScoreColor.hsb(for: 50).hue * 360
        XCTAssertTrue((250...330).contains(fifty), "score 50 hue \(fifty)")
        let sixtyTwo = ScoreColor.hsb(for: 62).hue * 360
        XCTAssertTrue((200...270).contains(sixtyTwo), "score 62 hue \(sixtyTwo)")
        let eighty = ScoreColor.hsb(for: 80).hue * 360
        XCTAssertTrue((140...200).contains(eighty), "score 80 hue \(eighty)")
        let greenHue = ScoreColor.hsb(for: 94).hue * 360
        XCTAssertTrue((110...140).contains(greenHue), "score 94 hue \(greenHue)")

        let green = ScoreColor.rgb(for: 94)
        XCTAssertGreaterThan(green.green, 0.8)
        XCTAssertGreaterThan(green.green, green.red + 0.5)
        XCTAssertGreaterThan(green.green, green.blue)

        let gold = ScoreColor.hsb(for: 95)
        XCTAssertEqual(ScoreColor.rgb(for: 95), ScoreColor.rgb(for: 100))
        XCTAssertEqual(ScoreColor.rgb(for: 95), ScoreColor.goldRich)
        XCTAssertNotEqual(ScoreColor.rgb(for: 94), ScoreColor.rgb(for: 95))
        XCTAssertEqual(ScoreColor.goldMinimum, 95)
        let goldDegrees = gold.hue * 360
        XCTAssertTrue((35...55).contains(goldDegrees), "gold hue \(goldDegrees)")
        XCTAssertGreaterThanOrEqual(gold.saturation, 0.8)
        XCTAssertGreaterThanOrEqual(gold.brightness, 0.8)

        let goldFill = ScoreColor.fill(for: 95)
        XCTAssertEqual(goldFill, ScoreColor.fill(for: 100))
        XCTAssertEqual(goldFill.top, ScoreColor.goldWash)
        XCTAssertEqual(goldFill.bottom, ScoreColor.goldRich)
        XCTAssertEqual(goldFill.border, ScoreColor.goldRich)
        XCTAssertNotEqual(ScoreColor.fill(for: 94).border, goldFill.border)

        for score in [0, 30, 50, 62, 80, 94] {
            let fill = ScoreColor.fill(for: score)
            XCTAssertEqual(fill.border, ScoreColor.rgb(for: score))
            let tint = fill.bottom.red + fill.bottom.green + fill.bottom.blue
            let ink = fill.border.red + fill.border.green + fill.border.blue
            XCTAssertGreaterThan(tint, ink)
        }
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
