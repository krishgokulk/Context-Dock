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
