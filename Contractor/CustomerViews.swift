import PhotosUI
import SwiftUI

struct CustomerHome: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DemoBanner()
                    Text("Your jobs")
                        .font(.title2.weight(.semibold))
                    if model.jobs.isEmpty {
                        Text("Post a lawn or moving job. Up to 3 local pros can quote, for free.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.jobs) { job in
                        NavigationLink {
                            JobDetailView(jobID: job.id)
                        } label: {
                            JobCard(job: job, quoteCount: model.quotes(for: job.id).count)
                        }
                        .buttonStyle(.plain)
                    }
                    AccountNote()
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(paper)
            .navigationTitle("Contractor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { Task { await model.signOut() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Post") { PostJobView() }
                }
            }
            .refreshable { await model.reload() }
            .task { await model.reload() }
        }
    }
}

struct JobCard: View {
    var job: JobRecord
    var quoteCount: Int

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(job.category.title, systemImage: job.category.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(job.category == .lawn ? pine : clay)
                    Spacer()
                    Text(job.status.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(paper, in: Capsule())
                }
                Text(job.place).font(.headline).foregroundStyle(ink)
                Text("\(DayStamp.display(job.scheduledOn)) · \(job.details.summary(for: job.category))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(quoteCount == 0 ? "No quotes yet" : "\(quoteCount) of 3 quotes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PostJobView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var category = ServiceCategory.lawn
    @State private var street = ""
    @State private var zip = "44903"
    @State private var date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var lawnSize = "Medium"
    @State private var rooms = 2
    @State private var stairs = false
    @State private var notes = ""
    @State private var picker: [PhotosPickerItem] = []
    @State private var photos: [Data] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Category", selection: $category) {
                    ForEach(ServiceCategory.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Street address", text: $street)
                TextField("ZIP code", text: $zip)
                    .keyboardType(.numberPad)
                if !zip.isEmpty && !RichlandCounty.contains(zip) {
                    Text("Use a Richland County ZIP.").font(.footnote).foregroundStyle(.red)
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                if category == .lawn {
                    Picker("Lawn size", selection: $lawnSize) {
                        Text("Small").tag("Small")
                        Text("Medium").tag("Medium")
                        Text("Large").tag("Large")
                    }
                    .pickerStyle(.segmented)
                } else {
                    Stepper("Rooms: \(rooms)", value: $rooms, in: 1...8)
                    Toggle("Stairs", isOn: $stairs)
                }
                TextField("Details", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                PhotosPicker(selection: $picker, maxSelectionCount: 4, matching: .images) {
                    Label(photos.isEmpty ? "Add photos" : "\(photos.count) photos", systemImage: "photo")
                }
                .onChange(of: picker) { _, items in
                    Task {
                        var loaded: [Data] = []
                        for item in items {
                            if let data = try? await item.loadTransferable(type: Data.self) {
                                loaded.append(data)
                            }
                        }
                        photos = loaded
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button(model.busy ? "Posting…" : "Post job") {
                    let details = JobDetails(lawnSize: lawnSize, rooms: rooms, stairs: stairs, notes: notes)
                    Task {
                        let ok = await model.postJob(
                            category: category,
                            street: street,
                            zip: zip,
                            scheduledOn: DayStamp.string(from: date),
                            details: details,
                            photos: photos
                        )
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("New job")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct JobDetailView: View {
    @EnvironmentObject private var model: AppModel
    var jobID: UUID
    @State private var rating = 5
    @State private var review = ""

    private var job: JobRecord? { model.jobs.first { $0.id == jobID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job {
                    Text(job.category.title).font(.subheadline.weight(.semibold)).foregroundStyle(pine)
                    Text(job.place).font(.title2.weight(.semibold))
                    Text("\(DayStamp.display(job.scheduledOn)) · \(job.details.summary(for: job.category))")
                        .foregroundStyle(.secondary)
                    if !job.details.notes.isEmpty {
                        Text(job.details.notes)
                    }
                    photoRow(job.photoNames)
                    Text("Quotes").font(.headline)
                    let rows = model.quotes(for: job.id)
                    if rows.isEmpty {
                        Text("Up to 3 pros can quote. You compare them here and book one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { quote in
                        QuoteCard(quote: quote, job: job)
                    }
                    if job.status == .booked {
                        reviewBox
                    }
                    if let booking = model.booking(for: job.id), job.status != .open {
                        Text(paymentLine(priceCents: booking.priceCents, percent: booking.feePercent))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Paid in the app. Card charge is stubbed for this demo.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if job.category == .lawn || job.status == .completed || job.status == .booked {
                            bookAgain(booking)
                        }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bookAgain(_ booking: BookingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Book again at \(FeeSchedule.launch.repeatPercent)%").font(.headline)
            Button("Book the same pro again") {
                Task { _ = await model.bookAgain(bookingID: booking.id, scheduledOn: DayStamp.string(from: Date().addingTimeInterval(7 * 24 * 3600)), recurrence: "") }
            }
            .buttonStyle(.borderedProminent)
            if job?.category == .lawn {
                Button("Weekly lawn service") {
                    Task { _ = await model.bookAgain(bookingID: booking.id, scheduledOn: DayStamp.string(from: Date().addingTimeInterval(7 * 24 * 3600)), recurrence: "weekly") }
                }
                .buttonStyle(.bordered)
                Button("Every 2 weeks") {
                    Task { _ = await model.bookAgain(bookingID: booking.id, scheduledOn: DayStamp.string(from: Date().addingTimeInterval(14 * 24 * 3600)), recurrence: "biweekly") }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var reviewBox: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rate the job").font(.headline)
                Stepper("Stars: \(rating)", value: $rating, in: 1...5)
                TextField("How did it go?", text: $review, axis: .vertical)
                Button("Submit review") {
                    Task {
                        _ = await model.review(jobID: jobID, rating: rating, body: review)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func photoRow(_ names: [String]) -> some View {
        if !names.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(names, id: \.self) { name in
                        if let image = PhotoStore.image(name) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }
}

struct QuoteCard: View {
    @EnvironmentObject private var model: AppModel
    var quote: QuoteRecord
    var job: JobRecord
    @State private var name = "Pro"

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name).font(.headline)
                    Spacer()
                    Text(Money.string(cents: quote.priceCents)).font(.headline)
                }
                if model.hasGuarantee(quote.proID) {
                    Text(Guarantee.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(pine.opacity(0.12), in: Capsule())
                }
                if !quote.message.isEmpty {
                    let unlocked = model.contactUnlocked(jobID: job.id)
                    Text(ContactFilter.display(quote.message, unlocked: unlocked).text).foregroundStyle(.secondary)
                }
                Text(paymentLine(priceCents: quote.priceCents, percent: FeeSchedule.launch.standardPercent))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(quote.status == .sent ? "Waiting" : quote.status.rawValue.capitalized)
                    .font(.caption)
                HStack {
                    if job.status == .open && quote.status == .sent {
                        Button("Pay and book") {
                            Task { _ = await model.book(quoteID: quote.id) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    NavigationLink("Message") {
                        ChatView(jobID: job.id, proID: quote.proID, title: name)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .task {
            if let person = await model.person(quote.proID) {
                name = person.publicName
            }
        }
    }
}
