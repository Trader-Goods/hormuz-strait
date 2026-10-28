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
}

enum UserRole: String, Codable {
    case customer
    case pro
}

enum JobStatus: String, Codable {
    case open
    case booked
    case completed
    case cancelled

    var title: String {
        switch self {
        case .open: return "Open"
        case .booked: return "Booked"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
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

    func reaches(_ job: JobRecord) -> Bool {
        guard categories.contains(job.category) else { return false }
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
    var rooms: Int
    var stairs: Bool
    var notes: String

    static let empty = JobDetails(lawnSize: "Medium", rooms: 2, stairs: false, notes: "")

    func summary(for category: ServiceCategory) -> String {
        switch category {
        case .lawn:
            return "\(lawnSize) lawn"
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

    var fullAddress: String { "\(street), \(city), \(state) \(zip)" }

    func place(exact: Bool) -> String {
        exact ? fullAddress : "Near \(city), \(state) \(zip)"
    }

    var coordinate: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    func mapCoordinate(exact: Bool) -> GeoPoint? {
        guard let coordinate else { return nil }
        return exact ? coordinate : coordinate.approximate(seed: id)
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
