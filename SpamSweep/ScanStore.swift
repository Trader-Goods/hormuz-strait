import Foundation

struct BlockEntry: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable {
        case address
        case domain
    }

    var kind: Kind
    var value: String
    var id: String { "\(kind.rawValue):\(value)" }
}

struct FolderCursor: Codable, Equatable {
    var lastUID: UInt64 = 0
    var done = false
}

struct PendingMove: Codable, Equatable {
    var junk: Bool
    var destination: String
    var moved: Int
    var total: Int
    var remaining: [String: [UInt64]]
    var searchAddresses: [String] = []
    var searchDomains: [String] = []

    var remainingCount: Int {
        remaining.values.reduce(0) { $0 + $1.count }
    }

    var hasWork: Bool {
        remainingCount > 0 || !searchAddresses.isEmpty || !searchDomains.isEmpty
    }
}

enum ScanStore {
    struct Snapshot: Codable, Equatable {
        var accountEmail = ""
        var sweptTotal = 0
        var blocks: [BlockEntry] = []
        var whitelist: [BlockEntry] = []
        var keepAwake = true
        var includeBulk = true
        var includeOther = false
        var useContacts = false
        var folders: [String: FolderCursor] = [:]
        var processed = 0
        var scanComplete = false
        var senders: [SenderAggregate] = []
        var sentAddresses: [String] = []
        var sentDomains: [String] = []
        var sentWarning = ""
        var inboxUIDs: [String: [UInt64]] = [:]
        var pendingMove: PendingMove?
    }

    private static let lock = NSLock()

    static func load() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return Snapshot() }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot
        }
        if let loose = try? JSONDecoder().decode(LooseSnapshot.self, from: data) {
            return loose.make()
        }
        guard let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else { return Snapshot() }
        var snapshot = Snapshot()
        snapshot.sweptTotal = legacy.sweptTotal ?? 0
        snapshot.blocks = legacy.blocks ?? []
        return snapshot
    }

    static func save(_ snapshot: Snapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private struct LegacySnapshot: Codable {
        var sweptTotal: Int?
        var blocks: [BlockEntry]?
    }

    /// Older saves omit inbox ids and the pending move. Missing keys must not wipe the scan.
    private struct LooseSnapshot: Decodable {
        var accountEmail: String?
        var sweptTotal: Int?
        var blocks: [BlockEntry]?
        var whitelist: [BlockEntry]?
        var keepAwake: Bool?
        var includeBulk: Bool?
        var includeOther: Bool?
        var useContacts: Bool?
        var folders: [String: FolderCursor]?
        var processed: Int?
        var scanComplete: Bool?
        var senders: [SenderAggregate]?
        var sentAddresses: [String]?
        var sentDomains: [String]?
        var sentWarning: String?
        var inboxUIDs: [String: [UInt64]]?
        var pendingMove: PendingMove?

        func make() -> Snapshot {
            var snapshot = Snapshot()
            snapshot.accountEmail = accountEmail ?? ""
            snapshot.sweptTotal = sweptTotal ?? 0
            snapshot.blocks = blocks ?? []
            snapshot.whitelist = whitelist ?? []
            snapshot.keepAwake = keepAwake ?? true
            snapshot.includeBulk = includeBulk ?? true
            snapshot.includeOther = includeOther ?? false
            snapshot.useContacts = useContacts ?? false
            snapshot.folders = folders ?? [:]
            snapshot.processed = processed ?? 0
            snapshot.scanComplete = scanComplete ?? false
            snapshot.senders = senders ?? []
            snapshot.sentAddresses = sentAddresses ?? []
            snapshot.sentDomains = sentDomains ?? []
            snapshot.sentWarning = sentWarning ?? ""
            snapshot.inboxUIDs = inboxUIDs ?? [:]
            snapshot.pendingMove = pendingMove
            return snapshot
        }
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
