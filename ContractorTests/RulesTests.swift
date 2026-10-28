import XCTest
@testable import Contractor

final class RulesTests: XCTestCase {
    func testRichlandCountyZips() {
        XCTAssertTrue(RichlandCounty.contains("44903"))
        XCTAssertTrue(RichlandCounty.contains("44903-1205"))
        XCTAssertTrue(RichlandCounty.contains("44875"))
        XCTAssertFalse(RichlandCounty.contains("43215"))
        XCTAssertFalse(RichlandCounty.contains("449"))
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

    func testSignupRejectsZipsOutsideTheCounty() {
        var book = MarketplaceBook.demo()
        XCTAssertThrowsError(try book.signUp(
            role: .customer, name: "Alex", email: "alex@example.com", password: "secret1",
            zip: "43215", business: "", categories: [], serviceZips: [], acceptedTerms: true
        )) { error in
            XCTAssertEqual(error as? MarketplaceError, .outsideArea)
        }
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
