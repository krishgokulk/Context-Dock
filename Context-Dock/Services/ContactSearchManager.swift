import Foundation
import Contacts
import AppKit
import Combine

final class ContactSearchManager: ObservableObject {
    static let shared = ContactSearchManager()

    private let store = CNContactStore()
    @Published private(set) var hasContactsPermission: Bool = false

    private init() {
        // Initialize permission state
        let status = CNContactStore.authorizationStatus(for: .contacts)
        self.hasContactsPermission = (status == .authorized)
    }

    @MainActor
    func requestPermission() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        print("👤 ContactSearchManager: Current status = \(status.rawValue) (.authorized=\(CNAuthorizationStatus.authorized.rawValue), .denied=\(CNAuthorizationStatus.denied.rawValue), .notDetermined=\(CNAuthorizationStatus.notDetermined.rawValue))")

        switch status {
        case .authorized:
            print("👤 ContactSearchManager: Already authorized")
            hasContactsPermission = true
            return true
        case .notDetermined:
            print("👤 ContactSearchManager: Not determined, requesting...")
            do {
                try await store.requestAccess(for: .contacts)
                let newStatus = CNContactStore.authorizationStatus(for: .contacts)
                print("👤 ContactSearchManager: After request, status = \(newStatus.rawValue)")
                hasContactsPermission = (newStatus == .authorized)
                return hasContactsPermission
            } catch {
                print("👤 ContactSearchManager: Request failed with error: \(error)")
                hasContactsPermission = false
                return false
            }
        default:
            print("👤 ContactSearchManager: Status is denied/restricted. User must enable in System Settings.")
            hasContactsPermission = false
            return false
        }
    }

    /// Check and update permission status (useful after user enables in System Settings)
    func checkPermission() -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        let authorized = (status == .authorized)
        if Thread.isMainThread {
            hasContactsPermission = authorized
        } else {
            DispatchQueue.main.async {
                self.hasContactsPermission = authorized
            }
        }
        print("👤 ContactSearchManager: checkPermission() = \(authorized) (status=\(status.rawValue))")
        return authorized
    }

    struct ContactResult {
        let identifier: String
        let givenName: String
        let familyName: String
        let primaryEmail: String
        let allEmails: [String]
        let primaryPhone: String
        let allPhones: [String]
        let image: NSImage?

        var fullName: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
        var subtitle: String {
            if !primaryEmail.isEmpty {
                return primaryEmail
            } else if !primaryPhone.isEmpty {
                return primaryPhone
            } else {
                return "No contact info"
            }
        }

        func openInContacts() {
            // Open the contact in Contacts app if possible
            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let keys: [CNKeyDescriptor] = [CNContactViewController.descriptorForRequiredKeys()] as [CNKeyDescriptor]
            // We cannot directly open a single contact by identifier via NSWorkspace, so open Contacts app
            if let url = URL(string: "addressbook:") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func getAllContacts() async -> [ContactResult] {
        // Perform contact fetching off the main actor to avoid UI unresponsiveness warnings.
        await withCheckedContinuation { (continuation: CheckedContinuation<[ContactResult], Never>) in
            Task.detached(priority: .utility) { [store] in
                let keysToFetch: [CNKeyDescriptor] = [
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactImageDataAvailableKey as CNKeyDescriptor,
                    CNContactThumbnailImageDataKey as CNKeyDescriptor,
                    CNContactIdentifierKey as CNKeyDescriptor
                ]

                var results: [ContactResult] = []
                let request = CNContactFetchRequest(keysToFetch: keysToFetch)
                request.unifyResults = true

                do {
                    try store.enumerateContacts(with: request) { contact, _ in
                        let allEmails = contact.emailAddresses.map { $0.value as String }
                        let primaryEmail = allEmails.first ?? ""

                        let allPhones = contact.phoneNumbers.map { $0.value.stringValue }
                        let primaryPhone = allPhones.first ?? ""

                        // Only include contacts that have at least a name, email or phone
                        if !(contact.givenName.isEmpty && contact.familyName.isEmpty) || !primaryEmail.isEmpty || !primaryPhone.isEmpty {
                            var image: NSImage? = nil
                            if contact.imageDataAvailable, let data = contact.thumbnailImageData, let nsImage = NSImage(data: data) {
                                image = nsImage
                            }
                            results.append(ContactResult(
                                identifier: contact.identifier,
                                givenName: contact.givenName,
                                familyName: contact.familyName,
                                primaryEmail: primaryEmail,
                                allEmails: allEmails,
                                primaryPhone: primaryPhone,
                                allPhones: allPhones,
                                image: image
                            ))
                        }
                    }
                } catch {
                    Swift.print("⚠️ Failed to enumerate contacts: \(error)")
                }

                continuation.resume(returning: results)
            }
        }
    }
}

// Import ContactsUI only when available for descriptor access
#if canImport(ContactsUI)
import ContactsUI
#endif
