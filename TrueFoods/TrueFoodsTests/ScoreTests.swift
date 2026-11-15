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

    func testColorPreviewSamplesStayOutOfRealScores() {
        XCTAssertEqual(ColorSamples.scores, [35, 45, 62, 75, 85, 94, 96])
        XCTAssertEqual(ColorSamples.foods.dropLast().map(\.id), ColorSamples.scores.map { "color-sample-\($0)" })
        let flagged = ColorSamples.foods.last
        XCTAssertEqual(flagged?.id, "color-sample-flagged")
        XCTAssertEqual(flagged?.ingredients, "red 40")
        let flaggedNotes = IngredientBook.matches(in: flagged?.ingredients ?? "", tags: flagged?.additiveTags ?? [])
        XCTAssertTrue(flaggedNotes.contains { $0.id == "red-40" })
        XCTAssertEqual(ColorSamples.displayedScore(for: flagged!), 90)
        XCTAssertEqual(ScoreColor.colorScore(numeric: 90, notes: flaggedNotes), 0)
        let red = ScoreColor.hsb(for: 0)
        XCTAssertTrue(red.hue * 360 <= 15 || red.hue * 360 >= 345)
        for food in ColorSamples.foods {
            XCTAssertTrue(food.isSample)
            XCTAssertTrue(food.name.hasPrefix("Sample"))
            XCTAssertEqual(food.brand, "Color preview")
        }
        XCTAssertNil(ColorSamples.displayedScore(for: .sampleEggs))
        XCTAssertEqual(ScoreColor.colorScore(numeric: 96, notes: []), 96)
    }

    func testWineCannotScoreGoldAndBlankIngredientsAreUnknown() {
        var wine = Product.sampleOats
        wine.name = "Vella Merlot"
        wine.ingredients = "grapes, sulfites"
        wine.categories = ["en:wines"]
        wine.alcoholPercent = 13.5
        let scored = ScoreEngine.score(wine, notes: [])
        XCTAssertTrue(ScoreEngine.isAlcoholic(wine))
        XCTAssertLessThanOrEqual(scored.value, ScoreRules.alcoholCap)
        XCTAssertLessThan(scored.value, 95)
        XCTAssertTrue(scored.reasons.contains { $0.id == "alcohol" })

        var blank = Product.sampleOats
        blank.ingredients = "  "
        blank.name = "Mystery milk"
        XCTAssertFalse(ScoreEngine.hasKnownIngredients(blank))
        XCTAssertFalse(ScoreEngine.isAlcoholic(blank))

        var ginger = Product.sampleOats
        ginger.name = "Ginger ale"
        ginger.ingredients = "carbonated water, ginger"
        ginger.categories = ["en:sodas"]
        XCTAssertFalse(ScoreEngine.isAlcoholic(ginger))
    }

    func testScoreColorBoundaries() {
        for score in [0, 30, 35, 45, 50, 62, 80, 94] {
            let color = ScoreColor.hsb(for: score)
            XCTAssertGreaterThanOrEqual(color.saturation, 0.95, "score \(score) saturation")
            let degrees = color.hue * 360
            XCTAssertTrue((0...120).contains(degrees), "score \(score) hue \(degrees) left the green-to-red arc")
            XCTAssertFalse((180...359).contains(degrees), "score \(score) hue \(degrees) is purple, magenta, or pink")
        }

        let worst = ScoreColor.hsb(for: 0)
        let redThirty = ScoreColor.hsb(for: 30)
        let redFortyFive = ScoreColor.hsb(for: 45)
        XCTAssertLessThanOrEqual(worst.hue * 360, 5)
        XCTAssertLessThanOrEqual(redThirty.hue * 360, 5)
        XCTAssertLessThanOrEqual(redFortyFive.hue * 360, 5)
        XCTAssertLessThan(worst.brightness, redThirty.brightness)
        XCTAssertLessThan(redThirty.brightness, redFortyFive.brightness)
        XCTAssertTrue(ScoreColor.inkIsWhite(for: 0))
        for score in [0, 30, 35, 45] {
            let rgb = ScoreColor.rgb(for: score)
            XCTAssertGreaterThan(rgb.red, rgb.green + 0.25)
            XCTAssertGreaterThan(rgb.red, rgb.blue + 0.25)
            XCTAssertLessThan(rgb.blue, 0.05)
            XCTAssertLessThan(rgb.green, 0.08)
        }

        let fifty = ScoreColor.hsb(for: 50).hue * 360
        XCTAssertTrue((5...40).contains(fifty), "score 50 hue \(fifty)")
        let sixtyTwo = ScoreColor.hsb(for: 62).hue * 360
        XCTAssertTrue((20...55).contains(sixtyTwo), "score 62 hue \(sixtyTwo)")
        let eighty = ScoreColor.hsb(for: 80).hue * 360
        XCTAssertTrue((70...110).contains(eighty), "score 80 hue \(eighty)")
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
        XCTAssertEqual(goldFill.top, ScoreColor.goldHighlight)
        XCTAssertEqual(goldFill.bottom, ScoreColor.goldRich)
        XCTAssertNotEqual(ScoreColor.fill(for: 94).bottom, goldFill.bottom)

        for score in [0, 30, 50, 62, 80, 94] {
            let fill = ScoreColor.fill(for: score)
            let solid = ScoreColor.rgb(for: score)
            XCTAssertEqual(fill.top, solid)
            XCTAssertEqual(fill.bottom, solid)
            XCTAssertEqual(fill.border, solid)
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
