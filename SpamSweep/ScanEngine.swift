import Foundation

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

struct ScanTick {
    var phase: String
    var done: Int
    var total: Int
    var eta: String
    var snapshot: ScanStore.Snapshot
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

    static func scan(
        snapshot start: ScanStore.Snapshot,
        restart: Bool,
        stop: StopFlag,
        onTick: @escaping (ScanTick) -> Void
    ) async throws -> ScanStore.Snapshot {
        guard let saved = KeychainStore.load() else { throw IMAPError.loginFailed }
        return try await exclusive {
            let client = IMAPClient()
            do {
                try await client.connect()
                try await client.login(email: saved.email, password: saved.appPassword)
                let boxes = try await client.listMailboxes()
                var snapshot = start
                if restart {
                    snapshot.senders = []
                    snapshot.folders = [:]
                    snapshot.sentAddresses = []
                    snapshot.sentDomains = []
                    snapshot.scanComplete = false
                    snapshot.processed = 0
                    snapshot.sentWarning = ""
                }
                let started = Date()
                var done = 0
                let sentCount = try await readSent(client: client, boxes: boxes, snapshot: &snapshot, stop: stop, started: started, onTick: onTick)
                if stop.isStopped {
                    snapshot.scanComplete = false
                    ScanStore.save(snapshot)
                    await client.logout()
                    return snapshot
                }
                done += sentCount
                let targets = MailboxPlan.targets(boxes, includeBulk: snapshot.includeBulk, includeOther: snapshot.includeOther)
                var plans: [(ScanFolder, [UInt64])] = []
                var total = sentCount
                for target in targets {
                    if stop.isStopped { break }
                    try await client.select(target.name)
                    let all = try await client.uidSearchAll().sorted()
                    let last = snapshot.folders[target.name]?.lastUID ?? 0
                    let todo = snapshot.folders[target.name]?.done == true ? [] : all.filter { $0 > last }
                    let already = all.count - todo.count
                    total += all.count
                    done += already
                    plans.append((target, todo))
                }
                publish(snapshot, phase: "Reading the mailbox", done: done, total: max(total, done), started: started, onTick: onTick)
                var map: [String: SenderAggregate] = [:]
                for sender in snapshot.senders {
                    map[sender.address] = sender
                }
                for (target, todo) in plans {
                    if snapshot.folders[target.name]?.done == true { continue }
                    var index = 0
                    while index < todo.count {
                        if stop.isStopped || Task.isCancelled {
                            snapshot.senders = map.values.sorted { $0.address < $1.address }
                            snapshot.processed = done
                            snapshot.scanComplete = false
                            ScanStore.save(snapshot)
                            publish(snapshot, phase: "Paused", done: done, total: max(total, done), started: started, onTick: onTick)
                            await client.logout()
                            return snapshot
                        }
                        let end = min(index + 80, todo.count)
                        let slice = Array(todo[index..<end])
                        let fetched = try await client.uidFetchHeaders(uids: slice, fields: MailFields.inbox)
                        for item in fetched {
                            guard let header = MailHeader.parse(text: item.text, uid: item.uid, size: item.size, inBulk: target.countsAsJunk) else { continue }
                            SenderStats.fold(header, into: &map)
                        }
                        var cursor = snapshot.folders[target.name] ?? FolderCursor()
                        cursor.lastUID = max(cursor.lastUID, slice.max() ?? cursor.lastUID)
                        snapshot.folders[target.name] = cursor
                        snapshot.senders = map.values.sorted { $0.address < $1.address }
                        done += slice.count
                        snapshot.processed = done
                        ScanStore.save(snapshot)
                        let phase = target.countsAsJunk ? "Reading Junk" : "Reading \(target.name)"
                        publish(snapshot, phase: phase, done: done, total: max(total, done), started: started, onTick: onTick)
                        index = end
                    }
                    var cursor = snapshot.folders[target.name] ?? FolderCursor()
                    cursor.done = true
                    snapshot.folders[target.name] = cursor
                    ScanStore.save(snapshot)
                }
                snapshot.scanComplete = !stop.isStopped && !Task.isCancelled
                snapshot.processed = done
                snapshot.senders = map.values.sorted { $0.address < $1.address }
                ScanStore.save(snapshot)
                publish(snapshot, phase: snapshot.scanComplete ? "Scan finished" : "Paused", done: done, total: max(total, done), started: started, onTick: onTick)
                await client.logout()
                return snapshot
            } catch {
                await client.logout()
                throw error
            }
        }
    }

    static func move(
        needles: [String],
        junk: Bool,
        protect: Set<String>,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> Int {
        let unique = Array(Set(needles.map { $0.lowercased() }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return 0 }
        guard let saved = KeychainStore.load() else { throw IMAPError.loginFailed }
        return try await exclusive {
            let client = IMAPClient()
            do {
                try await client.connect()
                try await client.login(email: saved.email, password: saved.appPassword)
                let boxes = try await client.listMailboxes()
                let destination = junk
                    ? MailboxPlan.junkName(boxes)
                    : MailboxPlan.trashName(boxes)
                guard let destination else { throw IMAPError.missingFolder(junk ? "Junk" : "Trash") }
                try await client.select("INBOX")
                var uids = Set<UInt64>()
                for needle in unique {
                    let found = try await client.uidSearch(from: needle)
                    uids.formUnion(found)
                }
                var moving = Array(uids)
                if !protect.isEmpty {
                    moving = try await dropping(moving, protect: protect, client: client)
                }
                try await client.uidMove(uids: moving, to: destination, onProgress: onProgress)
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
        let snapshot = ScanStore.load()
        let needles = snapshot.blocks.map { entry -> String in
            entry.kind == .domain ? "@\(entry.value)" : entry.value
        }
        guard !needles.isEmpty else { return 0 }
        var protect = Set(snapshot.sentAddresses)
        protect.formUnion(snapshot.whitelist.filter { $0.kind == .address }.map(\.value))
        if snapshot.useContacts {
            protect.formUnion(ContactsReader.loadIfAllowed())
        }
        let blockedAddresses = Set(snapshot.blocks.filter { $0.kind == .address }.map { $0.value.lowercased() })
        protect.subtract(blockedAddresses)
        protect.formUnion(snapshot.whitelist.filter { $0.kind == .address }.map { $0.value.lowercased() })
        let moved = try await move(needles: needles, junk: true, protect: protect) { _, _ in }
        if moved > 0 {
            var updated = ScanStore.load()
            updated.sweptTotal += moved
            ScanStore.save(updated)
        }
        return moved
    }

    private static func readSent(
        client: IMAPClient,
        boxes: [IMAPMailbox],
        snapshot: inout ScanStore.Snapshot,
        stop: StopFlag,
        started: Date,
        onTick: @escaping (ScanTick) -> Void
    ) async throws -> Int {
        guard let sent = MailboxPlan.sentName(boxes) else {
            snapshot.sentWarning = "Yahoo did not list a Sent folder, so reply history was not used."
            return 0
        }
        do {
            try await client.select(sent)
            let uids = try await client.uidSearchAll()
            var addresses = Set<String>()
            var index = 0
            let sorted = uids.sorted()
            while index < sorted.count {
                if stop.isStopped { break }
                let end = min(index + 80, sorted.count)
                let fetched = try await client.uidFetchHeaders(uids: Array(sorted[index..<end]), fields: MailFields.sent)
                for item in fetched {
                    let fields = HeaderBlock.fields(item.text)
                    for key in ["to", "cc", "bcc"] {
                        addresses.formUnion(MailAddress.emails(in: fields[key] ?? ""))
                    }
                }
                index = end
                publish(snapshot, phase: "Reading mail you've sent", done: index, total: sorted.count, started: started, onTick: onTick)
            }
            snapshot.sentAddresses = Array(addresses).sorted()
            var domains = Set<String>()
            for email in addresses {
                let domain = MailAddress.domain(of: email)
                if !domain.isEmpty, !SpamScorer.isFreemail(domain) {
                    domains.insert(domain)
                }
            }
            snapshot.sentDomains = Array(domains).sorted()
            snapshot.sentWarning = ""
            ScanStore.save(snapshot)
            return sorted.count
        } catch {
            snapshot.sentWarning = "Sent mail could not be read, so the scan stopped before scoring strangers as spam."
            ScanStore.save(snapshot)
            throw error
        }
    }

    private static func dropping(_ uids: [UInt64], protect: Set<String>, client: IMAPClient) async throws -> [UInt64] {
        let lowered = Set(protect.map { $0.lowercased() })
        guard !lowered.isEmpty else { return uids }
        let headers = try await client.uidFetchHeaders(uids: uids, fields: MailFields.fromOnly)
        var fromByUID: [UInt64: String] = [:]
        for header in headers {
            let fields = HeaderBlock.fields(header.text)
            if let email = MailAddress.mailbox(fields["from"] ?? "")?.email {
                fromByUID[header.uid] = email
            }
        }
        return uids.filter { uid in
            guard let from = fromByUID[uid] else { return true }
            return !lowered.contains(from)
        }
    }

    private static func publish(
        _ snapshot: ScanStore.Snapshot,
        phase: String,
        done: Int,
        total: Int,
        started: Date,
        onTick: (ScanTick) -> Void
    ) {
        onTick(ScanTick(
            phase: phase,
            done: done,
            total: total,
            eta: ScanETA.text(done: done, total: total, elapsed: Date().timeIntervalSince(started)),
            snapshot: snapshot
        ))
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

extension MailboxPlan {
    static func junkName(_ boxes: [IMAPMailbox]) -> String? {
        if let found = boxes.first(where: { $0.flags.contains("junk") }) { return found.name }
        let names: Set<String> = ["bulk", "junk", "junk mail"]
        return boxes.first { names.contains($0.name.lowercased()) }?.name
    }

    static func trashName(_ boxes: [IMAPMailbox]) -> String? {
        if let found = boxes.first(where: { $0.flags.contains("trash") }) { return found.name }
        let names: Set<String> = ["trash", "deleted", "deleted items", "deleted messages"]
        return boxes.first { names.contains($0.name.lowercased()) }?.name
    }
}
