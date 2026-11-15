// ShareCapabilities.swift
// Context-Dock
//
// `share.send` — hand a file, link or text to a person or a share destination, from any
// chat (issue #204). Sharing is a system verb on the object the chat already holds, not
// another app's job: Finder's own Share menu sends to Messages without being Messages. So
// this capability carries no app, which makes it visible in every App Pet and in General
// Chat, and it always asks first.
//
// It is a thin capability over `ShareIntentRouter`, the same code the share pills use — not
// a second copy. Before #204's last retirement, a typed "send this to Salman" reached that
// router through the pre-model `CrossAppNLHandler` shortcut; the model reaches it here.

import AppKit
import Foundation

enum ShareCapabilities {
    static let sendID = "share.send"

    /// Capability ids listed in every app's prompt, not only their own app's.
    static let listedInEveryApp: Set<String> = [sendID]

    static func register(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: sendID,
                title: "Send or share a file, link or text with a person or a share destination "
                    + "(Messages, Mail, AirDrop, Notes…). Works from any chat.",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "recipient",
                        description: "Who or where: a contact name, phone number, email address, "
                            + "or a share destination such as Notes or Reminders. Omit for AirDrop.",
                        required: false),
                    .init(
                        name: "channel",
                        description: "messages, mail or airdrop. Omit to choose from the recipient: "
                            + "an email address goes by mail, a person by messages.",
                        required: false),
                    .init(
                        name: "path",
                        description: "File to send; several separated by a newline or a comma. "
                            + "Defaults to the selected or attached item.",
                        required: false),
                    .init(name: "text", description: "Text or a link to send instead of a file", required: false),
                ]),
                riskLevel: .high
            ) { request in
                let paths = filePaths(from: request)
                let text = request.input["text"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let missing = paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
                    return .init(success: false, output: "No file at \(missing).")
                }
                guard !paths.isEmpty || !(text ?? "").isEmpty else {
                    return .init(success: false, output: "Nothing to send — select or attach a file, or pass text.")
                }
                let recipient = request.input["recipient"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let channel = channelHint(named: request.input["channel"], recipient: recipient)
                let output = await send(
                    paths: paths, text: paths.isEmpty ? text : nil, recipient: recipient,
                    channel: channel, rawQuery: request.userRequest)
                return .init(success: !output.hasPrefix("❌"), output: output)
            }
        )
    }

    /// The channel for a request: the one named, else mail for an email address, Messages
    /// for a person, and the share destinations (Notes, Reminders…) for anything else.
    nonisolated static func channelHint(named raw: String?, recipient: String?) -> ShareChannelHint {
        switch (raw ?? "").lowercased().replacingOccurrences(of: " ", with: "") {
        case "messages", "message", "imessage", "sms", "text": return .messages
        case "mail", "email": return .mail
        case "airdrop": return .airDrop
        default: break
        }
        guard let recipient, !recipient.isEmpty else { return .picker }
        if recipient.contains("@") { return .mail }
        return .messages
    }

    private static func filePaths(from request: AICapabilityExecutionRequest) -> [String] {
        let named = (request.input["path"] ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .compactMap { FinderCoworkerCapabilities.resolveRoot($0)?.path }
        if !named.isEmpty { return named }
        if request.input["text"]?.isEmpty == false { return [] }
        return FinderCoworkerCapabilities.selectedURLs(from: request).map(\.path)
    }

    @MainActor
    private static func send(
        paths: [String], text: String?, recipient: String?, channel: ShareChannelHint, rawQuery: String
    ) async -> String {
        var context = AXContext.empty
        context.selectedFilePaths = paths
        context.selectedText = text
        let router = ShareIntentRouter.shared
        let resolution = await router.resolve(
            ShareIntent(
                rawQuery: rawQuery, channelHint: channel,
                recipientQuery: (recipient?.isEmpty ?? true) ? nil : recipient))
        return await router.execute(resolution, axContext: context)
    }
}
