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
        XCTAssertTrue(SearchRank.categoryQuery("almond milk")?.contains("en:almond-based-drinks") == true)
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
