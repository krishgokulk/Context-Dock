import AppKit
import ApplicationServices
import Foundation

enum MailAutomationSearchTokenKind: String {
    case generic
    case sender
    case subject
    case attachment
    case date
}

struct MailAutomationMessageSummary {
    let subject: String
    let sender: String
    let dateText: String
    let isRead: Bool
}

struct MailAutomationMailboxSnapshot {
    let mailboxName: String
    let messages: [MailAutomationMessageSummary]
}

enum MailAutomation {
    nonisolated private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func escapeAppleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func activateOrLaunchMail() async -> NSRunningApplication? {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.mail" && !$0.isTerminated
        }) {
            _ = await MainActor.run { runningApp.activate() }
            return runningApp
        }

        guard
            let appURL =
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail")
                ?? URL(string: "file:///System/Applications/Mail.app")
        else { return nil }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            return try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            NSWorkspace.shared.open(appURL)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == "com.apple.mail" && !$0.isTerminated
                }) {
                    _ = await MainActor.run { runningApp.activate() }
                    return runningApp
                }
            }
            return nil
        }
    }

    static func listMenuActions(query: String = "", maxResults: Int = 24) async -> String {
        let mailApp = await activateOrLaunchMail()
        guard let mailApp else { return "Mail is not available." }

        let liveItems = AXMenuReader.shared.refreshAllMenuItems(for: mailApp.processIdentifier, maxDepth: 6)
        if !liveItems.isEmpty {
            AppMenuCapabilityCache.shared.store(items: liveItems, for: mailApp)
        }

        let items = AppMenuCapabilityCache.shared.menuItems(
            for: mailApp,
            query: query,
            maxResults: maxResults
        )

        guard !items.isEmpty else { return "No Mail menu actions found." }
        let lines = items.map { item in
            let shortcut = item.shortcutDisplay.map { " [\($0)]" } ?? ""
            return "- \(item.path.joined(separator: " > "))\(shortcut)"
        }
        return "Mail actions:\n" + lines.joined(separator: "\n")
    }

    static func executeMenuPath(_ path: [String]) async -> String {
        let trimmedPath = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmedPath.isEmpty else { return "❌ No Mail menu path provided." }
        guard let mailApp = await activateOrLaunchMail() else { return "❌ Couldn't open Mail." }

        let success = AXMenuReader.shared.clickMenuItem(path: trimmedPath, in: mailApp.processIdentifier)
        return success
            ? "✅ Executed Mail menu: \(trimmedPath.joined(separator: " > "))"
            : "❌ Couldn't execute Mail menu: \(trimmedPath.joined(separator: " > "))"
    }

    private static func mailDateSuggestionCandidates(for query: String) -> [String] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return [] }

        var candidates: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        let calendar = Calendar.current
        let now = Date()

        let weekdays = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        ]
        if let weekday = weekdays.first(where: { $0.hasPrefix(normalized) || normalized.hasPrefix($0) }) {
            candidates.append(weekday)
            if let weekdayIndex = [
                "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                "thursday": 5, "friday": 6, "saturday": 7,
            ][weekday] {
                let currentWeekday = calendar.component(.weekday, from: now)
                let offset = (weekdayIndex - currentWeekday + 7) % 7
                if let date = calendar.date(byAdding: .day, value: offset, to: now) {
                    candidates.append(formatter.string(from: date))
                }
            }
        }

        if ["today", "tod"].contains(where: { normalized.hasPrefix($0) }) {
            candidates.append(formatter.string(from: now))
        } else if ["yesterday", "yest"].contains(where: { normalized.hasPrefix($0) }),
            let date = calendar.date(byAdding: .day, value: -1, to: now)
        {
            candidates.append(formatter.string(from: date))
        } else if ["tomorrow", "tomo"].contains(where: { normalized.hasPrefix($0) }),
            let date = calendar.date(byAdding: .day, value: 1, to: now)
        {
            candidates.append(formatter.string(from: date))
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func axStringArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [String] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return [] }
        return ref as? [String] ?? []
    }

    private static func axChildElements(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
            let children = ref as? [AXUIElement]
        else { return [] }
        return children
    }

    private static func currentFocusedElement(in pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &ref
        ) == .success, let focused = ref
        else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    private static func isEditableAXElement(_ element: AXUIElement) -> Bool {
        let role = axStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        return ["AXSearchField", "AXTextField", "AXComboBox", "AXTextArea"].contains(role)
    }

    private static func findMailSearchField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }

        let role = axStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        if role == "AXSearchField" {
            return element
        }

        let description = axStringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        let title = axStringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let help = axStringAttribute(element, kAXHelpAttribute as CFString) ?? ""
        let metadata = normalize([description, title, help].joined(separator: " "))

        if isEditableAXElement(element), metadata.contains("search") || metadata.contains("mailbox") {
            return element
        }

        var firstEditableField: AXUIElement?
        for child in axChildElements(element) {
            if let exact = findMailSearchField(in: child, depth: depth + 1) {
                return exact
            }
            if firstEditableField == nil, isEditableAXElement(child) {
                firstEditableField = child
            }
        }
        return firstEditableField
    }

    private static func setAXTextValue(_ text: String, on element: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        ) == .success else { return false }

        guard let currentValue = axStringAttribute(element, kAXValueAttribute as CFString) else {
            return false
        }
        let normalizedCurrent = normalize(currentValue)
        let normalizedTarget = normalize(text)
        return normalizedCurrent == normalizedTarget || normalizedCurrent.contains(normalizedTarget)
    }

    private static func postKeyCode(_ keyCode: CGKeyCode, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    private static func postModifiedKeyCode(_ keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    private static func pasteString(_ text: String, to pid: pid_t) {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postModifiedKeyCode(9, flags: .maskCommand, to: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
            }
        }
    }

    private static func typeMailSearchQuery(_ query: String, into element: AXUIElement, pid: pid_t) async -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 60_000_000)
        postModifiedKeyCode(0, flags: .maskCommand, to: pid)
        try? await Task.sleep(nanoseconds: 40_000_000)
        pasteString(query, to: pid)
        try? await Task.sleep(nanoseconds: 80_000_000)

        if let currentValue = axStringAttribute(element, kAXValueAttribute as CFString) {
            let normalizedCurrent = normalize(currentValue)
            let normalizedTarget = normalize(query)
            return normalizedCurrent == normalizedTarget || normalizedCurrent.contains(normalizedTarget)
        }
        return true
    }

    private static func axSearchableStrings(for element: AXUIElement) -> [String] {
        [
            axStringAttribute(element, kAXTitleAttribute as CFString),
            axStringAttribute(element, kAXValueAttribute as CFString),
            axStringAttribute(element, kAXDescriptionAttribute as CFString),
            axStringAttribute(element, kAXHelpAttribute as CFString),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private static func axSubtreeSearchableStrings(for element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 2 else { return axSearchableStrings(for: element) }
        var results = axSearchableStrings(for: element)
        for child in axChildElements(element).prefix(12) {
            results.append(contentsOf: axSubtreeSearchableStrings(for: child, depth: depth + 1))
        }
        return results
    }

    private static func isMailSuggestionActionRole(_ role: String) -> Bool {
        ["AXRow", "AXGroup", "AXButton", "AXMenuItem", "AXListItem", "AXCell"].contains(role)
    }

    private struct MailSuggestionMatcher {
        let tokenKind: MailAutomationSearchTokenKind
        let normalizedQuery: String
        let normalizedCandidates: [String]
        let normalizedQueryTokens: [String]
        let normalizedFieldTokens: [String]

        init(query: String, tokenKind: MailAutomationSearchTokenKind, candidates: [String]) {
            self.tokenKind = tokenKind
            self.normalizedQuery = normalize(query)
            self.normalizedCandidates = candidates.map(normalize).filter { !$0.isEmpty }
            self.normalizedQueryTokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
            switch tokenKind {
            case .generic:
                self.normalizedFieldTokens = []
            case .sender:
                self.normalizedFieldTokens = ["sender", "contains"]
            case .subject:
                self.normalizedFieldTokens = ["subject", "contains"]
            case .attachment:
                self.normalizedFieldTokens = ["attachment", "name", "contains"]
            case .date:
                self.normalizedFieldTokens = ["date"]
            }
        }

        func score(role: String, actionNames: [String], directStrings: [String], subtreeStrings: [String]) -> Int? {
            let normalizedDirect = directStrings.map(normalize).filter { !$0.isEmpty }
            let normalizedSubtree = subtreeStrings.map(normalize).filter { !$0.isEmpty }
            let combinedDirect = normalizedDirect.joined(separator: " ")
            let combinedSubtree = normalizedSubtree.joined(separator: " ")
            guard !combinedSubtree.isEmpty else { return nil }

            let exactDirectMatch = normalizedCandidates.contains { combinedDirect == $0 || combinedDirect.contains($0) }
            let exactSubtreeMatch = normalizedCandidates.contains { combinedSubtree == $0 || combinedSubtree.contains($0) }

            let tokenMatch: Bool = {
                switch tokenKind {
                case .generic:
                    return false
                case .date:
                    return exactDirectMatch || exactSubtreeMatch
                        || normalizedQueryTokens.contains(where: { combinedSubtree.contains($0) })
                case .sender, .subject, .attachment:
                    let hasFieldTokens = normalizedFieldTokens.allSatisfy { combinedSubtree.contains($0) }
                    let hasQueryTokens =
                        !normalizedQueryTokens.isEmpty
                        && normalizedQueryTokens.allSatisfy { combinedSubtree.contains($0) }
                    return exactDirectMatch || exactSubtreeMatch || (hasFieldTokens && hasQueryTokens)
                }
            }()

            guard tokenMatch else { return nil }

            var score = 0
            if exactDirectMatch { score += 240 }
            if exactSubtreeMatch { score += 180 }
            if isMailSuggestionActionRole(role) { score += 120 }
            if role == "AXStaticText" { score -= 240 }
            if role == "AXRow" { score += 80 }
            if ["AXMenuItem", "AXListItem", "AXCell"].contains(role) { score += 60 }
            if ["AXGroup", "AXButton"].contains(role) { score += 40 }
            if actionNames.contains(kAXPressAction as String) { score += 30 }
            if actionNames.contains(kAXConfirmAction as String) { score += 15 }
            if combinedDirect.contains(normalizedQuery) { score += 20 }
            if combinedSubtree.contains(normalizedQuery) { score += 10 }
            return score
        }
    }

    private static func bestMailSuggestionTarget(
        in element: AXUIElement,
        matcher: MailSuggestionMatcher,
        depth: Int = 0
    ) -> (element: AXUIElement, score: Int)? {
        guard depth < 10 else { return nil }

        let role = axStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let actionNames = axStringArrayAttribute(element, "AXActions" as CFString)
        let directStrings = axSearchableStrings(for: element)
        let subtreeStrings = isMailSuggestionActionRole(role)
            ? axSubtreeSearchableStrings(for: element)
            : directStrings

        var best: (element: AXUIElement, score: Int)?
        if let score = matcher.score(
            role: role,
            actionNames: actionNames,
            directStrings: directStrings,
            subtreeStrings: subtreeStrings
        ) {
            best = (element, score)
        }

        for child in axChildElements(element) {
            guard let childBest = bestMailSuggestionTarget(in: child, matcher: matcher, depth: depth + 1)
            else { continue }
            if let currentBest = best {
                if childBest.score > currentBest.score { best = childBest }
            } else {
                best = childBest
            }
        }
        return best
    }

    private static func pressMailSuggestion(
        in element: AXUIElement,
        matcher: MailSuggestionMatcher
    ) -> Bool {
        guard let best = bestMailSuggestionTarget(in: element, matcher: matcher) else { return false }
        if AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success { return true }
        if AXUIElementPerformAction(best.element, kAXConfirmAction as CFString) == .success { return true }
        for child in axChildElements(best.element) {
            if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success { return true }
            if AXUIElementPerformAction(child, kAXConfirmAction as CFString) == .success { return true }
        }
        return false
    }

    private static func applyTokenSuggestion(
        query: String,
        tokenKind: MailAutomationSearchTokenKind,
        in pid: pid_t
    ) async -> Bool {
        let candidates: [String]
        switch tokenKind {
        case .generic:
            return true
        case .sender:
            candidates = ["Sender contains: \(query)"]
        case .subject:
            candidates = ["Subject contains: \(query)"]
        case .attachment:
            candidates = ["Attachment name contains: \(query)"]
        case .date:
            candidates = mailDateSuggestionCandidates(for: query)
        }

        let matcher = MailSuggestionMatcher(query: query, tokenKind: tokenKind, candidates: candidates)
        for _ in 0..<12 {
            let appElement = AXUIElementCreateApplication(pid)
            if pressMailSuggestion(in: appElement, matcher: matcher) { return true }
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        return false
    }

    static func openMailboxSearch(
        query: String,
        tokenKind: MailAutomationSearchTokenKind = .generic
    ) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "❌ No Mail search query provided." }
        guard let mailApp = await activateOrLaunchMail() else { return "❌ Couldn't open Mail." }

        let pid = mailApp.processIdentifier
        try? await Task.sleep(nanoseconds: 220_000_000)

        let liveItems = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)
        let mailboxSearchPath = liveItems.first(where: { item in
            normalize(item.title) == "mailbox search"
                || normalize(item.path.joined(separator: " ")) == "edit find mailbox search"
        })?.path

        var triggeredSearch = false
        if let mailboxSearchPath {
            triggeredSearch = AXMenuReader.shared.clickMenuItem(path: mailboxSearchPath, in: pid)
        }
        if !triggeredSearch {
            AXMenuReader.shared.executeShortcut(char: "f", modifiers: 2, in: pid)
            triggeredSearch = true
        }
        guard triggeredSearch else { return "❌ Couldn't open Mail search." }

        let injected = await injectSearchQuery(trimmed, into: pid)
        guard injected else {
            return "⚠️ Opened Mail search, but couldn't inject the query automatically."
        }

        let appliedToken = await applyTokenSuggestion(query: trimmed, tokenKind: tokenKind, in: pid)
        if tokenKind != .generic, appliedToken {
            return "✅ Opened Mailbox Search for \(tokenKind.rawValue): \(trimmed)"
        }
        return "✅ Opened Mailbox Search for “\(trimmed)”"
    }

    private static func injectSearchQuery(_ query: String, into pid: pid_t) async -> Bool {
        for _ in 0..<18 {
            if let focusedElement = currentFocusedElement(in: pid), isEditableAXElement(focusedElement) {
                let didSetAXValue = setAXTextValue(query, on: focusedElement)
                let didTypeValue = didSetAXValue ? false : await typeMailSearchQuery(query, into: focusedElement, pid: pid)
                if didSetAXValue || didTypeValue {
                    postKeyCode(36, to: pid)
                    return true
                }
            }

            let appElement = AXUIElementCreateApplication(pid)
            if let searchField = findMailSearchField(in: appElement) {
                let didSetAXValue = setAXTextValue(query, on: searchField)
                let didTypeValue = didSetAXValue ? false : await typeMailSearchQuery(query, into: searchField, pid: pid)
                if didSetAXValue || didTypeValue {
                    postKeyCode(36, to: pid)
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    nonisolated static func mailboxSnapshot(
        senderContains: String = "",
        subjectContains: String = "",
        unreadOnly: Bool = false,
        relativeDay: String = "",
        limit: Int = 20,
        maxScan: Int = 250
    ) -> String {
        let wantsToday = normalize(relativeDay) == "today"
        let wantsYesterday = normalize(relativeDay) == "yesterday"
        let safeLimit = max(1, min(limit, 50))
        let safeMaxScan = max(1, min(maxScan, 500))

        let script = """
            tell application "Mail"
                try
                    set senderFilter to "\(escapeAppleScriptLiteral(senderContains))"
                    set subjectFilter to "\(escapeAppleScriptLiteral(subjectContains))"
                    set wantsToday to \(wantsToday ? "true" : "false")
                    set wantsYesterday to \(wantsYesterday ? "true" : "false")
                    set wantsUnread to \(unreadOnly ? "true" : "false")
                    set maxScan to \(safeMaxScan)
                    set resultLimit to \(safeLimit)
                    set targetMailbox to missing value
                    set targetMailboxName to "Inbox"

                    set nowDate to current date
                    set todayStart to nowDate - (time of nowDate)
                    set todayEnd to todayStart + (24 * 60 * 60)
                    set yesterdayStart to todayStart - (24 * 60 * 60)
                    set yesterdayEnd to todayStart

                    try
                        if (count of message viewers) > 0 then
                            set viewerRef to item 1 of message viewers
                            try
                                set selectedBoxes to selected mailboxes of viewerRef
                                if (count of selectedBoxes) > 0 then
                                    set targetMailbox to item 1 of selectedBoxes
                                end if
                            end try
                            if targetMailbox is missing value then
                                try
                                    set selectedMsgs to selected messages of viewerRef
                                    if (count of selectedMsgs) > 0 then
                                        set targetMailbox to mailbox of (item 1 of selectedMsgs)
                                    end if
                                end try
                            end if
                        end if
                    end try

                    if targetMailbox is missing value then set targetMailbox to inbox
                    try
                        set targetMailboxName to (name of targetMailbox) as string
                    end try

                    set totalCount to count of messages of targetMailbox
                    if totalCount < maxScan then set maxScan to totalCount
                    set matchedLines to {}

                    repeat with i from 1 to maxScan
                        set msg to item i of messages of targetMailbox
                        set msgSender to (sender of msg) as string
                        set msgSubject to (subject of msg) as string
                        set msgDate to date received of msg
                        set msgRead to read status of msg

                        set senderMatches to (senderFilter is "")
                        if senderMatches is false then set senderMatches to (msgSender contains senderFilter)

                        set subjectMatches to (subjectFilter is "")
                        if subjectMatches is false then set subjectMatches to (msgSubject contains subjectFilter)

                        set dateMatches to true
                        if wantsToday then
                            set dateMatches to (msgDate ≥ todayStart and msgDate < todayEnd)
                        else if wantsYesterday then
                            set dateMatches to (msgDate ≥ yesterdayStart and msgDate < yesterdayEnd)
                        end if

                        set unreadMatches to true
                        if wantsUnread then set unreadMatches to (msgRead is false)

                        if senderMatches and subjectMatches and dateMatches and unreadMatches then
                            set end of matchedLines to "- " & msgSubject & " | From: " & msgSender & " | " & (msgDate as text) & " | Read: " & (msgRead as string)
                            if (count of matchedLines) ≥ resultLimit then exit repeat
                        end if
                    end repeat

                    if (count of matchedLines) = 0 then return "MAILBOX:" & targetMailboxName & return & "NO_MATCHES"

                    set AppleScript's text item delimiters to return
                    return "MAILBOX:" & targetMailboxName & return & (matchedLines as string)
                on error errMsg
                    return "ERROR: " & errMsg
                end try
            end tell
            """

        let result = AppleAppsAPI.shared.handleAppleScript(script) ?? ""
        if result.isEmpty {
            return "Mail context could not be read."
        }

        var mailboxName = "Inbox"
        var payload = result
        var lines = result.components(separatedBy: .newlines)
        if let first = lines.first, first.hasPrefix("MAILBOX:") {
            mailboxName = String(first.dropFirst("MAILBOX:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.removeFirst()
            payload = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if payload == "NO_MATCHES" {
            return "Mailbox: \(mailboxName)\nNo matching messages found."
        }
        if payload.hasPrefix("ERROR:") {
            return "Mailbox: \(mailboxName)\nMail context could not be read."
        }
        return "Mailbox: \(mailboxName)\n" + payload
    }

    nonisolated static func mailboxSnapshotData(
        senderContains: String = "",
        subjectContains: String = "",
        unreadOnly: Bool = false,
        relativeDay: String = "",
        limit: Int = 20,
        maxScan: Int = 250
    ) -> MailAutomationMailboxSnapshot? {
        let summary = mailboxSnapshot(
            senderContains: senderContains,
            subjectContains: subjectContains,
            unreadOnly: unreadOnly,
            relativeDay: relativeDay,
            limit: limit,
            maxScan: maxScan
        )

        let lines = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("Mailbox: ") else { return nil }

        let mailboxName = String(first.dropFirst("Mailbox: ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lines.count == 1 || lines.dropFirst().first == "No matching messages found." {
            return MailAutomationMailboxSnapshot(mailboxName: mailboxName, messages: [])
        }
        if lines.dropFirst().first == "Mail context could not be read." {
            return nil
        }

        let messages = lines.dropFirst().compactMap { line -> MailAutomationMessageSummary? in
            guard line.hasPrefix("- ") else { return nil }
            let payload = String(line.dropFirst(2))

            guard let fromRange = payload.range(of: " | From: ") else { return nil }
            let subject = String(payload[..<fromRange.lowerBound]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let senderAndRest = String(payload[fromRange.upperBound...])

            guard let dateSeparator = senderAndRest.range(of: " | ") else { return nil }
            let sender = String(senderAndRest[..<dateSeparator.lowerBound]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let dateAndRead = String(senderAndRest[dateSeparator.upperBound...])

            guard let readRange = dateAndRead.range(of: " | Read: ") else { return nil }
            let dateText = String(dateAndRead[..<readRange.lowerBound]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let readText = String(dateAndRead[readRange.upperBound...]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return MailAutomationMessageSummary(
                subject: subject.isEmpty ? "(no subject)" : subject,
                sender: sender,
                dateText: dateText,
                isRead: readText.caseInsensitiveCompare("true") == .orderedSame
            )
        }

        return MailAutomationMailboxSnapshot(mailboxName: mailboxName, messages: messages)
    }
}
