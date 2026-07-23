import Foundation

// First-party Apple Mail capabilities. Wraps AppleAppsAPI (AppleScript) reads.
//   mail.recent → recent inbox messages (read-only → .low)

@MainActor
enum AppleMailMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerRecent(registry)
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
