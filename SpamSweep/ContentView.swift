import SwiftUI
import UIKit

private let yahooSecurity = URL(string: "https://login.yahoo.com/account/security")!
private let yahooBlocked = URL(string: "https://mail.yahoo.com/d/settings/filters")!

struct ContentView: View {
    @ObservedObject var model: SweepModel

    var body: some View {
        NavigationStack {
            Group {
                if model.signedIn {
                    InboxScreen(model: model)
                } else {
                    SignInScreen(model: model)
                }
            }
            .navigationTitle("Spam Sweep")
            .navigationBarTitleDisplayMode(.large)
        }
        .onChange(of: model.scanning) { _, _ in model.syncIdleTimer() }
        .onChange(of: model.keepAwake) { _, _ in model.syncIdleTimer() }
    }
}

private struct SignInScreen: View {
    @ObservedObject var model: SweepModel
    @State private var email = ""
    @State private var password = ""
    @State private var revealPassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Score a spam-flooded Yahoo inbox and block the senders. The email and app password stay in the iPhone Keychain. Spam Sweep talks only to Yahoo.")
                    .foregroundStyle(.secondary)
                TextField("Yahoo email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 8) {
                    if revealPassword {
                        TextField("Yahoo app password", text: $password)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Yahoo app password", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let hint = YahooAccount.passwordHint(for: password) {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("In Yahoo, open Account Security, then Generate app password. Use that password here, not your normal Yahoo password. Spaces and dashes are removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(destination: yahooSecurity) {
                    Label("Open Yahoo Account Security", systemImage: "lock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button {
                    Task { await model.signIn(email: email, password: password) }
                } label: {
                    Label("Connect", systemImage: "envelope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.working)
                if model.working {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(model.status).foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    ErrorNote(message: error, detail: model.errorDetail)
                }
                PrivacyNote()
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct ErrorNote: View {
    var message: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            if let detail, !detail.isEmpty {
                Button("Copy details") {
                    if message.contains(detail) {
                        UIPasteboard.general.string = message
                    } else {
                        UIPasteboard.general.string = "\(message)\n\(detail)"
                    }
                }
                .font(.footnote)
            }
        }
    }
}

private struct InboxScreen: View {
    @ObservedObject var model: SweepModel
    @State private var filter = ResultFilter.all
    @State private var detailAddress: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                options
                if model.scanning || model.total > 0 && model.scanning {
                    progress
                }
                if !model.sentWarning.isEmpty {
                    Text(model.sentWarning).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    ErrorNote(message: error, detail: model.errorDetail)
                } else if !model.status.isEmpty {
                    Text(model.status).foregroundStyle(.secondary)
                }
                if !model.scanning, !model.scanComplete, model.hasProgress {
                    Text("Paused. Continue to finish the mailbox without starting over.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.rows.isEmpty, !model.scanning {
                    Text("Scan reads every inbox header, scores each sender, and selects spam. Message bodies stay on Yahoo.")
                        .foregroundStyle(.secondary)
                } else if !model.rows.isEmpty {
                    filters
                    Text("Spam is selected. Likely spam is listed but not selected. People you've written to stay unselected until you choose them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if filter == .all || filter == .spam {
                        domainSection
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(shownRows) { row in
                            SenderRow(row: row, selected: model.selected.contains(row.sender.address)) {
                                model.toggle(row)
                            } onOpen: {
                                detailAddress = row.sender.address
                            }
                        }
                    }
                }
                PrivacyNote()
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationDestination(item: $detailAddress) { address in
            SenderDetail(address: address, model: model)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Sign Out") { model.signOut() }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Select spam") { model.selectSpam() }
                    .disabled(model.rows.isEmpty || model.working)
                if !model.selected.isEmpty || !model.selectedDomains.isEmpty {
                    Button("Cancel") { model.cancelSelection() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.selected.isEmpty || !model.selectedDomains.isEmpty {
                actionBar
            }
        }
        .confirmationDialog("Block \(model.selectionSummary)?", isPresented: $model.confirmingBlock, titleVisibility: .visible) {
            Button("Move to Junk") { Task { await model.blockSelected(junk: true) } }
            Button("Move to Trash", role: .destructive) { Task { await model.blockSelected(junk: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves matching mail that is still in the inbox. Yahoo’s own Blocked Addresses list cannot be set from an app.")
        }
        .confirmationDialog("Mark \(model.selectionSummary) as not spam?", isPresented: $model.confirmingNotSpam, titleVisibility: .visible) {
            Button("Not spam") { model.markNotSpam() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will not be flagged again. Mail already moved to Junk stays there.")
        }
        .confirmationDialog("This is someone you've written to.", isPresented: safePrompt, titleVisibility: .visible) {
            Button("Select anyway") { model.confirmSafeSelection() }
            Button("Cancel", role: .cancel) { model.pendingSafe = nil }
        }
        .confirmationDialog("Scan the mailbox again?", isPresented: $model.confirmingRestart, titleVisibility: .visible) {
            Button("Start over") { Task { await model.startScan(restart: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current results and reads every message header again.")
        }
    }

    private var shownRows: [ScoredSender] {
        model.rows.filter { filter.includes($0.result.category) }
    }

    private var safePrompt: Binding<Bool> {
        Binding(get: { model.pendingSafe != nil }, set: { if !$0 { model.pendingSafe = nil } })
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.email).font(.subheadline).foregroundStyle(.secondary)
            Text("\(model.sweptTotal.formatted()) cleaned")
                .font(.title2.weight(.semibold))
            Text(summaryLine).foregroundStyle(.secondary)
            Button {
                Task { await model.sweepNow() }
            } label: {
                Label("Sweep Now", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.sweeping || model.scanning || model.working || model.blocks.isEmpty)
            Button {
                Task { await primaryScan() }
            } label: {
                Label(scanTitle, systemImage: "envelope.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.scanning || model.working || model.sweeping)
            if model.scanning {
                Button("Stop") { model.stopScan() }
                    .buttonStyle(.bordered)
            } else if model.hasProgress, !model.scanComplete {
                Button("Start over") { model.confirmingRestart = true }
                    .buttonStyle(.bordered)
            }
            NavigationLink {
                BlockListScreen(model: model)
            } label: {
                Label("Block list and not-spam", systemImage: "hand.raised")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var summaryLine: String {
        if model.rows.isEmpty { return model.blocks.isEmpty ? "Nothing scanned yet." : "\(model.blocks.count.formatted()) on the block list." }
        return "\(model.messageTotal.formatted()) messages from \(model.rows.count.formatted()) senders"
    }

    private var scanTitle: String {
        if model.scanning { return "Scanning…" }
        if !model.scanComplete && model.hasProgress { return "Continue scan" }
        if model.rows.isEmpty { return "Scan inbox" }
        return "Scan again"
    }

    private func primaryScan() async {
        if model.scanComplete && model.hasProgress {
            model.confirmingRestart = true
            return
        }
        await model.startScan(restart: !model.hasProgress)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Keep the screen awake while scanning", isOn: keepAwake)
            Toggle("Include Junk for better detection", isOn: includeBulk)
            Toggle("Also scan other folders", isOn: includeOther)
            Toggle("Use Contacts to protect people you know", isOn: useContacts)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var keepAwake: Binding<Bool> {
        Binding(get: { model.keepAwake }, set: { model.setKeepAwake($0) })
    }

    private var includeBulk: Binding<Bool> {
        Binding(get: { model.includeBulk }, set: { model.setIncludeBulk($0) })
    }

    private var includeOther: Binding<Bool> {
        Binding(get: { model.includeOther }, set: { model.setIncludeOther($0) })
    }

    private var useContacts: Binding<Bool> {
        Binding(get: { model.useContacts }, set: { value in
            Task { await model.setUseContacts(value) }
        })
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(model.done), total: Double(max(model.total, 1)))
                .tint(amber)
            Text(model.total > 0 ? "\(model.done.formatted()) of \(model.total.formatted())" : model.phase)
                .font(.subheadline)
            if !model.eta.isEmpty {
                Text(model.eta).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ResultFilter.allCases) { item in
                    let count = model.rows.filter { item.includes($0.result.category) }.count
                    Button("\(item.rawValue) \(count.formatted())") { filter = item }
                        .buttonStyle(.bordered)
                        .tint(filter == item ? amber : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var domainSection: some View {
        let shown = model.rollups.filter { filter == .all || $0.topScore >= 70 }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Domains with many addresses")
                    .font(.headline)
                ForEach(shown) { rollup in
                    Button {
                        model.toggleDomain(rollup)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: model.selectedDomains.contains(rollup.domain) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selectedDomains.contains(rollup.domain) ? amber : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rollup.domain).font(.headline).foregroundStyle(ink)
                                Text("\(rollup.addresses.count.formatted()) addresses · \(rollup.messageCount.formatted()) messages")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if !rollup.safeAddresses.isEmpty {
                                    Text("People you've written to on this domain stay unselected.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(rollup.topScore)")
                                .font(.headline)
                                .foregroundStyle(.red)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectionSummary.isEmpty ? "Selected" : model.selectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelSelection() }
                    .buttonStyle(.bordered)
                Button("Block selected") { model.confirmingBlock = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.working)
                Button("Not spam") { model.confirmingNotSpam = true }
                    .buttonStyle(.bordered)
                    .disabled(model.working)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }
}

private enum ResultFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case spam = "Spam"
    case likely = "Likely"
    case ok = "OK"
    case safe = "Safe"

    var id: String { rawValue }

    func includes(_ category: ScoreCategory) -> Bool {
        switch self {
        case .all: return true
        case .spam: return category == .spam
        case .likely: return category == .likely
        case .ok: return category == .ok
        case .safe: return category == .safe
        }
    }
}

private struct SenderRow: View {
    let row: ScoredSender
    let selected: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? scoreColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Deselect \(title)" : "Select \(title)")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.headline).foregroundStyle(ink)
                        Spacer()
                        Text("\(row.result.score)")
                            .font(.headline)
                            .foregroundStyle(scoreColor)
                    }
                    Text(row.sender.address).font(.subheadline).foregroundStyle(.secondary)
                    if let subject = row.sender.subjects.first {
                        Text(subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("\(row.result.category.title) · \(row.sender.count.formatted())")
                        .font(.caption)
                        .foregroundStyle(scoreColor)
                    if let reason = row.result.reasons.first {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var title: String {
        row.sender.displayName.isEmpty ? row.sender.address : row.sender.displayName
    }

    private var scoreColor: Color {
        switch row.result.category {
        case .spam: return .red
        case .likely: return amber
        case .ok: return .secondary
        case .safe: return Color(red: 0.12, green: 0.45, blue: 0.28)
        }
    }
}

private struct SenderDetail: View {
    let address: String
    @ObservedObject var model: SweepModel

    var body: some View {
        ScrollView {
            if let row = model.rows.first(where: { $0.sender.address == address }) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(row.sender.displayName.isEmpty ? row.sender.address : row.sender.displayName)
                        .font(.title2.weight(.semibold))
                    Text(row.sender.address).foregroundStyle(.secondary)
                    Text("\(row.result.category.title) · score \(row.result.score) · \(row.sender.count.formatted()) messages")
                    if !row.result.reasons.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Why").font(.headline)
                            ForEach(row.result.reasons, id: \.self) { reason in
                                Text("• \(reason)")
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subjects").font(.headline)
                        ForEach(row.sender.subjects, id: \.self) { subject in
                            Text(subject)
                        }
                    }
                    Button(model.selected.contains(address) ? "Deselect" : "Select") {
                        model.toggle(row)
                    }
                    .buttonStyle(.bordered)
                    if !SpamScorer.isFreemail(row.sender.domain) {
                        Button("Block the whole \(row.sender.domain) domain") {
                            if let rollup = model.rollups.first(where: { $0.domain == row.sender.domain }) {
                                model.toggleDomain(rollup)
                            } else {
                                model.selectedDomains.insert(row.sender.domain)
                                model.selected.insert(address)
                            }
                            model.confirmingBlock = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            } else {
                Text("That sender is no longer in the scan.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .navigationTitle("Sender")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct BlockListScreen: View {
    @ObservedObject var model: SweepModel

    var body: some View {
        List {
            Section("Blocked") {
                if model.blocks.isEmpty {
                    Text("Nobody is blocked yet.")
                }
                ForEach(model.blocks) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.value)
                            Text(entry.kind == .domain ? "Whole domain" : "Sender")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.removeBlock(entry) }
                    }
                }
            }
            Section("Not spam") {
                if model.whitelist.isEmpty {
                    Text("Nobody is marked not spam yet.")
                }
                ForEach(model.whitelist) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.value)
                            Text(entry.kind == .domain ? "Whole domain" : "Sender")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.removeWhitelist(entry) }
                    }
                }
            }
        }
        .navigationTitle("Block list")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mail on iPhone can’t be filtered by apps, so Spam Sweep cleans the Yahoo account directly. Yahoo’s server-side Blocked Addresses can’t be set via IMAP, so blocking means this app moves their mail to Junk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Spam Sweep does not use analytics, ads, or any server except Yahoo IMAP.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Yahoo blocked addresses", destination: yahooBlocked)
                .font(.footnote)
        }
    }
}
