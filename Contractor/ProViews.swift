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
            BrandHeader {
                HStack(spacing: 16) {
                    NavigationLink("Profile") { ProProfileView() }
                    Button("Sign out") { Task { await model.signOut() } }
                        .buttonStyle(.plain)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.notices.isEmpty {
                        NoticeList()
                    }
                    if let me = model.session {
                        Text(me.publicName).font(.title2.weight(.semibold))
                        if model.hasGuarantee(me.id) {
                            Text(Guarantee.title).font(.caption.weight(.semibold)).foregroundStyle(pine)
                        }
                        Text(me.categories.map(\.title).joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        if me.reviewCount > 0 {
                            Text(String(format: "%.1f · %d reviews", me.rating, me.reviewCount))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Section", selection: $section) {
                        Text("Nearby").tag(0)
                        Text("Offers").tag(1)
                        Text("My Jobs").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Job pipeline")
                    if section == 0 {
                        if model.live {
                            Toggle("Show sample jobs", isOn: Binding(
                                get: { model.showSampleJobs },
                                set: { on in Task { await model.setShowSampleJobs(on) } }
                            ))
                        }
                        HStack {
                            Menu(sort.title) {
                                ForEach(JobSort.allCases, id: \.self) { item in
                                    Button(item.title) { sort = item }
                                }
                            }
                            .accessibilityLabel("Sort by \(sort.title)")
                            Button("Filter") { showFilters = true }
                                .buttonStyle(.bordered)
                        }
                        if model.busy && openJobs.isEmpty {
                            SkeletonList()
                        } else if openJobs.isEmpty {
                            if let error = model.errorMessage {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(error).foregroundStyle(.red)
                                    Button("Try again") { Task { await model.reload() } }
                                        .buttonStyle(.borderedProminent)
                                }
                            } else {
                                Text("No open jobs.").font(.headline)
                            }
                        }
                        ForEach(openJobs) { job in
                            NavigationLink {
                                ProJobView(jobID: job.id)
                            } label: {
                                JobCard(job: job, quoteCount: model.quotes(for: job.id).count, exact: model.showsExactAddress(job), unread: model.unreadCount(jobID: job.id))
                            }
                            .buttonStyle(.plain)
                        }
                    } else if section == 1 {
                        if mine.isEmpty {
                            Text("No offers yet.").font(.headline)
                        }
                        ForEach(mine) { quote in
                            if let job = model.jobs.first(where: { $0.id == quote.jobID }) {
                                NavigationLink {
                                    ProJobView(jobID: job.id)
                                } label: {
                                    Card {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(job.place(exact: model.showsExactAddress(job))).font(.headline).foregroundStyle(ink)
                                            HStack {
                                                PriceChip(cents: quote.priceCents)
                                                StatusBadge(title: quote.status.rawValue.capitalized)
                                                UnreadBadge(count: model.unreadCount(jobID: job.id))
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        let booked = model.bookings.filter { $0.proID == model.session?.id }
                        if booked.isEmpty {
                            Text("No booked jobs.").font(.headline)
                        }
                        ForEach(booked) { booking in
                            if let job = model.jobs.first(where: { $0.id == booking.jobID }) {
                                NavigationLink {
                                    ProJobView(jobID: job.id)
                                } label: {
                                    Card {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(job.place(exact: true)).font(.headline).foregroundStyle(ink)
                                            HStack {
                                                PriceChip(cents: booking.priceCents)
                                                StatusBadge(title: job.status.title)
                                            }
                                            Text("You receive \(Money.string(cents: booking.charge.proPayoutCents))")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
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

    private var job: JobRecord? { model.jobs.first { $0.id == jobID } }
    private var mine: QuoteRecord? {
        guard let me = model.session else { return nil }
        return model.quotes(for: jobID).first { $0.proID == me.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job {
                    Label(job.serviceTitle, systemImage: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .foregroundStyle(job.category == .moving ? clay : pine)
                        .font(.subheadline.weight(.semibold))
                    if SampleJobs.contains(job.id) {
                        Text("Sample").font(.caption.weight(.semibold)).foregroundStyle(clay)
                    }
                    Text(job.place(exact: model.showsExactAddress(job))).font(.title2.weight(.semibold))
                    if job.offeredPriceCents > 0 {
                        PriceChip(cents: job.offeredPriceCents)
                    }
                    JobMiniMap(job: job, exact: model.showsExactAddress(job))
                    Text("\(DayStamp.display(job.scheduledOn)) · \(job.details.summary(for: job.category))")
                        .foregroundStyle(.secondary)
                    if job.estimatedMinutes > 0 {
                        Text("About \(job.estimatedMinutes) minutes")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let estimate = job.estimate {
                        Text(estimate.explanation)
                        Text(estimate.disclaimer).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !job.details.notes.isEmpty {
                        Text(job.details.notes)
                    }
                    if !job.details.obstacles.isEmpty {
                        Text("Obstacles: \(job.details.obstacles)").font(.footnote)
                    }
                    JobPhotos(names: job.photoNames)
                    if let me = model.session, let origin = me.coordinate, let point = job.mapCoordinate(exact: model.showsExactAddress(job)) {
                        Text(DistanceLabel.text(miles: origin.miles(to: point)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let mine {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Your offer").font(.headline)
                                    Spacer()
                                    PriceChip(cents: mine.priceCents)
                                }
                                StatusBadge(title: mine.status.rawValue.capitalized)
                                if !mine.message.isEmpty {
                                    Text(mine.message)
                                }
                                Text(paymentLine(priceCents: mine.priceCents, percent: FeeSchedule.launch.percent)).font(.footnote).foregroundStyle(.secondary)
                                NavigationLink {
                                    ChatView(jobID: job.id, proID: mine.proID, title: customer)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("Message \(customer)")
                                        UnreadBadge(count: model.unreadCount(jobID: job.id))
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else if job.status.isListed && !SampleJobs.contains(job.id) {
                        if model.session?.canTakeJobs == true {
                            Button("Accept \(Money.string(cents: job.offeredPriceCents))") {
                                Haptic.tap()
                                Task { _ = await model.acceptListing(jobID: job.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || job.offeredPriceCents <= 0)
                            Button("Make offer") {
                                Haptic.tap()
                                offering = true
                            }
                            .buttonStyle(.bordered)
                        } else {
                            NavigationLink("Finish profile") { ProProfileView() }
                                .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.borderedProminent)
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
        .task {
            if let job, let person = await model.person(job.customerID) {
                customer = person.displayName
            }
        }
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
                Stepper("Radius: \(radius) miles", value: $radius, in: 5...200, step: 5)
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
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
                if model.session?.identityVerified == false {
                    Button("Confirm identity") { Task { await model.verifyIdentity() } }
                        .buttonStyle(.bordered)
                }
                if model.session?.payoutsReady == false {
                    Button("Mark payouts ready") { Task { await model.connectPayouts() } }
                        .buttonStyle(.bordered)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                aboutSection("What it is", "Yard work and moving anywhere in the US. You set a price. A contractor accepts it or makes an offer.")
                aboutSection("Who is assigned", "One contractor gets the job unless you allow more than one. A listing stays up for 14 days.")
                aboutSection("The map", "Open jobs show as price bubbles about a quarter mile from the site. The street appears after booking and payment authorization.")
                aboutSection("Sample jobs", "Sample jobs on a contractor map are examples on this phone. They are not real customers and cannot be accepted.")
                aboutSection("Your phone", "Contractors enter a US phone number when they sign up. Customers do not see that number until the job is booked and the payment is authorized. This build does not send a text.")
                aboutSection("Payout setup", "Identity and payouts are recorded on this phone until a live identity check and Stripe Connect are connected.")
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
            Text(title).font(.headline)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
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
                paySection("When the card is used", "Booking authorizes the agreed price. The charge is captured only after the customer approves the finished work, or after the 72-hour review window ends with no response. Nothing is captured at the moment someone accepts.")
                paySection("The street address", "The contractor sees an approximate pin and “Near city, ST ZIP” until the job is booked and the payment is authorized. The street address is shown only to the assigned contractor after that.")
                paySection("Finishing the job", "The contractor uploads completion photos and taps Submit Completed Job. That saves the photos and tells the customer. It does not approve the work or start a payout. The customer then chooses Work Looks Complete or Report a Problem. The customer has 72 hours, with reminders during that window. If the customer does not respond, the job is approved and the payout starts. That automatic approval is part of these rules.")
                paySection("A problem with the work", "Report a Problem asks for an explanation and photos. The job moves to Disputed. Both sides can add evidence. The payout waits until the dispute is resolved. A resolution can refund the customer, pay the contractor, or split the difference. The \(percent)% fee follows the customer’s payment: it is refunded when that payment is refunded.")
                paySection("Refunds and cancellations", "The customer can cancel a listing before anyone is booked. Nothing is captured. After authorization, canceling before the work is submitted releases the authorization. A no-show or a failed payment leaves the job unpaid. After approval, a refund is a separate adjustment and does not happen by itself.")
                paySection("Contractor payouts", "Payouts go through Stripe Connect. The contractor finishes identity and Connect setup before accepting jobs or receiving money. A failed payout stays in Payout Processing and is retried. The job is not marked paid until the payout succeeds.")
                paySection("Why the job stays in the app", "Reviews and the Contractor Guarantee are only for jobs booked and paid in the app. Taking a job off the app with someone you met here breaks the terms. Phone numbers, emails, and links in chat stay hidden until the job is booked and the payment is authorized.")
                Text("This TestFlight build records the authorization and does not capture a card or send a Stripe payout yet.")
                    .font(.footnote)
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
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}
