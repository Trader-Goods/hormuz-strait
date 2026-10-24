import Foundation

enum MailFields {
    static let inbox = "UID RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM REPLY-TO RETURN-PATH SUBJECT DATE LIST-UNSUBSCRIBE PRECEDENCE AUTHENTICATION-RESULTS RECEIVED-SPF X-YAHOO-NEWMAN-PROPERTY X-SPAM-STATUS)]"
    static let sent = "UID RFC822.SIZE BODY.PEEK[HEADER.FIELDS (TO CC BCC)]"
    static let fromOnly = "UID BODY.PEEK[HEADER.FIELDS (FROM)]"
}

struct FetchedHeader: Equatable {
    var uid: UInt64
    var size: Int
    var text: String
}

enum HeaderFetch {
    static func parseLine(_ line: Data) -> FetchedHeader? {
        guard let fetch = line.range(of: Data(" FETCH ".utf8)) else { return nil }
        let body = Data(line[fetch.upperBound...])
        guard let parts = splitLiteral(body) else { return nil }
        guard let uid = number(after: "UID ", in: parts.meta) else { return nil }
        let size = number(after: "RFC822.SIZE ", in: parts.meta) ?? 0
        return FetchedHeader(uid: uid, size: Int(size), text: String(decoding: parts.header, as: UTF8.self))
    }

    static func splitLiteral(_ data: Data) -> (meta: Data, header: Data)? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "{") {
                var cursor = index + 1
                var count = 0
                var digits = 0
                while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                    count = count * 10 + Int(bytes[cursor] - 48)
                    digits += 1
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "+") {
                    cursor += 1
                }
                if digits > 0, cursor < bytes.count, bytes[cursor] == UInt8(ascii: "}") {
                    let start = cursor + 1
                    let end = start + count
                    if end <= bytes.count {
                        return (Data(bytes[..<index]), Data(bytes[start..<end]))
                    }
                }
            }
            index += 1
        }
        return nil
    }

    private static func number(after needle: String, in data: Data) -> UInt64? {
        guard let range = data.range(of: Data(needle.utf8)) else { return nil }
        var value: UInt64 = 0
        var found = false
        for byte in data[range.upperBound...] {
            if byte >= 48 && byte <= 57 {
                value = value * 10 + UInt64(byte - 48)
                found = true
            } else if found {
                break
            } else {
                break
            }
        }
        return found ? value : nil
    }
}

enum HeaderBlock {
    static func fields(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var name = ""
        var value = ""
        func commit() {
            let key = name.lowercased()
            guard !key.isEmpty else { return }
            if let existing = result[key], !existing.isEmpty {
                result[key] = existing + " " + value
            } else {
                result[key] = value
            }
        }
        for lineSub in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(lineSub)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                commit()
                name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        commit()
        return result
    }
}

enum MailAddress {
    static func mailbox(_ raw: String) -> (name: String, email: String)? {
        let decoded = HeaderText.decode(raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        if let start = decoded.lastIndex(of: "<"),
           let end = decoded[start...].firstIndex(of: ">"),
           start < end {
            let email = String(decoded[decoded.index(after: start)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let name = String(decoded[..<start]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            guard email.contains("@"), email.contains(".") else { return nil }
            return (name, email)
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.contains("."), !trimmed.contains(" ") else { return nil }
        return ("", trimmed)
    }

    static func emails(in raw: String) -> [String] {
        let decoded = HeaderText.decode(raw)
        var found: [String] = []
        for part in decoded.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            if let mail = mailbox(String(part)) {
                found.append(mail.email)
            }
        }
        if found.isEmpty, let mail = mailbox(decoded) {
            found.append(mail.email)
        }
        return found
    }

    static func domain(of email: String) -> String {
        let lower = email.lowercased()
        guard let at = lower.lastIndex(of: "@") else { return "" }
        return String(lower[lower.index(after: at)...]).trimmingCharacters(in: CharacterSet(charactersIn: ">. "))
    }

    static func localPart(of email: String) -> String {
        let lower = email.lowercased()
        guard let at = lower.lastIndex(of: "@") else { return lower }
        return String(lower[..<at])
    }

    static func cleanSubject(_ raw: String) -> String {
        let decoded = HeaderText.decode(raw)
        if decoded.isEmpty { return "(no subject)" }
        if decoded.count <= 180 { return decoded }
        return String(decoded.prefix(180))
    }
}

struct MailHeader: Equatable {
    var uid: UInt64
    var fromName: String
    var fromAddress: String
    var replyTo: String?
    var returnPath: String?
    var subject: String
    var unsubscribe: Bool
    var precedence: String
    var authentication: String
    var receivedSPF: String
    var newman: String
    var spamStatus: String
    var size: Int
    var inBulk: Bool

    static func parse(text: String, uid: UInt64, size: Int, inBulk: Bool) -> MailHeader? {
        let fields = HeaderBlock.fields(text)
        guard let from = MailAddress.mailbox(fields["from"] ?? "") else { return nil }
        return MailHeader(
            uid: uid,
            fromName: from.name,
            fromAddress: from.email,
            replyTo: MailAddress.mailbox(fields["reply-to"] ?? "")?.email,
            returnPath: MailAddress.mailbox(fields["return-path"] ?? "")?.email,
            subject: fields["subject"] ?? "",
            unsubscribe: !(fields["list-unsubscribe"] ?? "").isEmpty,
            precedence: fields["precedence"] ?? "",
            authentication: fields["authentication-results"] ?? "",
            receivedSPF: fields["received-spf"] ?? "",
            newman: fields["x-yahoo-newman-property"] ?? "",
            spamStatus: fields["x-spam-status"] ?? "",
            size: size,
            inBulk: inBulk
        )
    }
}

struct SubjectSignals: OptionSet {
    let rawValue: Int
    static let prize = SubjectSignals(rawValue: 1 << 0)
    static let gift = SubjectSignals(rawValue: 1 << 1)
    static let verify = SubjectSignals(rawValue: 1 << 2)
    static let crypto = SubjectSignals(rawValue: 1 << 3)
    static let deal = SubjectSignals(rawValue: 1 << 4)
    static let emoji = SubjectSignals(rawValue: 1 << 5)
    static let caps = SubjectSignals(rawValue: 1 << 6)
    static let fakeReply = SubjectSignals(rawValue: 1 << 7)

    static func detect(_ subject: String) -> SubjectSignals {
        let raw = subject.lowercased()
        let words = SpamScorer.words(in: subject)
        var hits: SubjectSignals = []
        if raw.contains("you won") || raw.contains("you've won") || raw.contains("you have won")
            || raw.contains("claim your") || words.contains("prize") || words.contains("winner") {
            hits.insert(.prize)
        }
        if raw.contains("gift card") || raw.contains("giftcard") {
            hits.insert(.gift)
        }
        if raw.contains("verify your") || raw.contains("verify account") || raw.contains("unusual sign")
            || raw.contains("unusual activity") || raw.contains("urgent") || words.contains("suspended") {
            hits.insert(.verify)
        }
        if words.contains("crypto") || words.contains("bitcoin") || words.contains("btc")
            || words.contains("ethereum") || words.contains("nft") {
            hits.insert(.crypto)
        }
        if raw.contains("% off") || raw.contains("percent off") || raw.contains("limited time") || words.contains("deal") {
            hits.insert(.deal)
        }
        if containsEmoji(subject) { hits.insert(.emoji) }
        if mostlyCaps(subject) { hits.insert(.caps) }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("re:") || trimmed.hasPrefix("re :") || trimmed.hasPrefix("fw:") || trimmed.hasPrefix("fwd:") {
            hits.insert(.fakeReply)
        }
        return hits
    }

    private static func containsEmoji(_ text: String) -> Bool {
        text.contains { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        }
    }

    private static func mostlyCaps(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 8 else { return false }
        let caps = letters.filter(\.isUppercase).count
        return caps * 5 >= letters.count * 4
    }
}

enum AuthKind {
    case pass
    case partial
    case fail
    case none
}

enum AuthVerdict {
    static func classify(authentication: String, receivedSPF: String) -> AuthKind {
        var spf = token("spf", in: authentication)
        if spf == .missing {
            spf = receivedSPFState(receivedSPF)
        }
        let dkim = token("dkim", in: authentication)
        let dmarc = token("dmarc", in: authentication)
        let states = [spf, dkim, dmarc]
        if states.contains(.fail) { return .fail }
        if spf == .pass && dkim == .pass && dmarc == .pass { return .pass }
        if states.contains(.pass) { return .partial }
        return .none
    }

    private enum Check {
        case pass
        case fail
        case missing
    }

    private static func token(_ name: String, in text: String) -> Check {
        let lower = text.lowercased()
        let needle = name + "="
        var search = lower.startIndex
        var sawPass = false
        while let range = lower.range(of: needle, range: search..<lower.endIndex) {
            let rest = lower[range.upperBound...]
            let value = rest.prefix { $0.isLetter }
            if value == "fail" || value == "softfail" || value == "hardfail" || value == "permerror" || value == "temperror" {
                return .fail
            }
            if value == "pass" { sawPass = true }
            search = range.upperBound
        }
        return sawPass ? .pass : .missing
    }

    private static func receivedSPFState(_ text: String) -> Check {
        let word = text.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        switch word {
        case "pass":
            return .pass
        case "fail", "softfail", "hardfail":
            return .fail
        default:
            return .missing
        }
    }
}

struct SenderAggregate: Codable, Equatable, Identifiable {
    var address: String
    var displayName: String = ""
    var domain: String = ""
    var count: Int = 0
    var totalBytes: Int = 0
    var subjects: [String] = []
    var newestUID: UInt64 = 0
    var replyToMismatch: Int = 0
    var returnPathMismatch: Int = 0
    var replyDomain: String = ""
    var returnDomain: String = ""
    var authPass: Int = 0
    var authPartial: Int = 0
    var authFail: Int = 0
    var authNone: Int = 0
    var unsubscribe: Int = 0
    var precedenceJunk: Int = 0
    var inBulk: Int = 0
    var spamStatusHits: Int = 0
    var newmanSpam: Int = 0
    var subjectPrize: Int = 0
    var subjectGift: Int = 0
    var subjectVerify: Int = 0
    var subjectCrypto: Int = 0
    var subjectDeal: Int = 0
    var subjectEmoji: Int = 0
    var subjectCaps: Int = 0
    var subjectFakeReply: Int = 0
    var id: String { address }
}

enum SenderStats {
    static func fold(_ header: MailHeader, into map: inout [String: SenderAggregate]) {
        let address = header.fromAddress.lowercased()
        var sender = map[address] ?? SenderAggregate(address: address)
        if sender.domain.isEmpty {
            sender.domain = MailAddress.domain(of: address)
        }
        sender.count += 1
        sender.totalBytes += max(0, header.size)
        let name = header.fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let newBrand = SpamScorer.claimsBrand(name)
            let oldBrand = SpamScorer.claimsBrand(sender.displayName)
            if sender.displayName.isEmpty || (newBrand && !oldBrand) || (!oldBrand && name.count > sender.displayName.count) {
                sender.displayName = name
            }
        }
        let subject = MailAddress.cleanSubject(header.subject)
        if header.uid >= sender.newestUID {
            sender.newestUID = header.uid
            sender.subjects.removeAll { $0 == subject }
            sender.subjects.insert(subject, at: 0)
            if sender.subjects.count > 5 {
                sender.subjects.removeLast(sender.subjects.count - 5)
            }
        } else if sender.subjects.count < 5, !sender.subjects.contains(subject) {
            sender.subjects.append(subject)
        }
        switch AuthVerdict.classify(authentication: header.authentication, receivedSPF: header.receivedSPF) {
        case .pass: sender.authPass += 1
        case .partial: sender.authPartial += 1
        case .fail: sender.authFail += 1
        case .none: sender.authNone += 1
        }
        if let reply = header.replyTo {
            let replyDomain = MailAddress.domain(of: reply)
            if SpamScorer.domainsDiffer(sender.domain, replyDomain) {
                sender.replyToMismatch += 1
                sender.replyDomain = replyDomain
            }
        }
        if let path = header.returnPath {
            let pathDomain = MailAddress.domain(of: path)
            if SpamScorer.domainsDiffer(sender.domain, pathDomain) {
                sender.returnPathMismatch += 1
                sender.returnDomain = pathDomain
            }
        }
        let hits = SubjectSignals.detect(header.subject)
        if hits.contains(.prize) { sender.subjectPrize += 1 }
        if hits.contains(.gift) { sender.subjectGift += 1 }
        if hits.contains(.verify) { sender.subjectVerify += 1 }
        if hits.contains(.crypto) { sender.subjectCrypto += 1 }
        if hits.contains(.deal) { sender.subjectDeal += 1 }
        if hits.contains(.emoji) { sender.subjectEmoji += 1 }
        if hits.contains(.caps) { sender.subjectCaps += 1 }
        if hits.contains(.fakeReply) { sender.subjectFakeReply += 1 }
        if header.unsubscribe { sender.unsubscribe += 1 }
        let precedence = header.precedence.lowercased()
        if precedence.contains("junk") || precedence.contains("bulk") { sender.precedenceJunk += 1 }
        if header.inBulk { sender.inBulk += 1 }
        if header.spamStatus.lowercased().hasPrefix("yes") { sender.spamStatusHits += 1 }
        let newman = header.newman.lowercased()
        if newman.contains("spam") || newman.contains("phish") { sender.newmanSpam += 1 }
        map[address] = sender
    }

    static func aggregate(_ headers: [MailHeader]) -> [SenderAggregate] {
        var map: [String: SenderAggregate] = [:]
        for header in headers {
            fold(header, into: &map)
        }
        return Array(map.values)
    }
}

struct ScanFolder: Equatable {
    var name: String
    var countsAsJunk: Bool
}

enum MailboxPlan {
    static func sentName(_ boxes: [IMAPMailbox]) -> String? {
        match(boxes, flag: "sent", names: ["sent", "sent items", "sent messages"])
    }

    static func targets(_ boxes: [IMAPMailbox], includeBulk: Bool, includeOther: Bool) -> [ScanFolder] {
        var result: [ScanFolder] = []
        let inbox = boxes.first { $0.name.uppercased() == "INBOX" || $0.flags.contains("inbox") }?.name ?? "INBOX"
        result.append(ScanFolder(name: inbox, countsAsJunk: false))
        if includeBulk, let junk = match(boxes, flag: "junk", names: ["bulk", "junk", "junk mail"]) {
            if junk.caseInsensitiveCompare(inbox) != .orderedSame {
                result.append(ScanFolder(name: junk, countsAsJunk: true))
            }
        }
        if includeOther {
            let skipFlags: Set<String> = ["sent", "trash", "drafts", "junk", "inbox", "all", "flagged", "noselect", "nonexistent"]
            let skipNames: Set<String> = [
                "sent", "sent items", "sent messages", "trash", "deleted", "deleted items", "deleted messages",
                "drafts", "draft", "junk", "junk mail", "bulk", "inbox", "all mail",
            ]
            for box in boxes {
                if box.flags.contains(where: { skipFlags.contains($0) }) { continue }
                if skipNames.contains(box.name.lowercased()) { continue }
                if result.contains(where: { $0.name.caseInsensitiveCompare(box.name) == .orderedSame }) { continue }
                result.append(ScanFolder(name: box.name, countsAsJunk: false))
            }
        }
        return result
    }

    private static func match(_ boxes: [IMAPMailbox], flag: String, names: [String]) -> String? {
        if let found = boxes.first(where: { $0.flags.contains(flag) }) {
            return found.name
        }
        let wanted = Set(names)
        return boxes.first { wanted.contains($0.name.lowercased()) }?.name
    }
}

enum ScanETA {
    static func text(done: Int, total: Int, elapsed: TimeInterval) -> String {
        guard done >= 20, elapsed > 1, total > done else { return "" }
        let remain = elapsed / Double(done) * Double(total - done)
        if remain < 45 { return "under a minute left" }
        let minutes = Int((remain / 60).rounded())
        if minutes <= 90 { return "about \(minutes) min left" }
        return String(format: "about %.1f hours left", remain / 3600)
    }
}
