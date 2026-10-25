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

struct SweepTick {
    var phase: String
    var done: Int
    var total: Int
    var eta: String
    var sender: String
    var snapshot: ScanStore.Snapshot
}

struct MoveTick {
    var moved: Int
    var total: Int
    var sender: String
    var eta: String
    var destination: String
    var junk: Bool
    var replacement: [String: [UInt64]]?
    var removed: [String: [UInt64]]
    var note: String = ""
    var cleared: [String] = []
}

enum SweepEngine {
    static func describe(_ error: Error) -> String {
        switch error {
        case IMAPError.loginFailed(let detail):
            if detail.hasPrefix("Saved sign-in") { return detail }
            return joined(
                "Yahoo refused the sign-in. Use your Yahoo email and an app password from Account Security, not your normal Yahoo password.",
                detail
            )
        case IMAPError.connectionFailed(let detail):
            return joined("Could not connect to Yahoo. The connection or TLS handshake failed.", detail)
        case IMAPError.disconnected:
            return "Could not connect to Yahoo. The connection closed before a reply."
        case IMAPError.unavailable(let detail):
            return joined("Yahoo is busy or temporarily unavailable. Spam Sweep already retried.", detail)
        case IMAPError.invalidPassword:
            return "Enter the Yahoo app password. It cannot contain a line break."
        case IMAPError.keychain:
            return "The password could not be saved in the iPhone Keychain."
        case IMAPError.missingFolder(let name):
            return "Yahoo did not list a \(name) folder."
        case IMAPError.busy:
            return "Spam Sweep is already talking to Yahoo."
        case IMAPError.timedOut:
            return "Yahoo stopped answering. Spam Sweep tried the command again."
        case IMAPError.refused(let line):
            return joined("Yahoo replied:", line)
        default:
            return "Could not reach Yahoo Mail."
        }
    }

    static func details(_ error: Error) -> String? {
        switch error {
        case IMAPError.loginFailed(let detail),
             IMAPError.connectionFailed(let detail),
             IMAPError.unavailable(let detail),
             IMAPError.refused(let detail):
            return detail.isEmpty ? nil : detail
        case IMAPError.disconnected:
            return "The connection closed before Yahoo replied."
        case IMAPError.timedOut:
            return "The mail server did not answer before the time limit."
        default:
            return nil
        }
    }

    private static func joined(_ summary: String, _ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return summary }
        return "\(summary)\n\(trimmed)"
    }

    static func verify(email: String, password: String) async throws {
        try await exclusive {
            let client = IMAPClient()
            do {
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
        guard let saved = KeychainStore.load() else {
            throw IMAPError.loginFailed("Saved sign-in is missing. Connect again.")
        }
        return try await exclusive {
            let client = IMAPClient()
            do {
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
                    snapshot.inboxUIDs = [:]
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
                let inboxName = targets.first?.name ?? "INBOX"
                var plans: [(ScanFolder, [UInt64])] = []
                var total = sentCount
                for target in targets {
                    if stop.isStopped { break }
                    try await client.select(target.name)
                    let validity = await client.currentValidity()
                    var remembered = snapshot.folders[target.name] ?? FolderCursor()
                    if remembered.uidValidity != 0, validity != 0, remembered.uidValidity != validity {
                        remembered.lastUID = 0
                        remembered.done = false
                        if target.name.caseInsensitiveCompare(inboxName) == .orderedSame {
                            snapshot.inboxUIDs = [:]
                        }
                    }
                    remembered.uidValidity = validity
                    snapshot.folders[target.name] = remembered
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
                        let recordsInbox = !target.countsAsJunk && target.name.caseInsensitiveCompare(inboxName) == .orderedSame
                        for item in fetched {
                            guard let header = MailHeader.parse(text: item.text, uid: item.uid, size: item.size, inBulk: target.countsAsJunk) else { continue }
                            SenderStats.fold(header, into: &map)
                            if recordsInbox {
                                let address = header.fromAddress.lowercased()
                                snapshot.inboxUIDs[address, default: []].append(header.uid)
                            }
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

    /// One batched inbox move. Known ids are not searched again. Missing senders are searched once, then every id is moved together.
    static func moveInbox(
        groups: [String: [UInt64]],
        searchAddresses: [String],
        searchDomains: [String],
        protect: Set<String>,
        junk: Bool,
        destinationName: String?,
        alreadyMoved: Int,
        stop: StopFlag,
        confirmSearch: Bool = false,
        sinceUID: UInt64 = 0,
        acceptAddresses: Set<String> = [],
        acceptDomains: Set<String> = [],
        onSearch: ((Int, Int) async -> Void)? = nil,
        onTick: (MoveTick) async -> Void
    ) async throws {
        guard let saved = KeychainStore.load() else {
            throw IMAPError.loginFailed("Saved sign-in is missing. Connect again.")
        }
        try await exclusive {
            let client = IMAPClient()
            do {
                try await client.login(email: saved.email, password: saved.appPassword)
                let boxes = try await client.listMailboxes()
                let destination = try resolveDestination(boxes, junk: junk, preferred: destinationName)
                if confirmSearch {
                    try await confirmAndMove(
                        client: client,
                        boxes: boxes,
                        groups: groups,
                        searchAddresses: searchAddresses,
                        searchDomains: searchDomains,
                        protect: protect,
                        junk: junk,
                        destination: destination,
                        alreadyMoved: alreadyMoved,
                        stop: stop,
                        onTick: onTick
                    )
                    await client.logout()
                    return
                }
                try await client.select("INBOX")
                var owners: [UInt64: String] = [:]
                var ordered: [UInt64] = []
                func add(_ uid: UInt64, sender: String) {
                    if owners[uid] != nil { return }
                    owners[uid] = sender
                    ordered.append(uid)
                }
                for (sender, uids) in groups {
                    for uid in uids {
                        add(uid, sender: sender)
                    }
                }
                if sinceUID > 0, !stop.isStopped {
                    let fresh = try await client.uidSearch(since: sinceUID + 1)
                    let matched = try await matchingFresh(
                        fresh,
                        addresses: acceptAddresses,
                        domains: acceptDomains,
                        client: client,
                        stop: stop
                    )
                    for (uid, sender) in matched {
                        add(uid, sender: sender)
                    }
                }
                let addressBatches = SenderSearch.batches(searchAddresses, size: 20)
                let searchSteps = addressBatches.count + searchDomains.count
                var searchStep = 0
                if !stop.isStopped && !addressBatches.isEmpty {
                    for batch in addressBatches where !stop.isStopped {
                        searchStep += 1
                        if let onSearch {
                            await onSearch(searchStep, max(searchSteps, 1))
                        }
                        let found = try await client.uidSearchSenders(batch)
                        let label = batch.count == 1 ? batch[0] : "Blocked senders"
                        for uid in found {
                            add(uid, sender: label)
                        }
                    }
                }
                if !stop.isStopped && !searchDomains.isEmpty {
                    for domain in searchDomains where !stop.isStopped {
                        searchStep += 1
                        if let onSearch {
                            await onSearch(searchStep, max(searchSteps, 1))
                        }
                        let found = try await client.uidSearch(from: "@\(domain)")
                        let kept = try await dropping(found, protect: protect, client: client)
                        for uid in kept {
                            add(uid, sender: "@\(domain)")
                        }
                    }
                }
                var prepared: [String: [UInt64]] = [:]
                for uid in ordered {
                    let sender = owners[uid] ?? "Unknown sender"
                    prepared[sender, default: []].append(uid)
                }
                let total = alreadyMoved + ordered.count
                await onTick(MoveTick(
                    moved: alreadyMoved,
                    total: total,
                    sender: ordered.isEmpty ? "Nothing to move" : "Starting the move",
                    eta: MoveETA.text(sessionMoved: 0, total: total, moved: alreadyMoved, elapsed: 0),
                    destination: destination,
                    junk: junk,
                    replacement: prepared,
                    removed: [:]
                ))
                let pieces = UIDSet.chunks(ordered)
                let started = Date()
                var moved = alreadyMoved
                var session = 0
                for piece in pieces {
                    if stop.isStopped || Task.isCancelled { break }
                    try await client.moveMessages(piece, to: destination)
                    session += piece.count
                    moved += piece.count
                    var removed: [String: [UInt64]] = [:]
                    for uid in piece {
                        let sender = owners[uid] ?? "Unknown sender"
                        removed[sender, default: []].append(uid)
                    }
                    await onTick(MoveTick(
                        moved: moved,
                        total: total,
                        sender: UIDSet.senderLabel(piece, owners: owners),
                        eta: MoveETA.text(sessionMoved: session, total: total, moved: moved, elapsed: Date().timeIntervalSince(started)),
                        destination: destination,
                        junk: junk,
                        replacement: nil,
                        removed: removed
                    ))
                }
                await client.logout()
            } catch {
                await client.logout()
                throw error
            }
        }
    }

    private static func confirmAndMove(
        client: IMAPClient,
        boxes: [IMAPMailbox],
        groups: [String: [UInt64]],
        searchAddresses: [String],
        searchDomains: [String],
        protect: Set<String>,
        junk: Bool,
        destination: String,
        alreadyMoved: Int,
        stop: StopFlag,
        onTick: (MoveTick) async -> Void
    ) async throws {
        let stored = ScanStore.load()
        let folders = MoveFolders.sources(
            folderNames: Array(stored.folders.keys),
            destination: destination,
            movingToJunk: junk
        )
        let addresses = Array(Set(searchAddresses).union(groups.keys).map { $0.lowercased() }.filter { !$0.isEmpty })
        let domains = Array(Set(searchDomains.map { $0.lowercased() }.filter { !$0.isEmpty }))
        var jobs: [(folder: String, uids: [UInt64], owners: [UInt64: String])] = []
        for folder in folders {
            if stop.isStopped { break }
            await onTick(MoveTick(
                moved: alreadyMoved,
                total: max(alreadyMoved, 1),
                sender: "Checking \(folder)",
                eta: "Estimating time left",
                destination: destination,
                junk: junk,
                replacement: nil,
                removed: [:]
            ))
            try await client.select(folder)
            var owners: [UInt64: String] = [:]
            var ordered: [UInt64] = []
            func add(_ uid: UInt64, sender: String) {
                if owners[uid] != nil { return }
                owners[uid] = sender
                ordered.append(uid)
            }
            if folder.caseInsensitiveCompare("INBOX") == .orderedSame {
                let validity = await client.currentValidity()
                let saved = stored.folders.first { $0.key.caseInsensitiveCompare(folder) == .orderedSame }?.value.uidValidity ?? 0
                let trust = saved == 0 || validity == 0 || saved == validity
                if trust {
                    let cached = groups.values.flatMap { $0 }
                    let live = Set(try await client.uidExisting(cached))
                    for (sender, uids) in groups {
                        for uid in uids where live.contains(uid) {
                            add(uid, sender: sender)
                        }
                    }
                }
            }
            if !stop.isStopped && (!addresses.isEmpty || !domains.isEmpty) {
                let found = try await client.findMessages(addresses: addresses, domains: domains)
                let kept = protect.isEmpty ? found : try await dropping(found, protect: protect, client: client)
                let label = addresses.count == 1 ? addresses[0] : "Selected senders"
                for uid in kept {
                    add(uid, sender: label)
                }
            }
            if !ordered.isEmpty {
                jobs.append((folder, ordered, owners))
            }
        }
        let discovered = jobs.reduce(0) { $0 + $1.uids.count }
        if stop.isStopped && discovered == 0 { return }
        if discovered == 0 {
            await onTick(MoveTick(
                moved: alreadyMoved,
                total: max(alreadyMoved, 1),
                sender: "Checking Junk and Trash",
                eta: "",
                destination: destination,
                junk: junk,
                replacement: nil,
                removed: [:]
            ))
            let places = try await parkedCounts(client: client, boxes: boxes, addresses: addresses, domains: domains, stop: stop)
            let note = MoveReport.alreadyMoved(places)
            await onTick(MoveTick(
                moved: alreadyMoved,
                total: alreadyMoved,
                sender: note,
                eta: "",
                destination: destination,
                junk: junk,
                replacement: [:],
                removed: [:],
                note: note,
                cleared: addresses
            ))
            return
        }
        let total = alreadyMoved + discovered
        await onTick(MoveTick(
            moved: alreadyMoved,
            total: total,
            sender: "Starting the move",
            eta: MoveETA.text(sessionMoved: 0, total: total, moved: alreadyMoved, elapsed: 0),
            destination: destination,
            junk: junk,
            replacement: combined(jobs),
            removed: [:]
        ))
        let started = Date()
        var moved = alreadyMoved
        var session = 0
        for job in jobs {
            if stop.isStopped { break }
            try await client.select(job.folder)
            for piece in UIDSet.chunks(job.uids) {
                if stop.isStopped || Task.isCancelled { break }
                try await client.moveMessages(piece, to: destination)
                let attributed = try await attribute(piece, fallback: job.owners, client: client)
                session += piece.count
                moved += piece.count
                await onTick(MoveTick(
                    moved: moved,
                    total: total,
                    sender: UIDSet.senderLabel(piece, owners: job.owners),
                    eta: MoveETA.text(sessionMoved: session, total: total, moved: moved, elapsed: Date().timeIntervalSince(started)),
                    destination: destination,
                    junk: junk,
                    replacement: nil,
                    removed: attributed
                ))
            }
        }
    }

    private static func combined(_ jobs: [(folder: String, uids: [UInt64], owners: [UInt64: String])]) -> [String: [UInt64]] {
        var grouped: [String: [UInt64]] = [:]
        for job in jobs {
            for uid in job.uids {
                let sender = job.owners[uid] ?? "Selected senders"
                grouped[sender, default: []].append(uid)
            }
        }
        return grouped
    }

    private static func attribute(
        _ uids: [UInt64],
        fallback: [UInt64: String],
        client: IMAPClient
    ) async throws -> [String: [UInt64]] {
        var owners = fallback
        let headers = try await client.uidFetchHeaders(uids: uids, fields: MailFields.fromOnly)
        for header in headers {
            let fields = HeaderBlock.fields(header.text)
            if let email = MailAddress.mailbox(fields["from"] ?? "")?.email {
                owners[header.uid] = email
            }
        }
        var removed: [String: [UInt64]] = [:]
        for uid in uids {
            let sender = owners[uid] ?? "Selected senders"
            removed[sender, default: []].append(uid)
        }
        return removed
    }

    private static func parkedCounts(
        client: IMAPClient,
        boxes: [IMAPMailbox],
        addresses: [String],
        domains: [String],
        stop: StopFlag
    ) async throws -> [(name: String, count: Int)] {
        var places: [(String, Int)] = []
        var seen = Set<String>()
        let candidates: [(String, String?)] = [
            ("Junk", MailboxPlan.junkName(boxes)),
            ("Trash", MailboxPlan.trashName(boxes)),
        ]
        for (label, name) in candidates {
            guard let name, seen.insert(name.lowercased()).inserted, !stop.isStopped else { continue }
            try await client.select(name)
            let found = try await client.findMessages(addresses: addresses, domains: domains)
            places.append((label, Set(found).count))
        }
        return places
    }

    private static func resolveDestination(_ boxes: [IMAPMailbox], junk: Bool, preferred: String?) throws -> String {
        if let preferred, boxes.contains(where: { $0.name == preferred }) {
            return preferred
        }
        if junk {
            guard let name = MailboxPlan.junkName(boxes) else { throw IMAPError.missingFolder("Junk") }
            return name
        }
        guard let name = MailboxPlan.trashName(boxes) else { throw IMAPError.missingFolder("Trash") }
        return name
    }

    static func move(
        needles: [String],
        junk: Bool,
        protect: Set<String>,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> Int {
        let unique = Array(Set(needles.map { $0.lowercased() }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return 0 }
        guard let saved = KeychainStore.load() else {
            throw IMAPError.loginFailed("Saved sign-in is missing. Connect again.")
        }
        return try await exclusive {
            let client = IMAPClient()
            do {
                try await client.login(email: saved.email, password: saved.appPassword)
                let boxes = try await client.listMailboxes()
                let destination = junk
                    ? MailboxPlan.junkName(boxes)
                    : MailboxPlan.trashName(boxes)
                guard let destination else { throw IMAPError.missingFolder(junk ? "Junk" : "Trash") }
                try await client.select("INBOX")
                let addresses = unique.filter { !$0.hasPrefix("@") }
                let domains = unique.filter { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
                var uids = Set(try await client.uidSearchSenders(addresses))
                for domain in domains {
                    uids.formUnion(try await client.uidSearch(from: "@\(domain)"))
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

    static func sweepBlocked(stop: StopFlag = StopFlag(), onTick: ((SweepTick) async -> Void)? = nil) async throws -> Int {
        guard KeychainStore.load() != nil else { return 0 }
        var snapshot = ScanStore.load()
        let before = snapshot.sweptTotal
        let plan = blockedPlan(snapshot)
        let resume = snapshot.pendingSweep
        let groups = (resume?.remainingCount ?? 0) > 0 ? (resume?.remaining ?? [:]) : plan.groups
        let searchAddresses = resume?.hasWork == true ? resume?.searchAddresses ?? [] : plan.missingAddresses
        let searchDomains = resume?.hasWork == true ? resume?.searchDomains ?? [] : plan.missingDomains
        let sinceUID = resume?.hasWork == true ? 0 : plan.sinceUID
        guard !groups.isEmpty || !searchAddresses.isEmpty || !searchDomains.isEmpty || sinceUID > 0 else { return 0 }
        snapshot.lastSweepAt = Date().timeIntervalSince1970
        ScanStore.save(snapshot)
        let started = Date()
        let searchSteps = SenderSearch.batches(searchAddresses, size: 20).count + searchDomains.count
        if searchSteps > 0 {
            await emitSweep(
                phase: "finding",
                done: 0,
                total: searchSteps,
                sender: "Finding blocked mail",
                eta: "Estimating time left",
                elapsed: 0,
                sessionDone: 0,
                stop: stop,
                onTick: onTick
            )
        }
        try await moveInbox(
            groups: groups,
            searchAddresses: searchAddresses,
            searchDomains: searchDomains,
            protect: plan.protect,
            junk: true,
            destinationName: resume?.destination.isEmpty == false ? resume?.destination : nil,
            alreadyMoved: resume?.moved ?? 0,
            stop: stop,
            sinceUID: sinceUID,
            acceptAddresses: plan.addresses,
            acceptDomains: plan.domains,
            onSearch: { done, total in
                await emitSweep(
                    phase: "finding",
                    done: done,
                    total: total,
                    sender: "Finding blocked mail",
                    eta: "",
                    elapsed: Date().timeIntervalSince(started),
                    sessionDone: done,
                    stop: stop,
                    onTick: onTick
                )
            },
            onTick: { tick in
                let updated = persistSweep(tick, stop: stop)
                await onTick?(SweepTick(
                    phase: "moving",
                    done: tick.moved,
                    total: tick.total,
                    eta: tick.eta,
                    sender: tick.sender,
                    snapshot: updated
                ))
            }
        )
        if stop.isStopped {
            var latest = ScanStore.load()
            latest.pendingSweep = nil
            latest.lastSweepAt = Date().timeIntervalSince1970
            ScanStore.save(latest)
        }
        return max(0, ScanStore.load().sweptTotal - before)
    }

    private static func emitSweep(
        phase: String,
        done: Int,
        total: Int,
        sender: String,
        eta: String,
        elapsed: TimeInterval,
        sessionDone: Int,
        stop: StopFlag,
        onTick: ((SweepTick) async -> Void)?
    ) async {
        let estimate = eta.isEmpty
            ? MoveETA.text(sessionMoved: sessionDone, total: total, moved: done, elapsed: elapsed)
            : eta
        await onTick?(SweepTick(
            phase: phase,
            done: done,
            total: total,
            eta: stop.isStopped ? "" : estimate,
            sender: sender,
            snapshot: ScanStore.load()
        ))
    }

    private static func persistSweep(_ tick: MoveTick, stop: StopFlag) -> ScanStore.Snapshot {
        var snapshot = ScanStore.load()
        var pending = snapshot.pendingSweep ?? PendingMove(
            junk: true,
            destination: tick.destination,
            moved: tick.moved,
            total: tick.total,
            remaining: [:]
        )
        pending.junk = true
        if !tick.destination.isEmpty {
            pending.destination = tick.destination
        }
        if let replacement = tick.replacement {
            pending.remaining = replacement
            pending.total = tick.total
            pending.moved = tick.moved
            pending.searchAddresses = []
            pending.searchDomains = []
        }
        if !tick.removed.isEmpty {
            var drop = Set<UInt64>()
            for uids in tick.removed.values {
                drop.formUnion(uids)
            }
            var next: [String: [UInt64]] = [:]
            for (sender, uids) in pending.remaining {
                let kept = uids.filter { !drop.contains($0) }
                if !kept.isEmpty { next[sender] = kept }
            }
            pending.remaining = next
            pending.moved = tick.moved
            pending.total = tick.total
            snapshot.sweptTotal += drop.count
            for sender in Array(snapshot.inboxUIDs.keys) {
                guard var stored = snapshot.inboxUIDs[sender] else { continue }
                let before = stored.count
                stored.removeAll { drop.contains($0) }
                let removed = before - stored.count
                if stored.isEmpty {
                    snapshot.inboxUIDs.removeValue(forKey: sender)
                } else {
                    snapshot.inboxUIDs[sender] = stored
                }
                if removed > 0, let index = snapshot.senders.firstIndex(where: { $0.address == sender }) {
                    snapshot.senders[index].count = max(0, snapshot.senders[index].count - removed)
                }
            }
            snapshot.senders.removeAll { $0.count == 0 && (snapshot.inboxUIDs[$0.address] ?? []).isEmpty }
        }
        if stop.isStopped || (pending.remaining.isEmpty && pending.searchAddresses.isEmpty && pending.searchDomains.isEmpty) {
            snapshot.pendingSweep = nil
        } else {
            snapshot.pendingSweep = pending
        }
        snapshot.lastSweepAt = Date().timeIntervalSince1970
        ScanStore.save(snapshot)
        return snapshot
    }

    private static func blockedPlan(_ snapshot: ScanStore.Snapshot) -> (
        groups: [String: [UInt64]],
        missingAddresses: [String],
        missingDomains: [String],
        addresses: Set<String>,
        domains: Set<String>,
        protect: Set<String>,
        sinceUID: UInt64
    ) {
        let addresses = Set(snapshot.blocks.filter { $0.kind == .address }.map { $0.value.lowercased() })
        let domains = Set(snapshot.blocks.filter { $0.kind == .domain }.map { $0.value.lowercased() })
        var protect = Set(snapshot.sentAddresses.map { $0.lowercased() })
        protect.formUnion(snapshot.whitelist.filter { $0.kind == .address }.map { $0.value.lowercased() })
        if snapshot.useContacts {
            protect.formUnion(ContactsReader.loadIfAllowed().map { $0.lowercased() })
        }
        protect.subtract(addresses)
        protect.formUnion(snapshot.whitelist.filter { $0.kind == .address }.map { $0.value.lowercased() })
        var groups: [String: [UInt64]] = [:]
        var missingAddresses: [String] = []
        for address in addresses where !protect.contains(address) {
            let uids = Array(Set(snapshot.inboxUIDs[address] ?? []))
            if uids.isEmpty {
                missingAddresses.append(address)
            } else {
                groups[address] = uids
            }
        }
        var missingDomains: [String] = []
        for domain in domains {
            let covered = snapshot.senders.filter { $0.domain == domain && !protect.contains($0.address.lowercased()) }
            for sender in covered {
                let uids = Array(Set(snapshot.inboxUIDs[sender.address] ?? []))
                if !uids.isEmpty {
                    groups[sender.address] = uids
                }
            }
            let ready = snapshot.scanComplete && !covered.isEmpty && covered.allSatisfy { sender in
                sender.count == 0 || !(snapshot.inboxUIDs[sender.address] ?? []).isEmpty
            }
            if !ready {
                missingDomains.append(domain)
            }
        }
        let sinceUID = snapshot.folders.first { $0.key.caseInsensitiveCompare("INBOX") == .orderedSame }?.value.lastUID ?? 0
        return (groups, missingAddresses.sorted(), missingDomains.sorted(), addresses, domains, protect, sinceUID)
    }

    private static func matchingFresh(
        _ uids: [UInt64],
        addresses: Set<String>,
        domains: Set<String>,
        client: IMAPClient,
        stop: StopFlag
    ) async throws -> [(UInt64, String)] {
        guard !uids.isEmpty, !addresses.isEmpty || !domains.isEmpty else { return [] }
        let wantedAddresses = Set(addresses.map { $0.lowercased() })
        let wantedDomains = Set(domains.map { $0.lowercased() })
        var matched: [(UInt64, String)] = []
        var index = 0
        let sorted = uids.sorted()
        while index < sorted.count {
            if stop.isStopped { break }
            let end = min(index + 80, sorted.count)
            let headers = try await client.uidFetchHeaders(uids: Array(sorted[index..<end]), fields: MailFields.fromOnly)
            for header in headers {
                let fields = HeaderBlock.fields(header.text)
                guard let email = MailAddress.mailbox(fields["from"] ?? "")?.email else { continue }
                let domain = MailAddress.domain(of: email)
                if wantedAddresses.contains(email) || (!domain.isEmpty && wantedDomains.contains(domain)) {
                    matched.append((header.uid, email))
                }
            }
            index = end
        }
        return matched
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
