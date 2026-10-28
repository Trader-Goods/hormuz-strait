import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var session: UserRecord?
    @Published var jobs: [JobRecord] = []
    @Published var quotes: [QuoteRecord] = []
    @Published var bookings: [BookingRecord] = []
    @Published var people: [UUID: UserRecord] = [:]
    @Published var errorMessage: String?
    @Published var busy = false
    @Published var notices: [NoticeRecord] = []
    @Published var showSampleJobs: Bool

    var showsSampleJobs: Bool { live && showSampleJobs }

    let live = BackendConfig.isLive
    private let api: any ContractorAPI

    init() {
        let stored = UserDefaults.standard.object(forKey: "contractor.showSampleJobs") as? Bool
        showSampleJobs = stored ?? true
        if BackendConfig.isLive {
            api = SupabaseBackend()
        } else {
            api = MockBackend()
        }
        Task { await restore() }
    }

    func setShowSampleJobs(_ on: Bool) async {
        showSampleJobs = on
        UserDefaults.standard.set(on, forKey: "contractor.showSampleJobs")
        await reload()
    }

    private func restore() async {
        session = try? await api.restore()
        if session != nil { await reload() }
    }

    func signIn(email: String, password: String) async {
        await run {
            self.session = try await self.api.signIn(email: email, password: password)
            await self.reload()
        }
    }

    func signUp(role: UserRole, name: String, email: String, password: String, zip: String, business: String, categories: [ServiceCategory], serviceZips: [String], acceptedTerms: Bool, radiusMiles: Int, serviceTypes: [String], phone: String) async {
        await run {
            self.session = try await self.api.signUp(role: role, name: name, email: email, password: password, zip: zip, business: business, categories: categories, serviceZips: serviceZips, acceptedTerms: acceptedTerms, radiusMiles: radiusMiles, serviceTypes: serviceTypes, phone: phone)
            await self.reload()
        }
    }

    func verifyPhone() async {
        await run {
            self.session = try await self.api.verifyPhone()
        }
    }

    func verifyIdentity() async {
        await run {
            self.session = try await self.api.verifyIdentity()
        }
    }

    func connectPayouts() async {
        await run {
            self.session = try await self.api.connectPayouts()
        }
    }

    func updateServiceArea(serviceTypes: [String], radiusMiles: Int) async {
        await run {
            self.session = try await self.api.updateServiceArea(serviceTypes: serviceTypes, radiusMiles: radiusMiles)
        }
    }

    func signOut() async {
        await api.signOut()
        session = nil
        jobs = []
        quotes = []
        bookings = []
    }

    func reload() async {
        guard session != nil else { return }
        await run { try await self.load() }
    }

    func reloadQuietly() async {
        guard session != nil else { return }
        try? await load()
    }

    private func load() async throws {
            self.people = [:]
            if self.session?.role == .customer {
                self.jobs = try await self.api.customerJobs()
            } else {
                self.jobs = try await self.api.openJobs()
            }
            self.quotes = []
            let mine = try await self.api.myQuotes()
            self.bookings = try await self.api.bookings()
            var ids = Set(self.jobs.map(\.id))
            ids.formUnion(mine.map(\.jobID))
            ids.formUnion(self.bookings.map(\.jobID))
            for id in ids where !self.jobs.contains(where: { $0.id == id }) {
                if let job = try await self.api.job(id: id) {
                    self.jobs.append(job)
                }
            }
            var all = mine
            for job in self.jobs {
                let rows = try await self.api.quotes(for: job.id)
                for row in rows where !all.contains(where: { $0.id == row.id }) {
                    all.append(row)
                }
            }
            self.quotes = all
            for id in self.bookings.map(\.jobID) {
                if let job = try await self.api.job(id: id) {
                    if let index = self.jobs.firstIndex(where: { $0.id == id }) {
                        self.jobs[index] = job
                    } else {
                        self.jobs.append(job)
                    }
                }
            }
            if self.showSampleJobs, let me = self.session, me.role == .pro, self.live {
                for sample in SampleJobs.near(me) where !self.jobs.contains(where: { $0.id == sample.id }) {
                    self.jobs.append(sample)
                }
            }
            self.notices = try await self.api.notices()
            let names = self.jobs.flatMap(\.photoNames)
            await self.api.cachePhotos(names)
            if let session = self.session {
                self.session = try await self.api.refresh(session)
            }
    }

    func postJob(category: ServiceCategory, street: String, city: String, state: String, zip: String, scheduledOn: String, details: JobDetails, photos: [Data], offeredPriceCents: Int, serviceType: String, estimate: PriceEstimate?, allowsMultiple: Bool, publish: Bool) async -> Bool {
        var ok = false
        var point = await SiteGeocoder.locate(street: street, city: city, state: state, zip: zip)
        if point == nil {
            point = await SiteGeocoder.locate(zip: zip)
        }
        await run {
            _ = try await self.api.postJob(category: category, street: street, city: city, state: state, zip: zip, latitude: point?.latitude, longitude: point?.longitude, scheduledOn: scheduledOn, details: details, photos: photos, offeredPriceCents: offeredPriceCents, serviceType: serviceType, estimate: estimate, allowsMultiple: allowsMultiple, publish: publish)
            ok = true
            await self.reload()
        }
        return ok
    }

    func acceptListing(jobID: UUID) async -> Bool {
        if SampleJobs.contains(jobID) {
            errorMessage = Self.describe(MarketplaceError.sampleJob)
            return false
        }
        var ok = false
        await run {
            _ = try await self.api.acceptListing(jobID: jobID)
            ok = true
            await self.reload()
        }
        return ok
    }

    func sendQuote(jobID: UUID, price: String, message: String) async -> Bool {
        if SampleJobs.contains(jobID) {
            errorMessage = Self.describe(MarketplaceError.sampleJob)
            return false
        }
        let digits = price.filter { $0.isNumber || $0 == "." }
        let dollars = Decimal(string: digits) ?? 0
        let cents = NSDecimalNumber(decimal: dollars * 100).intValue
        var ok = false
        await run {
            _ = try await self.api.sendQuote(jobID: jobID, priceCents: cents, message: message)
            ok = true
            await self.reload()
        }
        return ok
    }

    func book(quoteID: UUID) async -> Bool {
        var ok = false
        await run {
            _ = try await self.api.book(quoteID: quoteID)
            ok = true
            await self.reload()
        }
        return ok
    }

    func bookAgain(bookingID: UUID, scheduledOn: String, recurrence: String) async -> Bool {
        var ok = false
        await run {
            _ = try await self.api.bookAgain(bookingID: bookingID, scheduledOn: scheduledOn, recurrence: recurrence)
            ok = true
            await self.reload()
        }
        return ok
    }

    func report(userID: UUID, jobID: UUID?, reason: String) async -> Bool {
        var ok = false
        await run {
            try await self.api.report(userID: userID, jobID: jobID, reason: reason)
            ok = true
        }
        return ok
    }

    func rememberJobLocation(id: UUID, latitude: Double, longitude: Double) async {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].latitude = latitude
            jobs[index].longitude = longitude
        }
        await api.rememberJobLocation(id: id, latitude: latitude, longitude: longitude)
    }

    func rememberProLocation(latitude: Double, longitude: Double) async {
        session?.latitude = latitude
        session?.longitude = longitude
        await api.rememberProLocation(latitude: latitude, longitude: longitude)
    }

    func showsExactAddress(_ job: JobRecord) -> Bool {
        guard let me = session else { return false }
        if me.role == .customer { return job.customerID == me.id }
        return bookings.contains { booking in
            booking.jobID == job.id && booking.proID == me.id && booking.paidInApp
                && (booking.charge.status == "authorized" || booking.charge.status == "captured")
        }
    }

    func hasGuarantee(_ proID: UUID) -> Bool {
        bookings.contains { $0.proID == proID && $0.paidInApp }
    }

    func contactUnlocked(jobID: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return false }
        guard job.status == .booked || job.status == .completed else { return false }
        return booking(for: jobID)?.paidInApp == true
    }

    func review(jobID: UUID, rating: Int, body: String) async -> Bool {
        var ok = false
        await run {
            _ = try await self.api.review(jobID: jobID, rating: rating, body: body)
            ok = true
            await self.reload()
        }
        return ok
    }

    func messages(jobID: UUID, proID: UUID) async -> [MessageRecord] {
        (try? await api.messages(jobID: jobID, proID: proID)) ?? []
    }

    func sendMessage(jobID: UUID, proID: UUID, body: String) async -> [MessageRecord] {
        _ = try? await api.sendMessage(jobID: jobID, proID: proID, body: body)
        return await messages(jobID: jobID, proID: proID)
    }

    func person(_ id: UUID) async -> UserRecord? {
        if let cached = people[id] { return cached }
        let record = try? await api.user(id: id)
        if let record { people[id] = record }
        return record
    }

    func quotes(for jobID: UUID) -> [QuoteRecord] {
        quotes.filter { $0.jobID == jobID }.sorted { $0.priceCents < $1.priceCents }
    }

    func booking(for jobID: UUID) -> BookingRecord? {
        bookings.first { $0.jobID == jobID }
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await body()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? MarketplaceError {
        case .outsideArea:
            return USAddress.incompleteMessage
        case .quoteLimit:
            return "That offer could not be sent."
        case .taken:
            return "Another contractor already accepted this job."
        case .notReady:
            return "Confirm your identity and mark payouts ready before accepting a job. Stripe Connect is not live in this demo."
        case .notVerified:
            return "Verify your phone before posting or accepting."
        case .alreadyQuoted:
            return "You already sent an offer for this job."
        case .chatLocked:
            return "Chat opens after a quote is sent."
        case .invalid:
            return "Check the email, a password of at least 6 characters, and the rest of the form."
        case .closed:
            return "That job is no longer open."
        case .notPaid:
            return "Reviews are only for jobs booked in the app."
        case .termsRequired:
            return "Accept the Terms to create an account."
        case .confirmEmail:
            return "Check your email"
        case .sampleJob:
            return "Sample jobs are examples on this phone. They are not real customers."
        case .wrongAccount, .missing, .none:
            return "That could not be saved."
        }
    }
}
