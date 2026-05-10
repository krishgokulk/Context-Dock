import Foundation
import AppKit
import Contacts

enum ShareChannelHint: String {
    case messages
    case mail
    case picker
    case airDrop
}

struct ShareIntent {
    let rawQuery: String
    let channelHint: ShareChannelHint
    let recipientQuery: String?
}

struct ShareIntentResolution {
    let intent: ShareIntent
    let resolvedContact: CNContact?
    let recipientHandle: String?
    let recipientDisplayName: String
}

@MainActor
final class ShareIntentRouter {
    static let shared = ShareIntentRouter()

    private let store = CNContactStore()

    private init() {}

    func parse(_ raw: String) -> ShareIntent? {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return nil }

        let channelHint = detectChannel(in: normalized)
        let recipientQuery = extractRecipient(from: normalized)

        guard looksLikeShareIntent(
            normalized,
            channelHint: channelHint,
            recipientQuery: recipientQuery
        ) else {
            return nil
        }

        return ShareIntent(
            rawQuery: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            channelHint: channelHint ?? .picker,
            recipientQuery: recipientQuery
        )
    }

    func resolve(_ intent: ShareIntent) async -> ShareIntentResolution {
        let trimmedRecipient = intent.recipientQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = await lookupContactIfNeeded(trimmedRecipient)
        let mailSenderMatch = await lookupMailSenderIfNeeded(
            trimmedRecipient,
            channelHint: intent.channelHint,
            contact: contact
        )
        let handle = resolveHandle(
            channelHint: intent.channelHint,
            recipientQuery: trimmedRecipient,
            contact: contact,
            mailSenderMatch: mailSenderMatch
        )
        let displayName = resolvedDisplayName(
            recipientQuery: trimmedRecipient,
            contact: contact,
            mailSenderMatch: mailSenderMatch,
            fallbackHandle: handle
        )

        return ShareIntentResolution(
            intent: intent,
            resolvedContact: contact,
            recipientHandle: handle,
            recipientDisplayName: displayName
        )
    }

    func shareItems(for context: AXContext) -> [Any] {
        var items: [Any] = context.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if items.isEmpty, let urlString = context.currentURL, let url = URL(string: urlString) {
            items.append(url)
        }
        if items.isEmpty,
            let selectedText = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedText.isEmpty
        {
            items.append(selectedText)
        }
        return items
    }

    func execute(
        _ resolution: ShareIntentResolution,
        axContext: AXContext,
        presentSharingPicker: (([Any]) -> Void)? = nil
    ) async -> String {
        switch resolution.intent.channelHint {
        case .messages:
            return await executeMessages(
                resolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker
            )
        case .mail:
            return await executeMail(
                resolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker
            )
        case .airDrop:
            return executeWithSharingService(
                named: .sendViaAirDrop,
                resolution: resolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker,
                successMessage: "✅ Opening AirDrop…"
            )
        case .picker:
            if let directShareMessage = executeDirectShareDestination(
                for: resolution,
                axContext: axContext
            ) {
                return directShareMessage
            }
            return openSharePicker(
                for: resolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker
            )
        }
    }

    func executeText(
        _ text: String,
        resolution: ShareIntentResolution,
        subject: String = "Shared from Context-Dock",
        presentSharingPicker: (([Any]) -> Void)? = nil
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "❌ Nothing to send." }

        switch resolution.intent.channelHint {
        case .messages:
            if let recipientHandle = resolution.recipientHandle,
                AppSettings.shared.allowAutomation,
                runMessagesTextAutomation(
                    recipientHandle: recipientHandle,
                    text: String(trimmed.prefix(3500))
                )
            {
                return "✅ Sent summary to \(resolution.recipientDisplayName) via Messages"
            }
            if resolution.intent.recipientQuery != nil, resolution.recipientHandle == nil {
                return "⚠️ I couldn't resolve \(resolution.recipientDisplayName)."
            }
            presentSharingPicker?([trimmed])
            return "✅ Opening Messages share…"

        case .mail:
            if AppSettings.shared.allowAutomation,
                runMailAutomation(
                    recipient: resolution.recipientHandle,
                    subject: subject,
                    body: trimmed,
                    attachmentPaths: []
                )
            {
                return resolution.recipientHandle == nil
                    ? "✅ Mail draft opened with summary."
                    : "✅ Mail draft opened for \(resolution.recipientDisplayName)."
            }
            presentSharingPicker?([trimmed])
            return "✅ Opening Mail share…"

        case .airDrop, .picker:
            presentSharingPicker?([trimmed])
            return "✅ Opening share sheet…"
        }
    }

    private func executeMessages(
        _ resolution: ShareIntentResolution,
        axContext: AXContext,
        presentSharingPicker: (([Any]) -> Void)?
    ) async -> String {
        if let recipientHandle = resolution.recipientHandle,
            AppSettings.shared.allowAutomation,
            runMessagesAutomation(recipientHandle: recipientHandle, context: axContext)
        {
            let payloadLabel = sharePayloadLabel(for: axContext)
            return "✅ Sent \(payloadLabel) to \(resolution.recipientDisplayName) via Messages"
        }

        if resolution.intent.recipientQuery != nil, resolution.recipientHandle == nil {
            let pickerMessage = openSharePicker(
                for: resolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker
            )
            return "⚠️ I couldn't resolve \(resolution.recipientDisplayName). \(pickerMessage)"
        }

        return executeWithSharingService(
            named: .composeMessage,
            resolution: resolution,
            axContext: axContext,
            presentSharingPicker: presentSharingPicker,
            successMessage: resolution.recipientHandle == nil
                ? "✅ Opening Messages share…"
                : "✅ Opening Messages compose for \(resolution.recipientDisplayName)…"
        )
    }

    private func executeMail(
        _ resolution: ShareIntentResolution,
        axContext: AXContext,
        presentSharingPicker: (([Any]) -> Void)?
    ) async -> String {
        let filePaths = axContext.selectedFilePaths
        let subject = mailSubject(for: axContext)
        let body = mailBody(for: axContext)

        if AppSettings.shared.allowAutomation,
            runMailAutomation(
                recipient: resolution.recipientHandle,
                subject: subject,
                body: body,
                attachmentPaths: filePaths
            )
        {
            let label = filePaths.isEmpty ? "Mail draft opened." : "Mail draft with attachment opened."
            if resolution.recipientHandle != nil {
                return "✅ \(label) Recipient: \(resolution.recipientDisplayName)."
            }
            return "✅ \(label)"
        }

        if resolution.intent.recipientQuery != nil, resolution.recipientHandle == nil {
            let pickerMessage = openSharePicker(
                for: resolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker
            )
            return "⚠️ I couldn't resolve \(resolution.recipientDisplayName). \(pickerMessage)"
        }

        return executeWithSharingService(
            named: .composeEmail,
            resolution: resolution,
            axContext: axContext,
            presentSharingPicker: presentSharingPicker,
            successMessage: "✅ Opening Mail compose…",
            subject: subject
        )
    }

    private func executeWithSharingService(
        named serviceName: NSSharingService.Name,
        resolution: ShareIntentResolution,
        axContext: AXContext,
        presentSharingPicker: (([Any]) -> Void)?,
        successMessage: String,
        subject: String? = nil
    ) -> String {
        let items = shareItems(for: axContext)
        guard !items.isEmpty else {
            return "❌ Nothing to share — select a file, URL, or text first."
        }

        guard let service = NSSharingService(named: serviceName),
            service.canPerform(withItems: items)
        else {
            return openSharePicker(
                for: resolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker
            )
        }

        if let recipientHandle = resolution.recipientHandle, !recipientHandle.isEmpty {
            service.recipients = [recipientHandle]
        }
        if let subject, !subject.isEmpty {
            service.subject = subject
        }
        service.perform(withItems: items)
        return successMessage
    }

    private func openSharePicker(
        for resolution: ShareIntentResolution,
        axContext: AXContext,
        presentSharingPicker: (([Any]) -> Void)?
    ) -> String {
        let items = shareItems(for: axContext)
        guard !items.isEmpty else {
            return "❌ Nothing to share — select a file, URL, or text first."
        }

        if let presentSharingPicker {
            presentSharingPicker(items)
            return "✅ Opening share sheet…"
        }

        let picker = NSSharingServicePicker(items: items)
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
                let view = window.contentView
            {
                let rect = NSRect(x: window.frame.width / 2 - 60, y: 52, width: 120, height: 1)
                picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            }
        }
        return "✅ Opening share sheet…"
    }

    private func executeDirectShareDestination(
        for resolution: ShareIntentResolution,
        axContext: AXContext
    ) -> String? {
        guard resolution.recipientHandle == nil,
            let destinationQuery = resolution.intent.recipientQuery?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !destinationQuery.isEmpty
        else {
            return nil
        }

        let items = shareItems(for: axContext)
        guard !items.isEmpty else {
            return "❌ Nothing to share — select a file, URL, or text first."
        }

        guard let destination = ShareDestinationResolver.resolve(
            query: destinationQuery,
            items: items
        ) else {
            return nil
        }

        destination.service.perform(withItems: items)
        return "✅ Sharing via \(destination.title)…"
    }

    private func mailSubject(for context: AXContext) -> String {
        if let filePath = context.selectedFilePaths.first {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
        if let windowTitle = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !windowTitle.isEmpty
        {
            return windowTitle
        }
        if let currentURL = context.currentURL, !currentURL.isEmpty {
            return currentURL
        }
        return "Shared from Context-Dock"
    }

    private func mailBody(for context: AXContext) -> String {
        let selectedText = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentURL = context.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines)

        let pieces = [selectedText, currentURL].compactMap { piece -> String? in
            guard let piece, !piece.isEmpty else { return nil }
            return piece
        }

        if !pieces.isEmpty {
            return pieces.joined(separator: "\n\n")
        }

        if let filePath = context.selectedFilePaths.first {
            return "Sharing \(URL(fileURLWithPath: filePath).lastPathComponent)"
        }

        return ""
    }

    private func sharePayloadLabel(for context: AXContext) -> String {
        if let filePath = context.selectedFilePaths.first {
            let count = context.selectedFilePaths.count
            return count == 1
                ? URL(fileURLWithPath: filePath).lastPathComponent
                : "\(count) files"
        }
        if let selectedText = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedText.isEmpty
        {
            return "text"
        }
        if let currentURL = context.currentURL, !currentURL.isEmpty {
            return currentURL
        }
        return "content"
    }

    private func runMessagesAutomation(recipientHandle: String, context: AXContext) -> Bool {
        let handle = escapeAppleScript(recipientHandle)

        if !context.selectedFilePaths.isEmpty {
            let sendLines = context.selectedFilePaths.map {
                "send POSIX file \"\(escapeAppleScript($0))\" to buddyRef"
            }.joined(separator: "\n                ")

            let script = """
            tell application "Messages"
                set svc to 1st service whose service type = iMessage
                set buddyRef to buddy "\(handle)" of svc
                \(sendLines)
            end tell
            """
            return runAppleScript(script)
        }

        if let selectedText = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedText.isEmpty
        {
            let script = """
            tell application "Messages"
                set svc to 1st service whose service type = iMessage
                set buddyRef to buddy "\(handle)" of svc
                send "\(escapeAppleScript(String(selectedText.prefix(1200))))" to buddyRef
            end tell
            """
            return runAppleScript(script)
        }

        if let currentURL = context.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !currentURL.isEmpty
        {
            let script = """
            tell application "Messages"
                set svc to 1st service whose service type = iMessage
                set buddyRef to buddy "\(handle)" of svc
                send "\(escapeAppleScript(currentURL))" to buddyRef
            end tell
            """
            return runAppleScript(script)
        }

        let script = """
        tell application "Messages"
            activate
            set svc to 1st service whose service type = iMessage
            open (buddy "\(handle)" of svc)
        end tell
        """
        return runAppleScript(script)
    }

    private func runMessagesTextAutomation(recipientHandle: String, text: String) -> Bool {
        let script = """
        tell application "Messages"
            set svc to 1st service whose service type = iMessage
            set buddyRef to buddy "\(escapeAppleScript(recipientHandle))" of svc
            send "\(escapeAppleScript(text))" to buddyRef
        end tell
        """
        return runAppleScript(script)
    }

    private func runMailAutomation(
        recipient: String?,
        subject: String,
        body: String,
        attachmentPaths: [String]
    ) -> Bool {
        let recipientBlock: String = {
            guard let recipient, !recipient.isEmpty else { return "" }
            return """
                make new to recipient at end of to recipients with properties {address:"\(escapeAppleScript(recipient))"}
            """
        }()

        let attachmentBlock = attachmentPaths.map { path in
            """
                make new attachment with properties {file name:POSIX file "\(escapeAppleScript(path))"} at after the last paragraph
            """
        }.joined(separator: "\n")

        let contentBody: String = body.isEmpty ? "" : body + "\n"
        let script = """
        tell application "Mail"
            activate
            set newMessage to make new outgoing message with properties {visible:true, subject:"\(escapeAppleScript(subject))", content:"\(escapeAppleScript(contentBody))"}
            tell newMessage
        \(recipientBlock)
        \(attachmentBlock)
            end tell
        end tell
        """
        return runAppleScript(script)
    }

    private func lookupContactIfNeeded(_ recipientQuery: String?) async -> CNContact? {
        guard let recipientQuery, !recipientQuery.isEmpty, !looksLikeHandle(recipientQuery) else {
            return nil
        }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        let contacts = (try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: recipientQuery),
            keysToFetch: keys
        )) ?? []

        return contacts.first {
            $0.givenName.lowercased() == recipientQuery.lowercased()
                || ($0.givenName + " " + $0.familyName).lowercased() == recipientQuery.lowercased()
        } ?? contacts.first
    }

    private func lookupMailSenderIfNeeded(
        _ recipientQuery: String?,
        channelHint: ShareChannelHint,
        contact: CNContact?
    ) async -> ResolvedMailSender? {
        guard channelHint == .mail,
            contact == nil,
            let recipientQuery,
            !recipientQuery.isEmpty,
            !looksLikeHandle(recipientQuery)
        else {
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            MetadataResolver.bestMailSender(matching: recipientQuery)
        }.value
    }

    private func resolveHandle(
        channelHint: ShareChannelHint,
        recipientQuery: String?,
        contact: CNContact?,
        mailSenderMatch: ResolvedMailSender?
    ) -> String? {
        if let recipientQuery, looksLikeHandle(recipientQuery) {
            return recipientQuery
        }

        switch channelHint {
        case .messages:
            if let phone = contact?.phoneNumbers.first?.value.stringValue,
                !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return phone
            }
            if let email = contact?.emailAddresses.first?.value as String?,
                !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return email
            }
            return nil
        case .mail:
            if let email = contact?.emailAddresses.first?.value as String?,
                !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return email
            }
            if let mailSenderMatch,
                !mailSenderMatch.handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return mailSenderMatch.handle
            }
            return nil
        case .picker, .airDrop:
            return nil
        }
    }

    private func resolvedDisplayName(
        recipientQuery: String?,
        contact: CNContact?,
        mailSenderMatch: ResolvedMailSender?,
        fallbackHandle: String?
    ) -> String {
        if let contact,
            let fullName = CNContactFormatter.string(from: contact, style: .fullName),
            !fullName.isEmpty
        {
            return fullName
        }
        if let mailSenderMatch, !mailSenderMatch.displayName.isEmpty {
            return mailSenderMatch.displayName
        }
        if let recipientQuery, !recipientQuery.isEmpty {
            return recipientQuery
        }
        if let fallbackHandle, !fallbackHandle.isEmpty {
            return fallbackHandle
        }
        return "recipient"
    }

    private func normalize(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9@+._ -]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectChannel(in query: String) -> ShareChannelHint? {
        if query.range(of: "\\b(via|using|in)\\s+(messages?|imessage|sms|text)\\b", options: .regularExpression) != nil
            || query.range(of: "\\b(messages?|imessage|sms|text)\\b", options: .regularExpression) != nil
        {
            return .messages
        }
        if query.range(of: "\\b(via|using|in)\\s+(mail|email)\\b", options: .regularExpression) != nil
            || query.range(of: "\\b(mail|email)\\b", options: .regularExpression) != nil
        {
            return .mail
        }
        if query.contains("airdrop") || query.contains("air drop") {
            return .airDrop
        }
        if query.contains("share") || query.contains("send") {
            return .picker
        }
        return nil
    }

    private func looksLikeShareIntent(
        _ query: String,
        channelHint: ShareChannelHint?,
        recipientQuery: String?
    ) -> Bool {
        let tokens = Set(query.split(separator: " ").map(String.init))
        let actionWords: Set<String> = [
            "send", "share", "email", "mail", "message", "messages", "text", "sms", "imessage",
            "airdrop"
        ]
        let payloadHints: Set<String> = [
            "this", "that", "file", "files", "selection", "selected", "text", "link", "page",
            "url", "document", "pdf", "image"
        ]

        let hasAction = !tokens.intersection(actionWords).isEmpty
        let hasPayloadHint = !tokens.intersection(payloadHints).isEmpty
        let hasRecipientMarker = query.contains(" to ") || query.contains(" with ")
        let hasChannel = channelHint != nil
        let hasRecipient = recipientQuery != nil

        return (hasAction && (hasPayloadHint || hasRecipientMarker || hasChannel))
            || (hasChannel && (hasRecipientMarker || hasPayloadHint || hasRecipient))
    }

    private func extractRecipient(from query: String) -> String? {
        let channelPattern = "(?:messages?|imessage|sms|text|mail|email|airdrop|air drop|share(?: sheet)?)"
        let patterns = [
            "\\b(?:to|with)\\s+(.+?)(?=\\s+(?:via|using|in)\\s+\(channelPattern)\\b|$)",
            "^\\s*(?:via|using|in)\\s+\(channelPattern)\\s+(?:to|with\\s+)?(.+)$",
            "^\\s*\(channelPattern)\\s+(?:to|with)\\s+(.+)$",
            "^\\s*(?:send|share)\\s+(.+?)(?=\\s+(?:via|using|in)\\s+\(channelPattern)\\b|$)",
            "^\\s*(?:message|messages?|imessage|text|sms|email|mail)\\s+(.+)$"
        ]

        for pattern in patterns {
            if let match = query.firstMatch(for: pattern, group: 1) {
                let cleaned = match
                    .replacingOccurrences(of: "^\\s*(?:to|with)\\s+", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\b(this|that|file|files|selection|selected|text|link|page|url|document)\\b", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return nil
    }

    private func looksLikeHandle(_ value: String) -> Bool {
        if value.contains("@") {
            return true
        }

        let compact = value.replacingOccurrences(of: "[\\s\\-\\(\\)]", with: "", options: .regularExpression)
        return compact.range(of: "^\\+?\\d{7,}$", options: .regularExpression) != nil
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}

private extension String {
    func firstMatch(for pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range),
            match.numberOfRanges > group,
            let captureRange = Range(match.range(at: group), in: self)
        else {
            return nil
        }
        return String(self[captureRange])
    }
}
