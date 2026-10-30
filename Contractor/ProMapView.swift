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

struct ProJobMap: View {
    @EnvironmentObject private var model: AppModel
    var jobs: [JobRecord]
    var readOnly = false
    var expands = false
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
                if let center = model.session?.coordinate, let radius = model.session?.radiusMiles, radius > 0 {
                    MapCircle(
                        center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                        radius: Double(radius) * 1609.344
                    )
                    .foregroundStyle(pine.opacity(0.18))
                }
                ForEach(bubbles) { bubble in
                    Annotation(bubble.title, coordinate: bubble.coordinate) {
                        Button {
                            if bubble.jobs.count == 1 {
                                selectedID = bubble.jobs[0].id
                            } else if let first = bubble.jobs.first?.mapCoordinate(exact: false) {
                                let next = max(latitudeDelta / 4, 0.02)
                                position = .region(MKCoordinateRegion(
                                    center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                                    span: MKCoordinateSpan(latitudeDelta: next, longitudeDelta: next)
                                ))
                            }
                        } label: {
                            Text(bubble.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: bubble.jobs.count == 1 ? 46 : 36, height: bubble.jobs.count == 1 ? 46 : 36)
                                .background(bubble.jobs.allSatisfy { $0.category == .moving } ? clay : pine, in: Circle())
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
            .frame(maxWidth: .infinity, minHeight: expands ? 480 : 360, maxHeight: expands ? .infinity : 360)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if locating {
                Text("Locating job sites…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let job = selectedJob {
                JobPinCard(job: job, distance: distanceText(for: job), readOnly: readOnly)
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
            let latitudeDelta = miles / 69 * 2.4
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(job.category == .moving ? clay : pine)
                if SampleJobs.contains(job.id) {
                    Text("Sample — not a real customer").font(.caption.weight(.semibold)).foregroundStyle(clay)
                }
                Text(Money.string(cents: job.offeredPriceCents)).font(.title3.weight(.semibold))
                Text(job.place(exact: readOnly ? false : model.showsExactAddress(job)))
                    .font(.headline)
                    .foregroundStyle(ink)
                if !readOnly {
                    Text(job.details.summary(for: job.category))
                }
                Text("\(DayStamp.display(job.scheduledOn)) · \(distance)")
                    .foregroundStyle(.secondary)
                if job.estimatedMinutes > 0 {
                    Text("About \(job.estimatedMinutes) minutes").font(.footnote).foregroundStyle(.secondary)
                }
                if !readOnly, let estimate = job.estimate {
                    Text(estimate.explanation).font(.footnote)
                }
                if !readOnly && model.session?.canTakeJobs == true && job.status.isListed && !SampleJobs.contains(job.id) {
                    Button("Accept \(Money.compact(cents: job.offeredPriceCents))") {
                        Task { _ = await model.acceptListing(jobID: job.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    NavigationLink {
                        ProJobView(jobID: job.id)
                    } label: {
                        Text("View and quote")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
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
        VStack(spacing: 0) {
            if showsBrandHeader {
                BrandHeader()
            }
            VStack(alignment: .leading, spacing: 10) {
                Menu(typeFilter == "All" ? "All services" : (ServiceCatalog.find(typeFilter)?.title ?? "Service")) {
                    Button("All services") { typeFilter = "All" }
                    ForEach(ServiceCatalog.active) { service in
                        Button(service.title) { typeFilter = service.id }
                    }
                }
                if jobs.isEmpty {
                    Text("No open jobs.")
                        .foregroundStyle(.secondary)
                }
                ProJobMap(jobs: jobs, readOnly: readOnly, expands: true)
            }
            .padding(showsBrandHeader ? 16 : 0)
        }
        .background(paper)
        .navigationTitle(showsBrandHeader ? "" : "Nearby prices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.reload() }
    }
}
