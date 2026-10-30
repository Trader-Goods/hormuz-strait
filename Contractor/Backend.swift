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

enum AuthCallback {
    /// Add this exact value under Supabase Auth → URL Configuration → Redirect URLs.
    static let redirect = "contractorpros://auth-callback"

    static func signupPath() -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "redirect_to", value: redirect)]
        let query = components.percentEncodedQuery ?? ""
        return "/auth/v1/signup?\(query)"
    }

    static func params(from url: URL) -> [String: String] {
        guard url.scheme == "contractorpros" else { return [:] }
        var values: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                if let value = item.value { values[item.name] = value }
            }
        }
        if let fragment = url.fragment, !fragment.isEmpty,
           let items = URLComponents(string: "https://callback.invalid/?\(fragment)")?.queryItems {
            for item in items {
                if let value = item.value { values[item.name] = value }
            }
        }
        return values
    }

    static func needsEmailConfirmation(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("email not confirmed") || lower.contains("email_not_confirmed")
    }
}

@MainActor
protocol ContractorAPI: AnyObject {
    func restore() async throws -> UserRecord?
    func signUp(role: UserRole, name: String, email: String, password: String, zip: String, business: String, categories: [ServiceCategory], serviceZips: [String], acceptedTerms: Bool, radiusMiles: Int, serviceTypes: [String], phone: String) async throws -> UserRecord
    func signIn(email: String, password: String) async throws -> UserRecord
    func completeAuthCallback(_ url: URL) async throws -> UserRecord?
    func verifyPhone() async throws -> UserRecord
    func verifyIdentity() async throws -> UserRecord
    func connectPayouts() async throws -> UserRecord
    func updateServiceArea(serviceTypes: [String], radiusMiles: Int, bio: String, avatarJPEG: Data?) async throws -> UserRecord
    func declineQuote(quoteID: UUID) async throws
    func signOut() async
    func refresh(_ user: UserRecord) async throws -> UserRecord
    func customerJobs() async throws -> [JobRecord]
    func openJobs() async throws -> [JobRecord]
    func priceJobs() async throws -> [JobRecord]
    func quotes(for jobID: UUID) async throws -> [QuoteRecord]
    func myQuotes() async throws -> [QuoteRecord]
    func bookings() async throws -> [BookingRecord]
    func postJob(category: ServiceCategory, street: String, city: String, state: String, zip: String, latitude: Double?, longitude: Double?, scheduledOn: String, details: JobDetails, photos: [Data], offeredPriceCents: Int, serviceType: String, estimate: PriceEstimate?, allowsMultiple: Bool, publish: Bool) async throws -> JobRecord
    func acceptListing(jobID: UUID) async throws -> BookingRecord
    func notices() async throws -> [NoticeRecord]
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
    func cachePhotos(_ names: [String]) async
}

enum PhotoStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("ContractorPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func compressedJPEG(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { render(data) }
        }.value
    }

    private nonisolated static func render(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let longest = max(image.size.width, image.size.height)
        let scaled: UIImage
        if longest > maxSide, longest > 0 {
            let ratio = maxSide / longest
            let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        } else {
            scaled = image
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    static func save(_ data: Data) async -> String? {
        guard let jpeg = await compressedJPEG(data) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
            if let image = UIImage(data: jpeg) {
                cache.setObject(image, forKey: name as NSString)
            }
            return name
        } catch {
            return nil
        }
    }

    static func image(_ name: String) -> UIImage? {
        let key = safe(name) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = folder.appendingPathComponent(safe(name))
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func write(_ name: String, data: Data) async {
        guard let jpeg = await compressedJPEG(data) else { return }
        let key = safe(name)
        if let image = UIImage(data: jpeg) {
            cache.setObject(image, forKey: key as NSString)
        }
        try? jpeg.write(to: folder.appendingPathComponent(key), options: .atomic)
    }

    static func has(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(safe(name)).path)
    }

    private static func safe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
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

    func signUp(role: UserRole, name: String, email: String, password: String, zip: String, business: String, categories: [ServiceCategory], serviceZips: [String], acceptedTerms: Bool, radiusMiles: Int, serviceTypes: [String], phone: String) async throws -> UserRecord {
        let user = try book.signUp(role: role, name: name, email: email, password: password, zip: zip, business: business, categories: categories, serviceZips: serviceZips, acceptedTerms: acceptedTerms, radiusMiles: radiusMiles, serviceTypes: serviceTypes, phone: phone)
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

    func completeAuthCallback(_ url: URL) async throws -> UserRecord? { nil }

    func verifyPhone() async throws -> UserRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let user = try book.verifyPhone(sessionID)
        persist()
        return user
    }

    func verifyIdentity() async throws -> UserRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let user = try book.verifyIdentity(sessionID)
        persist()
        return user
    }

    func connectPayouts() async throws -> UserRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let user = try book.connectPayouts(sessionID)
        persist()
        return user
    }

    func updateServiceArea(serviceTypes: [String], radiusMiles: Int, bio: String, avatarJPEG: Data?) async throws -> UserRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        var avatarPath = ""
        if let avatarJPEG {
            let name = "\(sessionID.uuidString)/profile.jpg"
            await PhotoStore.write(name, data: avatarJPEG)
            avatarPath = name
        }
        let user = try book.updateServiceArea(proID: sessionID, serviceTypes: serviceTypes, radiusMiles: radiusMiles, bio: bio, avatarPath: avatarPath)
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

    func priceJobs() async throws -> [JobRecord] {
        book.jobs.filter { job in
            job.offeredPriceCents > 0 && job.status.isListed
        }
        .map { $0.publicPriceCopy() }
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

    func postJob(category: ServiceCategory, street: String, city: String, state: String, zip: String, latitude: Double?, longitude: Double?, scheduledOn: String, details: JobDetails, photos: [Data], offeredPriceCents: Int, serviceType: String, estimate: PriceEstimate?, allowsMultiple: Bool, publish: Bool) async throws -> JobRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        var names: [String] = []
        for photo in photos {
            if let name = await PhotoStore.save(photo) { names.append(name) }
        }
        let job = try book.postJob(customerID: sessionID, category: category, street: street, city: city, state: state, zip: zip, latitude: latitude, longitude: longitude, scheduledOn: scheduledOn, details: details, photoNames: names, offeredPriceCents: offeredPriceCents, serviceType: serviceType, estimate: estimate, allowsMultiple: allowsMultiple, publish: publish)
        persist()
        return job
    }

    func acceptListing(jobID: UUID) async throws -> BookingRecord {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        let booking = try book.acceptListing(proID: sessionID, jobID: jobID)
        persist()
        return booking
    }

    func notices() async throws -> [NoticeRecord] {
        guard let sessionID else { return [] }
        return book.notices.filter { $0.userID == sessionID }.sorted { $0.createdAt > $1.createdAt }
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

    func declineQuote(quoteID: UUID) async throws {
        guard let sessionID else { throw MarketplaceError.wrongAccount }
        try book.declineQuote(customerID: sessionID, quoteID: quoteID)
        persist()
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
        guard var record = book.user(id) else { return nil }
        if let sessionID, let viewer = book.user(sessionID), !book.canSeePhone(of: id, viewer: viewer) {
            record.phone = ""
        }
        return record
    }

    func job(id: UUID) async throws -> JobRecord? {
        guard let job = book.jobs.first(where: { $0.id == id }) else { return nil }
        guard let sessionID, let viewer = book.user(sessionID) else { return job.listingCopy() }
        return book.canSeeExactAddress(job, viewer: viewer) ? job : job.listingCopy()
    }

    func cachePhotos(_ names: [String]) async {}

    private func persist() {
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Live Supabase client. Used when SUPABASE_URL and SUPABASE_ANON_KEY are set.
/// Sign-up works with email confirmation on or off. No session means the person must confirm first.
@MainActor
final class SupabaseBackend: ContractorAPI {
    private let base: URL
    private let key: String
    private var accessToken: String?
    private var refreshToken: String?
    private var userID: UUID?

    init() {
        base = BackendConfig.supabaseURL!
        key = BackendConfig.anonKey
        accessToken = UserDefaults.standard.string(forKey: "contractor.access")
        refreshToken = UserDefaults.standard.string(forKey: "contractor.refresh")
        if let raw = UserDefaults.standard.string(forKey: "contractor.user") {
            userID = UUID(uuidString: raw)
        }
    }

    func restore() async throws -> UserRecord? {
        guard accessToken != nil || refreshToken != nil else { return nil }
        if accessToken == nil || Self.tokenExpired(accessToken) {
            guard await refreshed() else { return nil }
        }
        if let record = try? await currentUser() { return record }
        guard await refreshed() else { return nil }
        return try? await currentUser()
    }

    func signUp(role: UserRole, name: String, email: String, password: String, zip: String, business: String, categories: [ServiceCategory], serviceZips: [String], acceptedTerms: Bool, radiusMiles: Int, serviceTypes: [String], phone: String) async throws -> UserRecord {
        guard acceptedTerms else { throw MarketplaceError.termsRequired }
        guard USAddress.isValidZip(zip) else { throw MarketplaceError.invalid }
        let storedPhone: String
        if role == .pro {
            guard let number = USPhone.e164(phone) else { throw MarketplaceError.invalid }
            storedPhone = number
        } else {
            storedPhone = USPhone.e164(phone) ?? ""
        }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let metadata: [String: Any] = [
            "role": role.rawValue,
            "display_name": name,
            "zip": USAddress.normalizeZip(zip),
            "business_name": business,
            "categories": categories.map(\.rawValue),
            "service_zips": serviceZips.isEmpty ? [USAddress.normalizeZip(zip)] : serviceZips,
            "radius_miles": radiusMiles,
            "service_types": serviceTypes,
            "phone": storedPhone,
        ]
        let payload: [String: Any] = [
            "email": cleanEmail,
            "password": password,
            "data": metadata,
        ]
        let response: [String: Any]
        do {
            response = try await send(path: AuthCallback.signupPath(), method: "POST", body: payload, auth: false)
        } catch let MarketplaceError.server(message) {
            if message.lowercased().contains("already") {
                return try await signInAfterSignup(email: cleanEmail, password: password)
            }
            throw MarketplaceError.server(message)
        }
        do {
            try storeSession(response)
        } catch MarketplaceError.confirmEmail {
            return try await signInAfterSignup(email: cleanEmail, password: password)
        }
        try await ensureProfile(metadata: metadata, email: cleanEmail)
        return try await currentUser()
    }

    private func signInAfterSignup(email: String, password: String) async throws -> UserRecord {
        do {
            return try await signIn(email: email, password: password)
        } catch let MarketplaceError.server(message) where AuthCallback.needsEmailConfirmation(message) {
            throw MarketplaceError.confirmEmail
        } catch {
            throw error
        }
    }

    func signIn(email: String, password: String) async throws -> UserRecord {
        let payload = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "password": password,
        ]
        let response = try await send(path: "/auth/v1/token?grant_type=password", method: "POST", body: payload, auth: false)
        try storeSession(response)
        let user = (response["user"] as? [String: Any]) ?? [:]
        let metadata = (user["user_metadata"] as? [String: Any]) ?? [:]
        try await ensureProfile(metadata: metadata, email: payload["email"] ?? "")
        return try await currentUser()
    }

    func completeAuthCallback(_ url: URL) async throws -> UserRecord? {
        let params = AuthCallback.params(from: url)
        guard let access = params["access_token"], let refresh = params["refresh_token"],
              let user = Self.userID(fromJWT: access) else {
            return nil
        }
        try storeSession([
            "access_token": access,
            "refresh_token": refresh,
            "user": ["id": user.uuidString],
        ])
        if let authUser = try? await send(path: "/auth/v1/user", method: "GET", body: nil, auth: true) {
            let metadata = authUser["user_metadata"] as? [String: Any] ?? [:]
            let email = authUser["email"] as? String ?? ""
            try await ensureProfile(metadata: metadata, email: email)
        }
        return try await currentUser()
    }

    private static func userID(fromJWT token: String) -> UUID? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String else { return nil }
        return UUID(uuidString: subject)
    }

    func verifyPhone() async throws -> UserRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        _ = try await send(path: "/rest/v1/profiles?id=eq.\(userID.uuidString)", method: "PATCH", body: ["phone_verified": true], auth: true)
        return try await currentUser()
    }

    func verifyIdentity() async throws -> UserRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        _ = try await send(path: "/rest/v1/pro_profiles?id=eq.\(userID.uuidString)", method: "PATCH", body: ["identity_verified": true], auth: true)
        return try await currentUser()
    }

    func connectPayouts() async throws -> UserRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        _ = try await send(path: "/rest/v1/pro_profiles?id=eq.\(userID.uuidString)", method: "PATCH", body: ["payouts_ready": true, "stripe_account_id": ""], auth: true)
        return try await currentUser()
    }

    func updateServiceArea(serviceTypes: [String], radiusMiles: Int, bio: String, avatarJPEG: Data?) async throws -> UserRecord {
        guard let userID else { throw MarketplaceError.wrongAccount }
        let categories = ServiceCatalog.categories(in: serviceTypes).map(\.rawValue)
        var avatarPath = ""
        if let avatarJPEG, let uploaded = try? await upload(avatarJPEG) {
            avatarPath = uploaded
            await PhotoStore.write(uploaded, data: avatarJPEG)
        }
        var body: [String: Any] = [
            "service_types": serviceTypes,
            "categories": categories,
            "radius_miles": radiusMiles,
            "bio": bio.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if !avatarPath.isEmpty { body["avatar_path"] = avatarPath }
        do {
            _ = try await send(path: "/rest/v1/pro_profiles?id=eq.\(userID.uuidString)", method: "PATCH", body: body, auth: true)
        } catch {
            body.removeValue(forKey: "bio")
            body.removeValue(forKey: "avatar_path")
            _ = try await send(path: "/rest/v1/pro_profiles?id=eq.\(userID.uuidString)", method: "PATCH", body: body, auth: true)
        }
        return try await currentUser()
    }

    func declineQuote(quoteID: UUID) async throws {
        _ = try await send(path: "/rest/v1/quotes?id=eq.\(quoteID.uuidString)", method: "PATCH", body: ["status": "declined"], auth: true)
    }

    func signOut() async {
        clearSession()
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
        let jobs = try await listedJobs()
        return jobs.filter { job in
            job.status.isListed && me.reaches(job)
        }
    }

    func priceJobs() async throws -> [JobRecord] {
        let rows: [PricePinDTO] = try await get("/rest/v1/price_board?select=*&order=created_at.desc")
        return rows.map { pin in
            JobRecord(
                id: pin.id,
                customerID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                category: pin.category,
                street: "",
                city: pin.city,
                state: pin.state,
                zip: pin.zip,
                latitude: pin.latitude,
                longitude: pin.longitude,
                scheduledOn: pin.scheduledOn,
                details: .empty,
                status: pin.status,
                photoNames: [],
                createdAt: pin.createdAt,
                serviceType: pin.serviceType,
                offeredPriceCents: pin.offeredPriceCents,
                estimatedMinutes: pin.estimatedMinutes
            )
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

    func postJob(category: ServiceCategory, street: String, city: String, state: String, zip: String, latitude: Double?, longitude: Double?, scheduledOn: String, details: JobDetails, photos: [Data], offeredPriceCents: Int, serviceType: String, estimate: PriceEstimate?, allowsMultiple: Bool, publish: Bool) async throws -> JobRecord {
        guard let userID, accessToken != nil else { throw MarketplaceError.needsSignIn }
        let me = try await currentUser()
        guard me.role == .customer else { throw MarketplaceError.wrongAccount }
        if publish && offeredPriceCents <= 0 { throw MarketplaceError.invalid }
        var names: [String] = []
        for photo in photos {
            names.append(try await upload(photo))
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
                "lotSize": details.lotSize,
                "rooms": details.rooms,
                "stairs": details.stairs,
                "obstacles": details.obstacles,
                "notes": details.notes,
            ],
            "status": publish ? "awaitingAcceptance" : "draft",
            "photo_names": names,
            "service_type": serviceType.isEmpty ? category.defaultType : serviceType,
            "offered_price_cents": offeredPriceCents,
            "allows_multiple": allowsMultiple,
            "estimated_minutes": estimate?.estimatedMinutes ?? 0,
        ]
        var payload = body
        if let estimate {
            payload["estimate"] = [
                "lowCents": estimate.lowCents,
                "highCents": estimate.highCents,
                "suggestedCents": estimate.suggestedCents,
                "estimatedMinutes": estimate.estimatedMinutes,
                "difficulty": estimate.difficulty,
                "explanation": estimate.explanation,
                "assumptions": estimate.assumptions,
                "rateName": estimate.rateName,
                "disclaimer": estimate.disclaimer,
                "isGuaranteedQuote": false,
            ] as [String: Any]
        }
        let rows: [JobRecord] = try await post("/rest/v1/jobs", body: payload)
        guard let job = rows.first else { throw MarketplaceError.missing }
        return job
    }

    func acceptListing(jobID: UUID) async throws -> BookingRecord {
        let json = try await send(path: "/rest/v1/rpc/accept_listing", method: "POST", body: ["p_job_id": jobID.uuidString], auth: true)
        let data = try JSONSerialization.data(withJSONObject: json)
        return try decoder().decode(BookingRecord.self, from: data)
    }

    func notices() async throws -> [NoticeRecord] {
        guard let userID else { return [] }
        return try await get("/rest/v1/notices?user_id=eq.\(userID.uuidString)&select=*&order=created_at.desc")
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
        let json = try await send(path: "/rest/v1/rpc/accept_offer", method: "POST", body: ["p_offer_id": quoteID.uuidString], auth: true)
        let data = try JSONSerialization.data(withJSONObject: json)
        return try decoder().decode(BookingRecord.self, from: data)
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
        let json: [String: Any]
        if let card = try? await send(path: "/rest/v1/rpc/profile_card", method: "POST", body: ["p_id": id.uuidString], auth: true),
           card["id"] != nil {
            json = card
        } else {
            let profiles: [ProfileDTO] = try await get("/rest/v1/profiles?id=eq.\(id.uuidString)&select=id,role,email,display_name,zip,phone_verified")
            guard let profile = profiles.first else { return nil }
            json = [
                "id": profile.id.uuidString,
                "role": profile.role.rawValue,
                "email": profile.email ?? "",
                "display_name": profile.displayName,
                "zip": profile.zip,
                "phone_verified": profile.phoneVerified,
            ]
        }
        guard let idString = json["id"] as? String, let uuid = UUID(uuidString: idString) else { return nil }
        let role = UserRole(rawValue: json["role"] as? String ?? "") ?? .customer
        let pros: [ProDTO] = (try? await get("/rest/v1/pro_profiles?id=eq.\(id.uuidString)&select=*")) ?? []
        let pro = pros.first
        return UserRecord(
            id: uuid,
            role: role,
            email: json["email"] as? String ?? "",
            displayName: json["display_name"] as? String ?? "",
            zip: json["zip"] as? String ?? "",
            phoneVerified: json["phone_verified"] as? Bool ?? false,
            businessName: pro?.businessName ?? "",
            categories: pro?.categories ?? [],
            serviceZips: pro?.serviceZips ?? [],
            radiusMiles: pro?.radiusMiles ?? 25,
            latitude: pro?.latitude,
            longitude: pro?.longitude,
            rating: pro?.rating ?? 0,
            reviewCount: pro?.reviewCount ?? 0,
            serviceTypes: pro?.serviceTypes ?? [],
            identityVerified: pro?.identityVerified ?? false,
            payoutsReady: pro?.payoutsReady ?? false,
            stripeAccountID: pro?.stripeAccountID ?? "",
            phone: json["phone"] as? String ?? "",
            bio: pro?.bio,
            avatarPath: pro?.avatarPath
        )
    }

    func job(id: UUID) async throws -> JobRecord? {
        let me = try? await currentUser()
        if me?.role == .pro {
            if let listed = try? await firstJob("/rest/v1/pro_open_jobs?id=eq.\(id.uuidString)&select=*") {
                return listed
            }
            if let board = try? await firstJob("/rest/v1/job_board?id=eq.\(id.uuidString)&select=*") {
                return board
            }
            if let listing = try? await listingRecord(id) {
                return listing
            }
        }
        if let owned = try? await firstJob("/rest/v1/jobs?id=eq.\(id.uuidString)&select=*") {
            return owned
        }
        return try? await firstJob("/rest/v1/job_board?id=eq.\(id.uuidString)&select=*")
    }

    /// Open jobs a pro is allowed to read. `jobs` itself is hidden until a booking.
    private func listedJobs() async throws -> [JobRecord] {
        if let rows: [JobRecord] = try? await get("/rest/v1/pro_open_jobs?select=*&order=created_at.desc") {
            return rows
        }
        if let rows: [JobRecord] = try? await get("/rest/v1/job_board?status=in.(open,posted,awaitingAcceptance)&select=*") {
            return rows
        }
        let rows: [ListingDTO] = try await get("/rest/v1/job_listings?status=in.(open,posted,awaitingAcceptance)&select=*")
        return rows.map { $0.record() }
    }

    private func firstJob(_ path: String) async throws -> JobRecord? {
        let rows: [JobRecord] = try await get(path)
        return rows.first
    }

    private func listingRecord(_ id: UUID) async throws -> JobRecord? {
        let rows: [ListingDTO] = try await get("/rest/v1/job_listings?id=eq.\(id.uuidString)&select=*")
        return rows.first?.record()
    }

    private struct ListingDTO: Decodable {
        var id: UUID
        var customerID: UUID
        var category: ServiceCategory
        var city: String
        var state: String
        var zip: String
        var latitude: Double?
        var longitude: Double?
        var scheduledOn: String
        var details: JobDetails
        var status: JobStatus
        var photoNames: [String]
        var createdAt: Date
        var serviceType: String
        var offeredPriceCents: Int
        var allowsMultiple: Bool?
        var estimate: PriceEstimate?
        var estimatedMinutes: Int?
        var listedUntil: Date?

        func record() -> JobRecord {
            JobRecord(
                id: id,
                customerID: customerID,
                category: category,
                street: "",
                city: city,
                state: state,
                zip: zip,
                latitude: latitude,
                longitude: longitude,
                scheduledOn: scheduledOn,
                details: details,
                status: status,
                photoNames: photoNames,
                createdAt: createdAt,
                serviceType: serviceType,
                offeredPriceCents: offeredPriceCents,
                allowsMultiple: allowsMultiple ?? false,
                estimate: estimate,
                estimatedMinutes: estimatedMinutes ?? 0,
                listedUntil: listedUntil
            )
        }
    }

    private struct PricePinDTO: Decodable {
        var id: UUID
        var category: ServiceCategory
        var serviceType: String
        var city: String
        var state: String
        var zip: String
        var latitude: Double?
        var longitude: Double?
        var offeredPriceCents: Int
        var estimatedMinutes: Int
        var status: JobStatus
        var scheduledOn: String
        var createdAt: Date
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
        var serviceTypes: [String]?
        var identityVerified: Bool?
        var payoutsReady: Bool?
        var stripeAccountID: String?
        var bio: String?
        var avatarPath: String?
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func strings(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
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

    func cachePhotos(_ names: [String]) async {
        for name in names where !name.isEmpty && !PhotoStore.has(name) {
            guard let url = URL(string: "storage/v1/object/authenticated/job-photos/\(name)", relativeTo: base)?.absoluteURL else { continue }
            var request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(accessToken ?? key)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
            await PhotoStore.write(name, data: data)
        }
    }

    private func storeSession(_ json: [String: Any]) throws {
        let nested = json["session"] as? [String: Any]
        let token = (json["access_token"] as? String) ?? (nested?["access_token"] as? String)
        let user = (json["user"] as? [String: Any]) ?? (nested?["user"] as? [String: Any])
        let idString = (user?["id"] as? String) ?? (json["id"] as? String)
        guard let token, !token.isEmpty, let idString, let uuid = UUID(uuidString: idString) else {
            let pendingEmail = (user?["email"] as? String) ?? (json["email"] as? String)
            let pendingID = (user?["id"] as? String) ?? (json["id"] as? String)
            if pendingID != nil || pendingEmail != nil || json["confirmation_sent_at"] != nil || user?["confirmation_sent_at"] != nil {
                throw MarketplaceError.confirmEmail
            }
            throw MarketplaceError.invalid
        }
        accessToken = token
        refreshToken = (json["refresh_token"] as? String) ?? (nested?["refresh_token"] as? String)
        userID = uuid
        UserDefaults.standard.set(token, forKey: "contractor.access")
        UserDefaults.standard.set(refreshToken, forKey: "contractor.refresh")
        UserDefaults.standard.set(uuid.uuidString, forKey: "contractor.user")
    }

    private func clearSession() {
        accessToken = nil
        refreshToken = nil
        userID = nil
        UserDefaults.standard.removeObject(forKey: "contractor.access")
        UserDefaults.standard.removeObject(forKey: "contractor.refresh")
        UserDefaults.standard.removeObject(forKey: "contractor.user")
    }

    private func refreshed() async -> Bool {
        guard let refreshToken, !refreshToken.isEmpty else { return false }
        do {
            let json = try await send(path: "/auth/v1/token?grant_type=refresh_token", method: "POST", body: ["refresh_token": refreshToken], auth: false, retryUnauthorized: false)
            try storeSession(json)
            return true
        } catch let MarketplaceError.server(message) {
            let lower = message.lowercased()
            if lower.contains("invalid") || lower.contains("expired") || lower.contains("not found") || lower.contains("revoked") {
                clearSession()
            }
            print("Contractor session refresh failed: \(message)")
            return false
        } catch {
            print("Contractor session refresh failed: \(error)")
            return false
        }
    }

    private static func tokenExpired(_ token: String?) -> Bool {
        guard let token, let exp = userExpiry(fromJWT: token) else { return false }
        return Date().timeIntervalSince1970 > exp - 60
    }

    private static func userExpiry(fromJWT token: String) -> TimeInterval? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let exp = json["exp"] as? TimeInterval { return exp }
        if let exp = json["exp"] as? Int { return TimeInterval(exp) }
        return nil
    }

    private func ensureProfile(metadata: [String: Any], email: String) async throws {
        guard let userID else { return }
        if try await user(id: userID) != nil { return }
        let role = UserRole(rawValue: metadata["role"] as? String ?? "") ?? .customer
        let name = (metadata["display_name"] as? String) ?? "New member"
        let zip = USAddress.normalizeZip(metadata["zip"] as? String ?? "")
        guard USAddress.isValidZip(zip) else { return }
        var profile: [String: Any] = [
            "id": userID.uuidString,
            "role": role.rawValue,
            "email": email,
            "display_name": name,
            "zip": zip,
            "phone_verified": false,
        ]
        if let number = metadata["phone"] as? String, !number.isEmpty {
            profile["phone"] = number
        }
        _ = try? await send(path: "/rest/v1/profiles", method: "POST", body: profile, auth: true)
        if role == .pro {
            let categories = Self.strings(metadata["categories"])
            let zips = Self.strings(metadata["service_zips"])
            let types = Self.strings(metadata["service_types"])
            let radius = metadata["radius_miles"] as? Int ?? 25
            let pro: [String: Any] = [
                "id": userID.uuidString,
                "business_name": metadata["business_name"] as? String ?? "",
                "categories": categories,
                "service_zips": zips.isEmpty ? [zip] : zips,
                "radius_miles": radius,
                "service_types": types,
                "identity_verified": false,
                "payouts_ready": false,
                "stripe_account_id": "",
            ]
            _ = try? await send(path: "/rest/v1/pro_profiles", method: "POST", body: pro, auth: true)
        }
    }

    private func upload(_ data: Data) async throws -> String {
        guard let userID, let accessToken else { throw MarketplaceError.needsSignIn }
        guard let jpeg = await PhotoStore.compressedJPEG(data) else {
            throw MarketplaceError.server("That photo could not be saved.")
        }
        let name = "\(userID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        guard let uploadURL = URL(string: "storage/v1/object/job-photos/\(name)", relativeTo: base)?.absoluteURL else {
            throw MarketplaceError.invalid
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarketplaceError.server("Photo upload failed.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.serverMessage(from: body, status: http.statusCode)
            print("Contractor photo upload failed: \(http.statusCode) \(message)")
            if http.statusCode == 401 { throw MarketplaceError.needsSignIn }
            throw MarketplaceError.server(message)
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

    private func send(path: String, method: String, body: [String: Any]?, auth: Bool, represent: Bool = false, retryUnauthorized: Bool = true) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw MarketplaceError.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if represent { request.setValue("return=representation", forHTTPHeaderField: "Prefer") }
        if auth {
            guard let accessToken else { throw MarketplaceError.needsSignIn }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarketplaceError.server("The request failed.") }
        if http.statusCode == 401, auth, retryUnauthorized {
            if await refreshed() {
                return try await send(path: path, method: method, body: body, auth: auth, represent: represent, retryUnauthorized: false)
            }
            throw MarketplaceError.needsSignIn
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.serverMessage(from: data, status: http.statusCode)
            print("Contractor API \(method) \(path) failed: \(http.statusCode) \(message)")
            throw MarketplaceError.server(message)
        }
        if data.isEmpty { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any] { return dictionary }
        if let array = object as? [Any] { return ["rows": array] }
        return [:]
    }

    private static func serverMessage(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let parts = ["message", "error_description", "msg", "hint", "details", "error"].compactMap { key -> String? in
                guard let value = json[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            if let first = parts.first { return first }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return "The request failed (\(status))."
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
