import SwiftUI

struct MessagesInbox: View {
    @EnvironmentObject private var model: AppModel
    @State private var names: [UUID: String] = [:]

    private struct Thread: Identifiable {
        var id: String
        var jobID: UUID
        var proID: UUID
        var otherID: UUID
        var title: String
        var subtitle: String
        var unread: Int
    }

    private var threads: [Thread] {
        guard let me = model.session else { return [] }
        var seen = Set<String>()
        var rows: [Thread] = []
        func add(jobID: UUID, proID: UUID, otherID: UUID, fallback: String) {
            let key = "\(jobID.uuidString)-\(proID.uuidString)"
            guard seen.insert(key).inserted else { return }
            guard let job = model.jobs.first(where: { $0.id == jobID }) else { return }
            rows.append(Thread(
                id: key,
                jobID: jobID,
                proID: proID,
                otherID: otherID,
                title: names[otherID] ?? fallback,
                subtitle: job.serviceTitle,
                unread: model.unreadCount(jobID: jobID)
            ))
        }
        if me.role == .customer {
            for job in model.jobs {
                for quote in model.quotes(for: job.id) {
                    add(jobID: job.id, proID: quote.proID, otherID: quote.proID, fallback: "Pro")
                }
                if let booking = model.booking(for: job.id) {
                    add(jobID: job.id, proID: booking.proID, otherID: booking.proID, fallback: "Pro")
                }
            }
        } else {
            for quote in model.quotes where quote.proID == me.id {
                if let job = model.jobs.first(where: { $0.id == quote.jobID }) {
                    add(jobID: job.id, proID: me.id, otherID: job.customerID, fallback: "Customer")
                }
            }
            for booking in model.bookings where booking.proID == me.id {
                if let job = model.jobs.first(where: { $0.id == booking.jobID }) {
                    add(jobID: job.id, proID: me.id, otherID: job.customerID, fallback: "Customer")
                }
            }
        }
        return rows.sorted { lhs, rhs in
            if lhs.unread != rhs.unread { return lhs.unread > rhs.unread }
            return lhs.subtitle < rhs.subtitle
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrandHeader()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Messages")
                            .appText(28, weight: .bold, relativeTo: .title)
                            .foregroundStyle(ink)
                        Text(model.session?.role == .customer
                             ? "Conversations with pros about your jobs."
                             : "Conversations with customers about their jobs.")
                            .appText()
                            .foregroundStyle(.secondary)
                        if threads.isEmpty {
                            FriendlyEmpty(symbol: "bubble.left.and.bubble.right", title: "No messages yet.", photo: "yard-beds", button: nil)
                        }
                        ForEach(threads) { thread in
                            NavigationLink {
                                ChatView(jobID: thread.jobID, proID: thread.proID, title: thread.title)
                            } label: {
                                Card {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(thread.title)
                                                .appText(20, weight: .semibold, relativeTo: .headline)
                                                .foregroundStyle(ink)
                                            Text(thread.subtitle)
                                                .appText()
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        UnreadBadge(count: thread.unread)
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(thread.unread > 0 ? "\(thread.title), \(thread.subtitle), \(thread.unread) unread" : "\(thread.title), \(thread.subtitle)")
                        }
                    }
                    .padding(16)
                }
                .refreshable { await model.reload() }
            }
            .background(paper)
            .task(id: threads.map(\.otherID)) {
                for id in Set(threads.map(\.otherID)) where names[id] == nil {
                    if let person = await model.person(id) {
                        names[id] = person.publicName
                    }
                }
            }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    var jobID: UUID
    var proID: UUID
    var title: String
    @State private var lines: [MessageRecord] = []
    @State private var draft = ""
    @State private var reporting = false
    @State private var reason = "Asked to take this job off the app"
    @State private var reported = false

    private var unlocked: Bool { model.contactUnlocked(jobID: jobID) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if unlocked {
                        Text("This job was booked in the app, so contact details can be shown.")
                            .appText()
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ContactFilter.notice)
                            .appText()
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        let mine = line.senderID == model.session?.id
                        let shown = ContactFilter.display(line.body, unlocked: unlocked)
                        HStack {
                            if mine { Spacer(minLength: 40) }
                            Text(shown.text)
                                .padding(12)
                                .background(mine ? pine : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(mine ? Color.white : ink)
                            if !mine { Spacer(minLength: 40) }
                        }
                    }
                }
                .padding(16)
            }
            if !unlocked && ContactFilter.display(draft, unlocked: false).masked {
                Text("Contact details in this message stay hidden until you book.")
                    .appText()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            VStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .softField()
                Button("Send message") {
                    Haptic.tap()
                    let text = draft
                    draft = ""
                    Task { lines = await model.sendMessage(jobID: jobID, proID: proID, body: text) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .background(paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Report") { reporting = true }
            }
        }
        .sheet(isPresented: $reporting) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Report someone who asks to move a job off Contractor. Off-app deals with people you met here are not allowed.")
                        .foregroundStyle(.secondary)
                    TextField("What happened?", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                    if reported {
                        Text("Report sent. We review off-app deals.")
                            .foregroundStyle(pine)
                    }
                    Button("Send report") {
                        Task {
                            let other = model.session?.id == proID ? (model.jobs.first { $0.id == jobID }?.customerID ?? proID) : proID
                            reported = await model.report(userID: other, jobID: jobID, reason: reason)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(reported)
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Report")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { reporting = false }
                    }
                }
            }
        }
        .task {
            lines = await model.messages(jobID: jobID, proID: proID)
            model.markJobNoticesRead(jobID)
        }
    }
}
