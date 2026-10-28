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

    func testBookingFeeIsEightPercentWithAFiveDollarMinimum() {
        XCTAssertEqual(BookingFee.feeCents(priceCents: 8_500), 680)
        XCTAssertEqual(BookingFee.feeCents(priceCents: 2_000), 500)
        XCTAssertEqual(BookingFee.feeCents(priceCents: 0), 0)
    }

    func testAJobStopsAtThreeQuotes() throws {
        var book = MarketplaceBook.demo()
        let job = try XCTUnwrap(book.jobs.first { $0.street.contains("Park") })
        XCTAssertEqual(book.quotes(for: job.id).count, 2)
        let third = try book.signUp(
            role: .pro, name: "Pat Lane", email: "pat@example.com", password: "secret1",
            zip: "44903", business: "Pat Lawn", categories: [.lawn], serviceZips: ["44903"],
            acceptedTerms: true
        )
        _ = try book.verifyPhone(third.id)
        _ = try book.sendQuote(proID: third.id, jobID: job.id, priceCents: 9_000, message: "Saturday works.")
        XCTAssertEqual(book.quotes(for: job.id).count, 3)
        XCTAssertTrue(book.openJobs(for: try XCTUnwrap(book.user(third.id))).allSatisfy { $0.id != job.id })
        let fourth = try book.signUp(
            role: .pro, name: "Casey", email: "casey@example.com", password: "secret1",
            zip: "44903", business: "Casey Cuts", categories: [.lawn], serviceZips: ["44903"],
            acceptedTerms: true
        )
        _ = try book.verifyPhone(fourth.id)
        XCTAssertThrowsError(try book.sendQuote(proID: fourth.id, jobID: job.id, priceCents: 7_000, message: "I can come Sunday.")) { error in
            XCTAssertEqual(error as? MarketplaceError, .quoteLimit)
        }
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
            acceptedTerms: true, radiusMiles: 10
        )
        _ = try book.verifyPhone(pro.id)
        let index = try XCTUnwrap(book.users.firstIndex { $0.user.id == pro.id })
        book.users[index].user.latitude = 39.9612
        book.users[index].user.longitude = -82.9988
        let maya = try XCTUnwrap(book.users.first { $0.user.email == "maya@contractor.demo" }?.user)
        let near = try book.postJob(
            customerID: maya.id, category: .lawn, street: "1 Capitol Square", city: "Columbus", state: "OH", zip: "43215",
            latitude: 39.9615, longitude: -82.9990, scheduledOn: "2026-12-01", details: .empty, photoNames: []
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
        XCTAssertEqual(first.feePercent, 8)
        XCTAssertEqual(first.charge.status, "stubbed")
        XCTAssertEqual(first.charge.applicationFeeCents, 680)
        XCTAssertEqual(first.charge.proPayoutCents, 8_500 - 680)
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
}
