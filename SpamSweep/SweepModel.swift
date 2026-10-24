import Foundation
import SwiftUI

struct BlockEntry: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable {
        case address
        case domain
    }

    var kind: Kind
    var value: String
    var id: String { "\(kind.rawValue):\(value)" }
}

struct SenderGroup: Identifiable, Equatable {
    var address: String
    var name: String
    var domain: String
    var count: Int
    var latestSubject: String
    var hints: [String]
    var id: String { address }

    var title: String { name.isEmpty ? address : name }
}

enum LocalDatabase {
    struct Snapshot: Codable {
        var scanLimit = 2000
        var sweptTotal = 0
        var blocks: [BlockEntry] = []
    }

    private static let lock = NSLock()

    static func load() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    static func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = read()
        change(&snapshot)
        write(snapshot)
    }

    private static func read() -> Snapshot {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }
        return snapshot
    }

    private static func write(_ snapshot: Snapshot) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = base.appendingPathComponent("SpamSweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("store.json")
    }
}

actor SweepGate {
    static let shared = SweepGate()
    private var busy = false

    func enter() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    func leave() {
        busy = false
    }
}

enum SweepEngine {
    static func describe(_ error: Error) -> String {
        switch error {
        case IMAPError.loginFailed:
            return "Yahoo refused the sign-in. Use your Yahoo email and an app password from Account Security, not your normal Yahoo password."
        case IMAPError.invalidPassword:
            return "The app password cannot contain a line break."
        case IMAPError.keychain:
            return "The password could not be saved in the iPhone Keychain."
        case IMAPError.missingFolder(let name):
            return "Yahoo did not list a \(name) folder."
        case IMAPError.busy:
            return "Spam Sweep is already talking to Yahoo."
        case IMAPError.refused(let line):
            return "Yahoo replied: \(line)"
        default:
            return "Could not reach Yahoo Mail."
        }
    }

    static func verify(email: String, password: String) async throws {
        try await exclusive {
            let client = IMAPClient()
            do {
                try await client.connect()
                try await client.login(email: email, password: password)
                await client.logout()
            } catch {
                await client.logout()
                throw error
            }
        }
    }

    static func scan(limit: Int, onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> [SenderGroup] {
        guard let saved = KeychainStore.load() else { throw IMAPError.loginFailed }
        return try await exclusive {
            let client = IMAPClient()
            do {
                try await client.connect()
                try await client.login(email: saved.email, password: saved.appPassword)
                let boxes = try await client.listMailboxes()
                try await client.select("INBOX")
                let newest = Array(try await client.uidSearchAll().sorted().suffix(limit))
                onProgress(0, newest.count)
                var messages: [FetchedMail] = []
                var index = 0
                while index < newest.count {
                    let end = min(index + 40, newest.count)
                    let batch = try await client.uidFetch(uids: Array(newest[index..<end]), headers: true)
                    messages.append(contentsOf: batch)
                    index = end
                    onProgress(index, newest.count)
                }
                let replied = await repliedAddresses(client, boxes: boxes)
                await client.logout()
                return grouped(messages, replied: replied)
            } catch {
                await client.logout()
                throw error
            }
        }
    }

    static func move(needles: [String], junk: Bool) async throws -> Int {
        let unique = Array(Set(needles.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return 0 }
        guard let saved = KeychainStore.load() else { throw IMAPError.loginFailed }
        return try await exclusive {
            let client = IMAPClient()
            do {
                try await client.connect()
                try await client.login(email: saved.email, password: saved.appPassword)
                let boxes = try await client.listMailboxes()
                let destination = junk ? mailbox(boxes, flag: "junk", names: ["bulk", "junk", "junk mail"])
                    : mailbox(boxes, flag: "trash", names: ["trash", "deleted", "deleted items", "deleted messages"])
                guard let destination else { throw IMAPError.missingFolder(junk ? "Junk" : "Trash") }
                try await client.select("INBOX")
                var uids = Set<UInt64>()
                for needle in unique {
                    let found = try await client.uidSearch(from: needle)
                    uids.formUnion(found)
                }
                let moving = Array(uids)
                try await client.uidMove(uids: moving, to: destination)
                await client.logout()
                return moving.count
            } catch {
                await client.logout()
                throw error
            }
        }
    }

    static func sweepBlocked() async throws -> Int {
        guard KeychainStore.load() != nil else { return 0 }
        let snapshot = LocalDatabase.load()
        let needles = snapshot.blocks.map { entry -> String in
            entry.kind == .domain ? "@\(entry.value)" : entry.value
        }
        guard !needles.isEmpty else { return 0 }
        let moved = try await move(needles: needles, junk: true)
        if moved > 0 {
            LocalDatabase.update { $0.sweptTotal += moved }
        }
        return moved
    }

    private static func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        guard await SweepGate.shared.enter() else { throw IMAPError.busy }
        do {
            let value = try await body()
            await SweepGate.shared.leave()
            return value
        } catch {
            await SweepGate.shared.leave()
            throw error
        }
    }

    private static func repliedAddresses(_ client: IMAPClient, boxes: [IMAPMailbox]) async -> Set<String>? {
        guard let sent = mailbox(boxes, flag: "sent", names: ["sent", "sent items", "sent messages"]) else {
            return nil
        }
        do {
            try await client.select(sent)
            let uids = Array(try await client.uidSearchAll().sorted().suffix(800))
            let messages = try await client.uidFetch(uids: uids, headers: false)
            return Set(messages.flatMap(\.recipients))
        } catch {
            return nil
        }
    }

    private static func mailbox(_ boxes: [IMAPMailbox], flag: String, names: [String]) -> String? {
        if let match = boxes.first(where: { $0.flags.contains(flag) }) {
            return match.name
        }
        let wanted = Set(names)
        return boxes.first { wanted.contains($0.name.lowercased()) }?.name
    }

    private static func grouped(_ messages: [FetchedMail], replied: Set<String>?) -> [SenderGroup] {
        struct Bucket {
            var name = ""
            var count = 0
            var latestUID: UInt64 = 0
            var subject = ""
            var unsubscribe = false
        }
        var buckets: [String: Bucket] = [:]
        for message in messages {
            let address = message.address.lowercased()
            var bucket = buckets[address] ?? Bucket()
            bucket.count += 1
            bucket.unsubscribe = bucket.unsubscribe || message.hasUnsubscribe
            if message.uid >= bucket.latestUID {
                bucket.latestUID = message.uid
                bucket.subject = message.subject
            }
            if bucket.name.isEmpty {
                bucket.name = message.name
            }
            buckets[address] = bucket
        }
        return buckets.map { address, bucket in
            let domain = String(address.split(separator: "@").last ?? Substring(address))
            var hints: [String] = []
            if bucket.unsubscribe { hints.append("Unsubscribe list") }
            if let replied, !replied.contains(address) { hints.append("No prior reply") }
            if unusual(domain) { hints.append("Unusual domain") }
            return SenderGroup(
                address: address,
                name: bucket.name,
                domain: domain,
                count: bucket.count,
                latestSubject: bucket.subject,
                hints: hints
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.address < rhs.address
        }
    }

    private static let ordinaryDomains: Set<String> = [
        "yahoo.com", "ymail.com", "gmail.com", "googlemail.com", "outlook.com",
        "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "aol.com", "comcast.net", "verizon.net", "att.net", "sbcglobal.net",
        "proton.me", "protonmail.com", "pm.me", "hey.com", "fastmail.com",
    ]

    private static func unusual(_ domain: String) -> Bool {
        let domain = domain.lowercased()
        if domain.isEmpty || ordinaryDomains.contains(domain) { return false }
        if domain.contains("xn--") { return true }
        let labels = domain.split(separator: ".").dropLast()
        let focus = labels.isEmpty ? domain : labels.joined(separator: ".")
        let digits = focus.filter(\.isNumber).count
        let hyphens = focus.filter { $0 == "-" }.count
        if digits >= 4 || hyphens >= 3 || focus.count >= 24 { return true }
        let vowels = Set("aeiou")
        return focus.count >= 6 && !focus.contains(where: { vowels.contains($0) })
    }
}

@MainActor
final class SweepModel: ObservableObject {
    @Published var email = ""
    @Published var signedIn = false
    @Published var scanLimit = 2000
    @Published var sweptTotal = 0
    @Published var lastSwept = 0
    @Published var blocks: [BlockEntry] = []
    @Published var groups: [SenderGroup] = []
    @Published var selected: Set<String> = []
    @Published var scanning = false
    @Published var sweeping = false
    @Published var working = false
    @Published var checked = 0
    @Published var total = 0
    @Published var status = ""
    @Published var errorMessage: String?
    private var didOpenSweep = false

    var allSelected: Bool {
        !groups.isEmpty && selected.count == groups.count
    }

    func refreshAccount() {
        if let saved = KeychainStore.load() {
            email = saved.email
            signedIn = true
        } else {
            signedIn = false
        }
        let snapshot = LocalDatabase.load()
        scanLimit = min(5000, max(200, snapshot.scanLimit))
        sweptTotal = snapshot.sweptTotal
        blocks = snapshot.blocks
    }

    func signIn(email rawEmail: String, password rawPassword: String) async {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = rawPassword.replacingOccurrences(of: " ", with: "")
        guard email.contains("@"), email.contains("."), password.count >= 4 else {
            errorMessage = "Enter the Yahoo email address and the app password."
            return
        }
        working = true
        errorMessage = nil
        status = "Signing in to Yahoo…"
        defer {
            working = false
            status = ""
        }
        do {
            try await SweepEngine.verify(email: email, password: password)
            try KeychainStore.save(email: email, appPassword: password)
            self.email = email
            signedIn = true
            await sweepOnOpen()
        } catch {
            errorMessage = SweepEngine.describe(error)
        }
    }

    func signOut() {
        KeychainStore.clear()
        signedIn = false
        email = ""
        groups = []
        selected = []
        status = ""
        errorMessage = nil
    }

    func setScanLimit(_ value: Int) {
        let clamped = min(5000, max(200, value))
        scanLimit = clamped
        LocalDatabase.update { $0.scanLimit = clamped }
    }

    func scan() async {
        guard signedIn, !scanning, !working, !sweeping else { return }
        scanning = true
        errorMessage = nil
        checked = 0
        total = 0
        status = "Reading the inbox…"
        defer {
            scanning = false
            status = ""
        }
        do {
            let found = try await SweepEngine.scan(limit: scanLimit) { [weak self] done, expected in
                Task { @MainActor in
                    self?.checked = done
                    self?.total = expected
                }
            }
            groups = found
            selected = selected.intersection(Set(found.map(\.address)))
        } catch {
            errorMessage = SweepEngine.describe(error)
        }
    }

    func sweepOnOpen() async {
        guard signedIn, !blocks.isEmpty else { return }
        if didOpenSweep { return }
        didOpenSweep = true
        await sweepNow()
        didOpenSweep = false
    }

    func sweepNow() async {
        guard signedIn, !scanning, !working, !sweeping else { return }
        guard !blocks.isEmpty else {
            status = "Nothing is blocked yet."
            return
        }
        sweeping = true
        errorMessage = nil
        status = "Moving blocked mail to Junk…"
        defer {
            sweeping = false
        }
        do {
            let moved = try await SweepEngine.sweepBlocked()
            lastSwept = moved
            sweptTotal = LocalDatabase.load().sweptTotal
            status = moved == 0 ? "No new blocked mail." : "Moved \(moved.formatted()) messages to Junk."
        } catch {
            status = ""
            errorMessage = SweepEngine.describe(error)
        }
    }

    func toggle(_ group: SenderGroup) {
        if selected.contains(group.address) {
            selected.remove(group.address)
        } else {
            selected.insert(group.address)
        }
    }

    func selectAll() {
        selected = Set(groups.map(\.address))
    }

    func cancelSelection() {
        selected.removeAll()
    }

    func moveSelectedToJunk() async {
        await act(junk: true, needles: selected.map { $0 })
    }

    func deleteSelected() async {
        await act(junk: false, needles: selected.map { $0 })
    }

    func blockSelected(domains: Bool) async {
        let chosen = groups.filter { selected.contains($0.address) }
        guard !chosen.isEmpty else { return }
        var entries = blocks
        var needles: [String] = []
        for group in chosen {
            if domains {
                let entry = BlockEntry(kind: .domain, value: group.domain)
                if !entries.contains(entry) { entries.append(entry) }
                needles.append("@\(group.domain)")
            } else {
                let entry = BlockEntry(kind: .address, value: group.address)
                if !entries.contains(entry) { entries.append(entry) }
                needles.append(group.address)
            }
        }
        blocks = entries
        LocalDatabase.update { $0.blocks = entries }
        await act(junk: true, needles: needles)
    }

    func removeBlock(_ entry: BlockEntry) {
        blocks.removeAll { $0.id == entry.id }
        let remaining = blocks
        LocalDatabase.update { $0.blocks = remaining }
    }

    private func act(junk: Bool, needles: [String]) async {
        guard !needles.isEmpty, !working else { return }
        working = true
        errorMessage = nil
        status = junk ? "Moving mail to Junk…" : "Moving mail to Trash…"
        defer { working = false }
        do {
            let moved = try await SweepEngine.move(needles: needles, junk: junk)
            if junk {
                LocalDatabase.update { $0.sweptTotal += moved }
                sweptTotal = LocalDatabase.load().sweptTotal
                lastSwept = moved
            }
            selected.removeAll()
            working = false
            if !groups.isEmpty {
                await scan()
            }
            status = "Moved \(moved.formatted()) messages."
        } catch {
            status = ""
            errorMessage = SweepEngine.describe(error)
        }
    }
}
