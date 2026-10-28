import Foundation

enum ServiceCategory: String, Codable, CaseIterable, Identifiable {
    case lawn
    case moving

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lawn: return "Lawn care"
        case .moving: return "Moving"
        }
    }

    var symbol: String {
        switch self {
        case .lawn: return "leaf.fill"
        case .moving: return "shippingbox.fill"
        }
    }

    var defaultType: String { self == .moving ? "moving" : "mowing" }
}

struct ServiceType: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var category: ServiceCategory
    var symbol: String
}

enum ServiceCatalog {
    /// Offered in this build. Add a `ServiceType` here, a rate in `PricingRates.json`, and the id is live.
    static let active: [ServiceType] = [
        ServiceType(id: "mowing", title: "Mowing", category: .lawn, symbol: "leaf.fill"),
        ServiceType(id: "edging", title: "Edging", category: .lawn, symbol: "scissors"),
        ServiceType(id: "trimming", title: "Trimming", category: .lawn, symbol: "tree"),
        ServiceType(id: "leafCleanup", title: "Leaf cleanup", category: .lawn, symbol: "leaf"),
        ServiceType(id: "landscaping", title: "Landscaping", category: .lawn, symbol: "camera.macro"),
        ServiceType(id: "yardOther", title: "Other yard work", category: .lawn, symbol: "leaf.fill"),
        ServiceType(id: "moving", title: "Moving", category: .moving, symbol: "shippingbox.fill"),
    ]

    /// Not offered yet. They stay out of the picker until a rate and a screen are added.
    static let planned = ["pressureWashing", "gutters", "snowRemoval", "junkRemoval"]

    static func find(_ id: String) -> ServiceType? {
        active.first { $0.id == id }
    }

    static func ids(matching categories: [ServiceCategory]) -> [String] {
        active.filter { categories.contains($0.category) }.map(\.id)
    }

    static func categories(in ids: [String]) -> [ServiceCategory] {
        var seen: [ServiceCategory] = []
        for id in ids {
            guard let category = find(id)?.category, !seen.contains(category) else { continue }
            seen.append(category)
        }
        return seen
    }
}

enum UserRole: String, Codable {
    case customer
    case pro
}

enum JobStatus: String, Codable {
    case draft
    case posted
    case awaitingAcceptance
    case awaitingPayment
    case booked
    case inProgress
    case awaitingReview
    case disputed
    case approved
    case payoutProcessing
    case completed
    case canceled
    /// Older builds stored open listings under this name.
    case open
    case cancelled

    var isListed: Bool {
        self == .open || self == .posted || self == .awaitingAcceptance
    }

    var title: String {
        switch self {
        case .draft: return "Draft"
        case .posted: return "Posted"
        case .awaitingAcceptance, .open: return "Awaiting acceptance"
        case .awaitingPayment: return "Awaiting payment confirmation"
        case .booked: return "Booked"
        case .inProgress: return "In progress"
        case .awaitingReview: return "Awaiting customer review"
        case .disputed: return "Disputed"
        case .approved: return "Approved"
        case .payoutProcessing: return "Payout processing"
        case .completed: return "Completed"
        case .canceled, .cancelled: return "Canceled"
        }
    }
}

enum QuoteStatus: String, Codable {
    case sent
    case accepted
    case declined
}

struct UserRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var role: UserRole
    var email: String
    var displayName: String
    var zip: String
    var phoneVerified: Bool
    var businessName: String
    var categories: [ServiceCategory]
    var serviceZips: [String]
    var radiusMiles: Int = 25
    var latitude: Double?
    var longitude: Double?
    var rating: Double
    var reviewCount: Int
    var serviceTypes: [String] = []
    var identityVerified: Bool = false
    var payoutsReady: Bool = false
    var stripeAccountID: String = ""

    var canTakeJobs: Bool {
        role == .pro && phoneVerified && identityVerified && payoutsReady
    }

    func offers(_ job: JobRecord) -> Bool {
        if !serviceTypes.isEmpty {
            let type = job.serviceType.isEmpty ? job.category.defaultType : job.serviceType
            return serviceTypes.contains(type)
        }
        return categories.contains(job.category)
    }

    func reaches(_ job: JobRecord) -> Bool {
        guard offers(job) else { return false }
        if let latitude, let longitude, let jobLatitude = job.latitude, let jobLongitude = job.longitude {
            let miles = GeoPoint(latitude: latitude, longitude: longitude)
                .miles(to: GeoPoint(latitude: jobLatitude, longitude: jobLongitude))
            return miles <= Double(max(radiusMiles, 1))
        }
        return zip == job.zip || serviceZips.contains(job.zip)
    }

    var publicName: String {
        role == .pro && !businessName.isEmpty ? businessName : displayName
    }

    var coordinate: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}

struct JobDetails: Codable, Equatable {
    var lawnSize: String
    var lotSize: String = ""
    var rooms: Int
    var stairs: Bool
    var obstacles: String = ""
    var notes: String

    static let empty = JobDetails(lawnSize: "Medium", lotSize: "", rooms: 2, stairs: false, obstacles: "", notes: "")

    func summary(for category: ServiceCategory) -> String {
        switch category {
        case .lawn:
            let size = lawnSize.isEmpty || lawnSize == "Unknown" ? "Yard" : lawnSize
            return "\(size) yard"
        case .moving:
            return "\(rooms) room\(rooms == 1 ? "" : "s")\(stairs ? ", stairs" : "")"
        }
    }
}

struct JobRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var customerID: UUID
    var category: ServiceCategory
    var street: String
    var city: String
    var state: String
    var zip: String
    var latitude: Double?
    var longitude: Double?
    var scheduledOn: String
    var details: JobDetails
    var status: JobStatus
    var photoNames: [String]
    var createdAt: Date
    var serviceType: String = ""
    var offeredPriceCents: Int = 0
    var allowsMultiple: Bool = false
    var estimate: PriceEstimate? = nil
    var estimatedMinutes: Int = 0
    var listedUntil: Date? = nil

    var serviceTitle: String {
        ServiceCatalog.find(serviceType)?.title ?? category.title
    }

    var fullAddress: String { "\(street), \(city), \(state) \(zip)" }

    func place(exact: Bool) -> String {
        if exact, !street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fullAddress
        }
        return "Near \(city), \(state) \(zip)"
    }

    /// Copy shown to contractors who are not booked. Street is removed and the coordinate is shifted.
    func listingCopy() -> JobRecord {
        var copy = self
        guard !street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return copy }
        if let coordinate {
            let approx = coordinate.approximate(seed: id)
            copy.latitude = approx.latitude
            copy.longitude = approx.longitude
        }
        copy.street = ""
        return copy
    }

    var coordinate: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    func mapCoordinate(exact: Bool) -> GeoPoint? {
        guard let coordinate else { return nil }
        if exact { return coordinate }
        if street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return coordinate }
        return coordinate.approximate(seed: id)
    }
}

struct QuoteRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var jobID: UUID
    var proID: UUID
    var priceCents: Int
    var message: String
    var status: QuoteStatus
    var createdAt: Date
}

struct BookingRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var jobID: UUID
    var quoteID: UUID
    var proID: UUID
    var customerID: UUID
    var priceCents: Int
    var feeCents: Int
    var feePercent: Int
    var paidInApp: Bool
    var charge: PlatformCharge
    var repeatOfBookingID: UUID?
    var recurrence: String
    var createdAt: Date
}

struct ReportRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var reporterID: UUID
    var reportedUserID: UUID
    var jobID: UUID?
    var reason: String
    var createdAt: Date
}

struct MessageRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var jobID: UUID
    var proID: UUID
    var senderID: UUID
    var body: String
    var createdAt: Date
}

struct ReviewRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var jobID: UUID
    var proID: UUID
    var customerID: UUID
    var rating: Int
    var body: String
    var createdAt: Date
}

enum Money {
    static func string(cents: Int) -> String {
        let dollars = Decimal(cents) / 100
        return dollars.formatted(.currency(code: "USD"))
    }

    static func compact(cents: Int) -> String {
        let dollars = cents / 100
        return "$\(dollars)"
    }
}

struct NoticeRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var userID: UUID
    var title: String
    var body: String
    var jobID: UUID?
    var createdAt: Date
    var read: Bool
}

struct AuditRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var actorID: UUID
    var jobID: UUID?
    var action: String
    var detail: String
    var createdAt: Date
}

enum DayStamp {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    static func display(_ string: String) -> String {
        guard let date = date(from: string) else { return string }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
