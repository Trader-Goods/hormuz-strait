import CoreLocation
import MapKit
import PhotosUI
import SwiftUI
import UIKit

struct CustomerHome: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.selectTab) private var selectTab
    @State private var showAccepted = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            BrandHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your jobs")
                        .appText(28, weight: .bold, relativeTo: .title)
                    if !model.notices.isEmpty {
                        NoticeList()
                    }
                    if let waiting = model.jobs.first(where: { $0.status == .awaitingPayment }) {
                        NavigationLink {
                            ConfirmPayView(jobID: waiting.id)
                        } label: {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("A pro accepted your job. Confirm & pay to book them.")
                                        .appText(20, weight: .semibold, relativeTo: .headline)
                                        .foregroundStyle(ink)
                                    Text("Confirm & pay")
                                        .appText(weight: .semibold)
                                        .foregroundStyle(pine)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if model.busy && model.jobs.isEmpty {
                        SkeletonList()
                    } else if model.jobs.isEmpty {
                        if let error = model.errorMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(error).foregroundStyle(.red)
                                Button("Try again") { Task { await model.reload() } }
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                        } else {
                            FriendlyEmpty(symbol: "leaf.fill", title: "No jobs yet.", button: model.session?.role == .customer ? "Post a job" : nil) {
                                selectTab(0)
                            }
                        }
                    }
                    ForEach(model.jobs) { job in
                        NavigationLink {
                            JobDetailView(jobID: job.id)
                        } label: {
                            JobCard(job: job, quoteCount: model.quotes(for: job.id).count, unread: model.unreadCount(jobID: job.id))
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                    Card {
                        HelpLinks()
                    }
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
            .onChange(of: model.jobs.map { "\($0.id.uuidString):\($0.status.rawValue)" }.joined()) { _, _ in
                noteAcceptedJobs()
            }
            .onAppear { noteAcceptedJobs() }
            .alert("A pro accepted your job", isPresented: $showAccepted) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("A pro accepted your job. Confirm & pay to book them.")
            }
            .task { await model.reload() }
        }
    }

    private func noteAcceptedJobs() {
        var fresh = false
        for job in model.jobs where job.status == .awaitingPayment {
            let key = "contractor.pushedAccept.\(job.id.uuidString)"
            guard !UserDefaults.standard.bool(forKey: key) else { continue }
            UserDefaults.standard.set(true, forKey: key)
            PushNotifications.proAccepted(jobID: job.id)
            fresh = true
        }
        if fresh { showAccepted = true }
    }
}

struct JobCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var job: JobRecord
    var quoteCount: Int
    var exact = true
    var unread = 0

    private var milesText: String? {
        guard let origin = model.session?.coordinate,
              let point = job.mapCoordinate(exact: false) else { return nil }
        let miles = origin.miles(to: point)
        if miles < 0.2 { return nil }
        return DistanceLabel.text(miles: miles)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .appText(20, weight: .bold, relativeTo: .headline)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(serviceTint(job), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.serviceTitle)
                            .appText(22, weight: .bold, relativeTo: .title2)
                            .foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(job.place(exact: exact))
                            .appText()
                            .foregroundStyle(inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if job.offeredPriceCents > 0, !dynamicTypeSize.isAccessibilitySize {
                        PriceChip(cents: job.offeredPriceCents)
                    }
                }
                if job.offeredPriceCents > 0, dynamicTypeSize.isAccessibilitySize {
                    PriceChip(cents: job.offeredPriceCents)
                }
                InfoChip(text: job.whenLabel, symbol: "clock.fill")
                if let milesText {
                    InfoChip(text: milesText, symbol: "location.fill")
                }
                if SampleJobs.contains(job.id) {
                    Text("Sample").appText(weight: .semibold).foregroundStyle(amberText)
                }
                UnreadBadge(count: unread)
                StatusBadge(status: job.status)
                if quoteCount > 0 {
                    Text("\(quoteCount) offer\(quoteCount == 1 ? "" : "s")")
                        .appText()
                        .foregroundStyle(inkSoft)
                }
                if let name = job.photoNames.first, let image = PhotoStore.image(name) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("Job photo")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PostJobView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.selectTab) private var selectTab
    @StateObject private var completer = AddressCompleter()
    @State private var step = 0
    @State private var finished = false
    @State private var savedAsDraft = false
    @State private var popped = false
    @State private var serviceType = "mowing"
    @State private var street = ""
    @State private var city = ""
    @State private var state = ""
    @State private var zip = ""
    @State private var query = ""
    @State private var timing = JobTiming.flexible
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
        case 3: return offeredCents > 0
        case 4: return addressReady
        default: return true
        }
    }

    var body: some View {
        Group {
            if model.session?.role != .customer {
                Color.clear
            } else if finished {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(pine)
                        .scaleEffect(popped ? 1 : 0.4)
                        .accessibilityHidden(true)
                    Text(savedAsDraft ? "Draft saved" : "Your job is posted")
                        .appText(34, weight: .bold, relativeTo: .largeTitle)
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.center)
                    Text(savedAsDraft ? "You can finish it later." : "Pros near you can accept your price.")
                        .appText()
                        .foregroundStyle(inkSoft)
                        .multilineTextAlignment(.center)
                    Button(savedAsDraft ? "Done" : "See my jobs") {
                        Haptic.success()
                        selectTab(1)
                        dismiss()
                    }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    withAnimation(.spring(duration: 0.45)) { popped = true }
                }
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
                    Text(stepTitle).appText(22, weight: .bold, relativeTo: .title2)
                    HStack(spacing: 6) {
                        ForEach(0..<6, id: \.self) { index in
                            Capsule()
                                .fill(index <= step ? pine : Color.primary.opacity(0.12))
                                .frame(height: 6)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(step + 1) of 6")
                }
                stepBody
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                HStack(spacing: 12) {
                    if step > 0 {
                        Button("Back") {
                            Haptic.tap()
                            step -= 1
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if step < 5 {
                        Button("Next") { advance() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!canAdvance)
                    }
                }
                if step == 5 {
                    Button(model.busy ? "Posting…" : "Post job") { Task { await save(publish: true) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.busy || offeredCents <= 0 || !addressReady)
                    Button(model.busy ? "Saving…" : "Save draft") { Task { await save(publish: false) } }
                        .buttonStyle(SecondaryButtonStyle())
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
        .onAppear {
            if ProcessInfo.processInfo.environment["SCREENSHOT"] == "post" {
                prepareScreenshot()
            } else {
                loadDraft()
            }
        }
        .toolbar(.visible, for: .navigationBar)
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
        case 0: return "What do you need?"
        case 1: return "Photos"
        case 2: return "When?"
        case 3: return "Price"
        case 4: return "Address"
        default: return "Review"
        }
    }

    private func prepareScreenshot() {
        serviceType = "mowing"
        street = "418 River Road"
        city = "Maumee"
        state = "OH"
        zip = "43537"
        lawnSize = "Medium"
        notes = "Please mow the front and back."
        timing = .asap
        offered = "65"
        step = 3
        Task { await estimate() }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0: serviceStep
        case 1: photosStep
        case 2: whenStep
        case 3: priceStep
        case 4: addressStep
        default: reviewStep
        }
    }

    private var serviceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            serviceGrid(ServiceCatalog.featured)
            DisclosureGroup("Other one-day jobs") {
                serviceGrid(ServiceCatalog.more)
            }
            .appText()
            if service?.category == .moving {
                Stepper("Rooms: \(rooms)", value: $rooms, in: 1...8)
                Toggle("Stairs", isOn: $stairs)
            } else {
                Text("How big is the yard?")
                    .appText(22, weight: .bold, relativeTo: .title2)
                Picker("Yard size", selection: $lawnSize) {
                    Text("Unknown").tag("Unknown")
                    Text("Small").tag("Small")
                    Text("Medium").tag("Medium")
                    Text("Large").tag("Large")
                }
                .pickerStyle(.segmented)
                TextField("Lot size, if you know it", text: $lotSize)
                    .softField()
            }
            TextField("Obstacles", text: $obstacles)
                .softField()
        }
    }

    private var photosStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a photo if you have one. You can skip this.")
                .appText()
                .foregroundStyle(inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Anything the pro should know", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .softField()
            PhotosPicker(selection: $picker, maxSelectionCount: 4, matching: .images) {
                Label(photos.isEmpty ? "Choose photos" : "\(photos.count) photos", systemImage: "photo")
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(SecondaryButtonStyle())
            .onChange(of: picker) { _, items in
                Task {
                    var loaded: [Data] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            if let jpeg = await PhotoStore.compressedJPEG(data) {
                                loaded.append(jpeg)
                            } else {
                                loaded.append(data)
                            }
                        }
                    }
                    photos = loaded
                }
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take a photo") { showCamera = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(photos.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 88, height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityLabel("Photo")
                            }
                        }
                    }
                }
            }
        }
    }

    private var whenStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When do you need it?")
                .appText(22, weight: .bold, relativeTo: .title2)
            timingChoices
        }
    }

    private var timingChoices: some View {
        ForEach(JobTiming.allCases) { choice in
            Button {
                timing = choice
                Haptic.tap()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: choice.symbol)
                        .foregroundStyle(timing == choice ? .white : pineText)
                        .frame(width: 44, height: 44)
                        .background(timing == choice ? buttonGreen : pine.opacity(0.16), in: Circle())
                        .accessibilityHidden(true)
                    Text(choice.title)
                        .appText(20, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(ink)
                    Spacer()
                    if timing == choice {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(pineText)
                            .accessibilityHidden(true)
                    }
                }
                .padding(12)
                .frame(minHeight: 56)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(timing == choice ? pineText : Color.primary.opacity(0.08), lineWidth: timing == choice ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(timing == choice ? .isSelected : [])
        }
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search address", text: $query)
                .textContentType(.fullStreetAddress)
                .softField()
            ForEach(Array(completer.results.enumerated()), id: \.offset) { _, row in
                Button {
                    Task { await choose(row) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundStyle(ink).appText(weight: .semibold)
                        Text(row.subtitle).appText().foregroundStyle(inkSoft)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            TextField("Street address", text: $street)
                .softField()
            TextField("City", text: $city)
                .softField()
            TextField("State", text: $state)
                .textInputAutocapitalization(.characters)
                .softField()
            TextField("ZIP code", text: $zip)
                .keyboardType(.numberPad)
                .softField()
            if !addressReady, !street.isEmpty || !city.isEmpty || !state.isEmpty || !zip.isEmpty {
                Text(USAddress.incompleteMessage).appText().foregroundStyle(.red)
            }
        }
    }

    private func serviceGrid(_ items: [ServiceType]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
            ForEach(items) { item in
                Button {
                    serviceType = item.id
                    Haptic.tap()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .appText(22, weight: .semibold, relativeTo: .title2)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(item.category == .moving ? clay : pine, in: Circle())
                        Text(item.title)
                            .appText(weight: .semibold)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(ink)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .padding(8)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(serviceType == item.id ? pine : Color.primary.opacity(0.06), lineWidth: serviceType == item.id ? 2 : 1)
                    )
                    .shadow(color: .black.opacity(serviceType == item.id ? 0.08 : 0.04), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(serviceType == item.id ? .isSelected : [])
            }
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested")
                            .appText(weight: .semibold)
                            .foregroundStyle(.secondary)
                        Text(Money.string(cents: cents))
                            .appText(34, weight: .bold, relativeTo: .largeTitle)
                            .foregroundStyle(pine)
                    }
                }
                if !result.explanation.isEmpty {
                    Text(result.explanation)
                        .appText()
                        .foregroundStyle(.secondary)
                }
                ForEach(result.questions, id: \.self) { question in
                    Text(question)
                        .appText()
                        .foregroundStyle(.secondary)
                }
            }
            PriceEditor(offered: $offered)
            NavigationLink("See nearby prices") {
                NearbyPricesPage(readOnly: true, showsBrandHeader: false)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var reviewStep: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(service?.title ?? "Service", systemImage: service?.symbol ?? "leaf.fill")
                    .appText(20, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(service?.category == .moving ? clay : pine)
                Text("\(street), \(city), \(state) \(zip)")
                Text(timing.title)
                    .foregroundStyle(.secondary)
                PriceEditor(offered: $offered)
                Toggle("Let more than one pro take this job", isOn: $allowsMultiple)
            }
        }
    }

    private func advance() {
        Haptic.tap()
        step = min(step + 1, 5)
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

    private func save(publish: Bool) async {
        rememberDraft()
        let details = JobDetails(lawnSize: lawnSize, lotSize: lotSize, rooms: rooms, stairs: stairs, obstacles: request.obstacles, notes: notes)
        let savedEstimate = result.flatMap { $0.suggestedCents == nil ? nil : PriceEstimate($0) }
        let ok = await model.postJob(
            category: service?.category ?? .lawn,
            street: street,
            city: city,
            state: state,
            zip: zip,
            scheduledOn: DayStamp.string(from: Date()),
            details: details,
            photos: photos,
            offeredPriceCents: offeredCents,
            serviceType: serviceType,
            estimate: savedEstimate,
            allowsMultiple: allowsMultiple,
            publish: publish,
            timing: timing.rawValue
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
            timing: timing.rawValue,
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
        timing = JobTiming(rawValue: draft.timing) ?? .flexible
        step = min(max(draft.step, 0), 5)
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
    var timing: String
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

    private static let key = "contractor.postDraft.v2"
}

struct PriceEditor: View {
    @Binding var offered: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your price").appText(22, weight: .bold, relativeTo: .title2)
            HStack(spacing: 12) {
                Button {
                    PriceInput.step(&offered, by: -500)
                    Haptic.tap()
                }                 label: {
                    VStack(spacing: 4) {
                        Image(systemName: "minus")
                            .accessibilityHidden(true)
                        Text("Lower")
                    }
                    .appText(18, weight: .bold)
                    .foregroundStyle(pineText)
                    .frame(minWidth: 72, minHeight: 56)
                    .background(pine.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lower the price")
                HStack(spacing: 2) {
                    Text("$")
                        .appText(34, weight: .bold, relativeTo: .largeTitle)
                        .foregroundStyle(amber)
                    TextField("Price", text: $offered)
                        .keyboardType(.numberPad)
                        .appText(34, weight: .bold, relativeTo: .largeTitle)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .foregroundStyle(ink)
                        .accessibilityLabel("Your price")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Button {
                    PriceInput.step(&offered, by: 500)
                    Haptic.tap()
                }                 label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .accessibilityHidden(true)
                        Text("Higher")
                    }
                    .appText(18, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(minWidth: 72, minHeight: 56)
                    .background(buttonGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Raise the price")
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
                    .appText()
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
                    .appText(20, weight: .semibold, relativeTo: .headline)
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if model.pendingConfirmation != nil {
                    Text("Check your email")
                        .appText(20, weight: .semibold, relativeTo: .headline)
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
                .buttonStyle(PrimaryButtonStyle())
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
                Text("Estimate, not a guaranteed quote").appText(20, weight: .semibold, relativeTo: .headline)
                Text(result.explanation)
                if !result.questions.isEmpty {
                    ForEach(result.questions, id: \.self) { question in
                        Text(question).foregroundStyle(.red)
                    }
                }
                ForEach(result.assumptions, id: \.self) { line in
                    Text(line).appText().foregroundStyle(.secondary)
                }
                Text(result.disclaimer).appText().foregroundStyle(.secondary)
                if result.suggestedCents != nil {
                    TextField("Your offered price", text: $offered)
                        .keyboardType(.decimalPad)
                    Text("You can change the suggested price before publishing.")
                        .appText()
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
    @State private var reporting = false
    @State private var problem = ""
    @State private var confirmApprove = false
    @State private var approvedSuccess = false

    private var job: JobRecord? { model.jobs.first { $0.id == jobID } }

    var body: some View {
        Group {
            if approvedSuccess {
                SuccessCover(
                    symbol: "checkmark.seal.fill",
                    title: "You approved this job",
                    line: "No card was charged in this test version.",
                    button: "Back to my jobs"
                ) {
                    approvedSuccess = false
                }
            } else {
                detailBody
            }
        }
    }

    private var detailBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job, let role = model.session?.role {
                    NextStepBar(text: nextStepText(job, role: role))
                }
                if let job {
                    Card {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                                .appText(22, weight: .bold, relativeTo: .title2)
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(serviceTint(job), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.serviceTitle)
                                    .appText(28, weight: .bold, relativeTo: .title)
                                    .foregroundStyle(ink)
                                Text(job.place(exact: true))
                                    .appText()
                                    .foregroundStyle(.secondary)
                                StatusBadge(status: job.status)
                            }
                            Spacer(minLength: 4)
                            if job.offeredPriceCents > 0 {
                                PriceChip(cents: job.offeredPriceCents)
                            }
                        }
                    }
                    if job.status == .awaitingPayment {
                        NavigationLink {
                            ConfirmPayView(jobID: job.id)
                        } label: {
                            Text("Confirm & pay")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    if job.showsWorkProgress {
                        Card {
                            JobProgress(status: job.status)
                        }
                    }
                    Text("\(job.whenLabel) · \(job.details.summary(for: job.category))")
                        .appText()
                        .foregroundStyle(.secondary)
                    if job.status == .awaitingReview {
                        Button("Approve this job") { confirmApprove = true }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.busy)
                        Button("Report a problem") { reporting = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    if let note = job.completionNote, !note.isEmpty, job.status == .awaitingReview || job.status == .disputed || job.status == .completed {
                        Text(note)
                    }
                    if job.showsWorkProgress {
                        NavigationLink("How finishing a job works") { HowFinishingWorksView() }
                            .appText()
                            .foregroundStyle(.secondary)
                    }
                    if let estimate = job.estimate {
                        Text(estimate.explanation)
                        Text(estimate.disclaimer).appText().foregroundStyle(.secondary)
                        Text("About \(estimate.estimatedMinutes) minutes · \(estimate.difficulty)")
                            .appText()
                            .foregroundStyle(.secondary)
                    }
                    if !job.details.notes.isEmpty {
                        Text(job.details.notes)
                    }
                    JobPhotos(names: job.photoNames)
                    Text("Offers").appText(20, weight: .semibold, relativeTo: .headline)
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
                        Text(proPhone).appText(20, weight: .semibold, relativeTo: .headline)
                    }
                    ForEach(model.bookings.filter { $0.jobID == job.id }) { booking in
                        Text(paymentLine(priceCents: booking.priceCents, percent: booking.feePercent))
                            .appText()
                            .foregroundStyle(.secondary)
                        Text("Payment status: \(booking.charge.status). You are not charged while the status is authorized.")
                            .appText()
                            .foregroundStyle(.secondary)
                        if job.category == .lawn {
                            bookAgain(booking)
                        }
                    }
                } else if model.busy {
                    SkeletonList()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This job is unavailable.").appText(20, weight: .semibold, relativeTo: .headline)
                        Button("Try again") { Task { await model.reload() } }
                            .buttonStyle(PrimaryButtonStyle())
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
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            guard let job, job.status == .awaitingPayment else { return }
            let key = "contractor.pushedAccept.\(job.id.uuidString)"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            PushNotifications.proAccepted(jobID: job.id)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $confirmApprove) {
            ConfirmChoice(
                title: "Approve this job for \(Money.string(cents: job?.offeredPriceCents ?? 0))?",
                yes: "Yes, approve it"
            ) {
                confirmApprove = false
                Task {
                    let ok = await model.approveJob(jobID: jobID)
                    if ok {
                        Haptic.success()
                        approvedSuccess = true
                    }
                }
            } onNo: {
                confirmApprove = false
            }
        }
        .sheet(isPresented: $reporting) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("What went wrong?", text: $problem, axis: .vertical)
                        .lineLimit(3...6)
                    Button("Send") {
                        Task {
                            let ok = await model.reportJobProblem(jobID: jobID, reason: problem)
                            if ok { reporting = false }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy || problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Report a problem")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { reporting = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
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
            Text("Book again at \(FeeSchedule.launch.percent)%").appText(20, weight: .semibold, relativeTo: .headline)
            Button("Book the same pro again") {
                Task { _ = await model.bookAgain(bookingID: booking.id, scheduledOn: DayStamp.string(from: Date().addingTimeInterval(7 * 24 * 3600)), recurrence: "") }
            }
            .buttonStyle(PrimaryButtonStyle())
            if job?.category == .lawn {
                Button("Weekly lawn service") {
                    Task { _ = await model.bookAgain(bookingID: booking.id, scheduledOn: DayStamp.string(from: Date().addingTimeInterval(7 * 24 * 3600)), recurrence: "weekly") }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Every 2 weeks") {
                    Task { _ = await model.bookAgain(bookingID: booking.id, scheduledOn: DayStamp.string(from: Date().addingTimeInterval(14 * 24 * 3600)), recurrence: "biweekly") }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var reviewBox: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Review the contractor").appText(20, weight: .semibold, relativeTo: .headline)
                Text("This is a review only. It does not approve the work or send money.")
                    .appText()
                    .foregroundStyle(.secondary)
                Stepper("Stars: \(rating)", value: $rating, in: 1...5)
                TextField("How did it go?", text: $review, axis: .vertical)
                Button("Submit review") {
                    Task {
                        _ = await model.review(jobID: jobID, rating: rating, body: review)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

}

struct ConfirmPayView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var jobID: UUID
    @State private var booked = false

    private var job: JobRecord? { model.jobs.first { $0.id == jobID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(pine)
                    .frame(width: 72, height: 72)
                    .background(pine.opacity(0.12), in: Circle())
                Text("Payments coming soon")
                    .appText(28, weight: .bold, relativeTo: .title)
                if let job, job.offeredPriceCents > 0 || (model.booking(for: jobID)?.priceCents ?? 0) > 0 {
                    let cents = model.booking(for: jobID)?.priceCents ?? job.offeredPriceCents
                    Text(Money.string(cents: cents))
                        .appText(34, weight: .bold, relativeTo: .largeTitle)
                        .foregroundStyle(amber)
                    Text("Fee \(FeeSchedule.launch.percent)% (\(Money.string(cents: BookingFee.feeCents(priceCents: cents)))). No card is charged in this build.")
                        .appText()
                        .foregroundStyle(.secondary)
                }
                if booked {
                    Text("Booked")
                        .appText(20, weight: .semibold, relativeTo: .headline)
                } else {
                    Button(model.busy ? "Confirming…" : "Confirm & pay") {
                        Task {
                            let ok = await model.confirmAndPay(jobID: jobID)
                            if ok { booked = true }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("Confirm & pay")
        .navigationBarTitleDisplayMode(.inline)
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
                    Text(name).appText(20, weight: .semibold, relativeTo: .headline)
                    Spacer()
                    Text(Money.string(cents: quote.priceCents)).appText(20, weight: .semibold, relativeTo: .headline)
                }
                if model.hasGuarantee(quote.proID) {
                    Text(Guarantee.title)
                        .appText(weight: .semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(pine.opacity(0.12), in: Capsule())
                }
                if !quote.message.isEmpty {
                    let unlocked = model.contactUnlocked(jobID: job.id)
                    Text(ContactFilter.display(quote.message, unlocked: unlocked).text).foregroundStyle(.secondary)
                }
                Text(paymentLine(priceCents: quote.priceCents, percent: FeeSchedule.launch.standardPercent))
                    .appText()
                    .foregroundStyle(.secondary)
                Text(quote.status == .sent ? "Waiting" : quote.status.rawValue.capitalized)
                    .appText()
                if job.status.isListed && quote.status == .sent {
                    Button("Accept offer") {
                        Haptic.tap()
                        Task { _ = await model.book(quoteID: quote.id) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy)
                    Button("Decline") {
                        Haptic.tap()
                        Task { _ = await model.declineQuote(quoteID: quote.id) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
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
                .buttonStyle(SecondaryButtonStyle())
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
                    Text(notice.title).appText(20, weight: .semibold, relativeTo: .headline)
                    Text(notice.body).appText().foregroundStyle(.secondary)
                }
            }
        }
    }
}
