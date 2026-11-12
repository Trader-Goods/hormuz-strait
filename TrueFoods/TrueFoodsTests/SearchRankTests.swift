import XCTest
@testable import TrueFoods

final class SearchRankTests: XCTestCase {
    func testAlmondMilkPrefersUSGroceryDrinks() {
        let ranked = SearchRank.ordered("almond milk", [
            food("Boisson à l'amande, sans sucres", "Vemondo", english: "", langCountries: ["en:france"], scans: 400),
            food("Toblerone Milk Chocolate Almond Nougat", "Toblerone", categories: ["en:chocolates"], scans: 800),
            food("Almond milk", "Great Value", categories: ["en:almond-based-drinks"], scans: 5),
            food("Original Unsweetened Almondmilk", "Silk", categories: ["en:almond-based-drinks"], scans: 10),
            food("Almond Breeze Almondmilk Unsweetened", "Almond Breeze", categories: ["en:almond-based-drinks"], scans: 16),
            food("Almond milk", "Great Value", categories: ["en:almond-based-drinks"], scans: 5),
            food("Almond milk", "Silk", categories: ["en:almond-based-drinks"], scans: 40, image: false),
            food("Lait d'amande", "Vemondo", english: "", categories: ["en:almond-based-drinks"], scans: 100)
        ])
        let labels = ranked.map { "\($0.product.brand) \($0.product.name)" }
        XCTAssertEqual(labels.prefix(3).map { $0 }, [
            "Great Value Almond milk",
            "Almond Breeze Almond Breeze Almondmilk Unsweetened",
            "Silk Original Unsweetened Almondmilk"
        ])
        XCTAssertFalse(labels.contains { $0.contains("Toblerone") })
        XCTAssertFalse(labels.contains { $0.contains("Vemondo") })
        XCTAssertEqual(labels.filter { $0.hasPrefix("Great Value") }.count, 1)
    }

    func testQueryBuildsAUSSearch() {
        XCTAssertEqual(
            SearchRank.textQuery("almond milk"),
            "countries_tags:\"en:united-states\" AND almond AND milk"
        )
        let category = SearchRank.categoryQuery("almond milk") ?? ""
        XCTAssertTrue(category.contains("en:almond-based-drinks"))
        XCTAssertTrue(category.contains("countries_tags:\"en:united-states\""))
        XCTAssertEqual(
            SearchRank.swapQuery("fruit-yogurts"),
            "categories_tags:\"en:fruit-yogurts\" AND countries_tags:\"en:united-states\""
        )
    }

    func testSearchDropsEnglishFoodsThatAreNotSoldInTheUS() {
        let ranked = SearchRank.ordered("yogurt", [
            food("Jaouda Perly", "Jaouda", langCountries: ["en:morocco"], scans: 500),
            food("Plain Greek Yogurt", "Great Value", scans: 20)
        ])
        XCTAssertEqual(ranked.map(\.product.brand), ["Great Value"])
    }

    func testSwapsPreferPopularUSFoodsAndSkipForeignOnes() {
        let current = food(
            "Fruit yogurt",
            "Store brand",
            categories: ["en:dairies", "en:yogurts", "en:fruit-yogurts"],
            scans: 4
        ).product
        let specific = [
            food("Jaouda Perly", "Jaouda", langCountries: ["en:morocco"], scans: 500),
            food("Lindt Excellence 90%", "Lindt", langCountries: ["en:switzerland", "en:france"], scans: 900),
            food("Plain Greek Yogurt", "Great Value", scans: 30)
        ]
        let parent = [
            food("Ekibio Tartines craquantes au sarrasin", "Ekibio", langCountries: ["en:france"], scans: 400),
            food("Whole Milk Yogurt", "Kroger", scans: 80),
            food("Nonfat Greek Yogurt", "Chobani", scans: 200)
        ]
        let scores = [
            "Store brand Fruit yogurt": 40,
            "Jaouda Jaouda Perly": 90,
            "Lindt Lindt Excellence 90%": 95,
            "Great Value Plain Greek Yogurt": 70,
            "Ekibio Ekibio Tartines craquantes au sarrasin": 88,
            "Kroger Whole Milk Yogurt": 75,
            "Chobani Nonfat Greek Yogurt": 80
        ]
        let picks = SearchRank.higherSwaps(
            current: current,
            currentScore: 40,
            pools: [specific, parent],
            score: { scores["\($0.brand) \($0.name)"] ?? 0 }
        )
        XCTAssertEqual(picks.map { "\($0.product.brand) \($0.product.name)" }, [
            "Chobani Nonfat Greek Yogurt",
            "Kroger Whole Milk Yogurt",
            "Great Value Plain Greek Yogurt"
        ])
        XCTAssertEqual(
            SearchRank.categoryLadder(current.categories),
            ["fruit-yogurts", "yogurts"]
        )
    }

    func testSwapsShowNothingWhenOnlyForeignFoodsScoreHigher() {
        let current = food("Crackers", "Store brand", categories: ["en:crackers"], scans: 2).product
        let foreign = [
            food("Ekibio Tartines craquantes au sarrasin", "Ekibio", langCountries: ["en:france"], scans: 400),
            food("Lindt Excellence 90%", "Lindt", langCountries: ["en:france"], scans: 300, image: false)
        ]
        let picks = SearchRank.higherSwaps(
            current: current,
            currentScore: 10,
            pools: [foreign],
            score: { _ in 90 }
        )
        XCTAssertTrue(picks.isEmpty)
    }

    private func food(
        _ name: String,
        _ brand: String,
        english: String? = nil,
        categories: [String] = [],
        langCountries: [String] = ["en:united-states"],
        scans: Double,
        image: Bool = true
    ) -> GroceryCandidate {
        let shown = english ?? name
        return GroceryCandidate(
            product: Product(
                id: brand + name,
                name: shown,
                brand: brand,
                barcode: brand + name,
                ingredients: "",
                additiveTags: [],
                categories: categories,
                nova: nil,
                kcal: nil,
                sugar: nil,
                addedSugar: nil,
                sodiumMg: nil,
                saturatedFat: nil,
                fiber: nil,
                protein: nil,
                basis: "per serving",
                serving: "",
                source: "Open Food Facts",
                sourceDetail: "",
                isSample: false
            ),
            countries: langCountries,
            scans: scans,
            popularity: scans,
            hasImage: image,
            englishName: shown
        )
    }
}
