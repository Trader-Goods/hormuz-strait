import SwiftUI

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
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ContactFilter.notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        let mine = line.senderID == model.session?.id
                        let shown = ContactFilter.display(line.body, unlocked: unlocked)
                        HStack {
                            if mine { Spacer(minLength: 40) }
                            Text(shown.text)
                                .padding(12)
                                .background(mine ? pine : Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(mine ? Color.white : ink)
                            if !mine { Spacer(minLength: 40) }
                        }
                    }
                }
                .padding(16)
            }
            if !unlocked && ContactFilter.display(draft, unlocked: false).masked {
                Text("Contact details in this message stay hidden until you book.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            HStack {
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    let text = draft
                    draft = ""
                    Task { lines = await model.sendMessage(jobID: jobID, proID: proID, body: text) }
                }
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
                    .buttonStyle(.borderedProminent)
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
        .task { lines = await model.messages(jobID: jobID, proID: proID) }
    }
}
