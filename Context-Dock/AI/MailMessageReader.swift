// MailMessageReader.swift
// Context-Dock
//
// Reading one mail message, body included, for every surface that reads mail.
//
// "Read my latest email" means the body. The recent-mail reader returned a header line per
// message, so the model answered with sender, subject and date and asked the user to open the
// message by hand; with Mail closed the chat could not read mail at all. This is the one place
// that turns "a message" into text a model sees, so the Dock, the Corner and the Chat Window
// (all of which run the same `mail.*` capabilities) behave identically.
//
// A mail body is third-party text, the textbook prompt injection. Every message leaves here
// fenced (`UntrustedContent.fenced`) and capped; the turn taint tracker counts any `mail.*`
// read as private + untrusted on its own (`OutboundGate.readsThirdPartyContent`).
//
// The store is a protocol so tests drive the reader with a fake mailbox and no Mail.

import AppKit
import Foundation

nonisolated struct MailMessage: Equatable, Sendable {
    var id: String
    var subject: String
    var sender: String
    var date: String
    var read: Bool
    var body: String

    init(
        id: String = "", subject: String, sender: String, date: String = "",
        read: Bool = true, body: String = ""
    ) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.date = date
        self.read = read
        self.body = body
    }

    /// From the dictionaries `AppleAppsAPI` returns.
    init(_ record: [String: Any]) {
        self.init(
            id: (record["id"] as? String) ?? "",
            subject: ((record["subject"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            sender: (record["sender"] as? String) ?? "?",
            date: (record["date"] as? String) ?? "",
            read: (record["read"] as? Bool) ?? true,
            body: (record["body"] as? String) ?? "")
    }
}

/// Where messages come from. Every call is blocking and runs off the main thread.
nonisolated protocol MailSource: Sendable {
    var isRunning: Bool { get }
    /// Starts Mail without activating it, and reports whether it is now running.
    func launchQuietly() async -> Bool
    /// Newest first, bodies empty.
    func recent(limit: Int) -> [MailMessage]
    /// The newest inbox message, body included.
    func latest() -> MailMessage?
    /// One inbox message by id, body included.
    func message(id: String) -> MailMessage?
    /// The message selected or open in Mail's viewer, body included.
    func selected() -> MailMessage?
}

nonisolated struct MailReadOutcome: Equatable, Sendable {
    let success: Bool
    let output: String
    /// True when `output` is a message (so "nothing selected" was not what was found).
    var hasMessage: Bool = false
}

nonisolated enum MailReader {

    /// Characters of one body a model sees. Longer bodies end with a marker saying so.
    static let bodyBudget = 8_000

    /// How many headers `recent` lists.
    static let listLimit = 30

    // MARK: - Rendering

    /// One message as the model sees it. Headers and body sit inside one fence: a hostile
    /// sender chooses the subject and the body alike.
    static func render(_ message: MailMessage) -> String {
        let trimmed = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var text =
            "Subject: \(message.subject.isEmpty ? "(no subject)" : message.subject)\n"
            + "From: \(message.sender)\n"
        if !message.date.isEmpty { text += "Date: \(message.date)\n" }
        if !message.id.isEmpty { text += "Message id: \(message.id)\n" }
        let capped: String
        if trimmed.count > bodyBudget {
            capped = String(trimmed.prefix(bodyBudget))
                + "\n…(body truncated at \(bodyBudget) of \(trimmed.count) characters)"
        } else {
            capped = trimmed
        }
        return UntrustedContent.fenced(
            text + "\n" + (capped.isEmpty ? "(this message has no text body)" : capped),
            from: "an email")
    }

    /// One header line per message, ids included so `mail.read` can be called next.
    static func renderList(_ messages: [MailMessage]) -> String {
        let lines = messages.prefix(listLimit).map { m -> String in
            let subject = m.subject.isEmpty ? "(no subject)" : m.subject
            let unread = m.read ? "" : "● "
            let id = m.id.isEmpty ? "" : " [id \(m.id)]"
            return "\(unread)\(subject) — \(m.sender)\(m.date.isEmpty ? "" : " · \(m.date)")\(id)"
        }
        // Subjects and senders are strangers' text as well.
        return "Recent inbox (\(messages.count)):\n"
            + UntrustedContent.fenced(lines.joined(separator: "\n"), from: "email headers")
    }

    // MARK: - Reads

    static let mailNotRunning =
        "Mail isn't running, and I couldn't start it, so I couldn't read your mail."

    /// The newest message and its body. Starts Mail quietly when it is closed: an explicit
    /// "read my latest email" is consent to look in the mailbox, and it must not depend on the
    /// user having opened Mail first.
    static func latest(using source: MailSource) async -> MailReadOutcome {
        guard await ensureRunning(source) else {
            return .init(success: false, output: mailNotRunning)
        }
        guard let message = await offMain({ source.latest() }) else {
            return .init(success: true, output: "The inbox has no messages.")
        }
        return .init(success: true, output: render(message))
    }

    /// One message by id, as listed by `recent`. A blank id reads the newest message.
    static func read(id: String, using source: MailSource) async -> MailReadOutcome {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return await latest(using: source) }
        guard await ensureRunning(source) else {
            return .init(success: false, output: mailNotRunning)
        }
        guard let message = await offMain({ source.message(id: id) }) else {
            return .init(
                success: false,
                output: "No inbox message has id \(id). List recent mail for current ids.")
        }
        return .init(success: true, output: render(message))
    }

    /// The message selected or open in Mail. Says "nothing selected" only when Mail was asked
    /// and had nothing; a closed Mail is reported as closed, never as an empty selection.
    static func selected(using source: MailSource) async -> MailReadOutcome {
        guard source.isRunning else {
            return .init(
                success: true,
                output: "Mail isn't running, so no message is open. Ask for the latest "
                    + "message to read it without opening Mail.")
        }
        guard let message = await offMain({ source.selected() }) else {
            return .init(
                success: true,
                output: "Mail is running but no message is selected or open in it. "
                    + "Select a message, or ask for the latest one.")
        }
        return .init(success: true, output: render(message), hasMessage: true)
    }

    /// Recent headers (with ids), then the newest message's body so a single call answers
    /// "read my latest email".
    static func recent(limit: Int, using source: MailSource) async -> MailReadOutcome {
        guard await ensureRunning(source) else {
            return .init(success: false, output: mailNotRunning)
        }
        let limit = max(1, min(limit, 40))
        let messages = await offMain { source.recent(limit: limit) }
        guard !messages.isEmpty else {
            return .init(success: true, output: "The inbox has no recent messages.")
        }
        var output = renderList(messages)
        let newest: MailMessage? = await offMain {
            if let first = messages.first, !first.id.isEmpty {
                return source.message(id: first.id)
            }
            return source.latest()
        }
        if let newest {
            output += "\n\nNewest message, in full:\n" + render(newest)
        }
        return .init(success: true, output: output)
    }

    // MARK: - Plumbing

    private static func ensureRunning(_ source: MailSource) async -> Bool {
        if source.isRunning { return true }
        return await source.launchQuietly()
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// The real Mail, through AppleScript.
nonisolated struct LiveMailSource: MailSource {

    private static let bundleID = "com.apple.mail"

    var isRunning: Bool { AppleAppsAPI.isRunning(Self.bundleID) }

    func launchQuietly() async -> Bool {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            return false
        }
        // The launch call returns when the process exists; scripting needs it a moment longer.
        for _ in 0..<40 {
            if isRunning { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isRunning
    }

    func recent(limit: Int) -> [MailMessage] {
        AppleAppsAPI.shared.getRecentEmails(limit: limit).map(MailMessage.init)
    }

    func latest() -> MailMessage? {
        AppleAppsAPI.shared.getLatestEmail().map(MailMessage.init)
    }

    func message(id: String) -> MailMessage? {
        guard let number = Int(id) else { return nil }
        return AppleAppsAPI.shared.getEmail(id: number).map(MailMessage.init)
    }

    func selected() -> MailMessage? {
        AppleAppsAPI.shared.getSelectedEmail().map(MailMessage.init)
    }
}
