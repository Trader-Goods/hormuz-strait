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
    @Published var autoSweep = true
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
    @Published var moving = false
    @Published var moveVisible = false
    @Published var moveDone = 0
    @Published var moveTotal = 0
    @Published var moveSender = ""
    @Published var moveETA = ""
    @Published var moveNote = ""
    @Published var sweepBanner = false
    @Published var sweepPhase = ""
    @Published var sweepDone = 0
    @Published var sweepTotal = 0
    @Published var sweepETA = ""
    @Published var sweepSender = ""
    private var snapshot = ScanStore.Snapshot()
    private var contactEmails = Set<String>()
    private var heldOff = Set<String>()
    private var pinnedOn = Set<String>()
    private var stopFlag: StopFlag?
    private var moveStop: StopFlag?
    private var sweepStop: StopFlag?
    private var sweepTask: Task<Void, Never>?

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
        var changed = false
        if let pending = stored.pendingMove, !pending.hasWork {
            stored.pendingMove = nil
            changed = true
        }
        if let pending = stored.pendingSweep, !pending.hasWork {
            stored.pendingSweep = nil
            changed = true
        }
        if changed { ScanStore.save(stored) }
        applySnapshot(stored, preselect: !scanning && !moving && !sweepBanner)
    }

    func activate() async {
        if !scanning && !moving && sweepTask == nil {
            refreshAccount()
        } else if !signedIn {
            refreshAccount()
        }
        await sweepOnOpen()
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

    var moveRemaining: Int {
        max(0, moveTotal - moveDone)
    }

    var pendingMoveOffer: PendingMove? {
        guard !moveVisible, let pending = snapshot.pendingMove, pending.hasWork else { return nil }
        return pending
    }

    func signOut() {
        stopFlag?.stop()
        moveStop?.stop()
        sweepStop?.stop()
        sweepTask?.cancel()
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
        moving = false
        moveVisible = false
        sweepBanner = false
        sweeping = false
        syncIdleTimer()
    }

    func setAutoSweep(_ value: Bool) {
        autoSweep = value
        snapshot.autoSweep = value
        ScanStore.save(snapshot)
        if value {
            Task { await sweepOnOpen() }
        }
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
        await stopSweepForUserAction()
        guard signedIn, !scanning, !working, !moving else { return }
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
        guard signedIn, snapshot.autoSweep, !blocks.isEmpty else { return }
        guard snapshot.pendingMove?.hasWork != true else { return }
        guard !moving, !scanning, sweepTask == nil else { return }
        if snapshot.pendingSweep?.hasWork == true {
            await runSweep()
            return
        }
        guard SweepSchedule.due(last: snapshot.lastSweepAt, now: Date()) else { return }
        await runSweep()
    }

    func rescan() async {
        guard signedIn, !moving else { return }
        await startScan(restart: true)
    }

    func sweepNow() async {
        guard signedIn, !scanning, !moving, sweepTask == nil else { return }
        guard !blocks.isEmpty else {
            status = "Nothing is blocked yet."
            return
        }
        await runSweep()
    }

    func skipSweep() {
        sweepStop?.stop()
        snapshot.pendingSweep = nil
        snapshot.lastSweepAt = Date().timeIntervalSince1970
        ScanStore.save(snapshot)
        sweepBanner = false
        sweeping = false
        sweepPhase = ""
        sweepETA = ""
        sweepSender = ""
    }

    var sweepRemaining: Int {
        max(0, sweepTotal - sweepDone)
    }

    private func runSweep() async {
        guard sweepTask == nil else { return }
        let flag = StopFlag()
        sweepStop = flag
        sweeping = true
        sweepBanner = true
        sweepPhase = "finding"
        sweepDone = 0
        sweepTotal = 0
        sweepETA = "Estimating time left"
        sweepSender = "Finding blocked mail"
        clearError()
        let task = Task { @MainActor in
            await self.performSweep(flag)
        }
        sweepTask = task
        await task.value
    }

    private func performSweep(_ flag: StopFlag) async {
        defer {
            sweeping = false
            sweepStop = nil
            sweepTask = nil
            if sweepPhase != "failed" {
                sweepBanner = false
                sweepETA = ""
                sweepSender = ""
                sweepPhase = ""
            }
            if !moving && !scanning {
                rescore(preselect: false)
            }
        }
        do {
            _ = try await SweepEngine.sweepBlocked(stop: flag) { tick in
                await MainActor.run {
                    self.applySweep(tick)
                }
            }
            if flag.isStopped {
                status = "Sweep skipped."
            } else if sweepPhase == "moving" {
                status = sweepDone == 0 ? "No new blocked mail." : "Moved \(sweepDone.formatted()) blocked messages to Junk."
            } else {
                status = "No new blocked mail."
            }
        } catch {
            sweepPhase = "failed"
            sweepBanner = true
            sweepSender = "Sweep paused"
            report(error)
        }
    }

    private func applySweep(_ tick: SweepTick) {
        guard sweeping else { return }
        snapshot = tick.snapshot
        sweptTotal = tick.snapshot.sweptTotal
        blocks = tick.snapshot.blocks
        sweepPhase = tick.phase
        sweepDone = tick.done
        sweepTotal = tick.total
        sweepETA = tick.eta
        sweepSender = tick.sender
        sweepBanner = true
    }

    private func stopSweepForUserAction() async {
        guard sweepTask != nil else { return }
        sweepStop?.stop()
        snapshot.pendingSweep = nil
        ScanStore.save(snapshot)
        await sweepTask?.value
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
        await stopSweepForUserAction()
        let plan = blockPlan()
        guard !plan.addresses.isEmpty || !plan.domains.isEmpty else { return }
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
        blocks = entries
        let job = moveJob(plan: plan, protect: protected)
        let total = job.groups.values.reduce(0) { $0 + $1.count }
        snapshot.pendingMove = PendingMove(
            junk: junk,
            destination: "",
            moved: 0,
            total: total,
            remaining: job.groups,
            searchAddresses: job.missingAddresses,
            searchDomains: job.missingDomains
        )
        ScanStore.save(snapshot)
        selected.removeAll()
        selectedDomains.removeAll()
        await runMove(
            groups: job.groups,
            searchAddresses: job.missingAddresses,
            searchDomains: job.missingDomains,
            protect: protected,
            junk: junk,
            destinationName: nil,
            alreadyMoved: 0
        )
    }

    func continueMove() async {
        await stopSweepForUserAction()
        guard let pending = snapshot.pendingMove, pending.hasWork else { return }
        await runMove(
            groups: pending.remaining,
            searchAddresses: pending.searchAddresses,
            searchDomains: pending.searchDomains,
            protect: [],
            junk: pending.junk,
            destinationName: pending.destination.isEmpty ? nil : pending.destination,
            alreadyMoved: pending.moved
        )
    }

    func cancelMove() {
        moveStop?.stop()
        moveSender = "Stopping after this batch…"
    }

    func abandonMove() {
        moveStop?.stop()
        snapshot.pendingMove = nil
        ScanStore.save(snapshot)
        moving = false
        moveVisible = false
        moveSender = ""
        moveETA = ""
        syncIdleTimer()
        rescore(preselect: false)
    }

    func dismissMove() {
        moveVisible = false
        moveSender = ""
        moveETA = ""
        moving = false
        syncIdleTimer()
        rescore(preselect: false)
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
        UIApplication.shared.isIdleTimerDisabled = moving || (keepAwake && scanning)
    }

    private func runMove(
        groups: [String: [UInt64]],
        searchAddresses: [String],
        searchDomains: [String],
        protect: Set<String>,
        junk: Bool,
        destinationName: String?,
        alreadyMoved: Int
    ) async {
        let flag = StopFlag()
        moveStop = flag
        moving = true
        moveVisible = true
        moveDone = alreadyMoved
        moveTotal = alreadyMoved + groups.values.reduce(0) { $0 + $1.count }
        moveSender = "Connecting to Yahoo…"
        moveETA = "Estimating time left"
        moveNote = ""
        clearError()
        status = junk ? "Moving mail to Junk…" : "Moving mail to Trash…"
        syncIdleTimer()
        defer {
            moving = false
            moveStop = nil
            syncIdleTimer()
            if snapshot.pendingMove == nil {
                moveSender = ""
                moveETA = ""
            }
            rescore(preselect: false)
        }
        do {
            try await SweepEngine.moveInbox(
                groups: groups,
                searchAddresses: searchAddresses,
                searchDomains: searchDomains,
                protect: protect,
                junk: junk,
                destinationName: destinationName,
                alreadyMoved: alreadyMoved,
                stop: flag,
                confirmSearch: true
            ) { tick in
                await MainActor.run {
                    self.applyMove(tick)
                }
            }
            if flag.isStopped, let pending = snapshot.pendingMove, pending.remainingCount > 0 {
                moveSender = "Move paused"
                status = "Moved \(moveDone.formatted()) of \(moveTotal.formatted()) emails."
            } else if moveTotal == 0 {
                moveSender = "No matching inbox mail to move."
                status = moveSender
            } else {
                status = "Moved \(moveDone.formatted()) emails."
            }
        } catch {
            status = ""
            report(error)
            if snapshot.pendingMove != nil {
                moveSender = "Move paused"
            }
        }
    }

    private func applyMove(_ tick: MoveTick) {
        var pending = snapshot.pendingMove ?? PendingMove(
            junk: tick.junk,
            destination: tick.destination,
            moved: tick.moved,
            total: tick.total,
            remaining: [:]
        )
        pending.junk = tick.junk
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
                stored.removeAll { drop.contains($0) }
                if stored.isEmpty {
                    snapshot.inboxUIDs.removeValue(forKey: sender)
                } else {
                    snapshot.inboxUIDs[sender] = stored
                }
            }
            for (sender, uids) in tick.removed where sender.contains("@") {
                if let index = snapshot.senders.firstIndex(where: { $0.address == sender }) {
                    snapshot.senders[index].count = max(0, snapshot.senders[index].count - uids.count)
                }
            }
            snapshot.senders.removeAll { $0.count == 0 && (snapshot.inboxUIDs[$0.address] ?? []).isEmpty }
        }
        if !tick.cleared.isEmpty {
            for address in tick.cleared {
                snapshot.inboxUIDs.removeValue(forKey: address)
                if let index = snapshot.senders.firstIndex(where: { $0.address == address }) {
                    snapshot.senders[index].count = 0
                }
            }
            snapshot.senders.removeAll { $0.count == 0 && (snapshot.inboxUIDs[$0.address] ?? []).isEmpty }
        }
        if !tick.note.isEmpty {
            moveNote = tick.note
        }
        if pending.remaining.isEmpty {
            snapshot.pendingMove = nil
        } else {
            snapshot.pendingMove = pending
        }
        ScanStore.save(snapshot)
        sweptTotal = snapshot.sweptTotal
        moveDone = pending.moved
        moveTotal = max(pending.total, pending.moved)
        moveSender = tick.sender
        moveETA = tick.eta
    }

    private func moveJob(
        plan: (addresses: [String], domains: [String]),
        protect: Set<String>
    ) -> (groups: [String: [UInt64]], missingAddresses: [String], missingDomains: [String]) {
        let domainSet = Set(plan.domains)
        var chosen = Set(selected.map { $0.lowercased() })
        for sender in snapshot.senders where domainSet.contains(sender.domain) && !protect.contains(sender.address) {
            chosen.insert(sender.address.lowercased())
        }
        chosen.subtract(protect)
        var groups: [String: [UInt64]] = [:]
        var missingAddresses: [String] = []
        for address in chosen {
            let uids = Array(Set(snapshot.inboxUIDs[address] ?? []))
            if !uids.isEmpty {
                groups[address] = uids
            }
            missingAddresses.append(address)
        }
        return (groups, missingAddresses, plan.domains)
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
        autoSweep = stored.autoSweep
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
