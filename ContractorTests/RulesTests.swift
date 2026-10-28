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
            zip: "44903", business: "Pat Lawn", categories: [.lawn], serviceZips: ["44903"]
        )
        _ = try book.verifyPhone(third.id)
        _ = try book.sendQuote(proID: third.id, jobID: job.id, priceCents: 9_000, message: "Saturday works.")
        XCTAssertEqual(book.quotes(for: job.id).count, 3)
        XCTAssertTrue(book.openJobs(for: try XCTUnwrap(book.user(third.id))).allSatisfy { $0.id != job.id })
        let fourth = try book.signUp(
            role: .pro, name: "Casey", email: "casey@example.com", password: "secret1",
            zip: "44903", business: "Casey Cuts", categories: [.lawn], serviceZips: ["44903"]
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
            zip: "43215", business: "", categories: [], serviceZips: []
        )) { error in
            XCTAssertEqual(error as? MarketplaceError, .outsideArea)
        }
    }
}
