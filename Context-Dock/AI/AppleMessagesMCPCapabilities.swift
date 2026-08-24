import Foundation

/// First-party Messages tools for app-scoped chat. Reads are low-risk; composing opens
/// Messages for user review and never presses Send, so Context Dock cannot silently message.
@MainActor
enum AppleMessagesMCPCapabilities {
    static func register(in registry: CapabilityRegistry) {
        registerRecent(registry)
        registerSearch(registry)
        registerCompose(registry)
        registerTopCorrespondents(registry)
    }

    /// Who the user messages most — a count, which nothing else here could do.
    ///
    /// Every other Messages tool answers "what happened lately": recent conversations, a
    /// search, a draft. Asked who they talk to most, the model was handed a recent-items list
    /// and asked to rank from it, and correctly refused — recency is not frequency, and the
    /// one clearly named thread in a recent list is not the top contact. The missing tool was
    /// the one that counts.
    private static func registerTopCorrespondents(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "messages.topContacts",
                title: "Who You Message Most (ranked by count)",
                appBundleID: "com.apple.MobileSMS",
                inputSchema: .init(fields: [
                    .init(
                        name: "limit", description: "How many people to rank, 1–50",
                        required: false),
                    .init(
                        name: "days",
                        description: "Only count the last N days. Omit to count all history.",
                        required: false),
                ]),
                riskLevel: .low
            ) { request in
                try ensureEnabled()
                let limit = max(1, min(Int(request.input["limit"] ?? "10") ?? 10, 50))
                let days = request.input["days"].flatMap(Int.init)
                let output = await Task.detached(priority: .userInitiated) {
                    MessagesInsights.topCorrespondentsReport(limit: limit, days: days)
                }.value
                return .init(success: true, output: output)
            }
        )
    }

    private static func registerRecent(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "messages.recent",
                title: "List Recent Messages Conversations (recent, NOT ranked by volume)",
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
                    () -> String in
                    // AppleScript first, and only while Messages is already open: asking it
                    // anything launches the app, and reading someone's conversations should
                    // never spring a window onto their screen.
                    let scripted = MessagesAutomation.conversationSnapshot(
                        contactFilter: contact, limit: limit)
                    if !scripted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return scripted
                    }
                    // Messages closed, or AppleScript refused. The database says the same
                    // thing without opening anything — it was already written and this
                    // capability simply never called it.
                    guard let rows = MessagesChatDBReader.recent(limit: limit, contact: contact),
                        !rows.isEmpty
                    else { return "" }
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    return rows.map { row in
                        let who = row.handle.isEmpty ? "(group)" : row.handle
                        let direction = row.fromMe ? "you → \(who)" : "\(who) → you"
                        return "\(formatter.string(from: row.date)) · \(direction): "
                            + row.text.prefix(160)
                    }.joined(separator: "\n")
                }.value

                // An empty string was being returned as a success. The model received
                // nothing, reported "the Messages conversation list wasn't accessible", and
                // stopped — with the database reader sitting right there unused. Empty is a
                // failure, and a failure has to say what to do about it.
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .init(
                        success: false,
                        output: "No conversations could be read. Messages is not open, so "
                            + "AppleScript is unavailable, and the message database returned "
                            + "nothing — usually because DoraX lacks Full Disk Access "
                            + "(System Settings → Privacy & Security → Full Disk Access). "
                            + "For counts and rankings use messages.topContacts, which reads "
                            + "the database directly. Do not describe this as \"no messages\": "
                            + "it is a read that did not happen.")
                }
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
