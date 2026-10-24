import XCTest
@testable import SpamSweep

final class ScorerTests: XCTestCase {
    func testPrizeSpamScoresSeventyTwoAndIsSelected() {
        let header = mail(
            name: "Winner",
            address: "a8f3k2m9@promo-deals.top",
            subject: "You won a $500 gift card!!!"
        )
        let result = score(header)
        XCTAssertEqual(result.score, 72)
        XCTAssertEqual(result.category, .spam)
        XCTAssertTrue(result.category.preselected)
        XCTAssertTrue(result.reasons.contains("Suspicious domain .top"))
        XCTAssertTrue(result.reasons.contains("Random-looking address"))
        XCTAssertTrue(result.reasons.contains("Subject looks like a prize"))
        XCTAssertTrue(result.reasons.contains("Subject mentions a gift card"))
    }

    func testPhishingBrandMismatchClampsAtOneHundred() {
        var sender = SenderAggregate(address: "security@secure-paypai.xyz")
        sender.displayName = "PayPal"
        sender.domain = "secure-paypai.xyz"
        sender.count = 1
        sender.authFail = 1
        sender.replyToMismatch = 1
        sender.returnPathMismatch = 1
        sender.replyDomain = "evil.test"
        sender.returnDomain = "other.test"
        sender.subjectVerify = 1
        let result = SpamScorer.score(sender, context: ScoreContext())
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.category, .spam)
        XCTAssertTrue(result.reasons.contains("Name says PayPal, domain does not"))
        XCTAssertTrue(result.reasons.contains("Authentication failed"))
        XCTAssertTrue(result.reasons.contains("Reply-To uses evil.test"))
        XCTAssertTrue(result.reasons.contains("Subject asks you to verify an account"))
    }

    func testParsedPhishHeaderFailsAuthentication() throws {
        let raw = """
        From: PayPal <security@secure-paypai.xyz>\r
        Reply-To: theft@evil.test\r
        Return-Path: <bounce@other.test>\r
        Subject: Urgent: verify your account\r
        Authentication-Results: example.com;\r
         dkim=pass header.i=@secure-paypai.xyz;\r
         spf=fail smtp.mailfrom=secure-paypai.xyz;\r
         dmarc=pass\r
        """
        let header = try XCTUnwrap(MailHeader.parse(text: raw, uid: 4, size: 80, inBulk: false))
        XCTAssertEqual(header.fromAddress, "security@secure-paypai.xyz")
        XCTAssertEqual(header.fromName, "PayPal")
        let result = score(header)
        XCTAssertEqual(result.category, .spam)
        XCTAssertTrue(result.reasons.contains("Authentication failed"))
        XCTAssertTrue(result.reasons.contains("Name says PayPal, domain does not"))
    }

    func testFriendYouWroteIsSafeAndNotSelected() {
        let header = mail(name: "Sam Lee", address: "sam.lee@gmail.com", subject: "Dinner Thursday?", authentication: "spf=pass dkim=pass dmarc=pass")
        var context = ScoreContext()
        context.sentAddresses = ["sam.lee@gmail.com"]
        let result = SpamScorer.score(only(header), context: context)
        XCTAssertEqual(result.category, .safe)
        XCTAssertFalse(result.category.preselected)
        XCTAssertLessThanOrEqual(result.score, 8)
        XCTAssertEqual(result.reasons, ["You've written to this address"])
    }

    func testAuthenticatedAmazonIsProbablyOK() {
        let raw = """
        From: "Amazon.com" <auto-confirm@amazon.com>\r
        Return-Path: <bounce@bounces.amazon.com>\r
        Authentication-Results: amazonses.com; spf=pass; dkim=pass header.i=@amazon.com; dmarc=pass\r
        Subject: Your order has shipped\r
        """
        let header = MailHeader.parse(text: raw, uid: 9, size: 120, inBulk: false)!
        let result = score(header)
        XCTAssertEqual(result.category, .ok)
        XCTAssertFalse(result.category.preselected)
        XCTAssertLessThan(result.score, 40)
        XCTAssertTrue(result.reasons.contains("Authentication passed"))
        XCTAssertFalse(result.reasons.contains(where: { $0.contains("Return-Path") }))
    }

    func testAmazonYouWroteToDropsFurtherButIsNotSafeUnlessExact() {
        let header = mail(
            name: "Amazon.com",
            address: "auto-confirm@amazon.com",
            subject: "Your order has shipped",
            authentication: "spf=pass dkim=pass dmarc=pass"
        )
        var context = ScoreContext()
        context.sentDomains = ["amazon.com"]
        let result = SpamScorer.score(only(header), context: context)
        XCTAssertEqual(result.category, .ok)
        XCTAssertNotEqual(result.category, .safe)
        XCTAssertTrue(result.reasons.contains("You've written to someone at this domain"))
        XCTAssertTrue(result.reasons.contains("Authenticated brand you've written to"))
    }

    func testNewsletterWithoutAuthIsLikelyAndNotSelected() {
        var sender = SenderAggregate(address: "news@example.com")
        sender.displayName = "Shop"
        sender.domain = "example.com"
        sender.count = 30
        sender.authNone = 30
        sender.subjectDeal = 30
        sender.unsubscribe = 30
        sender.subjects = ["20% off this weekend"]
        let result = SpamScorer.score(sender, context: ScoreContext())
        XCTAssertEqual(result.score, 64)
        XCTAssertEqual(result.category, .likely)
        XCTAssertFalse(result.category.preselected)
        XCTAssertTrue(result.reasons.contains("High volume and no reply"))
        XCTAssertTrue(result.reasons.contains("Subject is a hard sell"))
    }

    func testWhitelistIsNeverFlagged() {
        var sender = SenderAggregate(address: "a8f3k2m9@promo-deals.top")
        sender.displayName = "Winner"
        sender.domain = "promo-deals.top"
        sender.count = 12
        sender.authNone = 12
        sender.subjectPrize = 12
        var context = ScoreContext()
        context.whitelistAddresses = ["a8f3k2m9@promo-deals.top"]
        let result = SpamScorer.score(sender, context: context)
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.category, .safe)
        XCTAssertFalse(result.category.preselected)
        XCTAssertEqual(result.reasons, ["Marked not spam"])
    }

    func testContactIsNotAutoSelected() {
        var sender = SenderAggregate(address: "security@secure-paypai.xyz")
        sender.displayName = "PayPal"
        sender.domain = "secure-paypai.xyz"
        sender.count = 1
        sender.authFail = 1
        sender.replyToMismatch = 1
        sender.returnPathMismatch = 1
        sender.subjectVerify = 1
        var context = ScoreContext()
        context.contacts = ["security@secure-paypai.xyz"]
        let result = SpamScorer.score(sender, context: context)
        XCTAssertLessThan(result.score, 40)
        XCTAssertEqual(result.category, .ok)
        XCTAssertFalse(result.category.preselected)
        XCTAssertEqual(result.reasons.first, "In your contacts")
    }

    func testPersonNamedChaseIsNotABrand() {
        let header = mail(
            name: "Chase Smith",
            address: "chase.smith@gmail.com",
            subject: "Lunch tomorrow?",
            authentication: "spf=pass dkim=pass dmarc=pass"
        )
        let result = score(header)
        XCTAssertEqual(result.category, .ok)
        XCTAssertFalse(result.reasons.contains(where: { $0.contains("Name says") }))
    }

    func testFakeChaseDomainIsSpam() {
        let header = mail(name: "Chase", address: "alert@chase-secure.top", subject: "Verify your account")
        let result = score(header)
        XCTAssertGreaterThanOrEqual(result.score, 70)
        XCTAssertEqual(result.category, .spam)
        XCTAssertTrue(result.reasons.contains("Name says Chase, domain does not"))
        XCTAssertTrue(result.reasons.contains("Suspicious domain .top"))
    }

    func testBulkHighVolumeMissingAuthIsSpam() {
        var sender = SenderAggregate(address: "deals@notice.example")
        sender.domain = "notice.example"
        sender.count = 40
        sender.authNone = 40
        sender.inBulk = 40
        let result = SpamScorer.score(sender, context: ScoreContext())
        XCTAssertGreaterThanOrEqual(result.score, 70)
        XCTAssertEqual(result.category, .spam)
        XCTAssertTrue(result.reasons.contains("Already in Yahoo Junk"))
        XCTAssertTrue(result.reasons.contains("High volume and no reply"))
    }

    func testAuthenticatedBulkIsNotAutoSelected() {
        var sender = SenderAggregate(address: "news@example.com")
        sender.domain = "example.com"
        sender.count = 40
        sender.authPass = 40
        sender.inBulk = 40
        let result = SpamScorer.score(sender, context: ScoreContext())
        XCTAssertEqual(result.category, .likely)
        XCTAssertFalse(result.category.preselected)
    }

    func testOnePrizeSubjectAmongManyDoesNotFlagTheSender() {
        var sender = SenderAggregate(address: "person@example.com")
        sender.domain = "example.com"
        sender.count = 10
        sender.authPass = 10
        sender.subjectPrize = 1
        let result = SpamScorer.score(sender, context: ScoreContext())
        XCTAssertFalse(result.reasons.contains("Subject looks like a prize"))
        XCTAssertLessThan(result.score, 40)
    }

    func testDomainRollupSkipsFreemailAndProtectsSafe() {
        let spam = (1...3).map { index -> ScoredSender in
            var sender = SenderAggregate(address: "a\(index)@shop-deals.xyz")
            sender.domain = "shop-deals.xyz"
            sender.count = 4
            return ScoredSender(sender: sender, result: ScoreResult(score: 80, category: .spam, reasons: []))
        }
        var safeSender = SenderAggregate(address: "owner@shop-deals.xyz")
        safeSender.domain = "shop-deals.xyz"
        safeSender.count = 2
        let safe = ScoredSender(sender: safeSender, result: ScoreResult(score: 0, category: .safe, reasons: []))
        var gmail: [ScoredSender] = []
        for index in 1...5 {
            var sender = SenderAggregate(address: "p\(index)@gmail.com")
            sender.domain = "gmail.com"
            sender.count = 3
            gmail.append(ScoredSender(sender: sender, result: ScoreResult(score: 80, category: .spam, reasons: [])))
        }
        let rollups = SpamScorer.rollups(from: spam + [safe] + gmail)
        XCTAssertEqual(rollups.map(\.domain), ["shop-deals.xyz"])
        XCTAssertEqual(rollups[0].addresses.count, 3)
        XCTAssertEqual(rollups[0].safeAddresses, ["owner@shop-deals.xyz"])
    }

    func testSharedDisplayNameAddsReason() {
        let names = ["a.example", "b.example", "c.test"]
        let senders = names.map { domain -> SenderAggregate in
            var sender = SenderAggregate(address: "billing@\(domain)")
            sender.displayName = "Amazon Support"
            sender.domain = domain
            sender.count = 2
            sender.authNone = 2
            return sender
        }
        let rows = SpamScorer.scoreAll(senders: senders, sentAddresses: [], sentDomains: [], contacts: [], whitelist: [])
        XCTAssertTrue(rows.allSatisfy { $0.result.reasons.contains("Same name used on many domains") })
    }

    func testFetchLineExtractsHeaderLiteral() {
        let header = "From: a@b.co\r\n"
        let prefix = "* 1 FETCH (UID 15 RFC822.SIZE 40 BODY[HEADER.FIELDS (FROM)] {\(header.utf8.count)}"
        let line = Data(prefix.utf8) + Data(header.utf8) + Data(")".utf8)
        let parsed = HeaderFetch.parseLine(line)
        XCTAssertEqual(parsed?.uid, 15)
        XCTAssertEqual(parsed?.size, 40)
        XCTAssertEqual(parsed?.text, header)
    }

    func testMailboxPlanSkipsAllMailAndSent() {
        let boxes = [
            IMAPMailbox(name: "INBOX", flags: ["inbox"]),
            IMAPMailbox(name: "Bulk", flags: ["junk"]),
            IMAPMailbox(name: "Sent", flags: ["sent"]),
            IMAPMailbox(name: "Trash", flags: ["trash"]),
            IMAPMailbox(name: "All Mail", flags: ["all"]),
            IMAPMailbox(name: "Archive", flags: ["archive"]),
            IMAPMailbox(name: "Projects", flags: []),
        ]
        let inboxAndJunk = MailboxPlan.targets(boxes, includeBulk: true, includeOther: false).map(\.name)
        XCTAssertEqual(inboxAndJunk, ["INBOX", "Bulk"])
        let more = MailboxPlan.targets(boxes, includeBulk: true, includeOther: true).map(\.name)
        XCTAssertEqual(more, ["INBOX", "Bulk", "Archive", "Projects"])
        XCTAssertEqual(MailboxPlan.sentName(boxes), "Sent")
    }

    func testFakeReplyNeedsOtherSignalsToBecomeLikely() {
        let header = mail(name: "Notice", address: "n@mail.xyz", subject: "Re: Your account")
        let result = score(header)
        XCTAssertEqual(result.category, .likely)
        XCTAssertFalse(result.category.preselected)
        XCTAssertTrue(result.reasons.contains("Subject pretends to be a reply"))
    }

    func testHighVolumeAuthenticatedMailStaysBelowSpam() {
        var sender = SenderAggregate(address: "news@brand.example")
        sender.domain = "brand.example"
        sender.count = 60
        sender.authPass = 60
        sender.unsubscribe = 60
        let result = SpamScorer.score(sender, context: ScoreContext())
        XCTAssertLessThan(result.score, 70)
        XCTAssertNotEqual(result.category, .spam)
    }

    func testETARoundsToMinutes() {
        XCTAssertEqual(ScanETA.text(done: 100, total: 200, elapsed: 100), "about 2 min left")
        XCTAssertEqual(ScanETA.text(done: 10, total: 200, elapsed: 100), "")
    }

    private func mail(name: String, address: String, subject: String, authentication: String = "") -> MailHeader {
        var lines = [
            "From: \(name) <\(address)>",
            "Subject: \(subject)",
        ]
        if !authentication.isEmpty {
            lines.append("Authentication-Results: test; \(authentication)")
        }
        return MailHeader.parse(text: lines.joined(separator: "\r\n"), uid: 1, size: 100, inBulk: false)!
    }

    private func only(_ header: MailHeader) -> SenderAggregate {
        SenderStats.aggregate([header])[0]
    }

    private func score(_ header: MailHeader, context: ScoreContext = ScoreContext()) -> ScoreResult {
        SpamScorer.score(only(header), context: context)
    }
}

final class SignInTests: XCTestCase {
    func testNormalizeEmailAndPassword() {
        XCTAssertEqual(YahooAccount.normalizeEmail("  Me@Yahoo.COM "), "me@yahoo.com")
        XCTAssertEqual(YahooAccount.normalizeEmail("Pat"), "pat@yahoo.com")
        XCTAssertEqual(
            YahooAccount.normalizePassword(" ABCD-EFGH—IJKL MNOP "),
            "abcdefghijklmnop"
        )
        XCTAssertNil(YahooAccount.passwordHint(for: ""))
        XCTAssertNil(YahooAccount.passwordHint(for: "abcd efgh ijkl mnop"))
        XCTAssertNotNil(YahooAccount.passwordHint(for: "abcd"))
        XCTAssertNotNil(YahooAccount.passwordHint(for: "abcdefghijklmno1"))
    }

    func testPlainTokenAndRedactionOmitThePassword() {
        let token = IMAPText.plainToken(email: "user", password: "pass")
        XCTAssertEqual(token, "AHVzZXIAcGFzcw==")
        let secret = "abcdefghijklmnop"
        let sasl = IMAPText.plainToken(email: "a@yahoo.com", password: secret)
        let line = "A003 NO [AUTHENTICATIONFAILED] \(secret) \(sasl)"
        let redacted = IMAPText.redact(line, password: secret, token: sasl)
        XCTAssertFalse(redacted.contains(secret))
        XCTAssertFalse(redacted.contains(sasl))
        XCTAssertTrue(redacted.contains("[AUTHENTICATIONFAILED]"))
        XCTAssertTrue(redacted.contains("[password]"))
    }

    func testCapabilityKeepsPlainAndIgnoresOAuthForAvailability() {
        let tokens = IMAPText.capabilityTokens(in: [
            Data("* CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN AUTH=XOAUTH2 AUTH=OAUTHBEARER ID".utf8)
        ])
        XCTAssertTrue(tokens.contains("AUTH=PLAIN"))
        XCTAssertTrue(tokens.contains("SASL-IR"))
        XCTAssertTrue(tokens.contains("AUTH=XOAUTH2"))
        XCTAssertFalse(IMAPText.isUnavailable("A001 NO [AUTHENTICATIONFAILED] Invalid credentials"))
        XCTAssertTrue(IMAPText.isUnavailable("A004 NO [UNAVAILABLE] Server busy"))
    }

    func testErrorTextDistinguishesConnectionAuthAndBusy() {
        let password = "abcdefghijklmnop"
        let auth = SweepEngine.describe(IMAPError.loginFailed("LOGIN: A003 NO [AUTHENTICATIONFAILED] Invalid credentials"))
        XCTAssertTrue(auth.contains("NO [AUTHENTICATIONFAILED]"))
        XCTAssertTrue(auth.contains("refused the sign-in"))
        XCTAssertFalse(auth.contains(password))

        let busy = SweepEngine.describe(IMAPError.unavailable("A001 NO [UNAVAILABLE] Server busy"))
        XCTAssertTrue(busy.contains("[UNAVAILABLE]"))
        XCTAssertFalse(busy.contains("refused the sign-in"))

        let offline = SweepEngine.describe(IMAPError.connectionFailed("The operation timed out"))
        XCTAssertTrue(offline.contains("TLS"))
        XCTAssertTrue(offline.contains("timed out"))
        XCTAssertFalse(offline.contains("refused the sign-in"))
        XCTAssertEqual(
            SweepEngine.details(IMAPError.loginFailed("LOGIN: A003 NO [AUTHENTICATIONFAILED] Invalid credentials")),
            "LOGIN: A003 NO [AUTHENTICATIONFAILED] Invalid credentials"
        )
    }
}
