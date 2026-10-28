import Foundation

enum USAddress {
    static let states: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL",
        "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME",
        "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH",
        "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI",
        "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
    ]
    static let incompleteMessage = "Please complete full address of job site"

    static func normalizeZip(_ raw: String) -> String {
        String(raw.filter(\.isNumber).prefix(5))
    }

    static func isValidZip(_ raw: String) -> Bool {
        let zip = normalizeZip(raw)
        return zip.count == 5 && zip != "00000"
    }

    static func isComplete(street: String, city: String, state: String, zip: String) -> Bool {
        !street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && states.contains(state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            && isValidZip(zip)
    }
}

struct GeoPoint: Equatable {
    var latitude: Double
    var longitude: Double

    func miles(to other: GeoPoint) -> Double {
        let earth = 3958.8
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earth * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Stable offset of about a quarter mile so the map does not reveal the street.
    func approximate(seed: UUID) -> GeoPoint {
        let bytes = seed.uuid
        let angle = Double(bytes.0) / 255 * 2 * .pi
        let meters = 0.25 * 1609.344
        let latitudeDelta = meters / 111_320 * cos(angle)
        let longitudeDelta = meters / (111_320 * cos(latitude * .pi / 180)) * sin(angle)
        return GeoPoint(latitude: latitude + latitudeDelta, longitude: longitude + longitudeDelta)
    }
}

enum DistanceLabel {
    static func text(miles: Double) -> String {
        if miles < 1 { return "under 1 mi" }
        let rounded = Int(miles.rounded())
        return "about \(max(rounded, 1)) mi"
    }
}

enum BookingFee {
    static func feeCents(priceCents: Int, percent: Int = FeeSchedule.launch.percent, minimumCents: Int = 0) -> Int {
        guard priceCents > 0, percent > 0 else { return 0 }
        let share = priceCents * percent / 100
        return max(minimumCents, share)
    }

    static func payoutCents(priceCents: Int, percent: Int) -> Int {
        max(0, priceCents - feeCents(priceCents: priceCents, percent: percent))
    }
}

enum MarketplaceError: Error, Equatable {
    case invalid
    case outsideArea
    case notVerified
    case missing
    case closed
    case alreadyQuoted
    case quoteLimit
    case taken
    case notReady
    case wrongAccount
    case chatLocked
    case notPaid
    case termsRequired
}

struct StoredUser: Codable, Equatable {
    var user: UserRecord
    var password: String
}

struct MarketplaceBook: Codable, Equatable {
    var users: [StoredUser]
    var jobs: [JobRecord]
    var quotes: [QuoteRecord]
    var bookings: [BookingRecord]
    var messages: [MessageRecord]
    var reviews: [ReviewRecord]
    var reports: [ReportRecord]
    var notices: [NoticeRecord] = []
    var audit: [AuditRecord] = []
    var fees: FeeSchedule

    func user(_ id: UUID) -> UserRecord? {
        users.first { $0.user.id == id }?.user
    }

    func quotes(for jobID: UUID) -> [QuoteRecord] {
        quotes.filter { $0.jobID == jobID }.sorted { $0.priceCents < $1.priceCents }
    }

    func canSeeExactAddress(_ job: JobRecord, viewer: UserRecord) -> Bool {
        if viewer.id == job.customerID { return true }
        return bookings.contains { booking in
            booking.jobID == job.id && booking.proID == viewer.id && booking.paidInApp
                && (booking.charge.status == "authorized" || booking.charge.status == "captured")
        }
    }

    func openJobs(for pro: UserRecord) -> [JobRecord] {
        jobs.filter { job in
            guard job.status.isListed else { return false }
            guard pro.reaches(job) else { return false }
            if let until = job.listedUntil, until < Date() { return false }
            if bookings.contains(where: { $0.jobID == job.id && $0.proID == pro.id && $0.charge.status != "failed" }) {
                return false
            }
            return true
        }
        .map { $0.listingCopy() }
        .sorted { $0.scheduledOn < $1.scheduledOn }
    }

    mutating func signUp(
        role: UserRole,
        name: String,
        email: String,
        password: String,
        zip: String,
        business: String,
        categories: [ServiceCategory],
        serviceZips: [String],
        acceptedTerms: Bool,
        radiusMiles: Int = 25,
        serviceTypes: [String] = []
    ) throws -> UserRecord {
        guard acceptedTerms else { throw MarketplaceError.termsRequired }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanZip = USAddress.normalizeZip(zip)
        guard cleanEmail.contains("@"), cleanEmail.contains("."), password.count >= 6, !cleanName.isEmpty else {
            throw MarketplaceError.invalid
        }
        guard USAddress.isValidZip(cleanZip) else { throw MarketplaceError.invalid }
        guard !users.contains(where: { $0.user.email == cleanEmail }) else { throw MarketplaceError.invalid }
        let chosenZips = serviceZips.map(USAddress.normalizeZip).filter(USAddress.isValidZip)
        let chosenTypes: [String]
        if role == .pro {
            chosenTypes = serviceTypes.isEmpty ? ServiceCatalog.ids(matching: categories.isEmpty ? [.lawn] : categories) : serviceTypes
        } else {
            chosenTypes = []
        }
        let chosenCategories = role == .pro ? ServiceCatalog.categories(in: chosenTypes) : []
        let record = UserRecord(
            id: UUID(),
            role: role,
            email: cleanEmail,
            displayName: cleanName,
            zip: cleanZip,
            phoneVerified: false,
            businessName: business.trimmingCharacters(in: .whitespacesAndNewlines),
            categories: chosenCategories.isEmpty && role == .pro ? [.lawn] : chosenCategories,
            serviceZips: role == .pro ? (chosenZips.isEmpty ? [cleanZip] : chosenZips) : [cleanZip],
            radiusMiles: role == .pro ? min(200, max(5, radiusMiles)) : 0,
            rating: 0,
            reviewCount: 0,
            serviceTypes: chosenTypes
        )
        users.append(StoredUser(user: record, password: password))
        return record
    }

    mutating func verifyPhone(_ id: UUID) throws -> UserRecord {
        guard let index = users.firstIndex(where: { $0.user.id == id }) else { throw MarketplaceError.missing }
        users[index].user.phoneVerified = true
        return users[index].user
    }

    mutating func verifyIdentity(_ id: UUID) throws -> UserRecord {
        guard let index = users.firstIndex(where: { $0.user.id == id }) else { throw MarketplaceError.missing }
        guard users[index].user.role == .pro else { throw MarketplaceError.wrongAccount }
        users[index].user.identityVerified = true
        log(actorID: id, jobID: nil, action: "identity_recorded", detail: "Identity confirmation recorded. This is not a live identity check.")
        return users[index].user
    }

    mutating func connectPayouts(_ id: UUID) throws -> UserRecord {
        guard let index = users.firstIndex(where: { $0.user.id == id }) else { throw MarketplaceError.missing }
        guard users[index].user.role == .pro else { throw MarketplaceError.wrongAccount }
        users[index].user.payoutsReady = true
        users[index].user.stripeAccountID = ""
        log(actorID: id, jobID: nil, action: "payouts_marked", detail: "Payouts marked ready without Stripe.")
        return users[index].user
    }

    mutating func updateServiceArea(proID: UUID, serviceTypes: [String], radiusMiles: Int) throws -> UserRecord {
        guard let index = users.firstIndex(where: { $0.user.id == proID }) else { throw MarketplaceError.missing }
        guard users[index].user.role == .pro else { throw MarketplaceError.wrongAccount }
        let types = serviceTypes.isEmpty ? users[index].user.serviceTypes : serviceTypes
        users[index].user.serviceTypes = types
        users[index].user.categories = ServiceCatalog.categories(in: types)
        users[index].user.radiusMiles = min(200, max(5, radiusMiles))
        return users[index].user
    }

    mutating func postJob(
        customerID: UUID,
        category: ServiceCategory,
        street: String,
        city: String,
        state: String,
        zip: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        scheduledOn: String,
        details: JobDetails,
        photoNames: [String],
        offeredPriceCents: Int = 0,
        serviceType: String = "",
        estimate: PriceEstimate? = nil,
        allowsMultiple: Bool = false,
        publish: Bool = true
    ) throws -> JobRecord {
        guard let customer = user(customerID), customer.role == .customer else { throw MarketplaceError.wrongAccount }
        guard customer.phoneVerified else { throw MarketplaceError.notVerified }
        let cleanStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanState = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanZip = USAddress.normalizeZip(zip)
        guard USAddress.isComplete(street: cleanStreet, city: cleanCity, state: cleanState, zip: cleanZip) else {
            throw MarketplaceError.outsideArea
        }
        let type = serviceType.isEmpty ? category.defaultType : serviceType
        let resolvedCategory = ServiceCatalog.find(type)?.category ?? category
        if publish && offeredPriceCents <= 0 { throw MarketplaceError.invalid }
        let created = Date()
        let job = JobRecord(
            id: UUID(),
            customerID: customerID,
            category: resolvedCategory,
            street: cleanStreet,
            city: cleanCity,
            state: cleanState,
            zip: cleanZip,
            latitude: latitude,
            longitude: longitude,
            scheduledOn: scheduledOn,
            details: details,
            status: publish ? .awaitingAcceptance : .draft,
            photoNames: photoNames,
            createdAt: created,
            serviceType: type,
            offeredPriceCents: offeredPriceCents,
            allowsMultiple: allowsMultiple,
            estimate: estimate,
            estimatedMinutes: estimate?.estimatedMinutes ?? 0,
            listedUntil: publish ? created.addingTimeInterval(14 * 24 * 3600) : nil
        )
        jobs.append(job)
        log(actorID: customerID, jobID: job.id, action: publish ? "posted" : "draft", detail: publish ? "Listing published at \(offeredPriceCents) cents." : "Draft saved.")
        return job
    }

    mutating func sendQuote(proID: UUID, jobID: UUID, priceCents: Int, message: String) throws -> QuoteRecord {
        guard let pro = user(proID), pro.role == .pro else { throw MarketplaceError.wrongAccount }
        guard pro.phoneVerified else { throw MarketplaceError.notVerified }
        guard pro.canTakeJobs else { throw MarketplaceError.notReady }
        guard priceCents > 0 else { throw MarketplaceError.invalid }
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw MarketplaceError.missing }
        guard job.status.isListed else { throw MarketplaceError.closed }
        guard pro.reaches(job) else { throw MarketplaceError.outsideArea }
        let existing = quotes(for: jobID)
        if existing.contains(where: { $0.proID == proID && $0.status != .declined }) { throw MarketplaceError.alreadyQuoted }
        let quote = QuoteRecord(
            id: UUID(),
            jobID: jobID,
            proID: proID,
            priceCents: priceCents,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .sent,
            createdAt: Date()
        )
        quotes.append(quote)
        notify(userID: job.customerID, title: "New offer", body: "\(pro.publicName) offered \(Money.string(cents: priceCents)).", jobID: jobID)
        log(actorID: proID, jobID: jobID, action: "counter_offer", detail: "Counter-offer \(priceCents) cents.")
        return quote
    }

    mutating func acceptListing(proID: UUID, jobID: UUID) throws -> BookingRecord {
        guard let pro = user(proID), pro.role == .pro else { throw MarketplaceError.wrongAccount }
        guard pro.phoneVerified else { throw MarketplaceError.notVerified }
        guard pro.canTakeJobs else { throw MarketplaceError.notReady }
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { throw MarketplaceError.missing }
        let job = jobs[jobIndex]
        guard job.status.isListed else { throw MarketplaceError.closed }
        guard job.offeredPriceCents > 0 else { throw MarketplaceError.invalid }
        guard pro.reaches(job) else { throw MarketplaceError.outsideArea }
        if !job.allowsMultiple && bookings.contains(where: { $0.jobID == jobID && $0.charge.status != "failed" }) {
            throw MarketplaceError.taken
        }
        let quoteID = upsertAcceptanceQuote(proID: proID, jobID: jobID, priceCents: job.offeredPriceCents, message: "Accepted the offered price.")
        return try claim(jobIndex: jobIndex, proID: proID, priceCents: job.offeredPriceCents, quoteID: quoteID)
    }

    mutating func book(customerID: UUID, quoteID: UUID) throws -> BookingRecord {
        guard let quoteIndex = quotes.firstIndex(where: { $0.id == quoteID }) else { throw MarketplaceError.missing }
        let quote = quotes[quoteIndex]
        guard let jobIndex = jobs.firstIndex(where: { $0.id == quote.jobID }) else { throw MarketplaceError.missing }
        guard jobs[jobIndex].customerID == customerID else { throw MarketplaceError.wrongAccount }
        guard jobs[jobIndex].status.isListed else { throw MarketplaceError.closed }
        guard quote.status == .sent else { throw MarketplaceError.closed }
        if !jobs[jobIndex].allowsMultiple && bookings.contains(where: { $0.jobID == quote.jobID && $0.charge.status != "failed" }) {
            throw MarketplaceError.taken
        }
        quotes[quoteIndex].status = .accepted
        return try claim(jobIndex: jobIndex, proID: quote.proID, priceCents: quote.priceCents, quoteID: quote.id)
    }

    mutating func bookAgain(customerID: UUID, bookingID: UUID, scheduledOn: String, recurrence: String) throws -> BookingRecord {
        guard let previous = bookings.first(where: { $0.id == bookingID }) else { throw MarketplaceError.missing }
        guard previous.customerID == customerID, previous.paidInApp else { throw MarketplaceError.notPaid }
        guard let source = jobs.first(where: { $0.id == previous.jobID }) else { throw MarketplaceError.missing }
        guard USAddress.isComplete(street: source.street, city: source.city, state: source.state, zip: source.zip) else {
            throw MarketplaceError.outsideArea
        }
        let job = JobRecord(
            id: UUID(),
            customerID: customerID,
            category: source.category,
            street: source.street,
            city: source.city,
            state: source.state,
            zip: source.zip,
            latitude: source.latitude,
            longitude: source.longitude,
            scheduledOn: scheduledOn,
            details: source.details,
            status: .booked,
            photoNames: [],
            createdAt: Date()
        )
        jobs.append(job)
        let quote = QuoteRecord(
            id: UUID(),
            jobID: job.id,
            proID: previous.proID,
            priceCents: previous.priceCents,
            message: "Repeat booking",
            status: .accepted,
            createdAt: Date()
        )
        quotes.append(quote)
        let cadence = recurrence == "weekly" || recurrence == "biweekly" ? recurrence : ""
        let booking = makeBooking(
            jobID: job.id,
            quoteID: quote.id,
            proID: previous.proID,
            customerID: customerID,
            priceCents: previous.priceCents,
            percent: fees.percent,
            repeatOf: previous.id,
            recurrence: cadence
        )
        bookings.append(booking)
        return booking
    }

    private mutating func makeBooking(
        jobID: UUID,
        quoteID: UUID,
        proID: UUID,
        customerID: UUID,
        priceCents: Int,
        percent: Int,
        repeatOf: UUID?,
        recurrence: String
    ) -> BookingRecord {
        let fee = BookingFee.feeCents(priceCents: priceCents, percent: percent)
        let charge = PlatformCharge(
            amountCents: priceCents,
            applicationFeeCents: fee,
            proPayoutCents: max(0, priceCents - fee),
            currency: "usd",
            status: "authorized",
            connectedAccountID: "",
            processingCents: 0
        )
        return BookingRecord(
            id: UUID(),
            jobID: jobID,
            quoteID: quoteID,
            proID: proID,
            customerID: customerID,
            priceCents: priceCents,
            feeCents: fee,
            feePercent: percent,
            paidInApp: true,
            charge: charge,
            repeatOfBookingID: repeatOf,
            recurrence: recurrence,
            createdAt: Date()
        )
    }

    private mutating func upsertAcceptanceQuote(proID: UUID, jobID: UUID, priceCents: Int, message: String) -> UUID {
        if let index = quotes.firstIndex(where: { $0.jobID == jobID && $0.proID == proID }) {
            quotes[index].status = .accepted
            quotes[index].priceCents = priceCents
            quotes[index].message = message
            return quotes[index].id
        }
        let quote = QuoteRecord(id: UUID(), jobID: jobID, proID: proID, priceCents: priceCents, message: message, status: .accepted, createdAt: Date())
        quotes.append(quote)
        return quote.id
    }

    private mutating func claim(jobIndex: Int, proID: UUID, priceCents: Int, quoteID: UUID) throws -> BookingRecord {
        let job = jobs[jobIndex]
        guard let pro = user(proID), pro.canTakeJobs else { throw MarketplaceError.notReady }
        if !job.allowsMultiple && bookings.contains(where: { $0.jobID == job.id && $0.charge.status != "failed" }) {
            throw MarketplaceError.taken
        }
        jobs[jobIndex].status = .awaitingPayment
        if !job.allowsMultiple {
            for index in quotes.indices where quotes[index].jobID == job.id && quotes[index].id != quoteID {
                quotes[index].status = .declined
            }
        }
        let booking = makeBooking(
            jobID: job.id,
            quoteID: quoteID,
            proID: proID,
            customerID: job.customerID,
            priceCents: priceCents,
            percent: fees.percent,
            repeatOf: nil,
            recurrence: ""
        )
        bookings.append(booking)
        jobs[jobIndex].status = job.allowsMultiple ? .awaitingAcceptance : .booked
        notify(userID: job.customerID, title: "Job accepted", body: "\(pro.publicName) accepted. The price is authorized, not captured, and the street is now available to that contractor.", jobID: job.id)
        notify(userID: proID, title: "You are booked", body: "The street address is available on this job. The customer has not been charged yet.", jobID: job.id)
        log(actorID: proID, jobID: job.id, action: "booked", detail: "Authorized \(priceCents) cents. Fee \(booking.feeCents) cents. Status authorized, not captured.")
        return booking
    }

    private mutating func notify(userID: UUID, title: String, body: String, jobID: UUID?) {
        notices.append(NoticeRecord(id: UUID(), userID: userID, title: title, body: body, jobID: jobID, createdAt: Date(), read: false))
    }

    private mutating func log(actorID: UUID, jobID: UUID?, action: String, detail: String) {
        audit.append(AuditRecord(id: UUID(), actorID: actorID, jobID: jobID, action: action, detail: detail, createdAt: Date()))
    }

    mutating func sendMessage(jobID: UUID, proID: UUID, senderID: UUID, body: String) throws -> MessageRecord {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MarketplaceError.invalid }
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw MarketplaceError.missing }
        let involved = quotes.contains(where: { $0.jobID == jobID && $0.proID == proID })
            || bookings.contains(where: { $0.jobID == jobID && $0.proID == proID })
        guard involved else { throw MarketplaceError.chatLocked }
        guard senderID == job.customerID || senderID == proID else { throw MarketplaceError.wrongAccount }
        let message = MessageRecord(
            id: UUID(),
            jobID: jobID,
            proID: proID,
            senderID: senderID,
            body: text,
            createdAt: Date()
        )
        messages.append(message)
        let recipient = senderID == job.customerID ? proID : job.customerID
        notify(userID: recipient, title: "New message", body: "You have a new message on a job.", jobID: jobID)
        return message
    }

    mutating func review(customerID: UUID, jobID: UUID, rating: Int, body: String) throws -> ReviewRecord {
        guard (1...5).contains(rating) else { throw MarketplaceError.invalid }
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw MarketplaceError.missing }
        guard job.customerID == customerID else { throw MarketplaceError.wrongAccount }
        guard job.status == .booked || job.status == .completed else { throw MarketplaceError.closed }
        guard !reviews.contains(where: { $0.jobID == jobID }) else { throw MarketplaceError.invalid }
        guard let booking = bookings.first(where: { $0.jobID == jobID }), booking.paidInApp else {
            throw MarketplaceError.notPaid
        }
        let review = ReviewRecord(
            id: UUID(),
            jobID: jobID,
            proID: booking.proID,
            customerID: customerID,
            rating: rating,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )
        reviews.append(review)
        log(actorID: customerID, jobID: jobID, action: "review", detail: "Review recorded. This does not approve the work or start a payout.")
        if let userIndex = users.firstIndex(where: { $0.user.id == booking.proID }) {
            let count = users[userIndex].user.reviewCount
            let total = users[userIndex].user.rating * Double(count) + Double(rating)
            users[userIndex].user.reviewCount = count + 1
            users[userIndex].user.rating = total / Double(count + 1)
        }
        return review
    }

    func hasGuarantee(_ proID: UUID) -> Bool {
        bookings.contains { booking in
            guard booking.proID == proID, booking.paidInApp else { return false }
            return jobs.contains { $0.id == booking.jobID && ($0.status == .booked || $0.status == .completed) }
        }
    }

    mutating func report(reporterID: UUID, reportedUserID: UUID, jobID: UUID?, reason: String) throws -> ReportRecord {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, user(reporterID) != nil, user(reportedUserID) != nil else { throw MarketplaceError.invalid }
        let report = ReportRecord(
            id: UUID(),
            reporterID: reporterID,
            reportedUserID: reportedUserID,
            jobID: jobID,
            reason: text,
            createdAt: Date()
        )
        reports.append(report)
        return report
    }

    static func demo() -> MarketplaceBook {
        let maya = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let sam = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let greenline = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let shelby = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let movers = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let lawnJob = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let moveJob = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let quoteA = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let quoteB = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        var book = MarketplaceBook(
            users: [
                StoredUser(user: UserRecord(id: maya, role: .customer, email: "maya@contractor.demo", displayName: "Maya Chen", zip: "44903", phoneVerified: true, businessName: "", categories: [], serviceZips: ["44903"], radiusMiles: 0, latitude: 40.758, longitude: -82.516, rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: sam, role: .customer, email: "sam@contractor.demo", displayName: "Sam Ortiz", zip: "44906", phoneVerified: true, businessName: "", categories: [], serviceZips: ["44906"], radiusMiles: 0, latitude: 40.760, longitude: -82.590, rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: greenline, role: .pro, email: "greenline@contractor.demo", displayName: "Avery Cole", zip: "44903", phoneVerified: true, businessName: "Greenline Lawn", categories: [.lawn], serviceZips: ["44903"], radiusMiles: 25, latitude: 40.758, longitude: -82.516, rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: shelby, role: .pro, email: "shelby@contractor.demo", displayName: "Jordan Peck", zip: "44875", phoneVerified: true, businessName: "Shelby Yard Co", categories: [.lawn], serviceZips: ["44875"], radiusMiles: 30, latitude: 40.881, longitude: -82.662, rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: movers, role: .pro, email: "northend@contractor.demo", displayName: "Riley Brooks", zip: "44902", phoneVerified: true, businessName: "North End Movers", categories: [.moving], serviceZips: ["44902"], radiusMiles: 40, latitude: 40.770, longitude: -82.520, rating: 0, reviewCount: 0), password: "demo1234"),
            ],
            jobs: [
                JobRecord(id: lawnJob, customerID: maya, category: .lawn, street: "418 Park Avenue West", city: "Mansfield", state: "OH", zip: "44903", latitude: 40.7584, longitude: -82.5290, scheduledOn: "2026-11-06", details: JobDetails(lawnSize: "Medium", rooms: 0, stairs: false, notes: "Corner lot. Please edge the sidewalk and blow clippings off the drive."), status: .open, photoNames: [], createdAt: Date(timeIntervalSince1970: 1_761_600_000)),
                JobRecord(id: moveJob, customerID: sam, category: .moving, street: "90 Lexington Avenue", city: "Ontario", state: "OH", zip: "44906", latitude: 40.7597, longitude: -82.5903, scheduledOn: "2026-11-14", details: JobDetails(lawnSize: "", rooms: 2, stairs: true, notes: "Second-floor apartment to a ranch house in Ontario. Washer and a sofa."), status: .open, photoNames: [], createdAt: Date(timeIntervalSince1970: 1_761_700_000)),
                JobRecord(id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!, customerID: sam, category: .lawn, street: "12 Maple Street", city: "Mansfield", state: "OH", zip: "44902", latitude: 40.7695, longitude: -82.5482, scheduledOn: "2026-11-08", details: JobDetails(lawnSize: "Small", rooms: 0, stairs: false, notes: "Front yard only. Gate is on the left."), status: .open, photoNames: [], createdAt: Date(timeIntervalSince1970: 1_761_720_000)),
            ],
            quotes: [
                QuoteRecord(id: quoteA, jobID: lawnJob, proID: greenline, priceCents: 8500, message: "Thursday morning works. Mow, edge, and blow the walk.", status: .sent, createdAt: Date(timeIntervalSince1970: 1_761_610_000)),
                QuoteRecord(id: quoteB, jobID: lawnJob, proID: shelby, priceCents: 11000, message: "We can be there Friday. Includes hedge trim along the porch.", status: .sent, createdAt: Date(timeIntervalSince1970: 1_761_640_000)),
            ],
            bookings: [],
            messages: [
                MessageRecord(id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!, jobID: lawnJob, proID: greenline, senderID: greenline, body: "We can start around 9 if the grass is dry.", createdAt: Date(timeIntervalSince1970: 1_761_620_000)),
            ],
            reviews: [],
            reports: [],
            fees: .launch
        )
        let estimator = RuleBasedEstimator(rates: .starter)
        for index in book.users.indices where book.users[index].user.role == .pro {
            book.users[index].user.identityVerified = true
            book.users[index].user.payoutsReady = true
            book.users[index].user.serviceTypes = ServiceCatalog.ids(matching: book.users[index].user.categories)
        }
        for index in book.jobs.indices {
            let job = book.jobs[index]
            let type = job.category == .moving ? "moving" : (job.street.contains("Maple") ? "edging" : "mowing")
            let obstacles = job.details.stairs ? "Stairs" : job.details.obstacles
            let result = estimator.estimateSync(PricingRequest(
                serviceType: type,
                yardSize: job.details.lawnSize.isEmpty ? "Unknown" : job.details.lawnSize,
                lotSize: job.details.lotSize,
                rooms: job.details.rooms,
                obstacles: obstacles,
                details: job.details.notes,
                photoCount: 0,
                zip: job.zip
            ))
            book.jobs[index].serviceType = type
            book.jobs[index].status = .awaitingAcceptance
            book.jobs[index].listedUntil = Date(timeIntervalSince1970: 1_830_000_000)
            book.jobs[index].offeredPriceCents = result.suggestedCents ?? 0
            book.jobs[index].estimatedMinutes = result.estimatedMinutes ?? 0
            if result.suggestedCents != nil {
                book.jobs[index].estimate = PriceEstimate(result)
            }
            if !obstacles.isEmpty {
                book.jobs[index].details.obstacles = obstacles
            }
        }
        return book
    }
}
