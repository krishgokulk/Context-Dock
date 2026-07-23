import Foundation

// First-party Apple Contacts capabilities registered in CapabilityRegistry.
// Wraps AppleAppsAPI (CNContacts) — no AppleScript required.
// Risk levels:
//   contacts.search  → .low (read-only, no approval)
//   contacts.details → .low (read-only, no approval)

@MainActor
enum AppleContactsMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerSearch(registry)
        registerDetails(registry)
        registerCreate(registry)
    }

    // MARK: - contacts.create

    private static func registerCreate(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "contacts.create",
                title: "Create Contact",
                appBundleID: "com.apple.AddressBook",
                inputSchema: .init(fields: [
                    .init(name: "firstName", description: "Contact's first name", required: true),
                    .init(name: "lastName", description: "Last name", required: false),
                    .init(name: "phone", description: "Phone number", required: false),
                    .init(name: "email", description: "Email address", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                guard AppSettings.shared.contactsMCPEnabled else {
                    throw AICapabilityError.blocked("Contacts access is disabled in Settings.")
                }
                guard let firstName = request.input["firstName"], !firstName.isEmpty else {
                    throw AICapabilityError.missingInput("firstName")
                }
                let saved = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: AppleAppsAPI.shared.createContact(
                            firstName: firstName,
                            lastName: request.input["lastName"],
                            phone: request.input["phone"],
                            email: request.input["email"]))
                    }
                }
                return .init(
                    success: saved != nil,
                    output: saved.map { "Created contact '\($0)'." }
                        ?? "Failed to create contact — grant Contacts access in System Settings › Privacy.")
            }
        )
    }

    // MARK: - contacts.search

    private static func registerSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "contacts.search",
                title: "Search Contacts",
                appBundleID: "com.apple.AddressBook",
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Name, phone, or email to search for", required: true)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.contactsMCPEnabled else {
                    throw AICapabilityError.blocked("Contacts access is disabled in Settings.")
                }
                guard let query = request.input["query"], !query.isEmpty else {
                    throw AICapabilityError.missingInput("query")
                }
                let contacts = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.searchContacts(query: query))
                    }
                }
                if contacts.isEmpty {
                    return .init(success: true, output: "No contacts found matching '\(query)'.")
                }
                let lines = contacts.prefix(10).map { c -> String in
                    let name = c["fullName"] as? String ?? "Unknown"
                    let phone = c["phone"] as? String ?? ""
                    let email = c["email"] as? String ?? ""
                    var parts = [name]
                    if !phone.isEmpty { parts.append(phone) }
                    if !email.isEmpty { parts.append(email) }
                    return "• " + parts.joined(separator: " | ")
                }
                return .init(
                    success: true,
                    output: "Contacts matching '\(query)' (\(min(contacts.count, 10)) shown):\n\(lines.joined(separator: "\n"))"
                )
            }
        )
    }

    // MARK: - contacts.details

    private static func registerDetails(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "contacts.details",
                title: "Get Contact Details",
                appBundleID: "com.apple.AddressBook",
                inputSchema: .init(fields: [
                    .init(name: "name", description: "Full or partial name of the contact", required: true)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.contactsMCPEnabled else {
                    throw AICapabilityError.blocked("Contacts access is disabled in Settings.")
                }
                guard let name = request.input["name"], !name.isEmpty else {
                    throw AICapabilityError.missingInput("name")
                }
                let contacts = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.searchContacts(query: name))
                    }
                }
                guard let contact = contacts.first else {
                    return .init(success: false, output: "No contact found named '\(name)'.")
                }
                var lines: [String] = []
                if let full = contact["fullName"] as? String, !full.isEmpty {
                    lines.append("Name: \(full)")
                }
                if let phone = contact["phone"] as? String, !phone.isEmpty {
                    lines.append("Phone: \(phone)")
                }
                if let email = contact["email"] as? String, !email.isEmpty {
                    lines.append("Email: \(email)")
                }
                let note = contacts.count > 1 ? "\n(\(contacts.count - 1) more contact(s) also match)" : ""
                return .init(success: true, output: lines.joined(separator: "\n") + note)
            }
        )
    }
}
