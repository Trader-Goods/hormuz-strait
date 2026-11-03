import PhotosUI
import SwiftUI
import UIKit

private enum JobSort: String, CaseIterable {
    case nearest, price, newest

    var title: String {
        switch self {
        case .nearest: return "Nearest"
        case .price: return "Price"
        case .newest: return "Newest"
        }
    }
}

struct ProHome: View {
    @EnvironmentObject private var model: AppModel
    var lane = 0
    @State private var section = 0
    @State private var typeFilter = "All"
    @State private var maxDollars = 500
    @State private var maxMiles = 40.0
    @State private var maxMinutes = 300
    @State private var dateFilter = "Any"
    @State private var sort = JobSort.nearest
    @State private var showFilters = false

    private var openJobs: [JobRecord] {
        guard let me = model.session else { return [] }
        let rows = model.jobs.filter { job in
            guard job.status.isListed, me.reaches(job) else { return false }
            if typeFilter != "All" && job.serviceType != typeFilter { return false }
            if job.offeredPriceCents > maxDollars * 100 { return false }
            if job.estimatedMinutes > maxMinutes { return false }
            if dateFilter != "Any" && job.scheduledOn != dateFilter { return false }
            if let origin = me.coordinate, let point = job.mapCoordinate(exact: false) {
                if origin.miles(to: point) > maxMiles { return false }
            }
            return true
        }
        return rows.sorted { left, right in
            switch sort {
            case .nearest:
                return miles(left) < miles(right)
            case .price:
                return left.offeredPriceCents > right.offeredPriceCents
            case .newest:
                return left.createdAt > right.createdAt
            }
        }
    }

    private func miles(_ job: JobRecord) -> Double {
        guard let origin = model.session?.coordinate, let point = job.mapCoordinate(exact: false) else {
            return .greatestFiniteMagnitude
        }
        return origin.miles(to: point)
    }

    private var mine: [QuoteRecord] {
        guard let me = model.session else { return [] }
        return model.quotes.filter { $0.proID == me.id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            BrandHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.notices.isEmpty {
                        NoticeList()
                    }
                    Text(lane == 0 ? "Jobs near me" : "My jobs")
                        .appText(28, weight: .bold, relativeTo: .title)
                        .foregroundStyle(ink)
                    if lane == 0 {
                        if model.live {
                            Toggle("Show sample jobs", isOn: Binding(
                                get: { model.showSampleJobs },
                                set: { on in Task { await model.setShowSampleJobs(on) } }
                            ))
                        }
                        Menu("Sort by \(sort.title)") {
                            ForEach(JobSort.allCases, id: \.self) { item in
                                Button(item.title) { sort = item }
                            }
                        }
                        .accessibilityLabel("Sort by \(sort.title)")
                        Button("Filter these jobs") { showFilters = true }
                            .buttonStyle(SecondaryButtonStyle())
                        NavigationLink("Show the map") { NearbyPricesPage(readOnly: false, showsBrandHeader: false) }
                            .buttonStyle(SecondaryButtonStyle())
                        if model.busy && openJobs.isEmpty {
                            SkeletonList()
                        } else if openJobs.isEmpty {
                            if let error = model.errorMessage {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(error).foregroundStyle(.red)
                                    Button("Try again") { Task { await model.reload() } }
                                        .buttonStyle(PrimaryButtonStyle())
                                }
                            } else {
                                FriendlyEmpty(symbol: "mappin.and.ellipse", title: "No open jobs.")
                            }
                        }
                        ForEach(openJobs) { job in
                            NavigationLink {
                                ProJobView(jobID: job.id)
                            } label: {
                                JobCard(job: job, quoteCount: model.quotes(for: job.id).count, exact: model.showsExactAddress(job), unread: model.unreadCount(jobID: job.id))
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                    } else {
                        if mine.isEmpty {
                            FriendlyEmpty(symbol: "text.bubble.fill", title: "No offers yet.")
                        }
                        ForEach(mine) { quote in
                            if let job = model.jobs.first(where: { $0.id == quote.jobID }) {
                                NavigationLink {
                                    ProJobView(jobID: job.id)
                                } label: {
                                    Card {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(job.place(exact: model.showsExactAddress(job))).appText(20, weight: .semibold, relativeTo: .headline).foregroundStyle(ink)
                                            HStack {
                                                PriceChip(cents: quote.priceCents)
                                                StatusBadge(title: quote.status.rawValue.capitalized)
                                                UnreadBadge(count: model.unreadCount(jobID: job.id))
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(PressableCardStyle())
                            }
                        }
                        let booked = model.bookings.filter { $0.proID == model.session?.id }
                        if booked.isEmpty {
                            FriendlyEmpty(symbol: "calendar", title: "No booked jobs.")
                        }
                        ForEach(booked) { booking in
                            if let job = model.jobs.first(where: { $0.id == booking.jobID }) {
                                NavigationLink {
                                    ProJobView(jobID: job.id)
                                } label: {
                                    Card {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(job.place(exact: true)).appText(20, weight: .semibold, relativeTo: .headline).foregroundStyle(ink)
                                            HStack {
                                                PriceChip(cents: booking.priceCents)
                                                StatusBadge(status: job.status)
                                            }
                                            Text("You get \(Money.string(cents: booking.charge.proPayoutCents)) after the fee.")
                                                .appText()
                                                .foregroundStyle(inkSoft)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HelpLinks()
                    if let error = model.errorMessage, !(section == 0 && openJobs.isEmpty) {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .refreshable { await model.reload() }
            }
            .background(paper)
            .toolbar(.hidden, for: .navigationBar)
            .animation(.smooth, value: section)
            .task { await model.reload() }
            .sheet(isPresented: $showFilters) {
                NavigationStack {
                    Form {
                        Picker("Service", selection: $typeFilter) {
                            Text("All services").tag("All")
                            ForEach(ServiceCatalog.active) { service in
                                Text(service.title).tag(service.id)
                            }
                        }
                        Stepper("Max price: $\(maxDollars)", value: $maxDollars, in: 25...2000, step: 25)
                        Stepper("Max distance: \(Int(maxMiles)) mi", value: $maxMiles, in: 5...200, step: 5)
                        Stepper("Max time: \(maxMinutes) min", value: $maxMinutes, in: 30...480, step: 30)
                        Picker("Date", selection: $dateFilter) {
                            Text("Any date").tag("Any")
                            ForEach(Array(Set(model.jobs.map(\.scheduledOn))).sorted(), id: \.self) { day in
                                Text(DayStamp.display(day)).tag(day)
                            }
                        }
                    }
                    .navigationTitle("Filter")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showFilters = false }
                        }
                    }
                }
            }
        }
    }
}

struct ProJobView: View {
    @EnvironmentObject private var model: AppModel
    var jobID: UUID
    @State private var price = ""
    @State private var message = ""
    @State private var customer = "Customer"
    @State private var offering = false
    @State private var loadError: String?
    @State private var checked = false
    @State private var showDone = false
    @State private var doneNote = ""
    @State private var donePicker: [PhotosPickerItem] = []
    @State private var donePhotos: [Data] = []
    @State private var confirmAccept = false
    @State private var confirmStart = false
    @State private var acceptedSuccess = false

    private var job: JobRecord? { model.jobs.first { $0.id == jobID } }
    private var mine: QuoteRecord? {
        guard let me = model.session else { return nil }
        return model.quotes(for: jobID).first { $0.proID == me.id }
    }

    var body: some View {
        Group {
            if acceptedSuccess {
                SuccessCover(
                    symbol: "checkmark.circle.fill",
                    title: "You accepted this job",
                    line: "The customer has 24 hours to confirm and pay. You are not booked until then.",
                    button: "Back to my jobs"
                ) {
                    acceptedSuccess = false
                }
            } else {
                jobBody
            }
        }
    }

    private var jobBody: some View {
        VStack(spacing: 0) {
            if let job, let role = model.session?.role {
                NextStepBar(text: nextStepText(job, role: role))
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job {
                    Label(job.serviceTitle, systemImage: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .foregroundStyle(job.category == .moving ? clay : pine)
                        .appText(weight: .semibold)
                    if SampleJobs.contains(job.id) {
                        Text("Sample").appText(weight: .semibold).foregroundStyle(clay)
                    }
                    Text(job.place(exact: model.showsExactAddress(job))).appText(28, weight: .bold, relativeTo: .title)
                    if job.offeredPriceCents > 0 {
                        PriceChip(cents: job.offeredPriceCents)
                    }
                    if job.status == .awaitingPayment {
                        Text("Waiting for the customer to confirm. You are not booked yet.")
                            .appText()
                            .foregroundStyle(.secondary)
                    }
                    if job.showsWorkProgress {
                        JobProgress(status: job.status)
                        workActions(job)
                        NavigationLink("How finishing a job works") { HowFinishingWorksView() }
                            .appText()
                            .foregroundStyle(.secondary)
                    }
                    JobMiniMap(job: job, exact: model.showsExactAddress(job))
                    detailLine("Service", job.serviceTitle)
                    detailLine("Area", job.place(exact: model.showsExactAddress(job)))
                    detailLine("When", whenText(job))
                    detailLine("Price", Money.string(cents: job.offeredPriceCents))
                    if job.category == .moving {
                        detailLine("Rooms", "\(job.details.rooms)")
                        detailLine("Stairs", job.details.stairs ? "Yes" : "No")
                    } else if !job.details.lawnSize.isEmpty {
                        detailLine("Yard size", job.details.lawnSize)
                    }
                    if !job.details.lotSize.isEmpty {
                        detailLine("Lot size", job.details.lotSize)
                    }
                    if !job.details.obstacles.isEmpty {
                        detailLine("Obstacles", job.details.obstacles)
                    }
                    if !jobNotes(job).isEmpty {
                        detailLine("Notes", jobNotes(job))
                    }
                    if job.estimatedMinutes > 0 {
                        detailLine("Time on site", "About \(job.estimatedMinutes) minutes")
                    }
                    if job.photoNames.isEmpty {
                        Text("No photos").foregroundStyle(.secondary)
                    } else {
                        JobPhotos(names: job.photoNames)
                    }
                    if let me = model.session, let origin = me.coordinate, let point = job.mapCoordinate(exact: model.showsExactAddress(job)) {
                        Text(DistanceLabel.text(miles: origin.miles(to: point)))
                            .appText()
                            .foregroundStyle(.secondary)
                    }
                    if let mine {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Your offer").appText(20, weight: .semibold, relativeTo: .headline)
                                    Spacer()
                                    PriceChip(cents: mine.priceCents)
                                }
                                StatusBadge(title: mine.status.rawValue.capitalized)
                                if !mine.message.isEmpty {
                                    Text(mine.message)
                                }
                                Text(paymentLine(priceCents: mine.priceCents, percent: FeeSchedule.launch.percent)).appText().foregroundStyle(.secondary)
                                NavigationLink {
                                    ChatView(jobID: job.id, proID: mine.proID, title: customer)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("Message \(customer)")
                                        UnreadBadge(count: model.unreadCount(jobID: job.id))
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    } else if job.status.isListed && !SampleJobs.contains(job.id) && model.session?.canTakeJobs != true {
                        NavigationLink("Finish my profile") { ProProfileView() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else if !checked {
                    ProgressView()
                        .accessibilityLabel("Loading")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(loadError ?? "This job is unavailable.").appText(20, weight: .semibold, relativeTo: .headline)
                        Button("Try again") {
                            Task { await loadJob() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                if let loadError, job != nil {
                    Text(loadError).foregroundStyle(.red)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .padding(20)
            }
        }
        .background(paper)
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { proActions }
        .sheet(isPresented: $confirmAccept) {
            if let job {
                ConfirmChoice(
                    title: "Accept this job for \(Money.string(cents: job.offeredPriceCents))?",
                    yes: "Yes, accept it"
                ) {
                    confirmAccept = false
                    acceptTapped(job)
                } onNo: {
                    confirmAccept = false
                }
            }
        }
        .sheet(isPresented: $confirmStart) {
            ConfirmChoice(title: "Start this job?", yes: "Yes, start it") {
                confirmStart = false
                Haptic.tap()
                Task { _ = await model.startJob(jobID: jobID) }
            } onNo: {
                confirmStart = false
            }
        }
        .sheet(isPresented: $showDone) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Note", text: $doneNote, axis: .vertical)
                        .lineLimit(3...6)
                    PhotosPicker(selection: $donePicker, maxSelectionCount: 4, matching: .images) {
                        Label(donePhotos.isEmpty ? "After photos" : "\(donePhotos.count) photos", systemImage: "photo")
                    }
                    .onChange(of: donePicker) { _, items in
                        Task {
                            var loaded: [Data] = []
                            for item in items {
                                if let data = try? await item.loadTransferable(type: Data.self) {
                                    loaded.append(data)
                                }
                            }
                            donePhotos = loaded
                        }
                    }
                    Button(model.busy ? "Saving…" : "I'm done, send for approval") {
                        Task {
                            let ok = await model.markJobDone(jobID: jobID, note: doneNote, photos: donePhotos)
                            if ok { showDone = false }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy)
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Mark job done")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { showDone = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $offering) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Your price", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    Button(model.busy ? "Sending…" : "Send offer") {
                        Task {
                            let ok = await model.sendQuote(jobID: jobID, price: price, message: message)
                            if ok { offering = false }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy || price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Make offer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { offering = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .task { await loadJob() }
    }

    @ViewBuilder
    private func workActions(_ job: JobRecord) -> some View {
        if job.status == .awaitingReview {
            Text("The customer has 48 hours to approve. This test version does not send money.")
                .appText()
                .foregroundStyle(inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var proActions: some View {
        if let job, !acceptedSuccess {
            VStack(spacing: 10) {
                if job.status == .booked {
                    Button("Start this job") { confirmStart = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.busy)
                } else if job.status == .inProgress {
                    Button("I'm done, send for approval") {
                        Haptic.tap()
                        showDone = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy)
                } else if job.status.isListed && !SampleJobs.contains(job.id) && model.session?.canTakeJobs == true {
                    Button("Accept this job") { confirmAccept = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.busy || job.offeredPriceCents <= 0)
                    Button("Send a different price") { offerTapped() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(paper)
        }
    }

    private func acceptTapped(_ job: JobRecord) {
        Haptic.tap()
        guard model.session?.canTakeJobs == true else {
            model.errorMessage = AppModel.describe(MarketplaceError.notReady)
            return
        }
        Task {
            let ok = await model.acceptListing(jobID: job.id)
            if ok {
                Haptic.success()
                acceptedSuccess = true
            }
        }
    }

    private func offerTapped() {
        Haptic.tap()
        guard model.session?.canTakeJobs == true else {
            model.errorMessage = AppModel.describe(MarketplaceError.notReady)
            return
        }
        offering = true
    }

    private func loadJob() async {
        checked = false
        loadError = await model.rememberOpenedJob(jobID)
        checked = true
        if let job, job.customerID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
           let person = await model.person(job.customerID) {
            customer = person.displayName
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appText(weight: .semibold).foregroundStyle(.secondary)
            Text(value)
        }
        .accessibilityElement(children: .combine)
    }

    private func whenText(_ job: JobRecord) -> String {
        if JobTiming.label(for: job.timing) != nil { return job.whenLabel }
        let date = DayStamp.display(job.scheduledOn)
        guard let time = scheduledTime(job) else { return date }
        return "\(date) · \(time)"
    }

    private func scheduledTime(_ job: JobRecord) -> String? {
        job.details.notes
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("Time:") }
            .map { $0.replacingOccurrences(of: "Time:", with: "").trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func jobNotes(_ job: JobRecord) -> String {
        job.details.notes
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("Time:") && !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct ProProfileView: View {
    @EnvironmentObject private var model: AppModel
    @State private var radius = 25
    @State private var selected: Set<String> = []
    @State private var bio = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarJPEG: Data?
    @State private var preview: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Group {
                        if let preview {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .foregroundStyle(pine)
                        }
                    }
                    .frame(width: 88, height: 88)
                    .background(pine.opacity(0.12), in: Circle())
                    .clipShape(Circle())
                }
                .accessibilityLabel("Profile photo")
                TextField("Bio", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
                Text("How far I'll travel")
                    .appText(22, weight: .bold, relativeTo: .title2)
                Text("Jobs farther than this stay off your list.")
                    .appText()
                    .foregroundStyle(inkSoft)
                Stepper("\(radius) miles", value: $radius, in: 5...200, step: 5)
                    .accessibilityLabel("How far I'll travel, \(radius) miles")
                ForEach(ServiceCatalog.active) { service in
                    Toggle(isOn: Binding(
                        get: { selected.contains(service.id) },
                        set: { on in
                            if on { selected.insert(service.id) } else { selected.remove(service.id) }
                        }
                    )) {
                        Label(service.title, systemImage: service.symbol)
                    }
                }
                Button(model.busy ? "Saving…" : "Save") {
                    Task {
                        await model.updateServiceArea(serviceTypes: Array(selected), radiusMiles: radius, bio: bio, avatarJPEG: avatarJPEG)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.busy)
                if model.session?.identityVerified == false {
                    Button("Confirm identity") { Task { await model.verifyIdentity() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if model.session?.payoutsReady == false {
                    Button("I'm ready to be paid") { Task { await model.connectPayouts() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = await PhotoStore.compressedJPEG(data) {
                    avatarJPEG = jpeg
                    preview = UIImage(data: jpeg)
                }
            }
        }
    }

    private func load() {
        radius = model.session?.radiusMiles ?? 25
        selected = Set(model.session?.serviceTypes ?? [])
        bio = model.session?.bio ?? ""
        if preview == nil, let path = model.session?.avatarPath {
            preview = PhotoStore.image(path)
        }
    }
}

struct HelpLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AboutLink()
            HowPayWorksLink()
        }
    }
}

struct AboutLink: View {
    var body: some View {
        NavigationLink {
            AboutView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                Text("About")
                Spacer()
                Image(systemName: "chevron.right")
                    .appText(weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .appText()
            .foregroundStyle(ink)
            .frame(minHeight: 56)
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                aboutSection("What it is", "One-day yard work, with one price for the whole job. Help moving and other yard jobs are available too. A contractor accepts your price or makes an offer.")
                aboutSection("Who is assigned", "One contractor gets the job unless you allow more than one. A job stays open for 14 days.")
                aboutSection("The map", "Open jobs show as price bubbles about a quarter mile from the site. The street appears after the job is booked and the card is held.")
                aboutSection("Sample jobs", "Sample jobs on a contractor map are examples on this phone. They are not real customers and cannot be accepted.")
                aboutSection("Your phone", "Contractors enter a US phone number when they sign up. Customers do not see that number until the job is booked and the payment is authorized. This build does not send a text.")
                aboutSection("Getting paid", "Your identity and pay setup stay on this phone until a live identity check and bank deposit are connected. This test version does not send money.")
                aboutSection("More services", "Pressure washing, gutters, snow removal, and junk removal can be added later.")
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func aboutSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appText(20, weight: .semibold, relativeTo: .headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}

struct HowPayWorksLink: View {
    var body: some View {
        NavigationLink {
            HowPayWorksView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("How pay works")
                Spacer()
                Image(systemName: "chevron.right")
                    .appText(weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .appText()
            .foregroundStyle(ink)
            .frame(minHeight: 56)
        }
    }
}

struct HowFinishingWorksView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Booked, then in progress, then done, then paid.")
                Text("The contractor starts the job and marks it done. The customer approves it, or it is approved automatically after 48 hours.")
                    .foregroundStyle(.secondary)
                Text("Approving does not send money in this test version. Bank deposits come later.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("How finishing a job works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EarningsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = 0
    @State private var showPayouts = false

    private var rows: [(job: JobRecord, booking: BookingRecord)] {
        guard let me = model.session else { return [] }
        return model.bookings.compactMap { booking in
            guard booking.proID == me.id, let job = model.jobs.first(where: { $0.id == booking.jobID }) else { return nil }
            return (job, booking)
        }
    }

    private var shown: [(job: JobRecord, booking: BookingRecord)] {
        rows.filter { item in
            switch section {
            case 0: return item.job.status == .awaitingReview
            case 1: return item.job.status == .completed || item.job.status == .approved
            default: return item.booking.charge.status == "captured"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
        BrandHeader()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Money I've earned")
                    .appText(28, weight: .bold, relativeTo: .title)
                Text("Bank deposits are coming soon. No money is sent in this test version.")
                    .appText()
                    .foregroundStyle(inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up bank deposits") { showPayouts = true }
                    .buttonStyle(SecondaryButtonStyle())
                Picker("Money", selection: $section) {
                    Text("Waiting").tag(0)
                    Text("Ready").tag(1)
                    Text("Sent").tag(2)
                }
                .pickerStyle(.segmented)
                if shown.isEmpty {
                    Text(section == 2 ? "No paid jobs." : "Nothing here.")
                        .appText(20, weight: .semibold, relativeTo: .headline)
                }
                ForEach(shown, id: \.booking.id) { item in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.job.serviceTitle).appText(20, weight: .semibold, relativeTo: .headline)
                            Text(item.job.whenLabel).foregroundStyle(.secondary)
                            Text(Money.string(cents: item.booking.priceCents))
                            Text("\(FeeSchedule.launch.percent)% fee \(Money.string(cents: item.booking.feeCents))")
                                .appText()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("Money I've earned")
        .navigationBarTitleDisplayMode(.inline)
        }
        .background(paper)
        .sheet(isPresented: $showPayouts) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Stripe Connect is not connected. No money is moved in this build.")
                    Button("Close") { showPayouts = false }
                        .buttonStyle(PrimaryButtonStyle())
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Bank deposits")
                .navigationBarTitleDisplayMode(.inline)
                .task { _ = await Payouts.connect() }
            }
            .presentationDetents([.medium])
        }
    }
}

struct HowPayWorksView: View {
    private var percent: Int { FeeSchedule.launch.percent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("The customer pays the agreed price in the app. Contractor keeps \(percent)%. The contractor receives the rest.")
                    .foregroundStyle(.secondary)
                paySection("The fee", "The platform fee is a flat \(percent)% of the agreed price. The contractor receives \(100 - percent)%, minus any card-processing cost shown before the customer confirms. Processing is $0 in this TestFlight build and will be shown separately when a live card is charged.")
                paySection("When the card is used", "Booking holds the agreed price on the card. The card is charged only after you approve the finished work, or after 48 hours with no response. Nothing is charged when someone accepts. This test version does not charge a card.")
                paySection("The street address", "The contractor sees an approximate pin and “Near city, ST ZIP” until the job is booked and the payment is authorized. The street address is shown only to the assigned contractor after that.")
                paySection("Finishing the job", "The pro starts the job, then marks it done. You can approve it or report a problem. If you do nothing for 48 hours, the job is approved. This test version does not send money.")
                paySection("A problem with the work", "Report a problem asks what went wrong. The job is marked Problem reported. The money waits until that is settled. A settlement can refund you, pay the pro, or split the difference. The \(percent)% fee is refunded when your payment is refunded.")
                paySection("Refunds and cancellations", "You can cancel a job before anyone is booked. Nothing is charged. After the card is held, canceling before the work is sent in releases that hold. A no-show leaves the job unpaid. After approval, a refund is a separate step.")
                paySection("Money sent to the pro", "Money will go to the pro's bank through Stripe. The pro confirms who they are before accepting jobs. If a bank deposit fails, it is tried again. The job is not marked paid until that deposit works. This test version does not send money.")
                paySection("Why the job stays in the app", "Reviews and the Contractor Guarantee are only for jobs booked and paid in the app. Taking a job off the app with someone you met here breaks the terms. Phone numbers, emails, and links in chat stay hidden until the job is booked and the payment is authorized.")
                Text("This test version records the card hold and does not charge a card or send money yet.")
                    .appText()
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("How Pay Works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paySection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appText(20, weight: .semibold, relativeTo: .headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}
