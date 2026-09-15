import Foundation

// First-party Apple Mail capabilities.
//   mail.recent         → recent inbox messages       (.low)
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
        registerSearch(registry)
        registerCurrentMessage(registry)
        registerCreateDraft(registry)
    }

    // MARK: - mail.search

    private static func registerSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.search",
                title: "Search Mail",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "sender", description: "Match messages whose sender contains this", required: false),
                    .init(name: "subject", description: "Match messages whose subject contains this", required: false),
                    .init(name: "unreadOnly", description: "\"true\" to return only unread messages", required: false),
                    .init(name: "day", description: "Optional relative day: \"today\" or \"yesterday\"", required: false),
                    .init(name: "limit", description: "Maximum messages to return (default 20)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                let sender = request.input["sender"] ?? ""
                let subject = request.input["subject"] ?? ""
                let unreadOnly = (request.input["unreadOnly"] ?? "").lowercased() == "true"
                let day = request.input["day"] ?? ""
                let limit = max(1, min(Int(request.input["limit"] ?? "20") ?? 20, 50))
                // A search with no filter at all is mail.recent wearing a different name, and
                // scanning the mailbox to say so is slow enough for the user to notice.
                guard !sender.isEmpty || !subject.isEmpty || unreadOnly || !day.isEmpty else {
                    throw AICapabilityError.missingInput("sender, subject, unreadOnly or day")
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

    // MARK: - mail.currentMessage

    private static func registerCurrentMessage(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "mail.currentMessage",
                title: "Read the Open Email",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                let message = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getSelectedEmail())
                    }
                }
                // Absence reported as absence. "Summarise this email" with nothing selected
                // has no answer, and inventing one is the failure this whole pass is about.
                guard let message else {
                    return .init(
                        success: true,
                        output: "No message is selected in Mail (or Mail isn't running).")
                }
                let subject = (message["subject"] as? String) ?? "(no subject)"
                let sender = (message["sender"] as? String) ?? "?"
                let date = (message["date"] as? String) ?? ""
                let body = (message["body"] as? String) ?? ""
                return .init(
                    success: true,
                    output: "Subject: \(subject)\nFrom: \(sender)\nDate: \(date)\n\n\(body)")
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
                riskLevel: .medium
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
                title: "Get Recent Emails",
                appBundleID: "com.apple.mail",
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "How many recent inbox messages (default 10)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.mailMCPEnabled else {
                    throw AICapabilityError.blocked("Mail access is disabled in Settings.")
                }
                let limit = max(1, min(Int(request.input["limit"] ?? "10") ?? 10, 40))
                let emails = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getRecentEmails(limit: limit))
                    }
                }
                if emails.isEmpty {
                    return .init(success: true, output: "No recent inbox messages (or Mail isn't running).")
                }
                let lines = emails.prefix(30).map { m -> String in
                    let subject = (m["subject"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "(no subject)"
                    let sender = (m["sender"] as? String) ?? "?"
                    let unread = (m["read"] as? Bool) == false ? "● " : ""
                    let date = (m["date"] as? String) ?? ""
                    return "\(unread)\(subject) — \(sender)\(date.isEmpty ? "" : " · \(date)")"
                }
                return .init(
                    success: true,
                    output: "Recent inbox (\(emails.count)):\n" + lines.joined(separator: "\n"))
            }
        )
    }
}
