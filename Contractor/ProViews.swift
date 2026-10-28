import SwiftUI

struct ProHome: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = 0
    @State private var showMap = true
    @State private var categoryFilter = "All"

    private var openJobs: [JobRecord] {
        guard let me = model.session else { return [] }
        return model.jobs.filter { job in
            guard job.status == .open, me.reaches(job) else { return false }
            guard !model.quotes(for: job.id).contains(where: { $0.proID == me.id }) else { return false }
            guard model.quotes(for: job.id).count < LeadRules.maxQuotes else { return false }
            if categoryFilter == "Lawn care" { return job.category == .lawn }
            if categoryFilter == "Moving" { return job.category == .moving }
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
                        Picker("Category", selection: $categoryFilter) {
                            Text("All").tag("All")
                            Text("Lawn care").tag("Lawn care")
                            Text("Moving").tag("Moving")
                        }
                        .pickerStyle(.segmented)
                        Picker("Layout", selection: $showMap) {
                            Text("Map").tag(true)
                            Text("List").tag(false)
                        }
                        .pickerStyle(.segmented)
                        if openJobs.isEmpty {
                            Text("No open jobs in your service area. Jobs close after 3 pros quote.")
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
                    Text(job.category.title).foregroundStyle(clay).font(.subheadline.weight(.semibold))
                    Text(job.place(exact: model.showsExactAddress(job))).font(.title2.weight(.semibold))
                    Text("\(DayStamp.display(job.scheduledOn)) · \(job.details.summary(for: job.category))")
                        .foregroundStyle(.secondary)
                    Text(job.details.notes)
                    Text("\(model.quotes(for: job.id).count) of 3 quotes sent. Quoting is free.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let mine {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your quote: \(Money.string(cents: mine.priceCents))").font(.headline)
                                Text(mine.message)
                                Text(paymentLine(priceCents: mine.priceCents, percent: FeeSchedule.launch.standardPercent)).font(.footnote).foregroundStyle(.secondary)
                                NavigationLink("Message \(customer)") {
                                    ChatView(jobID: job.id, proID: mine.proID, title: customer)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else if job.status == .open {
                        TextField("Price", text: $price)
                            .keyboardType(.decimalPad)
                        TextField("Message", text: $message, axis: .vertical)
                        Button("Send quote") {
                            Task { _ = await model.sendQuote(jobID: job.id, price: price, message: message) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
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

struct AccountNote: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("How pay works").font(.headline)
                Text("Pros never pay to see a lead or to send a quote. The customer pays the quote in the app. Contractor keeps \(FeeSchedule.launch.standardPercent)% (at least $5) before the pro is paid. Booking the same pro again is \(FeeSchedule.launch.repeatPercent)%. This demo records the Stripe Connect charge and does not take a real card.")
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
