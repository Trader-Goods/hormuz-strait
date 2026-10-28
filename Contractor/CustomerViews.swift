import PhotosUI
import SwiftUI
import UIKit

struct CustomerHome: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your jobs")
                        .font(.title2.weight(.semibold))
                    if !model.notices.isEmpty {
                        NoticeList()
                    }
                    if model.jobs.isEmpty {
                        NavigationLink("Post a job") { PostJobView() }
                            .buttonStyle(.borderedProminent)
                    }
                    ForEach(model.jobs) { job in
                        NavigationLink {
                            JobDetailView(jobID: job.id)
                        } label: {
                            JobCard(job: job, quoteCount: model.quotes(for: job.id).count)
                        }
                        .buttonStyle(.plain)
                    }
                    HelpLinks()
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(paper)
            .navigationTitle("Contractor Pros")
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
    var exact = true

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(job.serviceTitle, systemImage: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(job.category == .moving ? clay : pine)
                    Spacer()
                    Text(job.status.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(paper, in: Capsule())
                }
                if SampleJobs.contains(job.id) {
                    Text("Sample").font(.caption.weight(.semibold)).foregroundStyle(clay)
                }
                Text(job.place(exact: exact)).font(.headline).foregroundStyle(ink)
                Text("\(DayStamp.display(job.scheduledOn)) · \(job.details.summary(for: job.category))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if job.offeredPriceCents > 0 {
                    Text("Offered \(Money.string(cents: job.offeredPriceCents))")
                        .font(.subheadline.weight(.semibold))
                }
                Text(quoteCount == 0 ? "No offers yet" : "\(quoteCount) offer\(quoteCount == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PostJobView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var serviceType = "mowing"
    @State private var street = ""
    @State private var city = ""
    @State private var state = ""
    @State private var zip = ""
    @State private var date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var lawnSize = "Unknown"
    @State private var lotSize = ""
    @State private var rooms = 2
    @State private var stairs = false
    @State private var obstacles = ""
    @State private var notes = ""
    @State private var picker: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    @State private var result: PricingResult?
    @State private var offered = ""
    @State private var allowsMultiple = false

    private var service: ServiceType? { ServiceCatalog.find(serviceType) }
    private var addressReady: Bool { USAddress.isComplete(street: street, city: city, state: state, zip: zip) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Service", selection: $serviceType) {
                    ForEach(ServiceCatalog.active) { item in
                        Text(item.title).tag(item.id)
                    }
                }
                TextField("Street address", text: $street)
                TextField("City", text: $city)
                TextField("State", text: $state)
                    .textInputAutocapitalization(.characters)
                TextField("ZIP code", text: $zip)
                    .keyboardType(.numberPad)
                if !addressReady, !street.isEmpty || !city.isEmpty || !state.isEmpty || !zip.isEmpty {
                    Text(USAddress.incompleteMessage).font(.footnote).foregroundStyle(.red)
                }
                DatePicker("Preferred date", selection: $date, displayedComponents: .date)
                if service?.category == .moving {
                    Stepper("Rooms: \(rooms)", value: $rooms, in: 1...8)
                    Toggle("Stairs", isOn: $stairs)
                } else {
                    Picker("Yard size", selection: $lawnSize) {
                        Text("Unknown").tag("Unknown")
                        Text("Small").tag("Small")
                        Text("Medium").tag("Medium")
                        Text("Large").tag("Large")
                    }
                    .pickerStyle(.segmented)
                    TextField("Lot size, if you know it", text: $lotSize)
                }
                TextField("Obstacles", text: $obstacles)
                TextField("Instructions", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                HStack {
                    PhotosPicker(selection: $picker, maxSelectionCount: 4, matching: .images) {
                        Label(photos.isEmpty ? "Photo library" : "\(photos.count) photos", systemImage: "photo")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Camera") { showCamera = true }
                    }
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
                Button("Estimate price") { Task { await estimate() } }
                    .buttonStyle(.bordered)
                if let result {
                    EstimateCard(result: result, offered: $offered)
                }
                Toggle("Allow more than one contractor", isOn: $allowsMultiple)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button(model.busy ? "Saving…" : "Save draft") { Task { await save(publish: false) } }
                    .buttonStyle(.bordered)
                Button(model.busy ? "Publishing…" : "Publish offered price") { Task { await save(publish: true) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || result?.suggestedCents == nil || !addressReady)
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("New job")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCamera) {
            CameraPicker(image: $cameraImage)
        }
        .onChange(of: cameraImage) { _, image in
            if let image, let data = image.jpegData(compressionQuality: 0.7) {
                photos.append(data)
            }
        }
    }

    private func estimate() async {
        let engine = PricingEngine()
        let pricing = await engine.estimate(request)
        result = pricing
        if offered.isEmpty, let cents = pricing.suggestedCents {
            offered = String(cents / 100)
        }
    }

    private var request: PricingRequest {
        PricingRequest(
            serviceType: serviceType,
            yardSize: lawnSize,
            lotSize: lotSize,
            rooms: rooms,
            obstacles: stairs ? [obstacles, "Stairs"].filter { !$0.isEmpty }.joined(separator: ", ") : obstacles,
            details: notes,
            photoCount: photos.count,
            zip: zip
        )
    }

    private func save(publish: Bool) async {
        let dollars = Decimal(string: offered.filter { $0.isNumber || $0 == "." }) ?? 0
        let cents = NSDecimalNumber(decimal: dollars * 100).intValue
        let details = JobDetails(lawnSize: lawnSize, lotSize: lotSize, rooms: rooms, stairs: stairs, obstacles: request.obstacles, notes: notes)
        let savedEstimate = result.flatMap { $0.suggestedCents == nil ? nil : PriceEstimate($0) }
        let ok = await model.postJob(
            category: service?.category ?? .lawn,
            street: street,
            city: city,
            state: state,
            zip: zip,
            scheduledOn: DayStamp.string(from: date),
            details: details,
            photos: photos,
            offeredPriceCents: cents,
            serviceType: serviceType,
            estimate: savedEstimate,
            allowsMultiple: allowsMultiple,
            publish: publish
        )
        if ok { dismiss() }
    }
}

struct EstimateCard: View {
    var result: PricingResult
    @Binding var offered: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Estimate, not a guaranteed quote").font(.headline)
                Text(result.explanation)
                if !result.questions.isEmpty {
                    ForEach(result.questions, id: \.self) { question in
                        Text(question).foregroundStyle(.red)
                    }
                }
                ForEach(result.assumptions, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
                Text(result.disclaimer).font(.footnote).foregroundStyle(.secondary)
                if result.suggestedCents != nil {
                    TextField("Your offered price", text: $offered)
                        .keyboardType(.decimalPad)
                    Text("You can change the suggested price before publishing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct JobDetailView: View {
    @EnvironmentObject private var model: AppModel
    var jobID: UUID
    @State private var rating = 5
    @State private var review = ""
    @State private var proPhone = ""

    private var job: JobRecord? { model.jobs.first { $0.id == jobID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job {
                    Text(job.serviceTitle).font(.subheadline.weight(.semibold)).foregroundStyle(job.category == .moving ? clay : pine)
                    Text(job.place(exact: true)).font(.title2.weight(.semibold))
                    Text(job.status.title).font(.subheadline)
                    if job.offeredPriceCents > 0 {
                        Text("Offered \(Money.string(cents: job.offeredPriceCents))").font(.headline)
                    }
                    Text("\(DayStamp.display(job.scheduledOn)) · \(job.details.summary(for: job.category))")
                        .foregroundStyle(.secondary)
                    if let estimate = job.estimate {
                        Text(estimate.explanation)
                        Text(estimate.disclaimer).font(.footnote).foregroundStyle(.secondary)
                        Text("About \(estimate.estimatedMinutes) minutes · \(estimate.difficulty)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !job.details.notes.isEmpty {
                        Text(job.details.notes)
                    }
                    JobPhotos(names: job.photoNames)
                    Text("Offers").font(.headline)
                    let rows = model.quotes(for: job.id)
                    if rows.isEmpty && job.status.isListed {
                        Text("Waiting for a contractor to accept \(Money.string(cents: job.offeredPriceCents)) or send an offer.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { quote in
                        QuoteCard(quote: quote, job: job)
                    }
                    if job.status == .booked || job.status == .completed {
                        reviewBox
                    }
                    if model.contactUnlocked(jobID: job.id), !proPhone.isEmpty {
                        Text(proPhone).font(.headline)
                    }
                    ForEach(model.bookings.filter { $0.jobID == job.id }) { booking in
                        Text(paymentLine(priceCents: booking.priceCents, percent: booking.feePercent))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Payment status: \(booking.charge.status). You are not charged while the status is authorized.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if job.category == .lawn {
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
        .task(id: jobID) {
            proPhone = ""
            guard model.contactUnlocked(jobID: jobID),
                  let booking = model.booking(for: jobID),
                  let person = await model.person(booking.proID),
                  !person.phone.isEmpty else { return }
            proPhone = USPhone.display(person.phone)
        }
    }

    private func bookAgain(_ booking: BookingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Book again at \(FeeSchedule.launch.percent)%").font(.headline)
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
                Text("Review the contractor").font(.headline)
                Text("This records a review for a booked job. It does not approve the work or start a payout.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    if job.status.isListed && quote.status == .sent {
                        Button("Accept offer") {
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

struct JobPhotos: View {
    var names: [String]

    var body: some View {
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

struct NoticeList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ForEach(model.notices.prefix(3)) { notice in
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title).font(.headline)
                    Text(notice.body).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}
