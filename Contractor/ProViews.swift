import SwiftUI

struct ProHome: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = 0
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
            VStack(spacing: 0) {
            BrandHeader {
                Button("Sign out") { Task { await model.signOut() } }
                    .buttonStyle(.plain)
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
                        if openJobs.isEmpty {
                            Text("No open jobs.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(openJobs) { job in
                            NavigationLink {
                                ProJobView(jobID: job.id)
                            } label: {
                                JobCard(job: job, quoteCount: model.quotes(for: job.id).count, exact: model.showsExactAddress(job))
                            }
                            .buttonStyle(.plain)
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
                    HelpLinks()
                    if let error = model.errorMessage {
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
                Text("Service area").font(.headline)
                if model.session != nil {
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
                    if model.session?.identityVerified == false {
                        Button("Confirm identity") { Task { await model.verifyIdentity() } }
                            .buttonStyle(.bordered)
                    }
                    if model.session?.payoutsReady == false {
                        Button("Mark payouts ready") { Task { await model.connectPayouts() } }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onAppear {
            radius = model.session?.radiusMiles ?? 25
            selected = Set(model.session?.serviceTypes ?? [])
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
