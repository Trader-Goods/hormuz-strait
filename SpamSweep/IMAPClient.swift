import Foundation
import Network
import Security

enum IMAPError: Error {
    case disconnected
    case connectionFailed(String)
    case loginFailed(String)
    case unavailable(String)
    case refused(String)
    case badResponse
    case missingFolder(String)
    case keychain
    case invalidPassword
    case busy
}

enum YahooAccount {
    static func normalizeEmail(_ raw: String) -> String {
        var email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty && !email.contains("@") {
            email += "@yahoo.com"
        }
        return email
    }

    private static let dashes: Set<Unicode.Scalar> = ["-", "–", "—", "−"]

    static func normalizePassword(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            return !dashes.contains(scalar)
        }
        var built = ""
        built.unicodeScalars.append(contentsOf: stripped)
        return built.lowercased()
    }

    /// Yahoo app passwords are 16 lowercase letters. Empty input stays quiet so the field can start blank.
    static func passwordHint(for raw: String) -> String? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let password = normalizePassword(raw)
        let letters = password.allSatisfy { $0.isASCII && $0.isLetter }
        if password.count == 16 && letters { return nil }
        if !letters {
            return "Yahoo app passwords are 16 letters. After removing spaces and dashes, this one has \(password.count) characters and is not only letters."
        }
        return "Yahoo app passwords are 16 letters. After removing spaces and dashes, this one has \(password.count)."
    }
}

enum IMAPText {
    static func plainToken(email: String, password: String) -> String {
        var raw = Data([0])
        raw.append(contentsOf: email.utf8)
        raw.append(0)
        raw.append(contentsOf: password.utf8)
        return raw.base64EncodedString()
    }

    static func isUnavailable(_ text: String) -> Bool {
        text.range(of: "[UNAVAILABLE]", options: .caseInsensitive) != nil
    }

    static func redact(_ text: String, password: String, token: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\u{0}", with: "")
        if password.count >= 8 {
            cleaned = cleaned.replacingOccurrences(of: password, with: "[password]", options: .caseInsensitive)
        }
        if token.count >= 8 {
            cleaned = cleaned.replacingOccurrences(of: token, with: "[sasl]")
        }
        return clip(cleaned)
    }

    static func clip(_ text: String, limit: Int = 300) -> String {
        let flat = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit))
    }

    static func transcript(_ lines: [String]) -> String {
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }
        let text = unique.joined(separator: "\n")
        if text.count <= 900 { return text }
        return String(text.suffix(900))
    }

    static func capabilityTokens(in lines: [Data]) -> Set<String> {
        var tokens = Set<String>()
        for line in lines {
            let upper = String(decoding: line, as: UTF8.self).uppercased()
            guard let range = upper.range(of: "CAPABILITY") else { continue }
            for token in upper[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "[" || $0 == "]" }) {
                if !token.isEmpty { tokens.insert(String(token)) }
            }
        }
        return tokens
    }
}

struct IMAPMailbox {
    var name: String
    var flags: Set<String>
}

struct FetchedMail {
    var uid: UInt64
    var name: String
    var address: String
    var subject: String
    var hasUnsubscribe: Bool
    var recipients: [String]
}

enum UIDSet {
    /// `101:250,300,412:900` rather than one number per message.
    static func encode(_ uids: [UInt64]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var rangeStart: UInt64 = 0
        var rangeEnd: UInt64 = 0
        var open = false
        for uid in sorted {
            if !open {
                rangeStart = uid
                rangeEnd = uid
                open = true
            } else if uid == rangeEnd + 1 {
                rangeEnd = uid
            } else {
                parts.append(rangeStart == rangeEnd ? "\(rangeStart)" : "\(rangeStart):\(rangeEnd)")
                rangeStart = uid
                rangeEnd = uid
            }
        }
        if open {
            parts.append(rangeStart == rangeEnd ? "\(rangeStart)" : "\(rangeStart):\(rangeEnd)")
        }
        return parts.joined(separator: ",")
    }

    /// Prefer 1000–2000 messages per command. Sparse ids stay short enough for one IMAP line.
    static func chunks(_ uids: [UInt64], targetCount: Int = 1500, maxCharacters: Int = 6000) -> [[UInt64]] {
        let sorted = Array(Set(uids)).sorted()
        var chunks: [[UInt64]] = []
        var current: [UInt64] = []
        for uid in sorted {
            current.append(uid)
            let tooLong = current.count > 1 && encode(current).count > maxCharacters
            if tooLong {
                let overflow = current.removeLast()
                chunks.append(current)
                current = [overflow]
            } else if current.count >= targetCount {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    static func senderLabel(_ uids: [UInt64], owners: [UInt64: String]) -> String {
        var counts: [String: Int] = [:]
        for uid in uids {
            let name = owners[uid] ?? "Unknown sender"
            counts[name, default: 0] += 1
        }
        let ranked = counts.sorted { left, right in
            if left.value == right.value { return left.key < right.key }
            return left.value > right.value
        }
        guard let first = ranked.first else { return "Mail" }
        if ranked.count == 1 { return first.key }
        return "\(first.key) and \(ranked.count - 1) more"
    }
}

enum MoveETA {
    static func text(sessionMoved: Int, total: Int, moved: Int, elapsed: TimeInterval) -> String {
        guard sessionMoved > 0, total > moved, elapsed > 0.2 else {
            return total > moved ? "Estimating time left" : ""
        }
        let remain = elapsed / Double(sessionMoved) * Double(total - moved)
        if remain < 45 { return "under a minute left" }
        let minutes = Int((remain / 60).rounded())
        if minutes <= 90 { return "about \(minutes) min left" }
        return String(format: "about %.1f hours left", remain / 3600)
    }
}

enum IMAPValue {
    case atom(String)
    case string(String)
    case list([IMAPValue])
    case bytes(Data)
}

actor IMAPClient {
    private let host = "imap.mail.yahoo.com"
    private let port: UInt16 = 993
    private var connection: NWConnection?
    private var buffer = Data()
    private var tagNumber = 0
    private var selected = ""
    private var greetingLine = ""

    func connect() async throws {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        selected = ""
        greetingLine = ""
        do {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 30
            let parameters = NWParameters(tls: tls, tcp: tcp)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw IMAPError.connectionFailed("Could not open port 993.")
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
            self.connection = connection
            try await waitUntilReady(connection)
            let greeting = try await readLogicalLine()
            let raw = String(decoding: greeting, as: UTF8.self)
            greetingLine = raw
            let upper = raw.uppercased()
            if IMAPText.isUnavailable(raw) {
                throw IMAPError.unavailable(IMAPText.clip(raw))
            }
            if upper.contains("BYE") || !upper.contains("OK") {
                throw IMAPError.connectionFailed(IMAPText.clip(raw))
            }
        } catch let error as IMAPError {
            throw error
        } catch {
            throw IMAPError.connectionFailed(IMAPText.clip(error.localizedDescription))
        }
    }

    /// CAPABILITY, then ID, then LOGIN. A NO with AUTH=PLAIN falls back to AUTHENTICATE PLAIN. [UNAVAILABLE] is retried by the caller.
    func login(email rawEmail: String, password rawPassword: String) async throws {
        let email = YahooAccount.normalizeEmail(rawEmail)
        let password = YahooAccount.normalizePassword(rawPassword)
        guard !password.isEmpty else { throw IMAPError.invalidPassword }
        guard !password.contains("\r"), !password.contains("\n") else { throw IMAPError.invalidPassword }
        var lastUnavailable = ""
        for attempt in 1...4 {
            do {
                try await signInOnce(email: email, password: password)
                return
            } catch let error as IMAPError {
                guard case .unavailable(let detail) = error else { throw error }
                lastUnavailable = detail
                if attempt == 4 { break }
                let seconds = UInt64(1 << (attempt - 1))
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
        throw IMAPError.unavailable(lastUnavailable)
    }

    func listMailboxes() async throws -> [IMAPMailbox] {
        let result = try await command("LIST \"\" \"*\"")
        try requireOK(result)
        return result.untagged.compactMap(parseList)
    }

    func select(_ mailbox: String) async throws {
        let result = try await command("SELECT \(quote(mailbox))")
        try requireOK(result)
        selected = mailbox
    }

    func uidSearchAll() async throws -> [UInt64] {
        let result = try await command("UID SEARCH ALL")
        try requireOK(result)
        return searchUIDs(result.untagged)
    }

    func uidSearch(from needle: String) async throws -> [UInt64] {
        let result = try await command("UID SEARCH FROM \(quote(needle))")
        try requireOK(result)
        return searchUIDs(result.untagged)
    }

    /// One OR query per batch, instead of a round trip for every sender.
    func uidSearchSenders(_ addresses: [String]) async throws -> [UInt64] {
        let unique = Array(Set(addresses.map { $0.lowercased() }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [] }
        var found = Set<UInt64>()
        var index = 0
        while index < unique.count {
            let end = min(index + 40, unique.count)
            let slice = Array(unique[index..<end])
            let result = try await command("UID SEARCH \(fromTree(slice))")
            try requireOK(result)
            found.formUnion(searchUIDs(result.untagged))
            index = end
        }
        return Array(found)
    }

    func uidFetch(uids: [UInt64], headers: Bool) async throws -> [FetchedMail] {
        guard !uids.isEmpty else { return [] }
        var found: [FetchedMail] = []
        var index = 0
        while index < uids.count {
            let end = min(index + 40, uids.count)
            let slice = Array(uids[index..<end])
            let fields = headers
                ? "(UID ENVELOPE BODY.PEEK[HEADER.FIELDS (LIST-UNSUBSCRIBE)])"
                : "(UID ENVELOPE)"
            let result = try await command("UID FETCH \(uidSet(slice)) \(fields)")
            try requireOK(result)
            found.append(contentsOf: result.untagged.compactMap(parseFetch))
            index = end
        }
        return found
    }

    /// Header-only fetch. BODY.PEEK does not mark the message read, and the body is never requested.
    func uidFetchHeaders(uids: [UInt64], fields: String) async throws -> [FetchedHeader] {
        guard !uids.isEmpty else { return [] }
        var found: [FetchedHeader] = []
        var index = 0
        while index < uids.count {
            let end = min(index + 80, uids.count)
            let slice = Array(uids[index..<end])
            let result = try await command("UID FETCH \(uidSet(slice)) (\(fields))")
            try requireOK(result)
            for line in result.untagged {
                if let header = HeaderFetch.parseLine(line) {
                    found.append(header)
                }
            }
            index = end
        }
        return found
    }

    /// Moves messages in chunks. If UID MOVE is refused, copies them and then deletes the originals.
    func uidMove(uids: [UInt64], to mailbox: String, onProgress: ((Int, Int) -> Void)? = nil) async throws {
        guard !uids.isEmpty else { return }
        if selected.isEmpty { throw IMAPError.badResponse }
        let pieces = UIDSet.chunks(uids)
        var done = 0
        let total = pieces.reduce(0) { $0 + $1.count }
        for piece in pieces {
            try await moveChunk(piece, to: mailbox)
            done += piece.count
            onProgress?(done, total)
        }
    }

    func moveMessages(_ uids: [UInt64], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        if selected.isEmpty { throw IMAPError.badResponse }
        try await moveChunk(uids, to: mailbox)
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        connection?.cancel()
        connection = nil
        selected = ""
        buffer.removeAll()
    }

    private func signInOnce(email: String, password: String) async throws {
        let token = IMAPText.plainToken(email: email, password: password)
        try await connect()
        var caps = try await requestCapabilities()
        caps.formUnion(IMAPText.capabilityTokens(in: [Data(greetingLine.utf8)]))
        var notes = ["CAPABILITY: \(caps.sorted().joined(separator: " "))"]
        let idLine = try await sendClientID()
        notes.append("ID: \(IMAPText.redact(idLine, password: password, token: token))")

        let loginResult = try await command("LOGIN \(quote(email)) \(quote(password))")
        if loginResult.ok { return }
        let loginLine = IMAPText.redact(loginResult.tagLine, password: password, token: token)
        notes.append("LOGIN: \(loginLine)")
        if IMAPText.isUnavailable(loginResult.tagLine) {
            throw IMAPError.unavailable(IMAPText.transcript(notes))
        }
        guard caps.contains("AUTH=PLAIN") else {
            throw IMAPError.loginFailed(IMAPText.transcript(notes))
        }
        do {
            try await finishPlain(
                email: email,
                password: password,
                token: token,
                saslIR: caps.contains("SASL-IR"),
                notes: &notes
            )
        } catch let error as IMAPError {
            guard case .connectionFailed(let detail) = error else { throw error }
            notes.append("Connection closed after LOGIN: \(IMAPText.redact(detail, password: password, token: token))")
            do {
                try await connect()
                let retryCaps = try await requestCapabilities()
                _ = try await sendClientID()
                try await finishPlain(
                    email: email,
                    password: password,
                    token: token,
                    saslIR: retryCaps.contains("SASL-IR"),
                    notes: &notes
                )
            } catch let retry as IMAPError {
                switch retry {
                case .loginFailed, .unavailable:
                    throw retry
                case .connectionFailed(let again):
                    notes.append(IMAPText.redact(again, password: password, token: token))
                    throw IMAPError.connectionFailed(IMAPText.transcript(notes))
                default:
                    throw retry
                }
            }
        }
    }

    private func finishPlain(
        email: String,
        password: String,
        token: String,
        saslIR: Bool,
        notes: inout [String]
    ) async throws {
        let plain = try await authenticatePlain(email: email, password: password, saslIR: saslIR)
        if plain.ok { return }
        let plainLine = IMAPText.redact(plain.tagLine, password: password, token: token)
        notes.append("AUTHENTICATE PLAIN: \(plainLine)")
        if IMAPText.isUnavailable(plain.tagLine) {
            throw IMAPError.unavailable(IMAPText.transcript(notes))
        }
        throw IMAPError.loginFailed(IMAPText.transcript(notes))
    }

    private func requestCapabilities() async throws -> Set<String> {
        let result = try await command("CAPABILITY")
        var tokens = IMAPText.capabilityTokens(in: result.untagged)
        tokens.formUnion(IMAPText.capabilityTokens(in: [Data(result.tagLine.utf8)]))
        return tokens
    }

    private func sendClientID() async throws -> String {
        let result = try await command("ID (\"name\" \"SpamSweep\" \"version\" \"1.0\")")
        return result.tagLine
    }

    /// SASL-IR sends the initial response on the command line. Otherwise the server sends `+` first.
    private func authenticatePlain(email: String, password: String, saslIR: Bool) async throws -> CommandResult {
        let token = IMAPText.plainToken(email: email, password: password)
        tagNumber += 1
        let tag = String(format: "A%03d", tagNumber)
        if saslIR {
            try await sendLine("\(tag) AUTHENTICATE PLAIN \(token)")
        } else {
            try await sendLine("\(tag) AUTHENTICATE PLAIN")
        }
        var untagged: [Data] = []
        var sent = saslIR
        while true {
            let line = try await readLogicalLine()
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("+") {
                if !sent {
                    try await sendLine(token)
                    sent = true
                } else {
                    try await sendLine("")
                }
                continue
            }
            if text.uppercased().hasPrefix("* BYE"), IMAPText.isUnavailable(text) {
                throw IMAPError.unavailable(IMAPText.clip(text))
            }
            if isTagged(line, tag: tag) {
                return CommandResult(tagLine: text, untagged: untagged)
            }
            untagged.append(line)
        }
    }

    private func moveChunk(_ uids: [UInt64], to mailbox: String) async throws {
        do {
            try await moveBatch(uids, to: mailbox)
        } catch {
            guard uids.count > 100 else { throw error }
            let mid = uids.count / 2
            try await moveChunk(Array(uids[..<mid]), to: mailbox)
            try await moveChunk(Array(uids[mid...]), to: mailbox)
        }
    }

    private func moveBatch(_ uids: [UInt64], to mailbox: String) async throws {
        let set = uidSet(uids)
        let destination = quote(mailbox)
        let moved = try await command("UID MOVE \(set) \(destination)")
        if moved.ok { return }
        let copied = try await command("UID COPY \(set) \(destination)")
        try requireOK(copied)
        let stored = try await command("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        try requireOK(stored)
        let expunged = try await command("UID EXPUNGE \(set)")
        if !expunged.ok {
            try requireOK(try await command("EXPUNGE"))
        }
    }

    private struct CommandResult {
        var tagLine: String
        var untagged: [Data]
        var ok: Bool {
            let parts = tagLine.split(separator: " ")
            return parts.count >= 2 && parts[1].uppercased() == "OK"
        }
    }

    private func command(_ body: String) async throws -> CommandResult {
        tagNumber += 1
        let tag = String(format: "A%03d", tagNumber)
        try await sendLine("\(tag) \(body)")
        var untagged: [Data] = []
        while true {
            let line = try await readLogicalLine()
            let text = String(decoding: line, as: UTF8.self)
            if text.uppercased().hasPrefix("* BYE"), IMAPText.isUnavailable(text) {
                throw IMAPError.unavailable(IMAPText.clip(text))
            }
            if isTagged(line, tag: tag) {
                return CommandResult(tagLine: text, untagged: untagged)
            }
            untagged.append(line)
        }
    }

    private func isTagged(_ line: Data, tag: String) -> Bool {
        line.starts(with: Data("\(tag) ".utf8))
    }

    private func sendLine(_ text: String) async throws {
        try await send(Data("\(text)\r\n".utf8))
    }

    private func requireOK(_ result: CommandResult) throws {
        if result.ok { return }
        let text = result.tagLine
        let clipped = text.count > 180 ? String(text.prefix(180)) : text
        throw IMAPError.refused(clipped)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() {
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    }
                case .failed(let error):
                    if gate.claim() {
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if gate.claim() {
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: IMAPError.disconnected)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func send(_ data: Data) async throws {
        guard let connection else { throw IMAPError.connectionFailed("Yahoo closed the connection.") }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } catch let error as IMAPError {
            throw error
        } catch {
            throw IMAPError.connectionFailed(IMAPText.clip(error.localizedDescription))
        }
    }

    private func fill() async throws {
        guard let connection else { throw IMAPError.connectionFailed("Yahoo closed the connection.") }
        let chunk: Data?
        do {
            chunk = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }
                    if isComplete {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: Data())
                }
            }
        } catch let error as IMAPError {
            throw error
        } catch {
            throw IMAPError.connectionFailed(IMAPText.clip(error.localizedDescription))
        }
        guard let chunk else { throw IMAPError.connectionFailed("Yahoo closed the connection.") }
        if !chunk.isEmpty {
            buffer.append(chunk)
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fill()
        }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    private func readLine() async throws -> Data {
        let marker = Data([0x0D, 0x0A])
        while true {
            if let range = buffer.range(of: marker) {
                let line = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                return line
            }
            try await fill()
        }
    }

    private func readLogicalLine() async throws -> Data {
        var assembled = Data()
        while true {
            let line = try await readLine()
            if let count = literalCount(atEndOf: line) {
                assembled.append(line)
                assembled.append(try await readExact(count))
            } else {
                assembled.append(line)
                return assembled
            }
        }
    }

    private func literalCount(atEndOf line: Data) -> Int? {
        let bytes = [UInt8](line)
        guard let last = bytes.last, last == UInt8(ascii: "}") else { return nil }
        var index = bytes.count - 2
        if index >= 0 && bytes[index] == UInt8(ascii: "+") {
            index -= 1
        }
        var digits: [UInt8] = []
        while index >= 0 && bytes[index] >= 48 && bytes[index] <= 57 {
            digits.append(bytes[index])
            index -= 1
        }
        guard index >= 0, bytes[index] == UInt8(ascii: "{"), !digits.isEmpty else { return nil }
        return digits.reversed().reduce(0) { $0 * 10 + Int($1 - 48) }
    }

    private func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func uidSet(_ uids: [UInt64]) -> String {
        UIDSet.encode(uids)
    }

    private func fromTree(_ addresses: [String]) -> String {
        let keys = addresses.map { "FROM \(quote($0))" }
        guard var text = keys.first else { return "ALL" }
        for key in keys.dropFirst() {
            text = "OR \(text) \(key)"
        }
        return text
    }

    private func searchUIDs(_ lines: [Data]) -> [UInt64] {
        var uids: [UInt64] = []
        for line in lines {
            let text = String(decoding: line, as: UTF8.self)
            guard text.hasPrefix("* SEARCH") else { continue }
            for token in text.dropFirst("* SEARCH".count).split(separator: " ") {
                if let uid = UInt64(token) {
                    uids.append(uid)
                }
            }
        }
        return uids
    }

    private func parseList(_ line: Data) -> IMAPMailbox? {
        let prefix = Data("* LIST ".utf8)
        guard line.starts(with: prefix) else { return nil }
        var parser = IMAPParser(bytes: [UInt8](line.dropFirst(prefix.count)))
        guard let flags = try? parser.parseValue(),
              let _ = try? parser.parseValue(),
              let nameValue = try? parser.parseValue(),
              case .list(let flagValues) = flags,
              let name = Self.nstring(nameValue),
              !name.isEmpty
        else { return nil }
        let names = Set(flagValues.compactMap { value -> String? in
            guard case .atom(let flag) = value else { return nil }
            return flag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        })
        return IMAPMailbox(name: name, flags: names)
    }

    private func parseFetch(_ line: Data) -> FetchedMail? {
        guard let fetch = line.range(of: Data(" FETCH ".utf8)) else { return nil }
        let body = Data(line[fetch.upperBound...])
        guard let uid = Self.number(after: "UID ", in: body) else { return nil }
        var envelope: [IMAPValue]?
        if let marker = body.range(of: Data("ENVELOPE ".utf8)) {
            var parser = IMAPParser(bytes: [UInt8](body[marker.upperBound...]))
            if let value = try? parser.parseValue(), case .list(let items) = value {
                envelope = items
            }
        }
        let from = envelope.flatMap { Self.addressList($0, index: 2) } ?? []
        guard let sender = from.first else { return nil }
        let subject = envelope.flatMap { Self.nstring(at: $0, index: 1) }.map(HeaderText.decode) ?? ""
        let name = HeaderText.decode(sender.name ?? "")
        let to = envelope.flatMap { Self.addressList($0, index: 5) } ?? []
        let cc = envelope.flatMap { Self.addressList($0, index: 6) } ?? []
        return FetchedMail(
            uid: uid,
            name: name,
            address: sender.email,
            subject: subject.isEmpty ? "(no subject)" : subject,
            hasUnsubscribe: Self.containsHeader(body, "list-unsubscribe:"),
            recipients: (to + cc).map(\.email)
        )
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

    private static func containsHeader(_ data: Data, _ needle: String) -> Bool {
        let hay = [UInt8](data)
        let pin = [UInt8](needle.utf8)
        guard !pin.isEmpty, hay.count >= pin.count else { return false }
        func lower(_ byte: UInt8) -> UInt8 {
            byte >= 65 && byte <= 90 ? byte + 32 : byte
        }
        let lowered = pin.map(lower)
        for start in 0...(hay.count - pin.count) {
            var matches = true
            for offset in 0..<pin.count where lower(hay[start + offset]) != lowered[offset] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }

    private struct AddressParts {
        var name: String?
        var email: String
    }

    private static func addressList(_ envelope: [IMAPValue], index: Int) -> [AddressParts]? {
        guard envelope.indices.contains(index) else { return nil }
        guard case .list(let items) = envelope[index] else { return nil }
        return items.compactMap(address)
    }

    private static func address(_ value: IMAPValue) -> AddressParts? {
        guard case .list(let parts) = value, parts.count >= 4 else { return nil }
        guard let mailbox = nstring(parts[2]), let host = nstring(parts[3]) else { return nil }
        let email = "\(mailbox)@\(host)".lowercased()
        guard email.contains("@") else { return nil }
        return AddressParts(name: nstring(parts[0]), email: email)
    }

    private static func nstring(at values: [IMAPValue], index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        return nstring(values[index])
    }

    private static func nstring(_ value: IMAPValue) -> String? {
        switch value {
        case .atom(let text):
            return text.uppercased() == "NIL" ? nil : text
        case .string(let text):
            return text
        case .bytes(let data):
            return String(decoding: data, as: UTF8.self)
        case .list:
            return nil
        }
    }
}

private struct IMAPParser {
    var bytes: [UInt8]
    var index = 0

    mutating func parseValue() throws -> IMAPValue {
        skipSpace()
        guard index < bytes.count else { throw IMAPError.badResponse }
        let byte = bytes[index]
        if byte == UInt8(ascii: "(") { return try parseList() }
        if byte == UInt8(ascii: "\"") { return .string(try parseQuoted()) }
        if byte == UInt8(ascii: "{") { return .bytes(try parseLiteral()) }
        return .atom(parseAtom())
    }

    private mutating func parseList() throws -> IMAPValue {
        index += 1
        var items: [IMAPValue] = []
        skipSpace()
        while index < bytes.count && bytes[index] != UInt8(ascii: ")") {
            items.append(try parseValue())
            skipSpace()
        }
        guard index < bytes.count else { throw IMAPError.badResponse }
        index += 1
        return .list(items)
    }

    private mutating func parseQuoted() throws -> String {
        index += 1
        var units: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\\") {
                guard index < bytes.count else { throw IMAPError.badResponse }
                units.append(bytes[index])
                index += 1
            } else if byte == UInt8(ascii: "\"") {
                return String(decoding: Data(units), as: UTF8.self)
            } else {
                units.append(byte)
            }
        }
        throw IMAPError.badResponse
    }

    private mutating func parseLiteral() throws -> Data {
        index += 1
        var count = 0
        var digits = 0
        while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 {
            count = count * 10 + Int(bytes[index] - 48)
            digits += 1
            index += 1
        }
        if index < bytes.count && bytes[index] == UInt8(ascii: "+") {
            index += 1
        }
        guard digits > 0, index < bytes.count, bytes[index] == UInt8(ascii: "}") else {
            throw IMAPError.badResponse
        }
        index += 1
        let end = index + count
        guard end <= bytes.count else { throw IMAPError.badResponse }
        let data = Data(bytes[index..<end])
        index = end
        return data
    }

    private mutating func parseAtom() -> String {
        let start = index
        let specials = Set<UInt8>([UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: " "), UInt8(ascii: "\"")])
        while index < bytes.count && !specials.contains(bytes[index]) {
            index += 1
        }
        return String(decoding: Data(bytes[start..<index]), as: UTF8.self)
    }

    private mutating func skipSpace() {
        while index < bytes.count && (bytes[index] == 32 || bytes[index] == 9) {
            index += 1
        }
    }
}

enum HeaderText {
    static func decode(_ raw: String) -> String {
        var result = ""
        var rest = Substring(raw)
        while let start = rest.range(of: "=?") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "?=") else {
                result += rest[start.lowerBound...]
                return collapse(result)
            }
            let token = String(rest[start.upperBound..<end.lowerBound])
            result += decodeWord(token) ?? String(rest[start.lowerBound..<end.upperBound])
            rest = rest[end.upperBound...]
        }
        result += rest
        return collapse(result)
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeWord(_ token: String) -> String? {
        let parts = token.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = parts[0].lowercased()
        let coding = parts[1].uppercased()
        let text = String(parts[2])
        let data: Data?
        if coding == "B" {
            data = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        } else if coding == "Q" {
            data = decodeQuotedPrintable(text)
        } else {
            return nil
        }
        guard let data else { return nil }
        switch charset {
        case "utf-8", "us-ascii":
            return String(data: data, encoding: .utf8)
        case "iso-8859-1", "windows-1252":
            return String(data: data, encoding: .isoLatin1)
        default:
            return String(data: data, encoding: .utf8)
        }
    }

    private static func decodeQuotedPrintable(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "_" {
                bytes.append(32)
                index = text.index(after: index)
            } else if character == "=", text.distance(from: index, to: text.endIndex) >= 3 {
                let first = text.index(after: index)
                let second = text.index(after: first)
                let hex = text[first...second]
                if let value = UInt8(hex, radix: 16) {
                    bytes.append(value)
                    index = text.index(after: second)
                } else {
                    bytes.append(UInt8(ascii: "="))
                    index = text.index(after: index)
                }
            } else {
                let scalar = character.unicodeScalars.first?.value ?? 63
                bytes.append(UInt8(scalar > 255 ? 63 : scalar))
                index = text.index(after: index)
            }
        }
        return Data(bytes)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
