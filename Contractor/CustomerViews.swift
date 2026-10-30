import CoreLocation
import MapKit
import PhotosUI
import SwiftUI
import UIKit

struct CustomerHome: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            BrandHeader {
                HStack(spacing: 16) {
                    Button("Sign out") { Task { await model.signOut() } }
                        .buttonStyle(.plain)
                    NavigationLink("Post") { PostJobView() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your jobs")
                        .font(.title2.weight(.semibold))
                    if !model.notices.isEmpty {
                        NoticeList()
                    }
                    if model.busy && model.jobs.isEmpty {
                        SkeletonList()
                    } else if model.jobs.isEmpty {
                        if let error = model.errorMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(error).foregroundStyle(.red)
                                Button("Try again") { Task { await model.reload() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("No jobs yet.").font(.headline)
                                NavigationLink("Post a job") { PostJobView() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    ForEach(model.jobs) { job in
                        NavigationLink {
                            JobDetailView(jobID: job.id)
                        } label: {
                            JobCard(job: job, quoteCount: model.quotes(for: job.id).count, unread: model.unreadCount(jobID: job.id))
                        }
                        .buttonStyle(.plain)
                    }
                    HelpLinks()
                    if let error = model.errorMessage, !model.jobs.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .refreshable { await model.reload() }
            }
            .background(paper)
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.reload() }
        }
    }
}

struct JobCard: View {
    var job: JobRecord
    var quoteCount: Int
    var exact = true
    var unread = 0

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(job.serviceTitle, systemImage: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(job.category == .moving ? clay : pine)
                    Spacer()
                    StatusBadge(title: job.status.title)
                }
                if SampleJobs.contains(job.id) {
                    Text("Sample").font(.caption.weight(.semibold)).foregroundStyle(clay)
                }
                Text(job.place(exact: exact)).font(.headline).foregroundStyle(ink)
                Text("\(DayStamp.display(job.scheduledOn)) · \(job.details.summary(for: job.category))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    if job.offeredPriceCents > 0 {
                        PriceChip(cents: job.offeredPriceCents)
                    }
                    Text(quoteCount == 0 ? "No offers yet" : "\(quoteCount) offer\(quoteCount == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    UnreadBadge(count: unread)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PostJobView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = AddressCompleter()
    @State private var step = 0
    @State private var finished = false
    @State private var savedAsDraft = false
    @State private var serviceType = "mowing"
    @State private var street = ""
    @State private var city = ""
    @State private var state = ""
    @State private var zip = ""
    @State private var query = ""
    @State private var when = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
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
    private var offeredCents: Int { PriceInput.cents(from: offered) }
    private var canAdvance: Bool {
        switch step {
        case 2: return addressReady
        case 3: return offeredCents > 0
        default: return true
        }
    }

    var body: some View {
        Group {
            if finished {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(pine)
                        .accessibilityHidden(true)
                    Text(savedAsDraft ? "Draft saved" : "Job posted")
                        .font(.title2.weight(.bold))
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                wizard
            }
        }
        .background(paper)
        .navigationTitle("New job")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: step)
        .animation(.smooth, value: finished)
    }

    private var wizard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(stepTitle).font(.headline)
                    ProgressView(value: Double(step + 1), total: 5)
                        .tint(pine)
                        .accessibilityLabel("Step \(step + 1) of 5")
                }
                stepBody
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    if step > 0 {
                        Button("Back") {
                            Haptic.tap()
                            step -= 1
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    if step < 4 {
                        Button("Next") { advance() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAdvance)
                    }
                }
                if step == 4 {
                    Button(model.busy ? "Posting…" : "Post job") { Task { await save(publish: true) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || offeredCents <= 0 || !addressReady)
                    Button(model.busy ? "Saving…" : "Save draft") { Task { await save(publish: false) } }
                        .buttonStyle(.bordered)
                        .disabled(model.busy || !addressReady)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showCamera) { CameraPicker(image: $cameraImage) }
        .onChange(of: cameraImage) { _, image in
            guard let image, let data = image.jpegData(compressionQuality: 0.9) else { return }
            Task {
                if let jpeg = await PhotoStore.compressedJPEG(data) {
                    photos.append(jpeg)
                }
            }
        }
        .onChange(of: query) { _, value in
            completer.update(value)
        }
        .onAppear(perform: loadDraft)
        .onDisappear {
            if !finished { rememberDraft() }
        }
        .sheet(isPresented: $model.postSignIn) {
            PostSignInSheet {
                Task { await save(publish: true) }
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case 0: return "Service"
        case 1: return "Details"
        case 2: return "Where and when"
        case 3: return "Price"
        default: return "Review"
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0: serviceStep
        case 1: detailsStep
        case 2: placeStep
        case 3: priceStep
        default: reviewStep
        }
    }

    private var serviceStep: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
            ForEach(ServiceCatalog.active) { item in
                Button {
                    serviceType = item.id
                    Haptic.tap()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: item.symbol).font(.title2)
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .padding(8)
                    .background(
                        serviceType == item.id ? pine.opacity(0.16) : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(serviceType == item.id ? pine : .clear, lineWidth: 2)
                    )
                    .foregroundStyle(item.category == .moving ? clay : pine)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(serviceType == item.id ? .isSelected : [])
            }
        }
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let jpeg = await PhotoStore.compressedJPEG(data) {
                            loaded.append(jpeg)
                        }
                    }
                    photos = loaded
                }
            }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(photos.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    private var placeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search address", text: $query)
                .textContentType(.fullStreetAddress)
            ForEach(Array(completer.results.enumerated()), id: \.offset) { _, row in
                Button {
                    Task { await choose(row) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundStyle(ink)
                        Text(row.subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
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
            DatePicker("Date and time", selection: $when, displayedComponents: [.date, .hourAndMinute])
        }
    }

    private var priceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if result == nil && model.busy {
                ProgressView()
                    .accessibilityLabel("Estimating")
            }
            if let result {
                if let cents = result.suggestedCents {
                    Text("Suggested \(Money.string(cents: cents))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if !result.explanation.isEmpty {
                    Text(result.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(result.questions, id: \.self) { question in
                    Text(question)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            PriceEditor(offered: $offered)
            NavigationLink("See nearby prices") {
                NearbyPricesPage(readOnly: true, showsBrandHeader: false)
            }
            .buttonStyle(.bordered)
        }
    }

    private var reviewStep: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(service?.title ?? "Service", systemImage: service?.symbol ?? "leaf.fill")
                    .font(.headline)
                    .foregroundStyle(service?.category == .moving ? clay : pine)
                Text("\(street), \(city), \(state) \(zip)")
                Text(when.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                PriceEditor(offered: $offered)
                Toggle("Allow more than one contractor", isOn: $allowsMultiple)
            }
        }
    }

    private func advance() {
        Haptic.tap()
        step = min(step + 1, 4)
        if step == 3 {
            Task { await estimate() }
        }
    }

    private func choose(_ row: MKLocalSearchCompletion) async {
        guard let place = await completer.apply(row) else { return }
        if !place.street.isEmpty { street = place.street }
        if !place.city.isEmpty { city = place.city }
        if !place.state.isEmpty { state = place.state }
        if USAddress.isValidZip(place.zip) { zip = place.zip }
        query = ""
        Haptic.tap()
    }

    private func estimate() async {
        let engine = PricingEngine()
        let pricing = await engine.estimate(request)
        result = pricing
        if offered.isEmpty, let cents = pricing.suggestedCents, cents > 0 {
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

    private var notesWithTime: String {
        let time = when.formatted(date: .omitted, time: .shortened)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("Time:") { return trimmed }
        if trimmed.isEmpty { return "Time: \(time)" }
        return trimmed + "\nTime: \(time)"
    }

    private func save(publish: Bool) async {
        rememberDraft()
        let details = JobDetails(lawnSize: lawnSize, lotSize: lotSize, rooms: rooms, stairs: stairs, obstacles: request.obstacles, notes: notesWithTime)
        let savedEstimate = result.flatMap { $0.suggestedCents == nil ? nil : PriceEstimate($0) }
        let ok = await model.postJob(
            category: service?.category ?? .lawn,
            street: street,
            city: city,
            state: state,
            zip: zip,
            scheduledOn: DayStamp.string(from: when),
            details: details,
            photos: photos,
            offeredPriceCents: offeredCents,
            serviceType: serviceType,
            estimate: savedEstimate,
            allowsMultiple: allowsMultiple,
            publish: publish
        )
        if ok {
            if publish { PostDraft.clear() }
            savedAsDraft = !publish
            finished = true
        }
    }

    private func rememberDraft() {
        PostDraft(
            serviceType: serviceType,
            street: street,
            city: city,
            state: state,
            zip: zip,
            notes: notes,
            obstacles: obstacles,
            lawnSize: lawnSize,
            lotSize: lotSize,
            offered: offered,
            rooms: rooms,
            stairs: stairs,
            allowsMultiple: allowsMultiple,
            when: when,
            step: step
        ).save()
    }

    private func loadDraft() {
        guard street.isEmpty, notes.isEmpty, offered.isEmpty, let draft = PostDraft.load() else { return }
        serviceType = draft.serviceType
        street = draft.street
        city = draft.city
        state = draft.state
        zip = draft.zip
        notes = draft.notes
        obstacles = draft.obstacles
        lawnSize = draft.lawnSize
        lotSize = draft.lotSize
        offered = draft.offered
        rooms = draft.rooms
        stairs = draft.stairs
        allowsMultiple = draft.allowsMultiple
        when = draft.when
        step = min(max(draft.step, 0), 4)
    }
}

private struct PostDraft: Codable {
    var serviceType: String
    var street: String
    var city: String
    var state: String
    var zip: String
    var notes: String
    var obstacles: String
    var lawnSize: String
    var lotSize: String
    var offered: String
    var rooms: Int
    var stairs: Bool
    var allowsMultiple: Bool
    var when: Date
    var step: Int

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    static func load() -> PostDraft? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PostDraft.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static let key = "contractor.postDraft"
}

struct PriceEditor: View {
    @Binding var offered: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your price").font(.headline)
            HStack(spacing: 12) {
                Button {
                    PriceInput.step(&offered, by: -500)
                    Haptic.tap()
                } label: {
                    Image(systemName: "minus.circle.fill").font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decrease price")
                TextField("Price", text: $offered)
                    .keyboardType(.numberPad)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Your price")
                Button {
                    PriceInput.step(&offered, by: 500)
                    Haptic.tap()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Increase price")
            }
            Slider(
                value: Binding(
                    get: { min(2_000, Double(PriceInput.cents(from: offered)) / 100) },
                    set: { offered = String(Int($0.rounded())) }
                ),
                in: 0...2_000,
                step: 5
            )
            .accessibilityLabel("Price")
            if !offered.isEmpty && PriceInput.cents(from: offered) <= 0 {
                Text("Enter a price greater than zero.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

enum PriceInput {
    static func cents(from text: String) -> Int {
        let digits = text.filter { $0.isNumber || $0 == "." }
        let dollars = Decimal(string: digits) ?? 0
        return max(0, NSDecimalNumber(decimal: dollars * 100).intValue)
    }

    static func step(_ text: inout String, by delta: Int) {
        let next = max(0, cents(from: text) + delta)
        text = next == 0 ? "" : String(next / 100)
    }
}

private struct PostSignInSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onSignedIn: () -> Void
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sign in to post this job.")
                    .font(.headline)
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if model.pendingConfirmation != nil {
                    Text("Check your email")
                        .font(.headline)
                    ConfirmSignInButton()
                }
                if let error = model.errorMessage, error != "Check your email" {
                    Text(error).foregroundStyle(.red)
                }
                Button(model.busy ? "Signing in…" : "Sign in") {
                    Task {
                        if await model.signIn(email: email, password: password) {
                            onSignedIn()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || email.isEmpty || password.isEmpty)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        model.postSignIn = false
                        dismiss()
                    }
                }
            }
            .onAppear {
                if email.isEmpty {
                    email = UserDefaults.standard.string(forKey: "contractor.lastEmail") ?? ""
                }
            }
        }
        .presentationDetents([.medium])
    }
}

@MainActor
final class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func update(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let rows = Array(completer.results.prefix(5))
        Task { @MainActor in
            self.results = rows
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.results = []
        }
    }

    func apply(_ completion: MKLocalSearchCompletion) async -> (street: String, city: String, state: String, zip: String)? {
        let query = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        let marks = try? await CLGeocoder().geocodeAddressString(query)
        guard let placemark = marks?.first else { return nil }
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (
            street,
            placemark.locality ?? placemark.subAdministrativeArea ?? "",
            (placemark.administrativeArea ?? "").uppercased(),
            USAddress.normalizeZip(placemark.postalCode ?? "")
        )
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
                    Label(job.serviceTitle, systemImage: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(job.category == .moving ? clay : pine)
                    Text(job.place(exact: true)).font(.title2.weight(.semibold))
                    StatusBadge(title: job.status.title)
                    if job.offeredPriceCents > 0 {
                        PriceChip(cents: job.offeredPriceCents)
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
                } else if model.busy {
                    SkeletonList()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This job is unavailable.").font(.headline)
                        Button("Try again") { Task { await model.reload() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let error = model.errorMessage, job != nil {
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
                            Haptic.tap()
                            Task { _ = await model.book(quoteID: quote.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                        Button("Decline") {
                            Haptic.tap()
                            Task { _ = await model.declineQuote(quoteID: quote.id) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                    }
                    NavigationLink {
                        ChatView(jobID: job.id, proID: quote.proID, title: name)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Message")
                            UnreadBadge(count: model.unreadCount(jobID: job.id))
                        }
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
