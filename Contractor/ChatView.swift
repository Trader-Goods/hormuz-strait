import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    var jobID: UUID
    var proID: UUID
    var title: String
    @State private var lines: [MessageRecord] = []
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Phone numbers stay private. This chat is only for this quote.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(lines) { line in
                        let mine = line.senderID == model.session?.id
                        HStack {
                            if mine { Spacer(minLength: 40) }
                            Text(line.body)
                                .padding(12)
                                .background(mine ? pine : Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(mine ? Color.white : ink)
                            if !mine { Spacer(minLength: 40) }
                        }
                    }
                }
                .padding(16)
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
        .task { lines = await model.messages(jobID: jobID, proID: proID) }
    }
}
