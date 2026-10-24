import SwiftUI
import UIKit

@MainActor
final class SweepModel: ObservableObject {
    @Published var email = ""
    @Published var signedIn = false
    @Published var sweptTotal = 0
    @Published var blocks: [BlockEntry] = []
    @Published var whitelist: [BlockEntry] = []
    @Published var rows: [ScoredSender] = []
    @Published var rollups: [DomainRollup] = []
    @Published var selected: Set<String> = []
    @Published var selectedDomains: Set<String> = []
    @Published var keepAwake = true
    @Published var includeBulk = true
    @Published var includeOther = false
    @Published var useContacts = false
    @Published var scanning = false
    @Published var sweeping = false
    @Published var working = false
    @Published var phase = ""
    @Published var done = 0
    @Published var total = 0
    @Published var eta = ""
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    @Published var sentWarning = ""
    @Published var scanComplete = false
    @Published var pendingSafe: String?
    @Published var confirmingBlock = false
    @Published var confirmingNotSpam = false
    @Published var confirmingRestart = false
    private var snapshot = ScanStore.Snapshot()
    private var contactEmails = Set<String>()
    private var heldOff = Set<String>()
    private var pinnedOn = Set<String>()
    private var stopFlag: StopFlag?
    private var didOpenSweep = false

    var hasProgress: Bool {
        !snapshot.senders.isEmpty || snapshot.folders.values.contains { $0.lastUID > 0 }
    }

    var messageTotal: Int {
        rows.reduce(0) { $0 + $1.sender.count }
    }

    var selectionSummary: String {
        var parts: [String] = []
        if !selected.isEmpty { parts.append("\(selected.count.formatted()) senders") }
        if !selectedDomains.isEmpty { parts.append("\(selectedDomains.count.formatted()) domains") }
        return parts.joined(separator: " and ")
    }

    func refreshAccount() {
        if let saved = KeychainStore.load() {
            email = saved.email
            signedIn = true
        } else {
            signedIn = false
        }
        var stored = ScanStore.load()
        if signedIn, !stored.accountEmail.isEmpty, stored.accountEmail != email {
            stored = ScanStore.Snapshot()
            stored.accountEmail = email
            ScanStore.save(stored)
        }
        if stored.useContacts {
            contactEmails = ContactsReader.loadIfAllowed()
        }
        applySnapshot(stored, preselect: true)
    }

    func signIn(email rawEmail: String, password rawPassword: String) async {
        let email = YahooAccount.normalizeEmail(rawEmail)
        let password = YahooAccount.normalizePassword(rawPassword)
        guard email.contains("@"), email.contains("."), !password.isEmpty else {
            errorMessage = "Enter the Yahoo email address and the app password."
            errorDetail = nil
            return
        }
        working = true
        clearError()
        status = "Signing in to Yahoo…"
        defer {
            working = false
            if !scanning { status = "" }
        }
        do {
            try await SweepEngine.verify(email: email, password: password)
            try KeychainStore.save(email: email, appPassword: password)
            self.email = email
            signedIn = true
            var stored = ScanStore.load()
            if stored.accountEmail != email {
                stored = ScanStore.Snapshot()
            }
            stored.accountEmail = email
            ScanStore.save(stored)
            applySnapshot(stored, preselect: true)
            await sweepOnOpen()
        } catch {
            report(error)
        }
    }

    func signOut() {
        stopFlag?.stop()
        KeychainStore.clear()
        signedIn = false
        email = ""
        rows = []
        rollups = []
        selected.removeAll()
        selectedDomains.removeAll()
        status = ""
        clearError()
        scanning = false
        syncIdleTimer()
    }

    func setKeepAwake(_ value: Bool) {
        keepAwake = value
        snapshot.keepAwake = value
        ScanStore.save(snapshot)
        syncIdleTimer()
    }

    func setIncludeBulk(_ value: Bool) {
        includeBulk = value
        snapshot.includeBulk = value
        if value { snapshot.scanComplete = false }
        scanComplete = snapshot.scanComplete
        ScanStore.save(snapshot)
    }

    func setIncludeOther(_ value: Bool) {
        includeOther = value
        snapshot.includeOther = value
        if value { snapshot.scanComplete = false }
        scanComplete = snapshot.scanComplete
        ScanStore.save(snapshot)
    }

    func setUseContacts(_ value: Bool) async {
        if value {
            contactEmails = await ContactsReader.request()
            if !ContactsReader.isAuthorized && contactEmails.isEmpty {
                useContacts = false
                errorMessage = "Contacts access is off, so people you know were not protected."
                errorDetail = nil
            } else {
                useContacts = true
                clearError()
            }
        } else {
            useContacts = false
            contactEmails = []
        }
        snapshot.useContacts = useContacts
        ScanStore.save(snapshot)
        rescore(preselect: true)
    }

    func startScan(restart: Bool) async {
        guard signedIn, !scanning, !working, !sweeping else { return }
        if restart {
            heldOff.removeAll()
            pinnedOn.removeAll()
            selected.removeAll()
            selectedDomains.removeAll()
            rows = []
            rollups = []
        }
        scanning = true
        clearError()
        status = "Reading mail you've sent…"
        phase = status
        done = 0
        total = 0
        eta = ""
        let flag = StopFlag()
        stopFlag = flag
        syncIdleTimer()
        defer {
            scanning = false
            stopFlag = nil
            syncIdleTimer()
        }
        do {
            let result = try await SweepEngine.scan(snapshot: snapshot, restart: restart, stop: flag) { [weak self] tick in
                Task { @MainActor in
                    self?.apply(tick)
                }
            }
            applySnapshot(result, preselect: true)
            sentWarning = result.sentWarning
            status = result.scanComplete ? "Scan finished." : "Scan paused. Continue to finish the mailbox."
            phase = ""
        } catch {
            applySnapshot(ScanStore.load(), preselect: true)
            status = ""
            report(error)
        }
    }

    func stopScan() {
        guard scanning else { return }
        status = "Stopping after this batch…"
        stopFlag?.stop()
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
        clearError()
        status = "Moving blocked mail to Junk…"
        defer { sweeping = false }
        do {
            let moved = try await SweepEngine.sweepBlocked()
            sweptTotal = ScanStore.load().sweptTotal
            snapshot.sweptTotal = sweptTotal
            status = moved == 0 ? "No new blocked mail." : "Moved \(moved.formatted()) messages to Junk."
        } catch {
            status = ""
            report(error)
        }
    }

    func toggle(_ row: ScoredSender) {
        let address = row.sender.address
        if selected.contains(address) {
            selected.remove(address)
            pinnedOn.remove(address)
            heldOff.insert(address)
            selectedDomains.remove(row.sender.domain)
            return
        }
        if row.result.category == .safe {
            pendingSafe = address
            return
        }
        selected.insert(address)
        heldOff.remove(address)
    }

    func confirmSafeSelection() {
        guard let address = pendingSafe else { return }
        selected.insert(address)
        pinnedOn.insert(address)
        heldOff.remove(address)
        pendingSafe = nil
    }

    func toggleDomain(_ rollup: DomainRollup) {
        if selectedDomains.contains(rollup.domain) {
            selectedDomains.remove(rollup.domain)
            for address in rollup.addresses {
                selected.remove(address)
                heldOff.insert(address)
            }
            return
        }
        selectedDomains.insert(rollup.domain)
        for address in rollup.addresses {
            selected.insert(address)
            heldOff.remove(address)
        }
    }

    func selectSpam() {
        for row in rows where row.result.category == .spam {
            selected.insert(row.sender.address)
            heldOff.remove(row.sender.address)
        }
    }

    func cancelSelection() {
        for address in selected { heldOff.insert(address) }
        selected.removeAll()
        selectedDomains.removeAll()
    }

    func blockSelected(junk: Bool) async {
        let plan = blockPlan()
        let needles = plan.addresses + plan.domains.map { "@\($0)" }
        guard !needles.isEmpty else { return }
        var entries = snapshot.blocks
        for address in plan.addresses {
            let entry = BlockEntry(kind: .address, value: address)
            if !entries.contains(entry) { entries.append(entry) }
        }
        for domain in plan.domains {
            let entry = BlockEntry(kind: .domain, value: domain)
            if !entries.contains(entry) { entries.append(entry) }
        }
        let protected = protectedAddresses(except: Set(plan.addresses))
        snapshot.blocks = entries
        ScanStore.save(snapshot)
        blocks = entries
        working = true
        clearError()
        status = junk ? "Moving mail to Junk…" : "Moving mail to Trash…"
        defer { working = false }
        do {
            let moved = try await SweepEngine.move(needles: needles, junk: junk, protect: protected) { [weak self] finished, expected in
                Task { @MainActor in
                    self?.status = "Moving \(finished.formatted()) of \(expected.formatted())"
                }
            }
            snapshot.sweptTotal += moved
            ScanStore.save(snapshot)
            sweptTotal = snapshot.sweptTotal
            selected.removeAll()
            selectedDomains.removeAll()
            status = "Cleaned \(moved.formatted()) messages."
        } catch {
            status = ""
            report(error)
        }
    }

    func markNotSpam() {
        var entries = snapshot.whitelist
        for address in selected {
            let entry = BlockEntry(kind: .address, value: address)
            if !entries.contains(entry) { entries.append(entry) }
        }
        for domain in selectedDomains {
            let entry = BlockEntry(kind: .domain, value: domain)
            if !entries.contains(entry) { entries.append(entry) }
        }
        let addresses = selected
        let domains = selectedDomains
        snapshot.blocks.removeAll { entry in
            if entry.kind == .address && addresses.contains(entry.value) { return true }
            if entry.kind == .domain && domains.contains(entry.value) { return true }
            return false
        }
        snapshot.whitelist = entries
        ScanStore.save(snapshot)
        blocks = snapshot.blocks
        whitelist = entries
        selected.removeAll()
        selectedDomains.removeAll()
        rescore(preselect: false)
        status = "Marked as not spam. Mail already in Junk stays there."
    }

    func removeBlock(_ entry: BlockEntry) {
        snapshot.blocks.removeAll { $0.id == entry.id }
        blocks = snapshot.blocks
        ScanStore.save(snapshot)
        rescore(preselect: false)
    }

    func removeWhitelist(_ entry: BlockEntry) {
        snapshot.whitelist.removeAll { $0.id == entry.id }
        whitelist = snapshot.whitelist
        ScanStore.save(snapshot)
        rescore(preselect: true)
    }

    func syncIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && scanning
    }

    private func report(_ error: Error) {
        errorMessage = SweepEngine.describe(error)
        errorDetail = SweepEngine.details(error)
    }

    private func clearError() {
        errorMessage = nil
        errorDetail = nil
    }

    private func apply(_ tick: ScanTick) {
        snapshot = tick.snapshot
        phase = tick.phase
        done = tick.done
        total = tick.total
        eta = tick.eta
        status = tick.total > 0 ? "\(tick.phase) · \(tick.done.formatted()) of \(tick.total.formatted())" : tick.phase
        sentWarning = tick.snapshot.sentWarning
        rescore(preselect: true)
    }

    private func applySnapshot(_ stored: ScanStore.Snapshot, preselect: Bool) {
        snapshot = stored
        blocks = stored.blocks
        whitelist = stored.whitelist
        sweptTotal = stored.sweptTotal
        keepAwake = stored.keepAwake
        includeBulk = stored.includeBulk
        includeOther = stored.includeOther
        useContacts = stored.useContacts
        scanComplete = stored.scanComplete
        sentWarning = stored.sentWarning
        rescore(preselect: preselect)
    }

    private func rescore(preselect: Bool) {
        rows = SpamScorer.scoreAll(
            senders: snapshot.senders,
            sentAddresses: Set(snapshot.sentAddresses),
            sentDomains: Set(snapshot.sentDomains),
            contacts: useContacts ? contactEmails : [],
            whitelist: snapshot.whitelist
        )
        rollups = SpamScorer.rollups(from: rows)
        if preselect {
            for row in rows where row.result.category == .spam && !heldOff.contains(row.sender.address) {
                selected.insert(row.sender.address)
            }
        }
        for row in rows where row.result.category == .safe && !pinnedOn.contains(row.sender.address) {
            selected.remove(row.sender.address)
        }
        let visible = Set(rows.map(\.sender.address))
        selected = selected.intersection(visible)
    }

    private func blockPlan() -> (addresses: [String], domains: [String]) {
        let domains = Array(selectedDomains)
        let covered = Set(domains)
        let addresses = selected.filter { address in
            !covered.contains(MailAddress.domain(of: address))
        }
        return (Array(addresses), domains)
    }

    private func protectedAddresses(except explicitly: Set<String>) -> Set<String> {
        var protect = Set(rows.filter { $0.result.category == .safe }.map(\.sender.address))
        for entry in snapshot.whitelist where entry.kind == .address {
            protect.insert(entry.value.lowercased())
        }
        protect.subtract(explicitly)
        return protect
    }
}
