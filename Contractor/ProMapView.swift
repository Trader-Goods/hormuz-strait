import CoreLocation
import MapKit
import SwiftUI

enum SiteGeocoder {
    static func locate(street: String, city: String, state: String, zip: String) async -> GeoPoint? {
        let address = "\(street), \(city), \(state) \(USAddress.normalizeZip(zip)), USA"
        return await geocode(address)
    }

    static func locate(zip: String) async -> GeoPoint? {
        let zip = USAddress.normalizeZip(zip)
        guard USAddress.isValidZip(zip) else { return nil }
        return await geocode("\(zip), USA")
    }

    private static func geocode(_ query: String) async -> GeoPoint? {
        let marks = try? await CLGeocoder().geocodeAddressString(query)
        guard let location = marks?.first?.location else { return nil }
        return GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
}

@MainActor
final class AreaLocator: NSObject, CLLocationManagerDelegate {
    static let shared = AreaLocator()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<GeoPoint?, Never>?

    func point() async -> GeoPoint? {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.requestLocation()
            case .denied, .restricted:
                self.finish(nil)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let point = locations.first.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        Task { @MainActor in
            self.finish(point)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(nil)
        }
    }

    private func finish(_ point: GeoPoint?) {
        continuation?.resume(returning: point)
        continuation = nil
    }
}

struct JobMiniMap: View {
    var job: JobRecord
    var exact: Bool

    var body: some View {
        if let point = job.mapCoordinate(exact: exact) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            ))) {
                Annotation(job.serviceTitle, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                    Image(systemName: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .appText(20, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(job.category == .moving ? clay : pine, in: Circle())
                }
            }
            .mapStyle(.standard)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityLabel("Map of the job area")
        }
    }
}

struct ProJobMap: View {
    @EnvironmentObject private var model: AppModel
    var jobs: [JobRecord]
    var readOnly = false
    var expands = false
    var onOpen: (UUID) -> Void = { _ in }
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedID: UUID?
    @State private var origin: GeoPoint?
    @State private var locating = false
    @State private var latitudeDelta = 0.45

    private var selectedJob: JobRecord? {
        jobs.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Map(position: $position) {
                if !readOnly, let center = model.session?.coordinate, let radius = model.session?.radiusMiles, radius > 0 {
                    MapCircle(
                        center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                        radius: Double(radius) * 1609.344
                    )
                    .foregroundStyle(pine.opacity(0.18))
                }
                ForEach(bubbles) { bubble in
                    Annotation(bubble.title, coordinate: bubble.coordinate) {
                        Button {
                            if bubble.jobs.count == 1, let id = bubble.jobs.first?.id {
                                selectedID = id
                                onOpen(id)
                            } else if let first = bubble.jobs.first?.mapCoordinate(exact: false) {
                                let next = max(latitudeDelta / 4, 0.02)
                                position = .region(MKCoordinateRegion(
                                    center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                                    span: MKCoordinateSpan(latitudeDelta: next, longitudeDelta: next)
                                ))
                            }
                        } label: {
                            MapPriceMarker(
                                label: bubble.label,
                                symbol: bubble.jobs.first.flatMap { ServiceCatalog.find($0.serviceType)?.symbol } ?? bubble.jobs.first?.category.symbol ?? "leaf.fill",
                                tint: bubble.jobs.first.map { serviceTint($0) } ?? pine,
                                clustered: bubble.jobs.count > 1
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .mapStyle(.standard)
            .onMapCameraChange(frequency: .onEnd) { context in
                let next = context.region.span.latitudeDelta
                if abs(next - latitudeDelta) > 0.0001 {
                    latitudeDelta = next
                }
            }
            .frame(maxWidth: .infinity, minHeight: expands ? 540 : 360, maxHeight: expands ? .infinity : 360)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if locating {
                Text("Locating job sites…")
                    .appText()
                    .foregroundStyle(.secondary)
            }
            if let job = selectedJob {
                Button {
                    onOpen(job.id)
                } label: {
                    JobPinCard(job: job, distance: distanceText(for: job), readOnly: readOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(job.serviceTitle)")
            }
        }
        .task(id: jobs.map(\.id)) {
            await prepare()
        }
    }

    private var bubbles: [JobBubble] {
        let cell = max(latitudeDelta / 14, 0.01)
        var groups: [String: [JobRecord]] = [:]
        for job in jobs {
            guard let point = job.mapCoordinate(exact: readOnly ? false : model.showsExactAddress(job)) else { continue }
            let key = "\(Int((point.latitude / cell).rounded())):\(Int((point.longitude / cell).rounded()))"
            groups[key, default: []].append(job)
        }
        return groups.map { key, grouped in
            let points = grouped.compactMap { $0.mapCoordinate(exact: readOnly ? false : model.showsExactAddress($0)) }
            let latitude = points.map(\.latitude).reduce(0, +) / Double(max(points.count, 1))
            let longitude = points.map(\.longitude).reduce(0, +) / Double(max(points.count, 1))
            let label: String
            let title: String
            if grouped.count == 1, let job = grouped.first {
                label = Money.compact(cents: job.offeredPriceCents)
                title = job.serviceTitle
            } else {
                label = "\(grouped.count)"
                title = "\(grouped.count) jobs"
            }
            return JobBubble(id: key, jobs: grouped, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), label: label, title: title)
        }
    }

    private func distanceText(for job: JobRecord) -> String {
        guard let origin, let target = job.coordinate else { return "Distance unavailable" }
        return DistanceLabel.text(miles: origin.miles(to: target))
    }

    private func prepare() async {
        locating = jobs.contains { $0.coordinate == nil }
        var center = model.session?.coordinate
        if center == nil, let device = await AreaLocator.shared.point() {
            center = device
            if !readOnly {
                await model.rememberProLocation(latitude: device.latitude, longitude: device.longitude)
            }
        }
        if center == nil, let zip = model.session?.zip, let zipPoint = await SiteGeocoder.locate(zip: zip) {
            center = zipPoint
            if !readOnly {
                await model.rememberProLocation(latitude: zipPoint.latitude, longitude: zipPoint.longitude)
            }
        }
        origin = center ?? model.session?.coordinate
        if let origin {
            let miles = Double(max(model.session?.radiusMiles ?? 25, 5))
            let latitudeDelta = ProcessInfo.processInfo.environment["SCREENSHOT"] == "map" ? 0.055 : miles / 69 * 2.4
            let longitudeDelta = latitudeDelta / max(0.2, cos(origin.latitude * .pi / 180))
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            ))
        }
        for job in jobs where !readOnly && (job.latitude == nil || job.longitude == nil) && !job.street.isEmpty {
            if let point = await SiteGeocoder.locate(street: job.street, city: job.city, state: job.state, zip: job.zip) {
                await model.rememberJobLocation(id: job.id, latitude: point.latitude, longitude: point.longitude)
            }
        }
        locating = false
    }
}

private struct MapPriceMarker: View {
    var label: String
    var symbol: String
    var tint: Color
    var clustered: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .appText(weight: .bold)
                .foregroundStyle(Color(red: 0.2, green: 0.1, blue: 0.02))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(amber, in: Capsule())
            Image(systemName: clustered ? "square.3.layers.3d.down.right.fill" : symbol)
                .appText(weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

private struct JobBubble: Identifiable {
    var id: String
    var jobs: [JobRecord]
    var coordinate: CLLocationCoordinate2D
    var label: String
    var title: String
}

private struct JobPinCard: View {
    @EnvironmentObject private var model: AppModel
    var job: JobRecord
    var distance: String
    var readOnly: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(job.serviceTitle, systemImage: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                    .appText(weight: .semibold)
                    .foregroundStyle(job.category == .moving ? clay : pine)
                if SampleJobs.contains(job.id) {
                    Text("Sample — not a real customer").appText(weight: .semibold).foregroundStyle(clay)
                }
                Text(Money.string(cents: job.offeredPriceCents)).appText(22, weight: .semibold, relativeTo: .title2)
                Text(job.place(exact: readOnly ? false : model.showsExactAddress(job)))
                    .appText(20, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(ink)
                if !readOnly {
                    Text(job.details.summary(for: job.category))
                }
                Text("\(job.whenLabel) · \(distance)")
                    .foregroundStyle(.secondary)
                if job.estimatedMinutes > 0 {
                    Text("About \(job.estimatedMinutes) minutes").appText().foregroundStyle(.secondary)
                }
                if !readOnly, let estimate = job.estimate {
                    Text(estimate.explanation).appText()
                }
            }
        }
    }
}

struct NearbyPricesPage: View {
    @EnvironmentObject private var model: AppModel
    var readOnly: Bool
    var showsBrandHeader = true
    @State private var typeFilter = "All"
    @State private var openedID: UUID?

    private var jobs: [JobRecord] {
        let source: [JobRecord]
        if readOnly {
            source = model.priceJobs
        } else if let me = model.session {
            source = model.jobs.filter { $0.status.isListed && me.reaches($0) && $0.offeredPriceCents > 0 }
        } else {
            source = []
        }
        return source.filter { job in
            guard job.status.isListed else { return false }
            if typeFilter != "All" && job.serviceType != typeFilter { return false }
            return true
        }
    }

    var body: some View {
        Group {
            if showsBrandHeader {
                NavigationStack { page }
            } else {
                page
            }
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            if showsBrandHeader {
                BrandHeader()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Menu(typeFilter == "All" ? "All services" : (ServiceCatalog.find(typeFilter)?.title ?? "Service")) {
                        Button("All services") { typeFilter = "All" }
                        ForEach(ServiceCatalog.active) { service in
                            Button(service.title) { typeFilter = service.id }
                        }
                    }
                    if model.busy && jobs.isEmpty {
                        ProgressView()
                            .accessibilityLabel("Loading")
                    } else if jobs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if let error = model.errorMessage {
                                Text(error).foregroundStyle(.red)
                                Button("Try again") { Task { await model.reload() } }
                                    .buttonStyle(PrimaryButtonStyle())
                            } else {
                                FriendlyEmpty(symbol: "map.fill", title: "No open jobs.")
                            }
                        }
                    }
                    ProJobMap(jobs: jobs, readOnly: readOnly, expands: true) { openedID = $0 }
                    ForEach(jobs) { job in
                        Button {
                            openedID = job.id
                        } label: {
                            if readOnly {
                                MapPriceRow(job: job)
                            } else {
                                JobCard(job: job, quoteCount: model.quotes(for: job.id).count, exact: model.showsExactAddress(job), unread: model.unreadCount(jobID: job.id))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(job.serviceTitle)")
                    }
                }
                .padding(showsBrandHeader ? 16 : 0)
            }
            .refreshable { await model.reload() }
        }
        .background(paper)
        .navigationTitle(showsBrandHeader ? "" : "Nearby prices")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedID) { id in
            if readOnly {
                MapPriceDetail(jobID: id)
            } else {
                ProJobView(jobID: id)
            }
        }
        .task { await model.reload() }
    }
}

private struct MapPriceRow: View {
    var job: JobRecord

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                    .appText(20, weight: .bold, relativeTo: .headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(serviceTint(job), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.serviceTitle)
                        .appText(22, weight: .bold, relativeTo: .title2)
                        .foregroundStyle(ink)
                    Text(job.place(exact: false))
                        .appText()
                        .foregroundStyle(.secondary)
                    InfoChip(text: job.whenLabel, symbol: "clock.fill")
                }
                Spacer(minLength: 4)
                if job.offeredPriceCents > 0 {
                    PriceChip(cents: job.offeredPriceCents)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MapPriceDetail: View {
    @EnvironmentObject private var model: AppModel
    var jobID: UUID

    private var job: JobRecord? {
        model.priceJobs.first { $0.id == jobID } ?? model.jobs.first { $0.id == jobID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let job {
                    Label(job.serviceTitle, systemImage: ServiceCatalog.find(job.serviceType)?.symbol ?? job.category.symbol)
                        .appText(weight: .semibold)
                        .foregroundStyle(job.category == .moving ? clay : pine)
                    if SampleJobs.contains(job.id) {
                        Text("Sample").appText(weight: .semibold).foregroundStyle(clay)
                    }
                    Text(job.place(exact: false)).appText(28, weight: .bold, relativeTo: .title)
                    if job.offeredPriceCents > 0 {
                        PriceChip(cents: job.offeredPriceCents)
                    }
                    Text(job.whenLabel)
                        .foregroundStyle(.secondary)
                    if job.estimatedMinutes > 0 {
                        Text("About \(job.estimatedMinutes) minutes")
                            .appText()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("This job is unavailable.").appText(20, weight: .semibold, relativeTo: .headline)
                }
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
    }
}
