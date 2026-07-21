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
        #if DEBUG
        print("👤 ContactSearchManager: Current status = \(status.rawValue) (.authorized=\(CNAuthorizationStatus.authorized.rawValue), .denied=\(CNAuthorizationStatus.denied.rawValue), .notDetermined=\(CNAuthorizationStatus.notDetermined.rawValue))")
        #endif

        switch status {
        case .authorized:
            #if DEBUG
            print("👤 ContactSearchManager: Already authorized")
            #endif
            hasContactsPermission = true
            return true
        case .notDetermined:
            #if DEBUG
            print("👤 ContactSearchManager: Not determined, requesting...")
            #endif
            do {
                try await store.requestAccess(for: .contacts)
                let newStatus = CNContactStore.authorizationStatus(for: .contacts)
                #if DEBUG
                print("👤 ContactSearchManager: After request, status = \(newStatus.rawValue)")
                #endif
                hasContactsPermission = (newStatus == .authorized)
                return hasContactsPermission
            } catch {
                #if DEBUG
                print("👤 ContactSearchManager: Request failed with error: \(error)")
                #endif
                hasContactsPermission = false
                return false
            }
        default:
            #if DEBUG
            print("👤 ContactSearchManager: Status is denied/restricted. User must enable in System Settings.")
            #endif
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
        #if DEBUG
        print("👤 ContactSearchManager: checkPermission() = \(authorized) (status=\(status.rawValue))")
        #endif
        return authorized
    }

    struct ContactResult {
        let identifier: String
        let givenName: String
        let familyName: String
        let nickname: String
        let organizationName: String
        let primaryEmail: String
        let allEmails: [String]
        let primaryPhone: String
        let allPhones: [String]
        let image: NSImage?

        var fullName: String {
            let name = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { return name }
            if !nickname.isEmpty { return nickname }
            return organizationName
        }

        var searchableNameParts: [String] {
            [givenName, familyName, nickname, organizationName, fullName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

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
                    CNContactNicknameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
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
                                nickname: contact.nickname,
                                organizationName: contact.organizationName,
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

    func rankedContacts(matching query: String, limit: Int = 12) async -> [ContactResult] {
        let contacts = await getAllContacts()
        return Self.rankContacts(contacts, matching: query, limit: limit)
    }

    static func rankContacts(
        _ contacts: [ContactResult],
        matching query: String,
        limit: Int = 12
    ) -> [ContactResult] {
        let tokens = contactQueryTokens(from: query)
        guard !tokens.isEmpty else {
            return Array(contacts.prefix(limit))
        }

        let scored = contacts.compactMap { contact -> (ContactResult, Int)? in
            let fields = contact.searchableNameParts + contact.allEmails + contact.allPhones
            let normalizedFields = fields.map(normalizedContactText)
            let fieldWords = normalizedFields.flatMap { $0.split(separator: " ").map(String.init) }

            var score = 0
            for token in tokens {
                if normalizedFields.contains(token) {
                    score += 120
                } else if normalizedFields.contains(where: { $0.hasPrefix(token) }) {
                    score += 95
                } else if normalizedFields.contains(where: { $0.contains(token) }) {
                    score += 80
                } else if fieldWords.contains(where: { fuzzyWordMatch(token, $0) }) {
                    score += 55
                }
            }

            if tokens.count > 1 {
                let joinedQuery = tokens.joined(separator: " ")
                if normalizedFields.contains(where: { $0.contains(joinedQuery) }) {
                    score += 60
                }
            }

            guard score > 0 else { return nil }
            return (contact, score)
        }

        return scored
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.fullName.localizedCaseInsensitiveCompare($1.0.fullName) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    static func contactQueryTokens(from query: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "can", "contact", "contacts", "detail", "details",
            "email", "find", "for", "from", "get", "give", "have", "info", "information",
            "is", "me", "my", "name", "named", "number", "of", "phone", "please", "show",
            "tell", "the", "their", "to", "what", "whats", "who",
        ]

        var seen = Set<String>()
        return normalizedContactText(query)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizedContactText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : " "
            }
            .reduce(into: "") { partial, character in
                if character == " ", partial.last == " " { return }
                partial.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fuzzyWordMatch(_ query: String, _ word: String) -> Bool {
        guard query.count >= 4, word.count >= 4 else { return false }
        if word.hasPrefix(query) || query.hasPrefix(word) { return true }
        let maxDistance = max(query.count, word.count) <= 5 ? 1 : 2
        return levenshteinDistance(query, word, maxDistance: maxDistance) <= maxDistance
    }

    private static func levenshteinDistance(
        _ lhs: String,
        _ rhs: String,
        maxDistance: Int
    ) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > maxDistance { return maxDistance + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maxDistance { return maxDistance + 1 }
            swap(&previous, &current)
        }

        return previous[b.count]
    }
}

// Import ContactsUI only when available for descriptor access
#if canImport(ContactsUI)
import ContactsUI
#endif
