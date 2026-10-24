import SwiftUI

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
    }
}

private struct SignInScreen: View {
    @ObservedObject var model: SweepModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Clean a spam-flooded Yahoo inbox. The email and app password stay in the iPhone Keychain. Spam Sweep talks only to Yahoo.")
                    .foregroundStyle(.secondary)
                TextField("Yahoo email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                SecureField("Yahoo app password", text: $password)
                    .textContentType(.password)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("In Yahoo, open Account Security, then Generate app password. Use that password here, not your normal Yahoo password.")
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
                        Text(model.status)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
                PrivacyNote()
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct InboxScreen: View {
    @ObservedObject var model: SweepModel
    @State private var confirmingDelete = false
    @State private var confirmingBlock = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                PrivacyNote()
                Stepper(value: limitBinding, in: 200...5000, step: 200) {
                    Text("Scan the latest \(model.scanLimit.formatted()) messages")
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if model.scanning || model.sweeping || model.working {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: model.scanning && model.total > 0 ? Double(model.checked) : nil, total: Double(max(model.total, 1)))
                            .tint(amber)
                        Text(progressText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                } else if !model.status.isEmpty {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                }
                if model.groups.isEmpty && !model.scanning {
                    Text("Scan the inbox to group mail by sender, largest counts first.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(model.groups) { group in
                            SenderRow(group: group, selected: model.selected.contains(group.address)) {
                                model.toggle(group)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Sign Out") { model.signOut() }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if model.selected.isEmpty {
                    Button("Select All") { model.selectAll() }
                        .disabled(model.groups.isEmpty || model.working)
                } else {
                    Button("Select All") { model.selectAll() }
                        .disabled(model.allSelected || model.working)
                    Button("Cancel") { model.cancelSelection() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.selected.isEmpty {
                actionBar
            }
        }
        .confirmationDialog(
            "Delete mail from \(model.selected.count.formatted()) senders?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Spam Sweep moves every matching message in the Yahoo inbox to Trash. Yahoo keeps Trash until you empty it there.")
        }
        .confirmationDialog(
            "Block \(model.selected.count.formatted()) senders?",
            isPresented: $confirmingBlock,
            titleVisibility: .visible
        ) {
            Button("This sender") {
                Task { await model.blockSelected(domains: false) }
            }
            Button("Whole domain") {
                Task { await model.blockSelected(domains: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blocked mail already in the inbox is moved to Junk. New mail from the block list is swept to Junk when you open Spam Sweep.")
        }
    }

    private var limitBinding: Binding<Int> {
        Binding(get: { model.scanLimit }, set: { model.setScanLimit($0) })
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.email)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(model.sweptTotal.formatted()) swept to Junk")
                .font(.title2)
                .fontWeight(.semibold)
            Text(model.blocks.isEmpty ? "No blocked senders yet." : "\(model.blocks.count.formatted()) on the block list.")
                .foregroundStyle(.secondary)
            Button {
                Task { await model.sweepNow() }
            } label: {
                Label("Sweep Now", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.sweeping || model.scanning || model.working || model.blocks.isEmpty)
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scan Inbox", systemImage: "envelope.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.scanning || model.working || model.sweeping)
            NavigationLink {
                BlockListScreen(model: model)
            } label: {
                Label("Block List", systemImage: "hand.raised")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Link(destination: yahooBlocked) {
                Label("Yahoo blocked addresses", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var progressText: String {
        if model.scanning && model.total > 0 {
            return "Read \(model.checked.formatted()) of \(model.total.formatted())"
        }
        return model.status.isEmpty ? "Talking to Yahoo…" : model.status
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.selected.count.formatted()) senders selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelSelection() }
                    .buttonStyle(.bordered)
                Button("Junk") { Task { await model.moveSelectedToJunk() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.working)
                Button("Delete") { confirmingDelete = true }
                    .buttonStyle(.bordered)
                    .disabled(model.working)
                Button("Block") { confirmingBlock = true }
                    .buttonStyle(.bordered)
                    .disabled(model.working)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }
}

private struct SenderRow: View {
    let group: SenderGroup
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? amber : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.headline)
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.leading)
                    if !group.name.isEmpty {
                        Text(group.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(group.latestSubject)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !group.hints.isEmpty {
                        Text(group.hints.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(amber)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Text(group.count.formatted())
                    .font(.headline)
                    .foregroundStyle(ink)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(group.count) messages")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BlockListScreen: View {
    @ObservedObject var model: SweepModel

    var body: some View {
        Group {
            if model.blocks.isEmpty {
                Text("No blocked senders or domains yet. Select senders in the scan, then tap Block.")
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                List {
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
            }
        }
        .navigationTitle("Block List")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mail on iPhone can’t be filtered by apps, so Spam Sweep cleans the Yahoo account directly. It does not use analytics, ads, or any server except Yahoo IMAP.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Yahoo’s own list is under Yahoo Mail → Settings → Filters → Blocked addresses.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Open Yahoo blocked addresses", destination: yahooBlocked)
                .font(.footnote)
        }
    }
}
