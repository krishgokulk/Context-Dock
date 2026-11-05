import Foundation

// First-party Apple Mail capabilities.
//   mail.recent         → recent inbox headers + the newest body   (.low)
//   mail.read           → one message's body by id (default: newest) (.low)
//   mail.search         → filtered mailbox search     (.low)
//   mail.currentMessage → the message on screen       (.low)
//   mail.createDraft    → opens a composer            (.medium, approval)
//
// There is deliberately no mail.send. Drafting is built on `mailto:`, which has no send verb,
// so this adapter cannot send mail however it is asked — the composer opens and the user
// presses Send. Note that Mail's *menu* can still reach Message ▸ Send; that route is gated
// separately by AppMenuConsentStore's outbound word list.

@MainActor
enum AppleMailMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerRecent(registry)
        registerRead(registry)
        registerSearch(registry)
        registerUnread(registry)
        registerCurrentMessage(registry)
        registerCreateDraft(registry)
        registerSend(registry)
    }

    // MARK: - mail.unread

    private static func registerUnread(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.unread",
                title: "Get Unread Emails",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "Maximum unread messages to return (default 20)", required: false),
                    .init(name: "sender", description: "Optional sender filter", required: false),
                    .init(name: "subject", description: "Optional subject filter", required: false),
                ]),
                riskLevel: .low,
                needsRunningApp: true
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                let limit = max(1, min(Int(request.input["limit"] ?? "20") ?? 20, 50))
                let sender = request.input["sender"] ?? ""
                let subject = request.input["subject"] ?? ""
                let summary = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: MailAutomation.mailboxSnapshot(
                            senderContains: sender,
                            subjectContains: subject,
                            unreadOnly: true,
                            relativeDay: "",
                            limit: limit
                        ))
                    }
                }
                return .init(success: true, output: summary)
            }
        )
    }

    // MARK: - mail.search

    private static func registerSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.search",
                title: "Search Mail",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Search keyword matching sender or subject", required: false),
                    .init(name: "sender", description: "Match messages whose sender contains this", required: false),
                    .init(name: "subject", description: "Match messages whose subject contains this", required: false),
                    .init(name: "unreadOnly", description: "\"true\" to return only unread messages", required: false),
                    .init(name: "day", description: "Optional relative day: \"today\" or \"yesterday\"", required: false),
                    .init(name: "limit", description: "Maximum messages to return (default 20)", required: false),
                ]),
                riskLevel: .low,
                needsRunningApp: true
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                let query = request.input["query"] ?? ""
                var sender = request.input["sender"] ?? ""
                var subject = request.input["subject"] ?? ""
                let unreadOnly = (request.input["unreadOnly"] ?? "").lowercased() == "true"
                let day = request.input["day"] ?? ""
                let limit = max(1, min(Int(request.input["limit"] ?? "20") ?? 20, 50))

                if !query.isEmpty && sender.isEmpty && subject.isEmpty {
                    subject = query
                }

                // A search with no filter at all is mail.recent wearing a different name, and
                // scanning the mailbox to say so is slow enough for the user to notice.
                guard !query.isEmpty || !sender.isEmpty || !subject.isEmpty || unreadOnly || !day.isEmpty else {
                    throw AICapabilityError.missingInput("query, sender, subject, unreadOnly or day")
                }
                let summary = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: MailAutomation.mailboxSnapshot(
                            senderContains: sender, subjectContains: subject,
                            unreadOnly: unreadOnly, relativeDay: day, limit: limit))
                    }
                }
                return .init(success: true, output: summary)
            }
        )
    }

    // MARK: - mail.send

    private static func registerSend(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.send",
                title: "Send Email (with approval)",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "to", description: "Recipient contact name or email address", required: true),
                    .init(name: "subject", description: "Subject line", required: true),
                    .init(name: "body", description: "Message body text", required: true),
                ]),
                riskLevel: .high,
                needsRunningApp: true
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                guard let to = request.input["to"], !to.isEmpty else {
                    throw AICapabilityError.missingInput("to")
                }
                guard let subject = request.input["subject"], !subject.isEmpty else {
                    throw AICapabilityError.missingInput("subject")
                }
                guard let body = request.input["body"], !body.isEmpty else {
                    throw AICapabilityError.missingInput("body")
                }

                let result = await MailAutomation.sendMail(to: to, subject: subject, body: body)
                return .init(success: result.success, output: result.message)
            }
        )
    }

    // MARK: - mail.currentMessage

    private static func registerCurrentMessage(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.currentMessage",
                title: "Read the selected or open email, body included",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: []),
                riskLevel: .low,
                needsRunningApp: true
            ) { _ in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                // Absence reported as absence, and only when Mail was asked and had nothing:
                // "summarise this email" with nothing selected has no answer, and inventing
                // one is the failure this whole pass is about. The body is fenced and capped.
                let outcome = await MailReader.selected(using: LiveMailSource())
                return .init(success: outcome.success, output: outcome.output)
            }
        )
    }

    // MARK: - mail.createDraft

    private static func registerCreateDraft(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.createDraft",
                title: "Open a Draft Email",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "to", description: "Recipient address (optional)", required: false),
                    .init(name: "subject", description: "Subject line", required: true),
                    .init(name: "body", description: "Message body", required: false),
                ]),
                riskLevel: .medium,
                surface: .opensApp  // opens the Mail composer window (#307)
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                guard let subject = request.input["subject"], !subject.isEmpty else {
                    throw AICapabilityError.missingInput("subject")
                }
                let recipient = request.input["to"] ?? ""
                let body = request.input["body"] ?? ""
                let opened = AppleAppsAPI.shared.composeMail(
                    to: recipient, subject: subject, body: body)
                // The claim is only ever "a composer opened", never "the mail was sent" —
                // this path has no way to send, and saying otherwise would be a lie the user
                // would only discover in their Sent folder, or not at all.
                return .init(
                    success: opened,
                    output: opened
                        ? "Opened a draft to \(recipient.isEmpty ? "no recipient yet" : recipient) — review it and press Send yourself."
                        : "Couldn't open a draft composer.")
            }
        )
    }

    private static func registerRecent(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.recent",
                title: "Get recent emails (headers with ids) and read the newest one's body",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "How many recent inbox messages (default 10)", required: false)
                ]),
                riskLevel: .low,
                needsRunningApp: true
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                let limit = Int(request.input["limit"] ?? "10") ?? 10
                let outcome = await MailReader.recent(limit: limit, using: LiveMailSource())
                return .init(success: outcome.success, output: outcome.output)
            }
        )
    }

    // MARK: - mail.read

    private static func registerRead(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.read",
                title: "Read an email's full body (the latest one, or by id from mail.recent)",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "id", description: "Message id from mail.recent; leave empty for the latest message", required: false)
                ]),
                riskLevel: .low,
                needsRunningApp: true
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                let outcome = await MailReader.read(
                    id: request.input["id"] ?? "", using: LiveMailSource())
                return .init(success: outcome.success, output: outcome.output)
            }
        )
    }
}
