import Foundation

/// First-party Messages tools for app-scoped chat. Reads are low-risk; composing opens
/// Messages for user review and never presses Send, so Context Dock cannot silently message.
@MainActor
enum AppleMessagesMCPCapabilities {
    static func register(in registry: CapabilityRegistry) {
        registerRecent(registry)
        registerSearch(registry)
        registerCompose(registry)
    }

    private static func registerRecent(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "messages.recent",
                title: "List Recent Messages Conversations",
                appBundleID: "com.apple.MobileSMS",
                inputSchema: .init(fields: [
                    .init(name: "contact", description: "Optional contact name or handle filter", required: false),
                    .init(name: "limit", description: "Maximum conversations, 1–30", required: false),
                ]),
                riskLevel: .low
            ) { request in
                try ensureEnabled()
                let contact = request.input["contact"] ?? ""
                let limit = max(1, min(Int(request.input["limit"] ?? "15") ?? 15, 30))
                let output = await Task.detached(priority: .userInitiated) {
                    MessagesAutomation.conversationSnapshot(contactFilter: contact, limit: limit)
                }.value
                return .init(success: true, output: output)
            }
        )
    }

    private static func registerSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "messages.search",
                title: "Search in Messages",
                appBundleID: "com.apple.MobileSMS",
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Contact, keyword, or phrase", required: true)
                ]),
                riskLevel: .low
            ) { request in
                try ensureEnabled()
                guard let query = request.input["query"], !query.isEmpty else {
                    throw AICapabilityError.missingInput("query")
                }
                let output = await MessagesAutomation.openSearch(query: query)
                return .init(success: !output.hasPrefix("❌"), output: output)
            }
        )
    }

    private static func registerCompose(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "messages.compose",
                title: "Open a Message for Review",
                appBundleID: "com.apple.MobileSMS",
                inputSchema: .init(fields: [
                    .init(name: "recipient", description: "Contact name, phone number, or Apple ID", required: true),
                    .init(name: "body", description: "Optional draft text for the user to review", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                try ensureEnabled()
                guard let recipient = request.input["recipient"], !recipient.isEmpty else {
                    throw AICapabilityError.missingInput("recipient")
                }
                let output = await MessagesAutomation.composeMessage(
                    to: recipient, body: request.input["body"] ?? "")
                return .init(success: !output.hasPrefix("❌"), output: output)
            }
        )
    }

    private static func ensureEnabled() throws {
        guard AppSettings.shared.messagesMCPEnabled else {
            throw AICapabilityError.blocked("Messages access is disabled in Settings.")
        }
    }
}
