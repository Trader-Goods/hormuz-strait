import SwiftUI

struct ProHome: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = 0
    @State private var showMap = true
    @State private var typeFilter = "All"
    @State private var maxDollars = 500
    @State private var maxMiles = 40.0
    @State private var maxMinutes = 300
    @State private var dateFilter = "Any"

    private var openJobs: [JobRecord] {
        guard let me = model.session else { return [] }
        return model.jobs.filter { job in
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
    }

    private var mine: [QuoteRecord] {
        guard let me = model.session else { return [] }
        return model.quotes.filter { $0.proID == me.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DemoBanner()
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
                        Text("Quotes").tag(1)
                        Text("Booked").tag(2)
                    }
                    .pickerStyle(.segmented)
                    if section == 0 {
                        if model.live {
                            Toggle("Show sample jobs", isOn: Binding(
                                get: { model.showSampleJobs },
                                set: { on in Task { await model.setShowSampleJobs(on) } }
                            ))
                        }
                        ProSetupCard()
                        Menu(typeFilter == "All" ? "All services" : (ServiceCatalog.find(typeFilter)?.title ?? "Service")) {
                            Button("All services") { typeFilter = "All" }
                            ForEach(ServiceCatalog.active) { service in
                                Button(service.title) { typeFilter = service.id }
                            }
                        }
                        Stepper("Max price: $\(maxDollars)", value: $maxDollars, in: 25...2000, step: 25)
                        Stepper("Max distance: \(Int(maxMiles)) mi", value: $maxMiles, in: 5...200, step: 5)
                        Stepper("Max time: \(maxMinutes) min", value: $maxMinutes, in: 30...480, step: 30)
                        Menu(dateFilter == "Any" ? "Any date" : DayStamp.display(dateFilter)) {
                            Button("Any date") { dateFilter = "Any" }
                            ForEach(Array(Set(model.jobs.map(\.scheduledOn))).sorted(), id: \.self) { day in
                                Button(DayStamp.display(day)) { dateFilter = day }
                            }
                        }
                        Picker("Layout", selection: $showMap) {
                            Text("Map").tag(true)
                            Text("List").tag(false)
                        }
                        .pickerStyle(.segmented)
                        if openJobs.isEmpty {
                            Text("No open jobs in this filter. Listings leave the map when a contractor is booked.")
                                .foregroundStyle(.secondary)
                        }
                        if showMap {
                            ProJobMap(jobs: openJobs)
                        } else {
                            ForEach(openJobs) { job in
                                NavigationLink {
                                    ProJobView(jobID: job.id)
                                } label: {
                                    JobCard(job: job, quoteCount: model.quotes(for: job.id).count, exact: model.showsExactAddress(job))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if section == 1 {
                        ForEach(mine) { quote in
                            if let job = model.jobs.first(where: { $0.id == quote.jobID }) {
                                NavigationLink {
                                    ProJobView(jobID: job.id)
                                } label: {
                                    Card {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(job.place(exact: model.showsExactAddress(job))).font(.headline).foregroundStyle(ink)
                                            Text("\(Money.string(cents: quote.priceCents)) · \(quote.status.rawValue)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(model.bookings.filter { $0.proID == model.session?.id }) { booking in
                            if let job = model.jobs.first(where: { $0.id == booking.jobID }) {
                                Card {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(job.place(exact: true)).font(.headline)
                                        Text("\(Money.string(cents: booking.priceCents)) · you receive \(Money.string(cents: booking.charge.proPayoutCents))")
                                            .foregroundStyle(.secondary)
                                        Text(paymentLine(priceCents: booking.priceCents, percent: booking.feePercent)).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    AccountNote()
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(paper)
            .navigationTitle("Jobs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { Task { await model.signOut() } }
                }
            }
            .refreshable { await model.reload() }
            .task { await model.reload() }
            .task(id: showMap) {
                guard showMap, section == 0 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    await model.reloadQuietly()
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

    private var job: JobRecord? { model.jobs.first { $0.id == jobID } }
    private var mine: QuoteRecord? {
        guard let me = model.session else { return nil }
        return model.quotes(for: jobID).first { $0.proID == me.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job {
                    Text(job.serviceTitle).foregroundStyle(job.category == .moving ? clay : pine).font(.subheadline.weight(.semibold))
                    if SampleJobs.contains(job.id) {
                        Text("Sample — not a real customer. You cannot accept this job.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(job.place(exact: model.showsExactAddress(job))).font(.title2.weight(.semibold))
                    if job.offeredPriceCents > 0 {
                        Text("Offered \(Money.string(cents: job.offeredPriceCents))").font(.title3.weight(.semibold))
                    }
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
                    Text(job.details.notes)
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
                                Text("Your quote: \(Money.string(cents: mine.priceCents))").font(.headline)
                                Text(mine.message)
                                Text(paymentLine(priceCents: mine.priceCents, percent: FeeSchedule.launch.percent)).font(.footnote).foregroundStyle(.secondary)
                                NavigationLink("Message \(customer)") {
                                    ChatView(jobID: job.id, proID: mine.proID, title: customer)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else if job.status.isListed && !SampleJobs.contains(job.id) {
                        if model.session?.canTakeJobs == true {
                            Button("Accept \(Money.string(cents: job.offeredPriceCents))") {
                                Task { _ = await model.acceptListing(jobID: job.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || job.offeredPriceCents <= 0)
                            TextField("Counter-offer", text: $price)
                                .keyboardType(.decimalPad)
                            TextField("Message", text: $message, axis: .vertical)
                            Button("Make offer") {
                                Task { _ = await model.sendQuote(jobID: job.id, price: price, message: message) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.busy)
                        } else {
                            Text("Confirm your identity and mark payouts ready before you can accept a job.")
                                .foregroundStyle(.secondary)
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
        .navigationTitle("Quote")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let job, let person = await model.person(job.customerID) {
                customer = person.displayName
            }
        }
    }
}

struct ProSetupCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var radius = 25
    @State private var selected: Set<String> = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Service area and verification").font(.headline)
                if let me = model.session {
                    Text(me.canTakeJobs ? "You can accept jobs. Payouts are marked ready. Stripe is not connected." : "Accept stays off until identity and payouts are recorded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Stepper("Radius: \(radius) miles", value: $radius, in: 5...200, step: 5)
                    ForEach(ServiceCatalog.active) { service in
                        Toggle(service.title, isOn: Binding(
                            get: { selected.contains(service.id) },
                            set: { on in
                                if on { selected.insert(service.id) } else { selected.remove(service.id) }
                            }
                        ))
                    }
                    Button("Save service area") {
                        Task { await model.updateServiceArea(serviceTypes: Array(selected), radiusMiles: radius) }
                    }
                    .buttonStyle(.bordered)
                    if !me.identityVerified {
                        Button("Confirm identity") { Task { await model.verifyIdentity() } }
                            .buttonStyle(.bordered)
                    }
                    if !me.payoutsReady {
                        Button("Mark payouts ready") { Task { await model.connectPayouts() } }
                            .buttonStyle(.bordered)
                    }
                    Text("Identity confirmation is stored on this phone. A live account will use a real identity check and Stripe Connect before payouts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            radius = model.session?.radiusMiles ?? 25
            selected = Set(model.session?.serviceTypes ?? [])
        }
    }
}

struct AccountNote: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("How pay works").font(.headline)
                Text("The customer sets the price. You can accept it or make an offer. Contractor keeps \(FeeSchedule.launch.percent)%. You receive the rest, before any processing cost. \(FeeSchedule.launch.processingNote) This demo authorizes the card and does not capture it. Stripe Connect onboarding is not live.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Terms.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("A live charge needs a Stripe Connect platform, an Express account for each pro, and a PaymentIntent for the quote price with application_fee_amount set to the platform fee. The rest is transferred to the pro.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
