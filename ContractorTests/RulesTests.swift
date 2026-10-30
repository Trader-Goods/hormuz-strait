import XCTest
@testable import Contractor

final class RulesTests: XCTestCase {
    func testAnyFiveDigitUSZipIsAccepted() throws {
        XCTAssertTrue(USAddress.isValidZip("44903"))
        XCTAssertTrue(USAddress.isValidZip("44903-1205"))
        XCTAssertTrue(USAddress.isValidZip("43215"))
        XCTAssertTrue(USAddress.isValidZip("02139"))
        XCTAssertFalse(USAddress.isValidZip("449"))
        XCTAssertFalse(USAddress.isValidZip("00000"))
        var book = MarketplaceBook.demo()
        let user = try book.signUp(
            role: .customer, name: "Alex", email: "alex@example.com", password: "secret1",
            zip: "02139", business: "", categories: [], serviceZips: [], acceptedTerms: true
        )
        XCTAssertEqual(user.zip, "02139")
    }

    func testBookingFeeIsFivePercent() {
        XCTAssertEqual(FeeSchedule.launch.percent, 5)
        XCTAssertEqual(BookingFee.feeCents(priceCents: 8_500), 425)
        XCTAssertEqual(BookingFee.feeCents(priceCents: 2_000), 100)
        XCTAssertEqual(BookingFee.feeCents(priceCents: 0), 0)
        XCTAssertEqual(BookingFee.payoutCents(priceCents: 8_500, percent: 5), 8_075)
    }

    func testOneAcceptWinsUnlessTheCustomerAllowsMore() throws {
        var book = MarketplaceBook.demo()
        let job = try XCTUnwrap(book.jobs.first { $0.street.contains("Park") })
        let greenline = try XCTUnwrap(book.users.first { $0.user.email == "greenline@contractor.demo" }?.user)
        let first = try book.acceptListing(proID: greenline.id, jobID: job.id)
        XCTAssertEqual(first.feePercent, 5)
        XCTAssertEqual(first.charge.status, "authorized")
        XCTAssertEqual(book.bookings.filter { $0.jobID == job.id }.count, 1)
        let other = try readyPro(&book, email: "pat@example.com", categories: [.lawn])
        XCTAssertThrowsError(try book.acceptListing(proID: other.id, jobID: job.id))
        var shared = MarketplaceBook.demo()
        let index = try XCTUnwrap(shared.jobs.firstIndex { $0.street.contains("Maple") })
        shared.jobs[index].allowsMultiple = true
        let maple = shared.jobs[index]
        let firstPro = try readyPro(&shared, email: "pat@example.com", categories: [.lawn])
        let secondPro = try readyPro(&shared, email: "casey@example.com", categories: [.lawn])
        try place(&shared, proID: firstPro.id, near: maple)
        try place(&shared, proID: secondPro.id, near: maple)
        _ = try shared.acceptListing(proID: firstPro.id, jobID: maple.id)
        _ = try shared.acceptListing(proID: secondPro.id, jobID: maple.id)
        XCTAssertEqual(shared.bookings.filter { $0.jobID == maple.id }.count, 2)
        XCTAssertTrue(shared.jobs[index].status.isListed)
    }

    func testIncompleteJobSiteAddressIsRejected() throws {
        var book = MarketplaceBook.demo()
        let customer = try XCTUnwrap(book.users.first { $0.user.email == "maya@contractor.demo" }?.user)
        XCTAssertEqual(USAddress.incompleteMessage, "Please complete full address of job site")
        XCTAssertThrowsError(try book.postJob(
            customerID: customer.id, category: .lawn, street: "1 High Street", city: "", state: "OH", zip: "43215",
            scheduledOn: "2026-12-01", details: .empty, photoNames: []
        )) { error in
            XCTAssertEqual(error as? MarketplaceError, .outsideArea)
        }
    }

    func testOpenPinsAreOffsetAboutAQuarterMile() {
        let home = GeoPoint(latitude: 40.7584, longitude: -82.5290)
        let id = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let hidden = home.approximate(seed: id)
        XCTAssertEqual(home.miles(to: hidden), 0.25, accuracy: 0.02)
        XCTAssertEqual(hidden, home.approximate(seed: id))
        let job = JobRecord(
            id: id, customerID: UUID(), category: .lawn, street: "418 Park Avenue West", city: "Mansfield", state: "OH",
            zip: "44903", latitude: home.latitude, longitude: home.longitude, scheduledOn: "2026-11-06",
            details: .empty, status: .open, photoNames: [], createdAt: Date()
        )
        XCTAssertEqual(job.place(exact: false), "Near Mansfield, OH 44903")
        XCTAssertEqual(job.place(exact: true), "418 Park Avenue West, Mansfield, OH 44903")
        XCTAssertEqual(job.mapCoordinate(exact: true)?.latitude, home.latitude)
        XCTAssertEqual(job.mapCoordinate(exact: true)?.longitude, home.longitude)
        XCTAssertEqual(job.mapCoordinate(exact: false)?.miles(to: home) ?? 0, 0.25, accuracy: 0.02)
        XCTAssertEqual(DistanceLabel.text(miles: 0.4), "under 1 mi")
        XCTAssertEqual(DistanceLabel.text(miles: 4.2), "about 4 mi")
    }

    func testServiceRadiusMatchesJobsNationwide() throws {
        var book = MarketplaceBook.demo()
        let pro = try book.signUp(
            role: .pro, name: "Alex", email: "alex@example.com", password: "secret1",
            zip: "43215", business: "Alex Lawn", categories: [.lawn], serviceZips: ["43215"],
            acceptedTerms: true, radiusMiles: 10, phone: "419-555-0191"
        )
        _ = try book.verifyPhone(pro.id)
        let index = try XCTUnwrap(book.users.firstIndex { $0.user.id == pro.id })
        book.users[index].user.latitude = 39.9612
        book.users[index].user.longitude = -82.9988
        let maya = try XCTUnwrap(book.users.first { $0.user.email == "maya@contractor.demo" }?.user)
        let near = try book.postJob(
            customerID: maya.id, category: .lawn, street: "1 Capitol Square", city: "Columbus", state: "OH", zip: "43215",
            latitude: 39.9615, longitude: -82.9990, scheduledOn: "2026-12-01", details: .empty, photoNames: [], offeredPriceCents: 8_500, serviceType: "mowing"
        )
        XCTAssertTrue(try XCTUnwrap(book.user(pro.id)).reaches(near))
        let far = try XCTUnwrap(book.jobs.first { $0.city == "Mansfield" && $0.category == .lawn })
        XCTAssertFalse(try XCTUnwrap(book.user(pro.id)).reaches(far))
        XCTAssertTrue(book.openJobs(for: try XCTUnwrap(book.user(pro.id))).contains { $0.id == near.id })
    }

    func testChatHidesContactDetailsUntilBooking() {
        let samples = [
            "Text me at 419-555-1212",
            "maya@example.com",
            "See https://example.com/job",
            "I'm on @lawnpros",
            "four one nine five five five",
            "four-one-nine",
        ]
        for sample in samples {
            let hidden = ContactFilter.display(sample, unlocked: false)
            XCTAssertTrue(hidden.masked, sample)
            XCTAssertFalse(hidden.text.contains("419"), sample)
            XCTAssertFalse(hidden.text.contains("@"), sample)
            let open = ContactFilter.display(sample, unlocked: true)
            XCTAssertEqual(open.text, sample)
            XCTAssertFalse(open.masked)
        }
        let plain = ContactFilter.display("Thursday morning works.", unlocked: false)
        XCTAssertFalse(plain.masked)
        XCTAssertEqual(plain.text, "Thursday morning works.")
    }

    func testInAppPaymentKeepsTheFeeAndRepeatBookingsCostLess() throws {
        var book = MarketplaceBook.demo()
        let quote = try XCTUnwrap(book.quotes.first)
        let job = try XCTUnwrap(book.jobs.first { $0.id == quote.jobID })
        let first = try book.book(customerID: job.customerID, quoteID: quote.id)
        XCTAssertTrue(first.paidInApp)
        XCTAssertEqual(first.feePercent, 5)
        XCTAssertEqual(first.charge.status, "authorized")
        XCTAssertEqual(first.charge.processingCents, 0)
        XCTAssertEqual(first.charge.applicationFeeCents, 425)
        XCTAssertEqual(first.charge.proPayoutCents, 8_500 - 425)
        XCTAssertNotEqual(book.jobs.first { $0.id == job.id }?.status, .completed)
        XCTAssertTrue(book.hasGuarantee(quote.proID))
        let again = try book.bookAgain(customerID: job.customerID, bookingID: first.id, scheduledOn: "2026-11-20", recurrence: "weekly")
        XCTAssertEqual(again.feePercent, 5)
        XCTAssertEqual(again.recurrence, "weekly")
        XCTAssertEqual(again.charge.amountCents, first.priceCents)
        XCTAssertEqual(again.charge.applicationFeeCents, BookingFee.feeCents(priceCents: first.priceCents, percent: 5))
        book.bookings[book.bookings.firstIndex { $0.id == first.id }!].paidInApp = false
        XCTAssertThrowsError(try book.review(customerID: job.customerID, jobID: job.id, rating: 5, body: "Great")) { error in
            XCTAssertEqual(error as? MarketplaceError, .notPaid)
        }
    }

    func testRuleEstimatorAsksInsteadOfGuessingAndUsesTheRateCard() {
        let estimator = RuleBasedEstimator(rates: .starter)
        let missing = estimator.estimateSync(PricingRequest(
            serviceType: "mowing", yardSize: "Unknown", lotSize: "", rooms: 0, obstacles: "",
            details: "Hi", photoCount: 2, zip: "94110"
        ))
        XCTAssertNil(missing.suggestedCents)
        XCTAssertFalse(missing.questions.isEmpty)
        XCTAssertFalse(missing.isGuaranteedQuote)
        let priced = estimator.estimateSync(PricingRequest(
            serviceType: "mowing", yardSize: "Medium", lotSize: "", rooms: 0, obstacles: "",
            details: "Please mow the front and back.", photoCount: 1, zip: "94110"
        ))
        XCTAssertEqual(priced.suggestedCents, 8_500)
        XCTAssertEqual(priced.lowCents, 6_800)
        XCTAssertEqual(priced.highCents, 10_200)
        XCTAssertEqual(priced.estimatedMinutes, 60)
        XCTAssertEqual(priced.rateName, "US default")
        XCTAssertTrue(priced.disclaimer.contains("not a survey"))
        XCTAssertFalse(priced.isGuaranteedQuote)
        XCTAssertTrue(priced.assumptions.contains { $0.contains("Photos are not measured") })
        XCTAssertTrue(priced.assumptions.contains { $0.contains("not live market data") })
        var card = RegionalRateCard.starter
        card.regions.insert(RateRegion(id: "bay", name: "Bay config", zipPrefixes: ["941"], services: card.regions[0].services), at: 0)
        let bay = RuleBasedEstimator(rates: card).estimateSync(PricingRequest(
            serviceType: "mowing", yardSize: "Medium", lotSize: "", rooms: 0, obstacles: "",
            details: "Please mow the front and back.", photoCount: 0, zip: "94110"
        ))
        XCTAssertEqual(bay.rateName, "Bay config")
        XCTAssertEqual(bay.suggestedCents, 8_500)
    }

    func testMarketplaceHidesTheStreetUntilAnAuthorizedBooking() throws {
        var book = MarketplaceBook.demo()
        let original = try XCTUnwrap(book.jobs.first { $0.street.contains("Park") })
        let greenline = try XCTUnwrap(book.user(UUID(uuidString: "20000000-0000-0000-0000-000000000001")!))
        let listed = try XCTUnwrap(book.openJobs(for: greenline).first { $0.id == original.id })
        XCTAssertEqual(listed.street, "")
        XCTAssertEqual(listed.place(exact: true), "Near Mansfield, OH 44903")
        let shifted = try XCTUnwrap(listed.coordinate)
        let home = try XCTUnwrap(original.coordinate)
        XCTAssertEqual(home.miles(to: shifted), 0.25, accuracy: 0.02)
        let fresh = try book.signUp(role: .pro, name: "New", email: "new@example.com", password: "secret1", zip: "44903", business: "New Yard", categories: [.lawn], serviceZips: ["44903"], acceptedTerms: true, phone: "419-555-0192")
        _ = try book.verifyPhone(fresh.id)
        XCTAssertThrowsError(try book.acceptListing(proID: fresh.id, jobID: original.id)) { error in
            XCTAssertEqual(error as? MarketplaceError, .notReady)
        }
        _ = try book.acceptListing(proID: greenline.id, jobID: original.id)
        XCTAssertTrue(book.canSeeExactAddress(original, viewer: greenline))
        let stored = try XCTUnwrap(book.jobs.first { $0.id == original.id })
        XCTAssertEqual(stored.street, original.street)
        XCTAssertFalse(book.openJobs(for: greenline).contains { $0.id == original.id })
    }

    func testSampleJobsStayOnThePhoneAndHideTheStreet() {
        let pro = UserRecord(
            id: UUID(), role: .pro, email: "pro@example.com", displayName: "Pat", zip: "94110",
            phoneVerified: true, businessName: "Pat Yard", categories: [.lawn, .moving], serviceZips: ["94110"],
            radiusMiles: 25, latitude: 37.76, longitude: -122.42, rating: 0, reviewCount: 0,
            serviceTypes: ServiceCatalog.ids(matching: [.lawn, .moving]), identityVerified: true, payoutsReady: true
        )
        let samples = SampleJobs.near(pro)
        XCTAssertEqual(samples.count, 3)
        for sample in samples {
            XCTAssertTrue(SampleJobs.contains(sample.id))
            XCTAssertEqual(sample.street, "")
            XCTAssertTrue(sample.details.notes.hasPrefix("SAMPLE — not a real customer."))
            XCTAssertTrue(pro.reaches(sample))
        }
        let price = samples[0].publicPriceCopy()
        XCTAssertEqual(price.street, "")
        XCTAssertEqual(price.details.notes, "")
        XCTAssertEqual(price.photoNames, [])
        XCTAssertEqual(price.customerID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertTrue(JobStatus.posted.isListed)
        XCTAssertTrue(JobStatus.awaitingAcceptance.isListed)
        XCTAssertFalse(JobStatus.booked.isListed)
        XCTAssertFalse(JobStatus.inProgress.isListed)
        XCTAssertFalse(JobStatus.completed.isListed)
        XCTAssertFalse(JobStatus.canceled.isListed)
        XCTAssertFalse(JobStatus.cancelled.isListed)
        XCTAssertFalse(JobStatus.disputed.isListed)
        XCTAssertFalse(JobStatus.approved.isListed)
        XCTAssertEqual(AppModel.describe(MarketplaceError.confirmEmail), "Check your email")
        XCTAssertTrue(AuthCallback.needsEmailConfirmation("Email not confirmed"))
        XCTAssertTrue(AuthCallback.needsEmailConfirmation("email_not_confirmed"))
        XCTAssertFalse(AuthCallback.needsEmailConfirmation("Invalid login credentials"))
        XCTAssertFalse(AuthCallback.needsEmailConfirmation("new row violates row-level security policy"))
        XCTAssertEqual(AppModel.describe(MarketplaceError.server("new row violates row-level security policy")), "new row violates row-level security policy")
        XCTAssertEqual(AuthCallback.redirect, "contractorpros://auth-callback")
        let url = URL(string: "contractorpros://auth-callback#access_token=abc&refresh_token=def&type=signup")!
        let params = AuthCallback.params(from: url)
        XCTAssertEqual(params["access_token"], "abc")
        XCTAssertEqual(params["refresh_token"], "def")
        let path = AuthCallback.signupPath()
        let components = URLComponents(string: "https://example.com" + path)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "redirect_to" }?.value, AuthCallback.redirect)
    }

    func testContractorPhoneIsStoredAndHiddenUntilBooking() throws {
        XCTAssertEqual(USPhone.e164("(419) 555-0100"), "+14195550100")
        XCTAssertEqual(USPhone.e164("1-419-555-0100"), "+14195550100")
        XCTAssertEqual(USPhone.e164("+1 419 555 0100"), "+14195550100")
        XCTAssertNil(USPhone.e164("555-0100"))
        XCTAssertNil(USPhone.e164("123-555-0100"))
        XCTAssertEqual(USPhone.display("+14195550100"), "(419) 555-0100")
        var book = MarketplaceBook.demo()
        XCTAssertThrowsError(try book.signUp(
            role: .pro, name: "No Phone", email: "nophone@example.com", password: "secret1",
            zip: "44903", business: "None", categories: [.lawn], serviceZips: ["44903"], acceptedTerms: true
        ))
        let pro = try book.signUp(
            role: .pro, name: "With Phone", email: "withphone@example.com", password: "secret1",
            zip: "44903", business: "Yard", categories: [.lawn], serviceZips: ["44903"],
            acceptedTerms: true, phone: "(419) 555-0194"
        )
        XCTAssertEqual(pro.phone, "+14195550194")
        let maya = try XCTUnwrap(book.users.first { $0.user.email == "maya@contractor.demo" }?.user)
        let greenline = try XCTUnwrap(book.users.first { $0.user.email == "greenline@contractor.demo" }?.user)
        XCTAssertFalse(greenline.phone.isEmpty)
        XCTAssertFalse(book.canSeePhone(of: greenline.id, viewer: maya))
        let quote = try XCTUnwrap(book.quotes.first { $0.proID == greenline.id })
        _ = try book.book(customerID: maya.id, quoteID: quote.id)
        XCTAssertTrue(book.canSeePhone(of: greenline.id, viewer: maya))
    }

    func testMissingJobDetailsStillDecode() throws {
        let details = try JSONDecoder().decode(JobDetails.self, from: Data("{}".utf8))
        XCTAssertEqual(details.lawnSize, "")
        XCTAssertEqual(details.notes, "")
        XCTAssertEqual(details.rooms, 0)
        XCTAssertFalse(details.stairs)
    }

    func testAProCannotPostAJob() throws {
        var book = MarketplaceBook.demo()
        let pro = try XCTUnwrap(book.users.first { $0.user.email == "greenline@contractor.demo" }?.user)
        XCTAssertThrowsError(try book.postJob(
            customerID: pro.id, category: .lawn, street: "1 High Street", city: "Mansfield", state: "OH", zip: "44903",
            scheduledOn: "2026-12-01", details: .empty, photoNames: [], offeredPriceCents: 6_400, publish: true
        )) { error in
            XCTAssertEqual(error as? MarketplaceError, .wrongAccount)
        }
    }

    func testPostedPriceIsTheAmountTheCustomerEntered() throws {
        var book = MarketplaceBook.demo()
        let maya = try XCTUnwrap(book.users.first { $0.user.email == "maya@contractor.demo" }?.user)
        let estimate = PriceEstimate(PricingResult(
            questions: [], lowCents: 6_800, highCents: 10_200, suggestedCents: 8_500,
            estimatedMinutes: 60, difficulty: "Typical", explanation: "Suggested",
            assumptions: [], rateName: "US default", disclaimer: "Not a quote", isGuaranteedQuote: false
        ))
        let job = try book.postJob(
            customerID: maya.id, category: .lawn, street: "1 High Street", city: "Mansfield", state: "OH", zip: "44903",
            scheduledOn: "2026-12-01", details: .empty, photoNames: [],
            offeredPriceCents: 6_400, serviceType: "mowing", estimate: estimate, publish: true
        )
        XCTAssertEqual(job.offeredPriceCents, 6_400)
        XCTAssertNotEqual(job.offeredPriceCents, estimate.suggestedCents)
        XCTAssertEqual(PriceInput.cents(from: "64"), 6_400)
        XCTAssertEqual(PriceInput.cents(from: "0"), 0)
    }

    func testCustomerCanDeclineAnOfferAndAProCanSaveABio() throws {
        var book = MarketplaceBook.demo()
        let maya = try XCTUnwrap(book.users.first { $0.user.email == "maya@contractor.demo" }?.user)
        let greenline = try XCTUnwrap(book.users.first { $0.user.email == "greenline@contractor.demo" }?.user)
        let quote = try XCTUnwrap(book.quotes.first { $0.proID == greenline.id && $0.status == .sent })
        try book.declineQuote(customerID: maya.id, quoteID: quote.id)
        XCTAssertEqual(book.quotes.first { $0.id == quote.id }?.status, .declined)
        XCTAssertThrowsError(try book.declineQuote(customerID: maya.id, quoteID: quote.id))
        let saved = try book.updateServiceArea(proID: greenline.id, serviceTypes: ["mowing"], radiusMiles: 12, bio: "  Weekly mowing. ")
        XCTAssertEqual(saved.bio, "Weekly mowing.")
        XCTAssertEqual(saved.radiusMiles, 12)
        XCTAssertEqual(saved.serviceTypes, ["mowing"])
    }

    private func readyPro(_ book: inout MarketplaceBook, email: String, categories: [ServiceCategory]) throws -> UserRecord {
        let user = try book.signUp(
            role: .pro, name: "Pat", email: email, password: "secret1", zip: "44903",
            business: "Yard", categories: categories, serviceZips: ["44903"], acceptedTerms: true, phone: "419-555-0193"
        )
        _ = try book.verifyPhone(user.id)
        _ = try book.verifyIdentity(user.id)
        return try book.connectPayouts(user.id)
    }

    private func place(_ book: inout MarketplaceBook, proID: UUID, near job: JobRecord) throws {
        let index = try XCTUnwrap(book.users.firstIndex { $0.user.id == proID })
        book.users[index].user.latitude = job.latitude
        book.users[index].user.longitude = job.longitude
    }
}
