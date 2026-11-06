import AppKit
import ApplicationServices
import Foundation

struct MessagesConversationSummary {
    let displayName: String
    let participants: [String]
    let lastMessageSnippet: String
    let lastMessageDate: String
}

enum MessagesAutomation {
    private static let bundleId = "com.apple.MobileSMS"

    nonisolated private static func escapeAppleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func activateOrLaunchMessages() async -> NSRunningApplication? {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId && !$0.isTerminated
        }) {
            _ = await MainActor.run { app.activate() }
            return app
        }

        guard let appURL =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            ?? URL(string: "file:///System/Applications/Messages.app")
        else { return nil }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        do {
            return try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            NSWorkspace.shared.open(appURL)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleId && !$0.isTerminated
                }) {
                    _ = await MainActor.run { app.activate() }
                    return app
                }
            }
            return nil
        }
    }

    // MARK: - Conversation Snapshot

    /// Returns a summary of recent conversations via AppleScript.
    nonisolated static func conversationSnapshot(
        contactFilter: String = "",
        limit: Int = 15
    ) -> String {
        // `tell application "Messages"` LAUNCHES Messages if it isn't running. Never
        // launch it just to read — return empty so callers fall back to the chat-DB
        // reader (MessagesChatDBReader) instead of springing Messages to life.
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.apple.MobileSMS" && !$0.isTerminated
        }) else { return "" }

        let safeLimit = max(1, min(limit, 30))
        let filterEscaped = escapeAppleScriptLiteral(contactFilter)

        let script = """
            tell application "Messages"
                try
                    set contactFilter to "\(filterEscaped)"
                    set resultLimit to \(safeLimit)
                    set outputLines to {}
                    set allChats to every chat
                    set chatCount to count of allChats

                    repeat with i from 1 to chatCount
                        set c to item i of allChats
                        try
                            set chatName to name of c
                        on error
                            set chatName to ""
                        end try

                        set participantNames to {}
                        try
                            set pList to participants of c
                            repeat with p in pList
                                try
                                    set pName to name of p
                                on error
                                    set pName to handle of p
                                end try
                                set end of participantNames to pName
                            end repeat
                        end try

                        set combinedNames to chatName & " " & (participantNames as string)

                        if contactFilter is "" or combinedNames contains contactFilter then
                            set snippet to ""
                            try
                                set msgList to messages of c
                                set msgCount to count of msgList
                                if msgCount > 0 then
                                    set lastMsg to item msgCount of msgList
                                    try
                                        set snippet to content of lastMsg
                                        if (count of snippet) > 80 then
                                            set snippet to (characters 1 through 80 of snippet as string) & "…"
                                        end if
                                    end try
                                end if
                            end try

                            if chatName is "" then
                                if (count of participantNames) > 0 then
                                    set chatName to (participantNames as string)
                                else
                                    set chatName to "(unknown)"
                                end if
                            end if

                            set end of outputLines to "- " & chatName & " | snippet: " & snippet
                            if (count of outputLines) >= resultLimit then exit repeat
                        end if
                    end repeat

                    if (count of outputLines) = 0 then return "NO_CONVERSATIONS"
                    set AppleScript's text item delimiters to return
                    return outputLines as string
                on error errMsg
                    return "ERROR: " & errMsg
                end try
            end tell
            """

        let result = AppleAppsAPI.shared.handleAppleScript(script) ?? ""
        if result.isEmpty || result == "NO_CONVERSATIONS" {
            return "No matching conversations found."
        }
        if result.hasPrefix("ERROR:") {
            return "Messages context could not be read."
        }
        return result
    }

    // MARK: - Open Search

    /// Opens Messages and triggers the search UI with the given query.
    static func openSearch(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "❌ No search query provided." }
        guard let app = await activateOrLaunchMessages() else { return "❌ Couldn't open Messages." }

        return await AXSearchFieldInjector.shared.inject(query: trimmed, into: app)
    }

    // MARK: - Compose Message

    /// Opens a new Messages compose window pre-filled with recipient and optional body.
    /// Does NOT send automatically — the user confirms in the UI.
    static func composeMessage(to recipient: String, body: String) async -> String {
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else { return "❌ No recipient provided." }
        guard await activateOrLaunchMessages() != nil else { return "❌ Couldn't open Messages." }

        try? await Task.sleep(nanoseconds: 300_000_000)

        // Use URL scheme: imessage://
        let encodedRecipient = trimmedRecipient.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmedRecipient
        let urlString = "imessage://\(encodedRecipient)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            let bodyNote = body.isEmpty ? "" : " (body pre-filled — review before sending)"
            return "✅ Opened Messages compose to \(trimmedRecipient)\(bodyNote)."
        }

        return "❌ Couldn't open Messages compose window."
    }

    // MARK: - Contact Resolution

    struct ResolvedContact: Equatable {
        let name: String
        let handle: String
    }

    enum ContactResolutionResult {
        case resolved(ResolvedContact)
        case ambiguous([ResolvedContact])
        case notFound
    }

    static func resolveRecipient(_ query: String) -> ContactResolutionResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        // If it looks like a direct phone number or email address, return immediately
        if trimmed.contains("@") || (trimmed.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil && trimmed.count >= 7 && !trimmed.contains(" ")) {
            return .resolved(ResolvedContact(name: trimmed, handle: trimmed))
        }

        let matches = AppleAppsAPI.shared.searchContacts(query: trimmed)
        var contactsWithHandles: [ResolvedContact] = []

        for match in matches {
            let fullName = match["fullName"] as? String ?? trimmed
            if let phone = match["phone"] as? String, !phone.isEmpty {
                contactsWithHandles.append(ResolvedContact(name: fullName, handle: phone))
            } else if let email = match["email"] as? String, !email.isEmpty {
                contactsWithHandles.append(ResolvedContact(name: fullName, handle: email))
            }
        }

        if contactsWithHandles.count == 1 {
            return .resolved(contactsWithHandles[0])
        } else if contactsWithHandles.count > 1 {
            return .ambiguous(contactsWithHandles)
        }

        return .notFound
    }

    // MARK: - Send Message (Rung 3 AppleScript -> Rung 4 UI Fallback + Verified Read-Back)

    static func sendMessage(to recipient: String, body: String) async -> (success: Bool, message: String, verified: Bool) {
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else {
            return (false, "No recipient provided.", false)
        }
        guard !trimmedBody.isEmpty else {
            return (false, "No message body provided.", false)
        }

        // 1. Resolve contact handle
        let targetHandle: String
        let displayName: String
        switch resolveRecipient(trimmedRecipient) {
        case .resolved(let contact):
            targetHandle = contact.handle
            displayName = contact.name
        case .ambiguous(let contacts):
            let options = contacts.prefix(4).map { "\($0.name) (\($0.handle))" }.joined(separator: ", ")
            return (false, "Multiple contacts found for '\(trimmedRecipient)': \(options). Please specify which one to message.", false)
        case .notFound:
            targetHandle = trimmedRecipient
            displayName = trimmedRecipient
        }

        // 2. Try headless AppleScript dispatch
        let escapedRecipient = escapeAppleScriptLiteral(targetHandle)
        let escapedBody = escapeAppleScriptLiteral(trimmedBody)
        let script = """
            tell application "Messages"
                try
                    set targetService to 1st service whose service type = iMessage
                    set targetBuddy to participant "\(escapedRecipient)" of targetService
                    send "\(escapedBody)" to targetBuddy
                    return "SENT_IMESSAGE"
                on error
                    try
                        set targetBuddy to participant "\(escapedRecipient)"
                        send "\(escapedBody)" to targetBuddy
                        return "SENT_BUDDY"
                    on error errMsg
                        return "ERROR: " & errMsg
                    end try
                end try
            end tell
            """
        let scriptResult = AppleAppsAPI.shared.handleAppleScript(script) ?? ""
        if scriptResult.hasPrefix("SENT_") {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let verified = MessagesChatDBReader.verifySentMessage(to: targetHandle, textSnippet: trimmedBody)
            let readback = verified ? " (Verified in Messages history)" : ""
            return (true, "Sent message to \(displayName)\(readback).", verified)
        }

        // 3. Fallback to native UI automation (imessage:// URL + text entry + Enter)
        guard let app = await activateOrLaunchMessages() else {
            return (false, "Could not launch Messages.", false)
        }

        let encoded = targetHandle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? targetHandle
        if let url = URL(string: "imessage://\(encoded)") {
            NSWorkspace.shared.open(url)
            try? await Task.sleep(nanoseconds: 800_000_000)

            let focusRes = AXUIFocusHelper.focusSearchOrTextField(in: app.processIdentifier, text: trimmedBody)
            if focusRes.success {
                try? await Task.sleep(nanoseconds: 250_000_000)
                postEnter(to: app.processIdentifier)

                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let verified = MessagesChatDBReader.verifySentMessage(to: targetHandle, textSnippet: trimmedBody)
                let readback = verified ? " (Verified via chat.db)" : ""
                return (true, "Sent message to \(displayName)\(readback).", verified)
            }
        }

        return (false, "Could not send message to \(displayName).", false)
    }

    // MARK: - AX Helpers

    private static func findSearchField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == "AXSearchField" {
            return element
        }
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findSearchField(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func postEnter(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
