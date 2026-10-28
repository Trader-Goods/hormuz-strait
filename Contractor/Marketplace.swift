import Foundation

enum RichlandCounty {
    /// ZIP codes that fall in Richland County, Ohio, around Mansfield.
    static let zips: Set<String> = [
        "44901", "44902", "44903", "44904", "44905", "44906", "44907",
        "44813", "44822", "44843", "44875", "44878",
    ]

    static func normalize(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return String(digits.prefix(5))
    }

    static func contains(_ raw: String) -> Bool {
        zips.contains(normalize(raw))
    }
}

enum LeadRules {
    static let maxQuotes = 3
}

enum BookingFee {
    static func feeCents(priceCents: Int, percent: Int = FeeSchedule.launch.standardPercent, minimumCents: Int = FeeSchedule.launch.minimumCents) -> Int {
        guard priceCents > 0 else { return 0 }
        let share = (priceCents * percent + 50) / 100
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
    var fees: FeeSchedule

    func user(_ id: UUID) -> UserRecord? {
        users.first { $0.user.id == id }?.user
    }

    func quotes(for jobID: UUID) -> [QuoteRecord] {
        quotes.filter { $0.jobID == jobID }.sorted { $0.priceCents < $1.priceCents }
    }

    func openJobs(for pro: UserRecord) -> [JobRecord] {
        jobs.filter { job in
            guard job.status == .open else { return false }
            guard pro.categories.contains(job.category) else { return false }
            guard pro.serviceZips.contains(job.zip) else { return false }
            let existing = quotes(for: job.id)
            if existing.count >= LeadRules.maxQuotes { return false }
            if existing.contains(where: { $0.proID == pro.id }) { return false }
            return true
        }
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
        acceptedTerms: Bool
    ) throws -> UserRecord {
        guard acceptedTerms else { throw MarketplaceError.termsRequired }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanZip = RichlandCounty.normalize(zip)
        guard cleanEmail.contains("@"), cleanEmail.contains("."), password.count >= 6, !cleanName.isEmpty else {
            throw MarketplaceError.invalid
        }
        guard RichlandCounty.contains(cleanZip) else { throw MarketplaceError.outsideArea }
        guard !users.contains(where: { $0.user.email == cleanEmail }) else { throw MarketplaceError.invalid }
        let chosenZips = serviceZips.isEmpty ? [cleanZip] : serviceZips.map(RichlandCounty.normalize).filter(RichlandCounty.contains)
        let record = UserRecord(
            id: UUID(),
            role: role,
            email: cleanEmail,
            displayName: cleanName,
            zip: cleanZip,
            phoneVerified: false,
            businessName: business.trimmingCharacters(in: .whitespacesAndNewlines),
            categories: role == .pro ? (categories.isEmpty ? [.lawn] : categories) : [],
            serviceZips: role == .pro ? (chosenZips.isEmpty ? [cleanZip] : chosenZips) : [cleanZip],
            rating: 0,
            reviewCount: 0
        )
        users.append(StoredUser(user: record, password: password))
        return record
    }

    mutating func verifyPhone(_ id: UUID) throws -> UserRecord {
        guard let index = users.firstIndex(where: { $0.user.id == id }) else { throw MarketplaceError.missing }
        users[index].user.phoneVerified = true
        return users[index].user
    }

    mutating func postJob(
        customerID: UUID,
        category: ServiceCategory,
        street: String,
        zip: String,
        scheduledOn: String,
        details: JobDetails,
        photoNames: [String]
    ) throws -> JobRecord {
        guard let customer = user(customerID), customer.role == .customer else { throw MarketplaceError.wrongAccount }
        guard customer.phoneVerified else { throw MarketplaceError.notVerified }
        let cleanZip = RichlandCounty.normalize(zip)
        let cleanStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RichlandCounty.contains(cleanZip), !cleanStreet.isEmpty else { throw MarketplaceError.outsideArea }
        let job = JobRecord(
            id: UUID(),
            customerID: customerID,
            category: category,
            street: cleanStreet,
            zip: cleanZip,
            scheduledOn: scheduledOn,
            details: details,
            status: .open,
            photoNames: photoNames,
            createdAt: Date()
        )
        jobs.append(job)
        return job
    }

    mutating func sendQuote(proID: UUID, jobID: UUID, priceCents: Int, message: String) throws -> QuoteRecord {
        guard let pro = user(proID), pro.role == .pro else { throw MarketplaceError.wrongAccount }
        guard pro.phoneVerified else { throw MarketplaceError.notVerified }
        guard priceCents > 0 else { throw MarketplaceError.invalid }
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw MarketplaceError.missing }
        guard job.status == .open else { throw MarketplaceError.closed }
        guard pro.categories.contains(job.category), pro.serviceZips.contains(job.zip) else {
            throw MarketplaceError.outsideArea
        }
        let existing = quotes(for: jobID)
        if existing.contains(where: { $0.proID == proID }) { throw MarketplaceError.alreadyQuoted }
        if existing.count >= LeadRules.maxQuotes { throw MarketplaceError.quoteLimit }
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
        return quote
    }

    mutating func book(customerID: UUID, quoteID: UUID) throws -> BookingRecord {
        guard let quoteIndex = quotes.firstIndex(where: { $0.id == quoteID }) else { throw MarketplaceError.missing }
        let quote = quotes[quoteIndex]
        guard let jobIndex = jobs.firstIndex(where: { $0.id == quote.jobID }) else { throw MarketplaceError.missing }
        guard jobs[jobIndex].customerID == customerID else { throw MarketplaceError.wrongAccount }
        guard jobs[jobIndex].status == .open else { throw MarketplaceError.closed }
        quotes[quoteIndex].status = .accepted
        for index in quotes.indices where quotes[index].jobID == quote.jobID && quotes[index].id != quote.id {
            quotes[index].status = .declined
        }
        jobs[jobIndex].status = .booked
        let booking = makeBooking(
            jobID: quote.jobID,
            quoteID: quote.id,
            proID: quote.proID,
            customerID: customerID,
            priceCents: quote.priceCents,
            percent: fees.standardPercent,
            repeatOf: nil,
            recurrence: ""
        )
        bookings.append(booking)
        return booking
    }

    mutating func bookAgain(customerID: UUID, bookingID: UUID, scheduledOn: String, recurrence: String) throws -> BookingRecord {
        guard let previous = bookings.first(where: { $0.id == bookingID }) else { throw MarketplaceError.missing }
        guard previous.customerID == customerID, previous.paidInApp else { throw MarketplaceError.notPaid }
        guard let source = jobs.first(where: { $0.id == previous.jobID }) else { throw MarketplaceError.missing }
        guard RichlandCounty.contains(source.zip) else { throw MarketplaceError.outsideArea }
        let job = JobRecord(
            id: UUID(),
            customerID: customerID,
            category: source.category,
            street: source.street,
            zip: source.zip,
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
            percent: fees.repeatPercent,
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
        let fee = BookingFee.feeCents(priceCents: priceCents, percent: percent, minimumCents: fees.minimumCents)
        let charge = PlatformCharge(
            amountCents: priceCents,
            applicationFeeCents: fee,
            proPayoutCents: max(0, priceCents - fee),
            currency: "usd",
            status: "stubbed",
            connectedAccountID: ""
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

    mutating func sendMessage(jobID: UUID, proID: UUID, senderID: UUID, body: String) throws -> MessageRecord {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MarketplaceError.invalid }
        guard let job = jobs.first(where: { $0.id == jobID }) else { throw MarketplaceError.missing }
        guard quotes.contains(where: { $0.jobID == jobID && $0.proID == proID }) else { throw MarketplaceError.chatLocked }
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
        if let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[jobIndex].status = .completed
        }
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
        let county = Array(RichlandCounty.zips).sorted()
        let mansfield = ["44901", "44902", "44903", "44904", "44905", "44906", "44907"]
        return MarketplaceBook(
            users: [
                StoredUser(user: UserRecord(id: maya, role: .customer, email: "maya@contractor.demo", displayName: "Maya Chen", zip: "44903", phoneVerified: true, businessName: "", categories: [], serviceZips: ["44903"], rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: sam, role: .customer, email: "sam@contractor.demo", displayName: "Sam Ortiz", zip: "44906", phoneVerified: true, businessName: "", categories: [], serviceZips: ["44906"], rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: greenline, role: .pro, email: "greenline@contractor.demo", displayName: "Avery Cole", zip: "44903", phoneVerified: true, businessName: "Greenline Lawn", categories: [.lawn], serviceZips: mansfield, rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: shelby, role: .pro, email: "shelby@contractor.demo", displayName: "Jordan Peck", zip: "44875", phoneVerified: true, businessName: "Shelby Yard Co", categories: [.lawn], serviceZips: ["44875", "44903", "44906", "44902"], rating: 0, reviewCount: 0), password: "demo1234"),
                StoredUser(user: UserRecord(id: movers, role: .pro, email: "northend@contractor.demo", displayName: "Riley Brooks", zip: "44902", phoneVerified: true, businessName: "North End Movers", categories: [.moving], serviceZips: county, rating: 0, reviewCount: 0), password: "demo1234"),
            ],
            jobs: [
                JobRecord(id: lawnJob, customerID: maya, category: .lawn, street: "418 Park Avenue West", zip: "44903", scheduledOn: "2026-11-06", details: JobDetails(lawnSize: "Medium", rooms: 0, stairs: false, notes: "Corner lot. Please edge the sidewalk and blow clippings off the drive."), status: .open, photoNames: [], createdAt: Date(timeIntervalSince1970: 1_761_600_000)),
                JobRecord(id: moveJob, customerID: sam, category: .moving, street: "90 Lexington Avenue", zip: "44906", scheduledOn: "2026-11-14", details: JobDetails(lawnSize: "", rooms: 2, stairs: true, notes: "Second-floor apartment to a ranch house in Ontario. Washer and a sofa."), status: .open, photoNames: [], createdAt: Date(timeIntervalSince1970: 1_761_700_000)),
                JobRecord(id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!, customerID: sam, category: .lawn, street: "12 Maple Street", zip: "44902", scheduledOn: "2026-11-08", details: JobDetails(lawnSize: "Small", rooms: 0, stairs: false, notes: "Front yard only. Gate is on the left."), status: .open, photoNames: [], createdAt: Date(timeIntervalSince1970: 1_761_720_000)),
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
    }
}
