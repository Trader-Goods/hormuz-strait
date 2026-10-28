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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else {
            finish(nil)
            return
        }
        finish(GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ point: GeoPoint?) {
        continuation?.resume(returning: point)
        continuation = nil
    }
}

struct ProJobMap: View {
    @EnvironmentObject private var model: AppModel
    var jobs: [JobRecord]
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedID: UUID?
    @State private var origin: GeoPoint?
    @State private var locating = false

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
                ForEach(pins) { pin in
                    Annotation(pin.job.category.title, coordinate: pin.coordinate) {
                        Button {
                            selectedID = pin.id
                        } label: {
                            Image(systemName: pin.job.category.symbol)
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(pin.job.category == .lawn ? pine : clay, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: selectedID == pin.id ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .mapStyle(.standard)
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if locating {
                Text("Locating job sites…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Pins sit about a quarter mile from the job site. The street address appears after the customer books you.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let job = selectedJob {
                JobPinCard(job: job, distance: distanceText(for: job))
            }
        }
        .task(id: jobs.map(\.id)) {
            await prepare()
        }
    }

    private var pins: [JobPin] {
        jobs.compactMap { job in
            guard let point = job.mapCoordinate(exact: model.showsExactAddress(job)) else { return nil }
            return JobPin(id: job.id, job: job, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
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
            await model.rememberProLocation(latitude: device.latitude, longitude: device.longitude)
        }
        if center == nil, let zip = model.session?.zip, let zipPoint = await SiteGeocoder.locate(zip: zip) {
            center = zipPoint
            await model.rememberProLocation(latitude: zipPoint.latitude, longitude: zipPoint.longitude)
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
        for job in jobs where job.latitude == nil || job.longitude == nil {
            if let point = await SiteGeocoder.locate(street: job.street, city: job.city, state: job.state, zip: job.zip) {
                await model.rememberJobLocation(id: job.id, latitude: point.latitude, longitude: point.longitude)
            }
        }
        locating = false
    }
}

private struct JobPin: Identifiable {
    var id: UUID
    var job: JobRecord
    var coordinate: CLLocationCoordinate2D
}

private struct JobPinCard: View {
    @EnvironmentObject private var model: AppModel
    var job: JobRecord
    var distance: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(job.category.title, systemImage: job.category.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(job.category == .lawn ? pine : clay)
                Text(job.place(exact: model.showsExactAddress(job)))
                    .font(.headline)
                    .foregroundStyle(ink)
                Text(job.details.summary(for: job.category))
                Text("\(DayStamp.display(job.scheduledOn)) · \(distance)")
                    .foregroundStyle(.secondary)
                NavigationLink {
                    ProJobView(jobID: job.id)
                } label: {
                    Text("View and quote")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
