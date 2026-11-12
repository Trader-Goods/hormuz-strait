import Foundation

enum FoodAPI {
    private static let agent = Copy.userAgent
    private static let pace = Pace()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": agent]
        config.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 80_000_000)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func lookup(barcode raw: String) async throws -> Product {
        let codes = barcodeCandidates(raw)
        guard !codes.isEmpty else { throw FoodError.notFound }
        for code in codes {
            if let product = try await openFoodFacts(code: code) {
                return product
            }
        }
        for code in codes {
            if let product = try await usda(query: code, barcode: code) {
                return product
            }
        }
        throw FoodError.notFound
    }

    static func search(name: String) async throws -> [Product] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        var found: [Product] = []
        let folded = query.lowercased()
        if folded.contains("sample") {
            found.append(contentsOf: [Product.sampleOats, Product.sampleCrunch])
        }
        if let remote = try? await grocerySearch(query) {
            found.append(contentsOf: remote)
        }
        if found.filter({ !$0.isSample }).isEmpty, let fallback = try? await usda(query: query, barcode: nil) {
            found.append(fallback)
        }
        var seen = Set<String>()
        return found.filter { product in
            let key = product.barcode.isEmpty ? product.id : product.barcode
            return seen.insert(key).inserted
        }
    }

    static func swaps(for product: Product) async -> [Product] {
        let category = product.categories.first?.replacingOccurrences(of: "en:", with: "").replacingOccurrences(of: "-", with: " ") ?? ""
        guard !category.isEmpty else { return [] }
        guard let list = try? await openFoodFactsCategory(category) else { return [] }
        let mine = scoreValue(product)
        return list
            .filter { $0.barcode != product.barcode && $0.id != product.id }
            .map { ($0, scoreValue($0)) }
            .filter { $0.1 > mine }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map(\.0)
    }

    static func recall(for product: Product) async -> RecallNote? {
        let words = significantWords(product.displayName + " " + product.brand)
        guard !words.isEmpty else { return nil }
        let phrase = words.prefix(3).joined(separator: " ")
        var query = "status:Ongoing AND product_description:\"\(phrase)\""
        if !product.barcode.isEmpty {
            query += " OR code_info:\"\(product.barcode)\""
        }
        guard let url = URL(string: "https://api.fda.gov/food/enforcement.json?limit=5&search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else {
            return nil
        }
        guard let json = try? await fetchJSON(url, paced: false),
              let results = json["results"] as? [[String: Any]] else {
            return nil
        }
        for item in results {
            let description = (item["product_description"] as? String) ?? ""
            let code = (item["code_info"] as? String) ?? ""
            let hay = IngredientBook.normalize(description + " " + code)
            let matched = words.filter { hay.contains(IngredientBook.normalize($0)) }
            let barcodeHit = !product.barcode.isEmpty && code.replacingOccurrences(of: " ", with: "").contains(product.barcode)
            guard barcodeHit || matched.count >= 2 else { continue }
            let reason = (item["reason_for_recall"] as? String) ?? "A recall notice was filed."
            let firm = (item["recalling_firm"] as? String) ?? ""
            var link: URL?
            if let id = item["recall_number"] as? String {
                link = URL(string: "https://www.fda.gov/safety/recalls-market-withdrawals-safety-alerts")
                _ = id
            }
            return RecallNote(
                summary: "A public recall notice uses similar words.",
                detail: "\(reason) \(firm). Read the notice before you decide. This is not proof that the package in your hand was recalled.",
                link: link
            )
        }
        return nil
    }

    private static func scoreValue(_ product: Product) -> Int {
        let notes = IngredientBook.matches(in: product.ingredients, tags: product.additiveTags)
        return ScoreEngine.score(product, notes: notes).value
    }

    private static func openFoodFacts(code: String) async throws -> Product? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json") else { return nil }
        let json: [String: Any]
        do {
            json = try await fetchJSON(url, paced: true)
        } catch FoodError.offline {
            throw FoodError.offline
        } catch {
            return nil
        }
        guard let status = json["status"] as? Int, status == 1,
              let product = json["product"] as? [String: Any] else { return nil }
        return parseOFF(product, code: code)
    }

    private static func grocerySearch(_ query: String) async throws -> [Product] {
        var pool: [GroceryCandidate] = []
        var seen = Set<String>()
        func add(_ items: [GroceryCandidate]) {
            for item in items where seen.insert(item.product.barcode.isEmpty ? item.product.id : item.product.barcode).inserted {
                pool.append(item)
            }
        }
        let text = (try? await searchAlicious(SearchRank.textQuery(query), pageSize: 50, sort: nil)) ?? []
        add(text)
        if let category = SearchRank.categoryQuery(query) {
            let popular = (try? await searchAlicious(category, pageSize: 24, sort: "-unique_scans_n")) ?? []
            add(popular)
        }
        var ranked = SearchRank.ordered(query, pool)
        if ranked.isEmpty {
            add((try? await openFoodFactsSearch(query)) ?? [])
            ranked = SearchRank.ordered(query, pool)
        }
        return Array(ranked.prefix(15).map(\.product))
    }

    private static func searchAlicious(_ lucene: String, pageSize: Int, sort: String?) async throws -> [GroceryCandidate] {
        var parts = URLComponents(string: "https://search.openfoodfacts.org/search")!
        var items = [
            URLQueryItem(name: "q", value: lucene),
            URLQueryItem(name: "langs", value: "en"),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "fields", value: "code,product_name,product_name_en,brands,ingredients_text,additives_tags,nova_group,categories_tags,countries_tags,nutriments,serving_size,unique_scans_n,popularity_key,lang,lc,image_front_small_url,image_front_url,image_url")
        ]
        if let sort {
            items.append(URLQueryItem(name: "sort_by", value: sort))
        }
        parts.queryItems = items
        guard let url = parts.url else { return [] }
        let json = try await fetchJSON(url, paced: true)
        let hits = json["hits"] as? [[String: Any]] ?? []
        return hits.compactMap(candidate(from:))
    }

    private static func candidate(from item: [String: Any]) -> GroceryCandidate? {
        let english = englishName(item)
        guard !english.isEmpty else { return nil }
        var copy = item
        copy["product_name"] = english
        if let brands = item["brands"] as? [String] {
            copy["brands"] = brands.joined(separator: ", ")
        } else if let brands = item["brands"] as? [Any] {
            copy["brands"] = brands.compactMap { $0 as? String }.joined(separator: ", ")
        }
        let code = string(item["code"])
        guard var product = parseOFF(copy, code: code) else { return nil }
        product.name = english
        let countries = (item["countries_tags"] as? [String]) ?? []
        let image = [item["image_front_small_url"], item["image_front_url"], item["image_url"]].contains { string($0).isEmpty == false }
        return GroceryCandidate(
            product: product,
            countries: countries,
            scans: doubleValue(item["unique_scans_n"]) ?? 0,
            popularity: doubleValue(item["popularity_key"]) ?? 0,
            hasImage: image,
            englishName: english
        )
    }

    private static func englishName(_ item: [String: Any]) -> String {
        let translated = string(item["product_name_en"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty { return translated }
        let name = string(item["product_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let language = string(item["lang"]).isEmpty ? string(item["lc"]) : string(item["lang"])
        guard language == "en", !name.isEmpty else { return "" }
        let accents = CharacterSet(charactersIn: "àâäéèêëïîôùûüçœ")
        if name.lowercased().unicodeScalars.contains(where: { accents.contains($0) }) { return "" }
        return name
    }

    private static func openFoodFactsSearch(_ query: String) async throws -> [GroceryCandidate] {
        var parts = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        parts.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "40"),
            URLQueryItem(name: "sort_by", value: "unique_scans_n"),
            URLQueryItem(name: "tagtype_0", value: "countries"),
            URLQueryItem(name: "tag_contains_0", value: "contains"),
            URLQueryItem(name: "tag_0", value: "united-states"),
            URLQueryItem(name: "fields", value: "code,product_name,product_name_en,brands,ingredients_text,additives_tags,nova_group,categories_tags,countries_tags,nutriments,serving_size,unique_scans_n,lang,image_front_url")
        ]
        guard let url = parts.url else { return [] }
        let json = try await fetchJSON(url, paced: true)
        let products = json["products"] as? [[String: Any]] ?? []
        return products.compactMap(candidate(from:))
    }

    private static func openFoodFactsCategory(_ category: String) async throws -> [Product] {
        var parts = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        parts.queryItems = [
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "tagtype_0", value: "categories"),
            URLQueryItem(name: "tag_contains_0", value: "contains"),
            URLQueryItem(name: "tag_0", value: category),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "8"),
            URLQueryItem(name: "fields", value: "code,product_name,brands,ingredients_text,additives_tags,nova_group,categories_tags,nutriments,serving_size")
        ]
        guard let url = parts.url else { return [] }
        let json = try await fetchJSON(url, paced: true)
        let products = json["products"] as? [[String: Any]] ?? []
        return products.compactMap { parseOFF($0, code: string($0["code"])) }
    }

    private static func parseOFF(_ item: [String: Any], code: String) -> Product? {
        let name = string(item["product_name"])
        guard !name.isEmpty else { return nil }
        let nutriments = item["nutriments"] as? [String: Any] ?? [:]
        let grams = grams(from: string(item["serving_size"]))
        let usedServing = nutriments["sugars_serving"] != nil || nutriments["sodium_serving"] != nil || nutriments["proteins_serving"] != nil
        let basis = usedServing || grams != nil ? "per serving" : "per 100 g"
        return Product(
            id: code.isEmpty ? "off-\(name)" : code,
            name: name,
            brand: string(item["brands"]),
            barcode: code,
            ingredients: string(item["ingredients_text"]),
            additiveTags: (item["additives_tags"] as? [String]) ?? [],
            categories: (item["categories_tags"] as? [String]) ?? [],
            nova: intValue(item["nova_group"]),
            kcal: nutrient(nutriments, serving: "energy-kcal_serving", hundred: "energy-kcal_100g", grams: grams),
            sugar: nutrient(nutriments, serving: "sugars_serving", hundred: "sugars_100g", grams: grams),
            addedSugar: nutrient(nutriments, serving: "added-sugars_serving", hundred: "added-sugars_100g", grams: grams),
            sodiumMg: sodium(nutriments, grams: grams),
            saturatedFat: nutrient(nutriments, serving: "saturated-fat_serving", hundred: "saturated-fat_100g", grams: grams),
            fiber: nutrient(nutriments, serving: "fiber_serving", hundred: "fiber_100g", grams: grams),
            protein: nutrient(nutriments, serving: "proteins_serving", hundred: "proteins_100g", grams: grams),
            basis: basis,
            serving: string(item["serving_size"]),
            source: "Open Food Facts",
            sourceDetail: "Open Food Facts contributors, Open Database License.",
            isSample: false
        )
    }

    private static func usda(query: String, barcode: String?) async throws -> Product? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "USDAAPIKey") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "DEMO_KEY"
        var parts = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!
        parts.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "dataType", value: "Branded"),
            URLQueryItem(name: "pageSize", value: "5"),
            URLQueryItem(name: "api_key", value: key)
        ]
        guard let url = parts.url else { return nil }
        let json: [String: Any]
        do {
            json = try await fetchJSON(url, paced: false)
        } catch FoodError.busy {
            throw FoodError.busy
        } catch {
            return nil
        }
        let foods = json["foods"] as? [[String: Any]] ?? []
        let chosen: [String: Any]?
        if let barcode {
            let digits = barcode.filter(\.isNumber)
            chosen = foods.first { string($0["gtinUpc"]).filter(\.isNumber) == digits } ?? foods.first
        } else {
            chosen = foods.first
        }
        guard let food = chosen else { return nil }
        let labels = food["labelNutrients"] as? [String: Any] ?? [:]
        let fdc = string(food["fdcId"])
        let code = string(food["gtinUpc"]).filter(\.isNumber)
        let brandName = string(food["brandName"])
        let brand = brandName.isEmpty ? string(food["brandOwner"]) : brandName
        return Product(
            id: code.isEmpty ? "usda-\(fdc)" : code,
            name: string(food["description"]),
            brand: brand,
            barcode: code,
            ingredients: string(food["ingredients"]),
            additiveTags: [],
            categories: [],
            nova: nil,
            kcal: label(labels, "calories"),
            sugar: label(labels, "sugars") ?? label(labels, "sugar"),
            addedSugar: label(labels, "addedSugar") ?? label(labels, "addedSugars"),
            sodiumMg: label(labels, "sodium"),
            saturatedFat: label(labels, "saturatedFat"),
            fiber: label(labels, "fiber"),
            protein: label(labels, "protein"),
            basis: "per serving",
            serving: [string(food["servingSize"]), string(food["servingSizeUnit"])].filter { !$0.isEmpty }.joined(separator: " "),
            source: "USDA FoodData Central",
            sourceDetail: "USDA FoodData Central branded foods. The demo key is fine for trying the app.",
            isSample: false
        )
    }

    private static func fetchJSON(_ url: URL, paced: Bool) async throws -> [String: Any] {
        if paced { await pace.wait() }
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FoodError.offline
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw FoodError.busy
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FoodError.bad
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func nutrient(_ n: [String: Any], serving: String, hundred: String, grams: Double?) -> Double? {
        if let value = doubleValue(n[serving]) { return value }
        guard let per = doubleValue(n[hundred]) else { return nil }
        if let grams, grams > 0 { return per * grams / 100 }
        return per
    }

    private static func sodium(_ n: [String: Any], grams: Double?) -> Double? {
        if let value = doubleValue(n["sodium_serving"]) { return value * 1000 }
        if let salt = doubleValue(n["salt_serving"]) { return salt / 2.5 * 1000 }
        if let value = doubleValue(n["sodium_100g"]) {
            let mg = value * 1000
            if let grams, grams > 0 { return mg * grams / 100 }
            return mg
        }
        return nil
    }

    private static func label(_ labels: [String: Any], _ key: String) -> Double? {
        guard let box = labels[key] as? [String: Any] else { return nil }
        return doubleValue(box["value"])
    }

    private static func grams(from serving: String) -> Double? {
        let lowered = serving.lowercased()
        guard lowered.contains("g"), !lowered.contains("mg") else { return nil }
        let number = lowered.split(whereSeparator: { !$0.isNumber && $0 != "." }).first
        return number.flatMap { Double($0) }
    }

    private static func barcodeCandidates(_ raw: String) -> [String] {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 8 else { return [] }
        var list = [digits]
        if digits.count == 12 { list.append("0" + digits) }
        if digits.count == 13, digits.hasPrefix("0") { list.append(String(digits.dropFirst())) }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func significantWords(_ text: String) -> [String] {
        let skip: Set<String> = ["the", "and", "with", "from", "food", "brand", "sample"]
        return text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 4 && !skip.contains($0) }
    }

    private static func string(_ any: Any?) -> String {
        if let text = any as? String { return text }
        if let number = any as? NSNumber { return number.stringValue }
        return ""
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let text = any as? String { return Int(text) }
        return nil
    }
}

enum FoodError: LocalizedError {
    case notFound
    case offline
    case busy
    case bad

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "We could not find that food in Open Food Facts or USDA FoodData Central. You can snap the label, and we will read it on this phone."
        case .offline:
            return "We could not reach the food database. Check your connection and try again."
        case .busy:
            return "The free USDA demo key is busy right now. Try again in a little while, or add your own free USDA key."
        case .bad:
            return "The food database sent an answer we could not read. Try again."
        }
    }
}

private actor Pace {
    private var last = Date.distantPast

    func wait() async {
        let gap = 0.75 - Date().timeIntervalSince(last)
        if gap > 0 {
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
        }
        last = Date()
    }
}
