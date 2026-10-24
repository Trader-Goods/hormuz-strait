import Foundation

enum ScoreCategory: String, Equatable {
    case spam
    case likely
    case ok
    case safe

    var title: String {
        switch self {
        case .spam: return "Spam"
        case .likely: return "Likely spam"
        case .ok: return "Probably OK"
        case .safe: return "Safe"
        }
    }

    var preselected: Bool { self == .spam }

    static func forScore(_ score: Int) -> ScoreCategory {
        if score >= 70 { return .spam }
        if score >= 40 { return .likely }
        return .ok
    }
}

struct ScoreResult: Equatable {
    var score: Int
    var category: ScoreCategory
    var reasons: [String]
}

struct ScoreContext: Equatable {
    var sentAddresses: Set<String> = []
    var sentDomains: Set<String> = []
    var contacts: Set<String> = []
    var whitelistAddresses: Set<String> = []
    var whitelistDomains: Set<String> = []
    var addressesOnDomain: [String: Int] = [:]
    var domainsForName: [String: Int] = [:]
}

struct ScoredSender: Identifiable, Equatable {
    var sender: SenderAggregate
    var result: ScoreResult
    var id: String { sender.address }
}

struct DomainRollup: Identifiable, Equatable {
    var domain: String
    var addresses: [String]
    var safeAddresses: [String]
    var messageCount: Int
    var topScore: Int
    var id: String { domain }
}

enum SpamScorer {
    static func scoreAll(
        senders: [SenderAggregate],
        sentAddresses: Set<String>,
        sentDomains: Set<String>,
        contacts: Set<String>,
        whitelist: [BlockEntry]
    ) -> [ScoredSender] {
        let context = makeContext(
            senders: senders,
            sentAddresses: sentAddresses,
            sentDomains: sentDomains,
            contacts: contacts,
            whitelist: whitelist
        )
        return senders.map { ScoredSender(sender: $0, result: score($0, context: context)) }
            .sorted { lhs, rhs in
                if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
                if lhs.sender.count != rhs.sender.count { return lhs.sender.count > rhs.sender.count }
                return lhs.sender.address < rhs.sender.address
            }
    }

    static func rollups(from rows: [ScoredSender]) -> [DomainRollup] {
        var groups: [String: [ScoredSender]] = [:]
        for row in rows where !row.sender.domain.isEmpty {
            groups[row.sender.domain, default: []].append(row)
        }
        var result: [DomainRollup] = []
        for (domain, group) in groups {
            guard group.count >= 3, !isFreemail(domain) else { continue }
            let safe = group.filter { $0.result.category == .safe }.map(\.sender.address)
            let blockable = group.filter { $0.result.category != .safe }
            guard !blockable.isEmpty else { continue }
            result.append(DomainRollup(
                domain: domain,
                addresses: blockable.map(\.sender.address).sorted(),
                safeAddresses: safe.sorted(),
                messageCount: group.reduce(0) { $0 + $1.sender.count },
                topScore: group.map(\.result.score).max() ?? 0
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.topScore != rhs.topScore { return lhs.topScore > rhs.topScore }
            if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }
            return lhs.domain < rhs.domain
        }
    }

    static func makeContext(
        senders: [SenderAggregate],
        sentAddresses: Set<String>,
        sentDomains: Set<String>,
        contacts: Set<String>,
        whitelist: [BlockEntry]
    ) -> ScoreContext {
        var addressesOnDomain: [String: Int] = [:]
        var nameDomains: [String: Set<String>] = [:]
        for sender in senders {
            addressesOnDomain[sender.domain, default: 0] += 1
            let key = normalizedName(sender.displayName)
            if !key.isEmpty {
                nameDomains[key, default: []].insert(sender.domain)
            }
        }
        var whitelistAddresses: Set<String> = []
        var whitelistDomains: Set<String> = []
        for entry in whitelist {
            if entry.kind == .domain {
                whitelistDomains.insert(entry.value.lowercased())
            } else {
                whitelistAddresses.insert(entry.value.lowercased())
            }
        }
        return ScoreContext(
            sentAddresses: sentAddresses,
            sentDomains: sentDomains,
            contacts: contacts,
            whitelistAddresses: whitelistAddresses,
            whitelistDomains: whitelistDomains,
            addressesOnDomain: addressesOnDomain,
            domainsForName: nameDomains.mapValues(\.count)
        )
    }

    static func score(_ sender: SenderAggregate, context: ScoreContext) -> ScoreResult {
        if context.whitelistAddresses.contains(sender.address) || domainListed(sender.domain, in: context.whitelistDomains) {
            return ScoreResult(score: 0, category: .safe, reasons: ["Marked not spam"])
        }
        let wroteExact = context.sentAddresses.contains(sender.address)
        let sentDomain = !isFreemail(sender.domain) && domainListed(sender.domain, in: context.sentDomains)
        let inContacts = context.contacts.contains(sender.address)
        let interacted = wroteExact || sentDomain || inContacts
        var points = 10
        var reasons: [String] = []
        var allPass = false

        if majority(sender.authFail, of: sender.count) {
            points += 18
            reasons.append("Authentication failed")
        } else if majority(sender.authPass, of: sender.count), sender.authFail == 0 {
            points -= 20
            reasons.append("Authentication passed")
            allPass = true
        } else if sender.authPartial > 0, sender.authFail == 0 {
            points -= 8
            reasons.append("Some authentication passed")
        } else {
            points += 12
            reasons.append("No authentication")
        }

        if allPass, sentDomain, brand(owning: sender.domain) != nil {
            points -= 25
            reasons.append("Authenticated brand you've written to")
        }
        if let claimed = claim(sender.displayName), !domainAllowed(sender.domain, allowed: claimed.domains) {
            points += 40
            reasons.append("Name says \(claimed.label), domain does not")
        }

        var identity = 0
        if majority(sender.replyToMismatch, of: sender.count) {
            identity += 14
            if sender.replyDomain.isEmpty {
                reasons.append("Reply-To is a different domain")
            } else {
                reasons.append("Reply-To uses \(sender.replyDomain)")
            }
        }
        if majority(sender.returnPathMismatch, of: sender.count) {
            identity += 10
            if sender.returnDomain.isEmpty {
                reasons.append("Return-Path is a different domain")
            } else {
                reasons.append("Return-Path uses \(sender.returnDomain)")
            }
        }
        points += min(identity, 18)

        if looksRandomLocal(MailAddress.localPart(of: sender.address)) {
            points += 14
            reasons.append("Random-looking address")
        }
        if looksRandomDomain(sender.domain) {
            points += 14
            reasons.append("Random-looking domain")
        }
        if sender.domain.contains("xn--") {
            points += 16
            reasons.append("Encoded international domain")
        }
        if let tld = suspiciousTLD(sender.domain) {
            points += 16
            reasons.append("Suspicious domain .\(tld)")
        }

        var subjectPoints = 0
        func addSubject(_ hits: Int, _ reason: String) {
            guard majority(hits, of: sender.count), subjectPoints < 28 else { return }
            let next = min(10, 28 - subjectPoints)
            subjectPoints += next
            points += next
            reasons.append(reason)
        }
        addSubject(sender.subjectPrize, "Subject looks like a prize")
        addSubject(sender.subjectGift, "Subject mentions a gift card")
        addSubject(sender.subjectVerify, "Subject asks you to verify an account")
        addSubject(sender.subjectCrypto, "Subject pushes crypto")
        addSubject(sender.subjectDeal, "Subject is a hard sell")
        if majority(sender.subjectEmoji, of: sender.count) || majority(sender.subjectCaps, of: sender.count) {
            addSubject(max(sender.subjectEmoji, sender.subjectCaps), "Subject is full of capitals or emoji")
        }
        if !interacted {
            addSubject(sender.subjectFakeReply, "Subject pretends to be a reply")
        }
        if majority(sender.unsubscribe, of: sender.count) {
            points += 6
            reasons.append("Unsubscribe header")
        }
        if majority(sender.precedenceJunk, of: sender.count) {
            points += 10
            reasons.append("Marked bulk by the sender")
        }
        if majority(sender.inBulk, of: sender.count) {
            points += 28
            reasons.append("Already in Yahoo Junk")
        } else if sender.inBulk > 0 {
            points += 8
            reasons.append("Some mail is already in Yahoo Junk")
        }
        if majority(sender.spamStatusHits, of: sender.count) || majority(sender.newmanSpam, of: sender.count) {
            points += 18
            reasons.append("Yahoo marked it as spam")
        }
        if !interacted {
            var volume = 0
            if sender.count >= 10 { volume += 12 }
            if sender.count >= 25 { volume += 14 }
            if sender.count >= 50 { volume += 10 }
            if volume > 0 {
                points += volume
                reasons.append("High volume and no reply")
            }
        }
        if let others = context.addressesOnDomain[sender.domain], others >= 3, !isFreemail(sender.domain) {
            points += 12
            reasons.append("Many different addresses on this domain")
        }
        let nameKey = normalizedName(sender.displayName)
        if !nameKey.isEmpty, !genericNames.contains(nameKey), let domains = context.domainsForName[nameKey], domains >= 3 {
            points += 16
            reasons.append("Same name used on many domains")
        }
        if sentDomain {
            points -= 36
            reasons.append("You've written to someone at this domain")
        }

        points = min(100, max(0, points))
        if wroteExact {
            return ScoreResult(score: min(points, 8), category: .safe, reasons: ["You've written to this address"])
        }
        if inContacts {
            points = min(39, max(0, points - 32))
            reasons.insert("In your contacts", at: 0)
            return ScoreResult(score: points, category: ScoreCategory.forScore(points), reasons: unique(reasons))
        }
        return ScoreResult(score: points, category: ScoreCategory.forScore(points), reasons: unique(reasons))
    }

    static func isFreemail(_ domain: String) -> Bool {
        let domain = domain.lowercased()
        if freemail.contains(domain) { return true }
        return freemail.contains { domain.hasSuffix("." + $0) }
    }

    static func claimsBrand(_ name: String) -> Bool {
        claim(name) != nil
    }

    static func domainsDiffer(_ from: String, _ other: String) -> Bool {
        if from.isEmpty || other.isEmpty { return false }
        if registrable(from) == registrable(other) { return false }
        if let brand = brand(owning: from), domainAllowed(other, allowed: brand.domains) { return false }
        if let brand = brand(owning: other), domainAllowed(from, allowed: brand.domains) { return false }
        return true
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func majority(_ hits: Int, of count: Int) -> Bool {
        hits > 0 && hits * 2 >= max(count, 1)
    }

    private static func unique(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    private static func domainListed(_ domain: String, in known: Set<String>) -> Bool {
        let domain = domain.lowercased()
        if known.contains(domain) { return true }
        return known.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    private static func normalizedName(_ name: String) -> String {
        words(in: name).joined(separator: " ")
    }

    static func registrable(_ domain: String) -> String {
        let parts = domain.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return domain.lowercased() }
        let twoLevel: Set<String> = ["co.uk", "com.au", "co.jp", "com.br", "co.nz", "com.mx", "co.za", "com.tr", "co.in"]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if parts.count >= 3, twoLevel.contains(lastTwo) {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static func looksRandomLocal(_ local: String) -> Bool {
        let raw = local.lowercased()
        if commonLocals.contains(raw) { return false }
        let stripped = String(raw.filter { $0.isLetter || $0.isNumber })
        if stripped.count < 8 { return false }
        let digits = stripped.filter(\.isNumber).count
        if digits >= 4 { return true }
        let vowels = stripped.filter { "aeiou".contains($0) }.count
        return stripped.count >= 10 && vowels * 5 <= stripped.count
    }

    private static func looksRandomDomain(_ domain: String) -> Bool {
        let label = registrableLabel(domain)
        let stripped = String(label.filter { $0.isLetter || $0.isNumber })
        let digits = stripped.filter(\.isNumber).count
        if digits >= 4 { return true }
        guard stripped.count >= 12 else { return false }
        let vowels = stripped.filter { "aeiou".contains($0) }.count
        return vowels * 5 <= stripped.count
    }

    private static func registrableLabel(_ domain: String) -> String {
        let registered = registrable(domain)
        return String(registered.split(separator: ".").first ?? Substring(registered))
    }

    private static func suspiciousTLD(_ domain: String) -> String? {
        let tld = domain.lowercased().split(separator: ".").last.map(String.init) ?? ""
        return suspiciousTLDs.contains(tld) ? tld : nil
    }

    private struct Brand {
        var label: String
        var aliases: [[String]]
        var domains: Set<String>
        var personal: Bool
    }

    static func claim(_ name: String) -> (label: String, domains: Set<String>)? {
        guard let brand = matchingBrand(name) else { return nil }
        return (brand.label, brand.domains)
    }

    private static func brand(owning domain: String) -> Brand? {
        brands.first { domainAllowed(domain, allowed: $0.domains) }
    }

    private static func matchingBrand(_ name: String) -> Brand? {
        let tokens = words(in: name)
        guard !tokens.isEmpty else { return nil }
        for brand in brands {
            for alias in brand.aliases {
                guard containsPhrase(tokens, alias) else { continue }
                if brand.personal, alias.count == 1 {
                    let exact = tokens == alias
                    let role = tokens.contains { roleWords.contains($0) }
                    if exact || role { return brand }
                } else {
                    return brand
                }
            }
        }
        return nil
    }

    private static func containsPhrase(_ tokens: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        if tokens.count == phrase.count { return tokens == phrase }
        for index in 0...(tokens.count - phrase.count) {
            if Array(tokens[index..<(index + phrase.count)]) == phrase { return true }
        }
        return false
    }

    static func domainAllowed(_ domain: String, allowed: Set<String>) -> Bool {
        let domain = domain.lowercased()
        for item in allowed {
            if domain == item || domain.hasSuffix("." + item) { return true }
        }
        return false
    }

    private static let freemail: Set<String> = [
        "yahoo.com", "ymail.com", "gmail.com", "googlemail.com", "outlook.com", "hotmail.com",
        "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "comcast.net",
        "verizon.net", "att.net", "sbcglobal.net", "proton.me", "protonmail.com", "pm.me",
        "hey.com", "fastmail.com",
    ]

    private static let suspiciousTLDs: Set<String> = [
        "xyz", "top", "click", "shop", "online", "icu", "buzz", "gq", "ml", "cf", "tk",
        "rest", "cfd", "loan", "win", "bid", "cyou", "monster", "quest", "sbs", "lol", "bond",
    ]

    private static let commonLocals: Set<String> = [
        "noreply", "no-reply", "newsletter", "news", "info", "support", "sales", "billing",
        "orders", "order", "mail", "email", "notifications", "notification", "alerts", "alert",
        "hello", "hi", "team", "admin", "contact", "service", "services", "updates", "update",
        "marketing", "promo", "offers", "security", "account", "accounts", "customerservice",
        "mailer-daemon", "postmaster",
    ]

    private static let genericNames: Set<String> = [
        "noreply", "no reply", "support", "info", "admin", "notification", "notifications",
        "newsletter", "news", "team", "service", "customer service", "mail", "email", "alert",
        "alerts", "update", "updates", "billing", "sales", "marketing", "promo", "offer",
        "offers", "account", "accounts", "security", "help", "contact", "postmaster",
    ]

    private static let roleWords: Set<String> = [
        "support", "service", "services", "account", "accounts", "security", "team", "alert",
        "alerts", "notification", "notifications", "customer", "billing", "payment", "payments",
        "order", "orders", "delivery", "update", "updates", "info", "help", "center", "centre",
        "online", "store", "rewards", "express", "shipping", "verification", "verify", "login",
        "notice", "notices", "message", "messages", "business", "platforms",
    ]

    private static let brands: [Brand] = [
        Brand(label: "PayPal", aliases: [["paypal"]], domains: ["paypal.com", "paypal.co.uk"], personal: false),
        Brand(label: "Amazon", aliases: [["amazon"]], domains: ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.fr", "amazonses.com"], personal: false),
        Brand(label: "Apple", aliases: [["apple"]], domains: ["apple.com", "icloud.com", "email.apple.com"], personal: true),
        Brand(label: "Microsoft", aliases: [["microsoft"], ["outlook"]], domains: ["microsoft.com", "office.com", "live.com", "outlook.com", "hotmail.com"], personal: false),
        Brand(label: "Google", aliases: [["google"]], domains: ["google.com", "gmail.com", "googlemail.com", "youtube.com"], personal: false),
        Brand(label: "Netflix", aliases: [["netflix"]], domains: ["netflix.com"], personal: false),
        Brand(label: "Facebook", aliases: [["facebook"]], domains: ["facebook.com", "facebookmail.com"], personal: false),
        Brand(label: "Meta", aliases: [["meta"]], domains: ["meta.com"], personal: true),
        Brand(label: "Instagram", aliases: [["instagram"]], domains: ["instagram.com", "mail.instagram.com"], personal: false),
        Brand(label: "LinkedIn", aliases: [["linkedin"]], domains: ["linkedin.com"], personal: false),
        Brand(label: "eBay", aliases: [["ebay"]], domains: ["ebay.com", "ebay.co.uk"], personal: false),
        Brand(label: "Walmart", aliases: [["walmart"]], domains: ["walmart.com"], personal: false),
        Brand(label: "Costco", aliases: [["costco"]], domains: ["costco.com"], personal: false),
        Brand(label: "Adobe", aliases: [["adobe"]], domains: ["adobe.com"], personal: false),
        Brand(label: "Dropbox", aliases: [["dropbox"]], domains: ["dropbox.com"], personal: false),
        Brand(label: "DHL", aliases: [["dhl"]], domains: ["dhl.com"], personal: false),
        Brand(label: "FedEx", aliases: [["fedex"]], domains: ["fedex.com"], personal: false),
        Brand(label: "UPS", aliases: [["ups"]], domains: ["ups.com"], personal: false),
        Brand(label: "IRS", aliases: [["irs"]], domains: ["irs.gov"], personal: false),
        Brand(label: "Chase", aliases: [["chase"]], domains: ["chase.com"], personal: true),
        Brand(label: "Wells Fargo", aliases: [["wells", "fargo"], ["wellsfargo"]], domains: ["wellsfargo.com"], personal: false),
        Brand(label: "Bank of America", aliases: [["bank", "of", "america"], ["bankofamerica"]], domains: ["bankofamerica.com", "bofa.com"], personal: false),
        Brand(label: "American Express", aliases: [["american", "express"], ["americanexpress"], ["amex"]], domains: ["americanexpress.com"], personal: false),
        Brand(label: "Coinbase", aliases: [["coinbase"]], domains: ["coinbase.com"], personal: false),
        Brand(label: "DocuSign", aliases: [["docusign"]], domains: ["docusign.com", "docusign.net"], personal: false),
    ]
}
