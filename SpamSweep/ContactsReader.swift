import Contacts
import Foundation

enum ContactsReader {
    static var isAuthorized: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        if #available(iOS 18.0, *), status == .limited { return true }
        return false
    }

    static func loadIfAllowed() -> Set<String> {
        guard isAuthorized else { return [] }
        return read(CNContactStore())
    }

    static func request() async -> Set<String> {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted || isAuthorized else { return [] }
        return read(store)
    }

    private static func read(_ store: CNContactStore) -> Set<String> {
        let keys = [CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var emails = Set<String>()
        try? store.enumerateContacts(with: request) { contact, _ in
            for labeled in contact.emailAddresses {
                let email = (labeled.value as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if email.contains("@") {
                    emails.insert(email)
                }
            }
        }
        return emails
    }
}
