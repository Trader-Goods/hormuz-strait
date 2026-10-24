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
    }

    private static let lock = NSLock()

    static func load() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return Snapshot() }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot
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

    private static func fileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = base.appendingPathComponent("SpamSweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("store.json")
    }
}
