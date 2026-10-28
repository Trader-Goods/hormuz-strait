import Foundation

/// Pricing is a swappable interface. TestFlight uses the rule estimator below.
/// A photo model can replace `PricingEngine.makeEstimator` later. No API key is read.
protocol PriceEstimator {
    func estimate(_ request: PricingRequest) async -> PricingResult
}

struct PricingRequest: Equatable {
    var serviceType: String
    var yardSize: String
    var lotSize: String
    var rooms: Int
    var obstacles: String
    var details: String
    var photoCount: Int
    var zip: String
}

struct PricingResult: Codable, Equatable {
    var questions: [String]
    var lowCents: Int?
    var highCents: Int?
    var suggestedCents: Int?
    var estimatedMinutes: Int?
    var difficulty: String
    var explanation: String
    var assumptions: [String]
    var rateName: String
    var disclaimer: String
    /// Always false for the rule estimator. A later model must keep this false unless a human priced the job.
    var isGuaranteedQuote: Bool

    var needsMoreInfo: Bool { suggestedCents == nil || !questions.isEmpty }
}

struct PriceEstimate: Codable, Equatable {
    var lowCents: Int
    var highCents: Int
    var suggestedCents: Int
    var estimatedMinutes: Int
    var difficulty: String
    var explanation: String
    var assumptions: [String]
    var rateName: String
    var disclaimer: String
    var isGuaranteedQuote: Bool

    init(_ result: PricingResult) {
        lowCents = result.lowCents ?? 0
        highCents = result.highCents ?? 0
        suggestedCents = result.suggestedCents ?? 0
        estimatedMinutes = result.estimatedMinutes ?? 0
        difficulty = result.difficulty
        explanation = result.explanation
        assumptions = result.assumptions
        rateName = result.rateName
        disclaimer = result.disclaimer
        isGuaranteedQuote = false
    }
}

struct ServiceRate: Codable, Equatable {
    var smallCents: Int
    var mediumCents: Int
    var largeCents: Int
    var smallMinutes: Int
    var mediumMinutes: Int
    var largeMinutes: Int
    var obstacleCents: Int
    var obstacleMinutes: Int

    func cents(for size: String) -> Int {
        switch size {
        case "small": return smallCents
        case "large": return largeCents
        default: return mediumCents
        }
    }

    func minutes(for size: String) -> Int {
        switch size {
        case "small": return smallMinutes
        case "large": return largeMinutes
        default: return mediumMinutes
        }
    }
}

struct RateRegion: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Empty matches nothing. The `default` region is the fallback. Prefixes let an owner add a region without shipping code.
    var zipPrefixes: [String]
    var services: [String: ServiceRate]
}

struct RegionalRateCard: Codable, Equatable {
    var disclaimer: String
    var regions: [RateRegion]

    func region(for zip: String) -> RateRegion? {
        let normalized = USAddress.normalizeZip(zip)
        if let match = regions.first(where: { region in
            !region.zipPrefixes.isEmpty && region.zipPrefixes.contains { normalized.hasPrefix($0) }
        }) {
            return match
        }
        return regions.first { $0.id == "default" } ?? regions.first
    }

    static let starter = RegionalRateCard(
        disclaimer: "Default regional rates are editable configuration. They are not a survey of local prices, and photos are not used to measure the job.",
        regions: [
            RateRegion(
                id: "default",
                name: "US default",
                zipPrefixes: [],
                services: [
                    "mowing": ServiceRate(smallCents: 5500, mediumCents: 8500, largeCents: 13000, smallMinutes: 45, mediumMinutes: 60, largeMinutes: 90, obstacleCents: 1500, obstacleMinutes: 15),
                    "edging": ServiceRate(smallCents: 3500, mediumCents: 5000, largeCents: 7500, smallMinutes: 30, mediumMinutes: 40, largeMinutes: 55, obstacleCents: 1000, obstacleMinutes: 10),
                    "trimming": ServiceRate(smallCents: 4500, mediumCents: 7000, largeCents: 11000, smallMinutes: 40, mediumMinutes: 55, largeMinutes: 80, obstacleCents: 2000, obstacleMinutes: 20),
                    "leafCleanup": ServiceRate(smallCents: 6000, mediumCents: 9500, largeCents: 15000, smallMinutes: 50, mediumMinutes: 75, largeMinutes: 110, obstacleCents: 2000, obstacleMinutes: 20),
                    "landscaping": ServiceRate(smallCents: 12000, mediumCents: 20000, largeCents: 35000, smallMinutes: 90, mediumMinutes: 150, largeMinutes: 240, obstacleCents: 4000, obstacleMinutes: 30),
                    "yardOther": ServiceRate(smallCents: 5000, mediumCents: 8000, largeCents: 12000, smallMinutes: 45, mediumMinutes: 60, largeMinutes: 90, obstacleCents: 1500, obstacleMinutes: 15),
                    "moving": ServiceRate(smallCents: 18000, mediumCents: 32000, largeCents: 48000, smallMinutes: 120, mediumMinutes: 210, largeMinutes: 300, obstacleCents: 5000, obstacleMinutes: 30),
                ]
            ),
        ]
    )
}

enum RateCardStore {
    static func load() -> RegionalRateCard {
        guard let url = Bundle.main.url(forResource: "PricingRates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let card = try? JSONDecoder().decode(RegionalRateCard.self, from: data),
              !card.regions.isEmpty else {
            return .starter
        }
        return card
    }
}

struct PricingEngine {
    var card: RegionalRateCard
    /// Replace this to plug in a photo model later. The replacement must return questions instead of inventing a measurement.
    var makeEstimator: (RegionalRateCard) -> any PriceEstimator

    init(card: RegionalRateCard = RateCardStore.load(), makeEstimator: @escaping (RegionalRateCard) -> any PriceEstimator = { RuleBasedEstimator(rates: $0) }) {
        self.card = card
        self.makeEstimator = makeEstimator
    }

    func estimate(_ request: PricingRequest) async -> PricingResult {
        await makeEstimator(card).estimate(request)
    }
}

struct RuleBasedEstimator: PriceEstimator {
    var rates: RegionalRateCard

    func estimate(_ request: PricingRequest) async -> PricingResult {
        estimateSync(request)
    }

    func estimateSync(_ request: PricingRequest) -> PricingResult {
        let region = rates.region(for: request.zip)
        let disclaimer = rates.disclaimer
        let rateName = region?.name ?? "US default"
        let service = ServiceCatalog.find(request.serviceType)
        var questions: [String] = []
        if service == nil {
            questions.append("Which service do you need?")
        }
        let rate = service.flatMap { region?.services[$0.id] }
        if service != nil && rate == nil {
            questions.append("That service is not on the rate card yet.")
        }
        if let service, service.category == .lawn {
            let size = request.yardSize.trimmingCharacters(in: .whitespacesAndNewlines)
            let lot = request.lotSize.trimmingCharacters(in: .whitespacesAndNewlines)
            if (size.isEmpty || size == "Unknown") && lot.isEmpty {
                questions.append("About how big is the yard, or what is the lot size?")
            }
        }
        if let service, service.category == .moving, request.rooms < 1 {
            questions.append("How many rooms are moving?")
        }
        let notes = request.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let obstacles = request.obstacles.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count < 8 && obstacles.isEmpty {
            questions.append("Add a short instruction or name any obstacles, such as a slope, pets, a gate, or stairs.")
        }
        guard let service, let rate else {
            return PricingResult(
                questions: questions.isEmpty ? ["Add a little more detail and estimate again."] : questions,
                lowCents: nil,
                highCents: nil,
                suggestedCents: nil,
                estimatedMinutes: nil,
                difficulty: "",
                explanation: "No price yet. Answer the questions above. The estimator will not guess.",
                assumptions: [],
                rateName: rateName,
                disclaimer: disclaimer,
                isGuaranteedQuote: false
            )
        }
        if !questions.isEmpty {
            return PricingResult(
                questions: questions,
                lowCents: nil,
                highCents: nil,
                suggestedCents: nil,
                estimatedMinutes: nil,
                difficulty: "",
                explanation: "No price yet. Answer the questions above. The estimator will not guess.",
                assumptions: [],
                rateName: rateName,
                disclaimer: disclaimer,
                isGuaranteedQuote: false
            )
        }
        var assumptions: [String] = []
        let size: String
        if service.category == .moving {
            if request.rooms <= 2 {
                size = "small"
            } else if request.rooms <= 4 {
                size = "medium"
            } else {
                size = "large"
            }
            assumptions.append("\(request.rooms) room\(request.rooms == 1 ? "" : "s") uses the \(size) moving rate.")
        } else if request.yardSize == "Small" {
            size = "small"
            assumptions.append("Small yard uses the small rate on the \(rateName) card.")
        } else if request.yardSize == "Large" {
            size = "large"
            assumptions.append("Large yard uses the large rate on the \(rateName) card.")
        } else if request.yardSize == "Medium" {
            size = "medium"
            assumptions.append("Medium yard uses the medium rate on the \(rateName) card.")
        } else {
            size = "medium"
            assumptions.append("The lot size was described in words, so the medium rate was used. This is not a measurement.")
        }
        var cents = rate.cents(for: size)
        var minutes = rate.minutes(for: size)
        if !obstacles.isEmpty {
            cents += rate.obstacleCents
            minutes += rate.obstacleMinutes
            assumptions.append("Obstacles add \(Money.string(cents: rate.obstacleCents)) and \(rate.obstacleMinutes) minutes from the rate card.")
        }
        if request.photoCount > 0 {
            assumptions.append("\(request.photoCount) photo\(request.photoCount == 1 ? "" : "s") will be shown to the contractor. Photos are not measured.")
        }
        let zip = USAddress.normalizeZip(request.zip)
        assumptions.append("ZIP \(zip.isEmpty ? "unknown" : zip) uses the \(rateName) card. That card is editable configuration, not live market data.")
        let low = cents * 80 / 100
        let high = cents * 120 / 100
        let difficulty = Self.difficulty(minutes: minutes, obstacles: !obstacles.isEmpty)
        let explanation = "\(service.title) estimate: \(Money.string(cents: low))–\(Money.string(cents: high)), suggested \(Money.string(cents: cents)). About \(minutes) minutes, \(difficulty). This is an estimate, not a guaranteed quote."
        return PricingResult(
            questions: [],
            lowCents: low,
            highCents: high,
            suggestedCents: cents,
            estimatedMinutes: minutes,
            difficulty: difficulty,
            explanation: explanation,
            assumptions: assumptions,
            rateName: rateName,
            disclaimer: disclaimer,
            isGuaranteedQuote: false
        )
    }

    private static func difficulty(minutes: Int, obstacles: Bool) -> String {
        let base: String
        if minutes < 50 {
            base = "Light"
        } else if minutes < 90 {
            base = "Typical"
        } else {
            base = "Heavy"
        }
        return obstacles ? "\(base), with obstacles" : base
    }
}
