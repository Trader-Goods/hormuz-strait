import SwiftUI

struct ProHome: View {
    @EnvironmentObject private var model: AppModel
    @State private var section = 0

    private var openJobs: [JobRecord] {
        guard let me = model.session else { return [] }
        return model.jobs.filter { job in
            job.status == .open && me.categories.contains(job.category) && me.serviceZips.contains(job.zip) && !model.quotes(for: job.id).contains { $0.proID == me.id } && model.quotes(for: job.id).count < LeadRules.maxQuotes
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
                        if openJobs.isEmpty {
                            Text("No open jobs in your ZIPs. Jobs close after 3 pros quote.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(openJobs) { job in
                            NavigationLink {
                                ProJobView(jobID: job.id)
                            } label: {
                                JobCard(job: job, quoteCount: model.quotes(for: job.id).count)
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
                                            Text(job.place).font(.headline).foregroundStyle(ink)
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
                                        Text(job.place).font(.headline)
                                        Text("\(Money.string(cents: booking.priceCents)) · fee \(Money.string(cents: booking.feeCents))")
                                            .foregroundStyle(.secondary)
                                        Text(feeLine(booking.priceCents)).font(.footnote).foregroundStyle(.secondary)
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
                    Text(job.place).font(.title2.weight(.semibold))
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
                                Text(feeLine(mine.priceCents)).font(.footnote).foregroundStyle(.secondary)
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
                Text("How the fee works").font(.headline)
                Text("Pros never pay to see a lead or to send a quote. When a customer books, the pro owes an 8% fee, at least $5. This build only shows that amount. Stripe is not connected, so nothing is charged.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Live payments need a Stripe Connect platform account, an Express account for each pro, and a PaymentIntent or invoice for the booking fee after the customer taps Book.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
