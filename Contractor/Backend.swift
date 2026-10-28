import Foundation
import UIKit

enum BackendConfig {
    static var supabaseURL: URL? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }

    static var anonKey: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isLive: Bool {
        supabaseURL != nil && !anonKey.isEmpty
    }
}

@MainActor
protocol ContractorAPI: AnyObject {
    func restore() async throws -> UserRecord?
    func signUp(role: UserRole, name: String, email: String, password: String, zip: String, business: String, categories: [ServiceCategory], serviceZips: [String], acceptedTerms: Bool, radiusMiles: Int) async throws -> UserRecord
    func signIn(email: String, password: String) async throws -> UserRecord
    func verifyPhone() async throws -> UserRecord
    func signOut() async
    func refresh(_ user: UserRecord) async throws -> UserRecord
    func customerJobs() async throws -> [JobRecord]
    func openJobs() async throws -> [JobRecord]
    func quotes(for jobID: UUID) async throws -> [QuoteRecord]
    func myQuotes() async throws -> [QuoteRecord]
    func bookings() async throws -> [BookingRecord]
    func postJob(category: ServiceCategory, street: String, city: String, state: String, zip: String, latitude: Double?, longitude: Double?, scheduledOn: String, details: JobDetails, photos: [Data]) async throws -> JobRecord
    func rememberJobLocation(id: UUID, latitude: Double, longitude: Double) async
    func rememberProLocation(latitude: Double, longitude: Double) async
    func sendQuote(jobID: UUID, priceCents: Int, message: String) async throws -> QuoteRecord
    func book(quoteID: UUID) async throws -> BookingRecord
    func bookAgain(bookingID: UUID, scheduledOn: String, recurrence: String) async throws -> BookingRecord
    func report(userID: UUID, jobID: UUID?, reason: String) async throws
    func messages(jobID: UUID, proID: UUID) async throws -> [MessageRecord]
    func sendMessage(jobID: UUID, proID: UUID, body: String) async throws -> MessageRecord
    func review(jobID: UUID, rating: Int, body: String) async throws -> ReviewRecord
    func user(id: UUID) async throws -> UserRecord?
    func job(id: UUID) async throws -> JobRecord?
}

enum PhotoStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("ContractorPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func save(_ data: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        let url = folder.appendingPathComponent(name)
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.7) else { return nil }
        do {
            try jpeg.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func image(_ name: String) -> UIImage? {
        let url = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

@MainActor
final class MockBackend: ContractorAPI {
    private var book: MarketplaceBook
    private var sessionID: UUID?
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("Contractor", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("demo.json")
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(MarketplaceBook.self, from: data) {
            book = stored
        } else {
            book = MarketplaceBook.demo()
            persist()
        }
        if let raw = UserDefaults.standard.string(forKey: "contractor.session") {
            sessionID = UUID(uuidString: raw)
        }
    }

    func restore() async throws -> UserRecord? {
        guard let sessionID else { return nil }
        return book.user(sessionID)
    }

    func signUp(role: UserRole, name: String, email: String, password: String, zip: String, business: String, categories: [ServiceCategory], serviceZips: [String], acceptedTerms: Bool, radiusMiles: Int) async throws -> UserRecord {
        let user = try book.signUp(role: role, name: name, email: email, password: password, zip: zip, business: business, categories: categories, serviceZips: serviceZips, acceptedTerms: acceptedTerms, radiusMiles: radiusMiles)
        sessionID = user.id
        UserDefaults.standard.set(user.id.uuidString, forKey: "contractor.session")
        persist()
        return user
    }

    func signIn(email: String, password: String) async throws -> UserRecord {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let stored = book.users.first(where: { $0.user.email == clean && $0.password == password }) else {
            throw MarketplaceError.invalid
        }
        sessionID = stored.user.id
        UserDefaults.standard.set(stored.user.id.uuidString, forKey: "contractor.session")
        return stored.user
    }

    func verifyPhone() async throws -> UserRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let user = try book.verifyPhone(sessionID)
        persist()
        return user
    }

    func signOut() async {
        sessionID = nil
        UserDefaults.standard.removeObject(forKey: "contractor.session")
    }

    func refresh(_ user: UserRecord) async throws -> UserRecord {
        book.user(user.id) ?? user
    }

    func customerJobs() async throws -> [JobRecord] {
        guard let sessionID else { return [] }
        return book.jobs.filter { $0.customerID == sessionID }.sorted { $0.createdAt > $1.createdAt }
    }

    func openJobs() async throws -> [JobRecord] {
        guard let sessionID, let pro = book.user(sessionID) else { return [] }
        return book.openJobs(for: pro)
    }

    func quotes(for jobID: UUID) async throws -> [QuoteRecord] {
        book.quotes(for: jobID)
    }

    func myQuotes() async throws -> [QuoteRecord] {
        guard let sessionID else { return [] }
        return book.quotes.filter { $0.proID == sessionID }.sorted { $0.createdAt > $1.createdAt }
    }

    func bookings() async throws -> [BookingRecord] {
        guard let sessionID else { return [] }
        return book.bookings.filter { $0.proID == sessionID || $0.customerID == sessionID }
    }

    func postJob(category: ServiceCategory, street: String, city: String, state: String, zip: String, latitude: Double?, longitude: Double?, scheduledOn: String, details: JobDetails, photos: [Data]) async throws -> JobRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let names = photos.compactMap { PhotoStore.save($0) }
        let job = try book.postJob(customerID: sessionID, category: category, street: street, city: city, state: state, zip: zip, latitude: latitude, longitude: longitude, scheduledOn: scheduledOn, details: details, photoNames: names)
        persist()
        return job
    }

    func rememberJobLocation(id: UUID, latitude: Double, longitude: Double) async {
        guard let index = book.jobs.firstIndex(where: { $0.id == id }) else { return }
        book.jobs[index].latitude = latitude
        book.jobs[index].longitude = longitude
        persist()
    }

    func rememberProLocation(latitude: Double, longitude: Double) async {
        guard let sessionID, let index = book.users.firstIndex(where: { $0.user.id == sessionID }) else { return }
        book.users[index].user.latitude = latitude
        book.users[index].user.longitude = longitude
        persist()
    }

    func sendQuote(jobID: UUID, priceCents: Int, message: String) async throws -> QuoteRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let quote = try book.sendQuote(proID: sessionID, jobID: jobID, priceCents: priceCents, message: message)
        persist()
        return quote
    }

    func book(quoteID: UUID) async throws -> BookingRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let booking = try book.book(customerID: sessionID, quoteID: quoteID)
        persist()
        return booking
    }

    func bookAgain(bookingID: UUID, scheduledOn: String, recurrence: String) async throws -> BookingRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let booking = try book.bookAgain(customerID: sessionID, bookingID: bookingID, scheduledOn: scheduledOn, recurrence: recurrence)
        persist()
        return booking
    }

    func report(userID: UUID, jobID: UUID?, reason: String) async throws {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        _ = try book.report(reporterID: sessionID, reportedUserID: userID, jobID: jobID, reason: reason)
        persist()
    }

    func messages(jobID: UUID, proID: UUID) async throws -> [MessageRecord] {
        book.messages.filter { $0.jobID == jobID && $0.proID == proID }.sorted { $0.createdAt < $1.createdAt }
    }

    func sendMessage(jobID: UUID, proID: UUID, body: String) async throws -> MessageRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let message = try book.sendMessage(jobID: jobID, proID: proID, senderID: sessionID, body: body)
        persist()
        return message
    }

    func review(jobID: UUID, rating: Int, body: String) async throws -> ReviewRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let review = try book.review(customerID: sessionID, jobID: jobID, rating: rating, body: body)
        persist()
        return review
    }

    func user(id: UUID) async throws -> UserRecord? {
        book.user(id)
    }

    func job(id: UUID) async throws -> JobRecord? {
        book.jobs.first { $0.id == id }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Live Supabase client. Used only when SUPABASE_URL and SUPABASE_ANON_KEY are set.
/// Email confirmation must be off, or sign-up will not return a session.
@MainActor
final class SupabaseBackend: ContractorAPI {
    private let base: URL
    private let key: String
    private var accessToken: String?
    private var userID: UUID?

    init() {
        base = BackendConfig.supabaseURL!
        key = BackendConfig.anonKey
    }

    func restore() async throws -> UserRecord? { nil }

    func signUp(role: UserRole, name: String, email: String, password: String, zip: String, business: String, categories: [ServiceCategory], serviceZips: [String], acceptedTerms: Bool, radiusMiles: Int) async throws -> UserRecord {
        guard acceptedTerms else { throw MarketplaceError.termsRequired }
        guard USAddress.isValidZip(zip) else { throw MarketplaceError.invalid }
        let payload: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "password": password,
        ]
        let response = try await send(path: "/auth/v1/signup", method: "POST", body: payload, auth: false)
        try storeSession(response)
        guard let userID else { throw MarketplaceError.invalid }
        let profile: [String: Any] = [
            "id": userID.uuidString,
            "role": role.rawValue,
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "display_name": name,
            "zip": USAddress.normalizeZip(zip),
            "phone_verified": false,
        ]
        _ = try await send(path: "/rest/v1/profiles", method: "POST", body: profile, auth: true)
        if role == .pro {
            let pro: [String: Any] = [
                "id": userID.uuidString,
                "business_name": business,
                "categories": categories.map(\.rawValue),
                "service_zips": serviceZips.isEmpty ? [USAddress.normalizeZip(zip)] : serviceZips,
                "radius_miles": radiusMiles,
            ]
            _ = try await send(path: "/rest/v1/pro_profiles", method: "POST", body: pro, auth: true)
        }
        return try await currentUser()
    }

    func signIn(email: String, password: String) async throws -> UserRecord {
        let payload = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "password": password,
        ]
        let response = try await send(path: "/auth/v1/token?grant_type=password", method: "POST", body: payload, auth: false)
        try storeSession(response)
        return try await currentUser()
    }

    func verifyPhone() async throws -> UserRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        _ = try await send(path: "/rest/v1/profiles?id=eq.\(userID.uuidString)", method: "PATCH", body: ["phone_verified": true], auth: true)
        return try await currentUser()
    }

    func signOut() async {
        accessToken = nil
        userID = nil
    }

    func refresh(_ user: UserRecord) async throws -> UserRecord {
        try await currentUser()
    }

    func customerJobs() async throws -> [JobRecord] {
        guard let userID else { return [] }
        return try await get("/rest/v1/jobs?customer_id=eq.\(userID.uuidString)&select=*&order=created_at.desc")
    }

    func openJobs() async throws -> [JobRecord] {
        let me = try await currentUser()
        let jobs: [JobRecord] = try await get("/rest/v1/jobs?status=eq.open&select=*")
        return jobs.filter { job in
            me.reaches(job)
        }
    }

    func quotes(for jobID: UUID) async throws -> [QuoteRecord] {
        try await get("/rest/v1/quotes?job_id=eq.\(jobID.uuidString)&select=*")
    }

    func myQuotes() async throws -> [QuoteRecord] {
        guard let userID else { return [] }
        return try await get("/rest/v1/quotes?pro_id=eq.\(userID.uuidString)&select=*")
    }

    func bookings() async throws -> [BookingRecord] {
        guard let userID else { return [] }
        return try await get("/rest/v1/bookings?or=(pro_id.eq.\(userID.uuidString),customer_id.eq.\(userID.uuidString))&select=*")
    }

    func rememberJobLocation(id: UUID, latitude: Double, longitude: Double) async {
        _ = try? await send(
            path: "/rest/v1/jobs?id=eq.\(id.uuidString)",
            method: "PATCH",
            body: ["latitude": latitude, "longitude": longitude],
            auth: true
        )
    }

    func rememberProLocation(latitude: Double, longitude: Double) async {
        guard let userID else { return }
        _ = try? await send(
            path: "/rest/v1/pro_profiles?id=eq.\(userID.uuidString)",
            method: "PATCH",
            body: ["latitude": latitude, "longitude": longitude],
            auth: true
        )
    }

    func postJob(category: ServiceCategory, street: String, city: String, state: String, zip: String, latitude: Double?, longitude: Double?, scheduledOn: String, details: JobDetails, photos: [Data]) async throws -> JobRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        var names: [String] = []
        for photo in photos {
            if let name = try await upload(photo) { names.append(name) }
        }
        let body: [String: Any] = [
            "customer_id": userID.uuidString,
            "category": category.rawValue,
            "street": street,
            "city": city,
            "state": state,
            "zip": USAddress.normalizeZip(zip),
            "latitude": latitude as Any,
            "longitude": longitude as Any,
            "scheduled_on": scheduledOn,
            "details": [
                "lawnSize": details.lawnSize,
                "rooms": details.rooms,
                "stairs": details.stairs,
                "notes": details.notes,
            ],
            "status": "open",
            "photo_names": names,
        ]
        let rows: [JobRecord] = try await post("/rest/v1/jobs", body: body)
        guard let job = rows.first else { throw MarketplaceError.missing }
        return job
    }

    func sendQuote(jobID: UUID, priceCents: Int, message: String) async throws -> QuoteRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        let body: [String: Any] = [
            "job_id": jobID.uuidString,
            "pro_id": userID.uuidString,
            "price_cents": priceCents,
            "message": message,
            "status": "sent",
        ]
        let rows: [QuoteRecord] = try await post("/rest/v1/quotes", body: body)
        guard let quote = rows.first else { throw MarketplaceError.missing }
        return quote
    }

    func book(quoteID: UUID) async throws -> BookingRecord {
        let quotes: [QuoteRecord] = try await get("/rest/v1/quotes?id=eq.\(quoteID.uuidString)&select=*")
        guard let quote = quotes.first, let userID else { throw MarketplaceError.missing }
        _ = try await send(path: "/rest/v1/quotes?id=eq.\(quote.id.uuidString)", method: "PATCH", body: ["status": "accepted"], auth: true)
        _ = try await send(path: "/rest/v1/jobs?id=eq.\(quote.jobID.uuidString)", method: "PATCH", body: ["status": "booked"], auth: true)
        let body: [String: Any] = [
            "job_id": quote.jobID.uuidString,
            "quote_id": quote.id.uuidString,
            "pro_id": quote.proID.uuidString,
            "customer_id": userID.uuidString,
            "price_cents": quote.priceCents,
            "fee_cents": BookingFee.feeCents(priceCents: quote.priceCents),
            "fee_percent": FeeSchedule.launch.standardPercent,
            "paid_in_app": true,
            "recurrence": "",
            "charge": [
                "amountCents": quote.priceCents,
                "applicationFeeCents": BookingFee.feeCents(priceCents: quote.priceCents),
                "proPayoutCents": BookingFee.payoutCents(priceCents: quote.priceCents, percent: FeeSchedule.launch.standardPercent),
                "currency": "usd",
                "status": "stubbed",
                "connectedAccountID": "",
            ],
        ]
        let rows: [BookingRecord] = try await post("/rest/v1/bookings", body: body)
        guard let booking = rows.first else { throw MarketplaceError.missing }
        return booking
    }

    func bookAgain(bookingID: UUID, scheduledOn: String, recurrence: String) async throws -> BookingRecord {
        throw MarketplaceError.invalid
    }

    func report(userID: UUID, jobID: UUID?, reason: String) async throws {
        guard let reporter = self.userID else { throw MarketplaceError.wrongAccount }
        var payload: [String: Any] = [
            "reporter_id": reporter.uuidString,
            "reported_user_id": userID.uuidString,
            "reason": reason,
        ]
        if let jobID {
            payload["job_id"] = jobID.uuidString
        }
        _ = try await send(path: "/rest/v1/reports", method: "POST", body: payload, auth: true)
    }

    func messages(jobID: UUID, proID: UUID) async throws -> [MessageRecord] {
        try await get("/rest/v1/messages?job_id=eq.\(jobID.uuidString)&pro_id=eq.\(proID.uuidString)&select=*&order=created_at.asc")
    }

    func sendMessage(jobID: UUID, proID: UUID, body: String) async throws -> MessageRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        let payload: [String: Any] = [
            "job_id": jobID.uuidString,
            "pro_id": proID.uuidString,
            "sender_id": userID.uuidString,
            "body": body,
        ]
        let rows: [MessageRecord] = try await post("/rest/v1/messages", body: payload)
        guard let message = rows.first else { throw MarketplaceError.missing }
        return message
    }

    func review(jobID: UUID, rating: Int, body: String) async throws -> ReviewRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        let bookings: [BookingRecord] = try await get("/rest/v1/bookings?job_id=eq.\(jobID.uuidString)&select=*")
        guard let booking = bookings.first else { throw MarketplaceError.missing }
        let payload: [String: Any] = [
            "job_id": jobID.uuidString,
            "pro_id": booking.proID.uuidString,
            "customer_id": userID.uuidString,
            "rating": rating,
            "body": body,
        ]
        let rows: [ReviewRecord] = try await post("/rest/v1/reviews", body: payload)
        guard let review = rows.first else { throw MarketplaceError.missing }
        return review
    }

    func user(id: UUID) async throws -> UserRecord? {
        let profiles: [ProfileDTO] = try await get("/rest/v1/profiles?id=eq.\(id.uuidString)&select=*")
        guard let profile = profiles.first else { return nil }
        let pros: [ProDTO] = (try? await get("/rest/v1/pro_profiles?id=eq.\(id.uuidString)&select=*")) ?? []
        let pro = pros.first
        return UserRecord(
            id: profile.id,
            role: profile.role,
            email: profile.email ?? "",
            displayName: profile.displayName,
            zip: profile.zip,
            phoneVerified: profile.phoneVerified,
            businessName: pro?.businessName ?? "",
            categories: pro?.categories ?? [],
            serviceZips: pro?.serviceZips ?? [],
            radiusMiles: pro?.radiusMiles ?? 25,
            latitude: pro?.latitude,
            longitude: pro?.longitude,
            rating: pro?.rating ?? 0,
            reviewCount: pro?.reviewCount ?? 0
        )
    }

    func job(id: UUID) async throws -> JobRecord? {
        let rows: [JobRecord] = try await get("/rest/v1/jobs?id=eq.\(id.uuidString)&select=*")
        return rows.first
    }

    private struct ProfileDTO: Decodable {
        var id: UUID
        var role: UserRole
        var email: String?
        var displayName: String
        var zip: String
        var phoneVerified: Bool
    }

    private struct ProDTO: Decodable {
        var businessName: String?
        var categories: [ServiceCategory]?
        var serviceZips: [String]?
        var radiusMiles: Int?
        var latitude: Double?
        var longitude: Double?
        var rating: Double?
        var reviewCount: Int?
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func camel(_ snake: String) -> String {
        guard snake.contains("_") else { return snake }
        let parts = snake.split(separator: "_")
        let head = String(parts[0])
        let tail = parts.dropFirst().map { part -> String in
            if part.lowercased() == "id" { return "ID" }
            let text = String(part)
            return text.prefix(1).uppercased() + text.dropFirst()
        }.joined()
        return head + tail
    }

    private func currentUser() async throws -> UserRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        guard let record = try await user(id: userID) else { throw MarketplaceError.missing }
        return record
    }

    private func storeSession(_ json: [String: Any]) throws {
        if let token = json["access_token"] as? String {
            accessToken = token
        }
        if let user = json["user"] as? [String: Any], let id = user["id"] as? String, let uuid = UUID(uuidString: id) {
            userID = uuid
        }
        guard accessToken != nil, userID != nil else { throw MarketplaceError.invalid }
    }

    private func upload(_ data: Data) async throws -> String? {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.7) else { return nil }
        let name = UUID().uuidString + ".jpg"
        var request = URLRequest(url: base.appendingPathComponent("storage/v1/object/job-photos/\(name)"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? key)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MarketplaceError.invalid
        }
        return name
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let json = try await send(path: path, method: "GET", body: nil, auth: true)
        let data = try JSONSerialization.data(withJSONObject: json["rows"] ?? [])
        return try decoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let json = try await send(path: path, method: "POST", body: body, auth: true, represent: true)
        let data = try JSONSerialization.data(withJSONObject: json["rows"] ?? [])
        return try decoder().decode(T.self, from: data)
    }

    private func send(path: String, method: String, body: [String: Any]?, auth: Bool, represent: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw MarketplaceError.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if represent { request.setValue("return=representation", forHTTPHeaderField: "Prefer") }
        if auth, let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarketplaceError.invalid }
        guard (200..<300).contains(http.statusCode) else { throw MarketplaceError.invalid }
        if data.isEmpty { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any] { return dictionary }
        if let array = object as? [Any] { return ["rows": array] }
        return [:]
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let raw = keys.last!.stringValue
            return AnyKey(stringValue: Self.camel(raw))!
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
        }
        return decoder
    }
}
