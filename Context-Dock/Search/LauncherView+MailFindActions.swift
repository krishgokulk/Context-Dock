import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension LauncherView {
    enum MailSearchTokenKind {
        case generic
        case sender
        case subject
        case attachment
        case date
    }

    struct MailSearchIntent {
        let query: String
        let tokenKind: MailSearchTokenKind
        let displayLabel: String
    }

    struct AppFindIntent {
        let query: String
        let targetBundleId: String
        let targetAppName: String
        let userMessage: String
        let commandTitle: String
        let preferMailboxSearch: Bool
    }

    struct AppFindToken {
        let title: String
        let targetBundleId: String
        let targetAppName: String
        let parentMenu: AXMenuItem?
        var selectedMenu: AXMenuItem?

        var hasChildMenu: Bool {
            guard let parentMenu else { return false }
            return parentMenu.children.contains { child in
                child.isEnabled || child.children.contains(where: { $0.isEnabled })
            }
        }
    }

    struct AppSearchProfile {
        let preferredMenuTitles: [String]
        let tryVisibleSearchFieldFirst: Bool
        let pressReturnAfterInject: Bool
    }

    func mailSearchDisplayLabel(
        query: String,
        tokenKind: MailSearchTokenKind
    ) -> String {
        switch tokenKind {
        case .date:
            return query
        case .sender:
            return "from \(query)"
        case .subject:
            return "subject \(query)"
        case .attachment:
            return "attachment \(query)"
        case .generic:
            return query
        }
    }

    func weekdayNameCandidate(for normalizedQuery: String) -> String? {
        let weekdays = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        ]
        return weekdays.first(where: {
            $0.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix($0)
        })
    }

    func mailDateSuggestionCandidates(for query: String) -> [String] {
        let normalized = normalizedDockPillText(query)
        guard !normalized.isEmpty else { return [] }

        var candidates: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        let calendar = Calendar.current
        let now = Date()

        if let weekday = weekdayNameCandidate(for: normalized) {
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

    func mailSemanticSearchIntent(from rawScopedQuery: String) -> MailSearchIntent? {
        let trimmed = rawScopedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalizedDockPillText(trimmed)
        let tokens = Set(dockPillTokens(normalized))
        let intentWords: Set<String> = ["search", "find", "lookup", "look", "show"]
        let dateCandidates = mailDateSuggestionCandidates(for: trimmed)
        let explicitSenderIntent = tokens.contains("from") || tokens.contains("sender")
        let explicitSubjectIntent = tokens.contains("subject")
        let explicitAttachmentIntent =
            tokens.contains("attachment") || tokens.contains("attachments")
            || tokens.contains("attach")
        let explicitDateIntent =
            tokens.contains("date") || !dateCandidates.isEmpty

        guard
            !tokens.isDisjoint(with: intentWords)
                || explicitSenderIntent
                || explicitSubjectIntent
                || explicitAttachmentIntent
                || explicitDateIntent
        else { return nil }

        if let quoted = firstQuotedPhrase(in: trimmed)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !quoted.isEmpty
        {
            let tokenKind: MailSearchTokenKind =
                explicitSenderIntent
                ? .sender
                : explicitSubjectIntent
                    ? .subject
                    : explicitAttachmentIntent
                        ? .attachment
                        : explicitDateIntent
                            ? .date
                            : .generic
            let label: String =
                tokenKind == .date
                ? quoted
                : tokenKind == .sender
                    ? "from \(quoted)"
                    : tokenKind == .subject
                        ? "subject \(quoted)"
                        : tokenKind == .attachment
                            ? "attachment \(quoted)"
                            : quoted
            return MailSearchIntent(query: quoted, tokenKind: tokenKind, displayLabel: label)
        }

        var cleaned = trimmed
        let patterns = [
            #"(?i)\b(search|find|lookup|look\s+for|show)\b"#,
            #"(?i)\b(mail|mails|email|emails|mailbox|inbox)\b"#,
            #"(?i)\b(sender|from|subject|attachment|attachments|attach|for|about|with|in|date)\b"#,
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        cleaned =
            cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let tokenKind: MailSearchTokenKind =
            explicitSenderIntent
            ? .sender
            : explicitSubjectIntent
                ? .subject
                : explicitAttachmentIntent
                    ? .attachment
                    : explicitDateIntent
                        ? .date
                        : .generic
        let label: String =
            tokenKind == .date
            ? cleaned
            : tokenKind == .sender
                ? "from \(cleaned)"
                : tokenKind == .subject
                    ? "subject \(cleaned)"
                    : tokenKind == .attachment
                        ? "attachment \(cleaned)"
                        : cleaned

        return MailSearchIntent(query: cleaned, tokenKind: tokenKind, displayLabel: label)
    }

    func mailSemanticSearchQuery(from rawScopedQuery: String) -> String? {
        mailSemanticSearchIntent(from: rawScopedQuery)?.query
    }

    /// Whether the sentence is asking something. Says nothing about whether it is asking
    /// about mail — see `MailQuestionRouter.mentionsMailbox` for that half, which the
    /// attach-context prompt now also requires.
    func isQuestionStyleMailQuery(_ rawScopedQuery: String) -> Bool {
        MailQuestionRouter.isQuestionShaped(rawScopedQuery)
    }

    /// Whether Mail's Mailbox Search shortcut takes this turn before the model (issue #195).
    /// Only when the sentence IS the search command and its value — "search mail from SBI".
    /// "check my recent mail from … and do what it says" or "find mail from SBI today" is a
    /// request: the model takes it, with `mail.search` and `mail.read`.
    func shouldExecuteMailMailboxSearch(for rawScopedQuery: String) -> MailSearchIntent? {
        guard let command = MailboxSearchCommand.claims(rawScopedQuery) else { return nil }
        let tokenKind: MailSearchTokenKind
        switch command.field {
        case .any: tokenKind = .generic
        case .sender: tokenKind = .sender
        case .subject: tokenKind = .subject
        case .attachment: tokenKind = .attachment
        }
        return MailSearchIntent(
            query: command.term,
            tokenKind: tokenKind,
            displayLabel: mailSearchDisplayLabel(query: command.term, tokenKind: tokenKind))
    }

    struct MailQuestionFilters {
        let senderFilter: String
        let subjectFilter: String
        let unreadOnly: Bool
        let relativeDay: String
        let criteriaSummary: [String]
    }

    func mailFieldFilter(
        from query: String,
        triggers: Set<String>
    ) -> String? {
        let tokens = dockPillTokens(normalizedDockPillText(query))
        guard let triggerIndex = tokens.firstIndex(where: { triggers.contains($0) }) else {
            return nil
        }

        let stopWords: Set<String> = [
            "today", "yesterday", "tomorrow", "unread", "read", "mail", "mails", "email",
            "emails", "mailbox", "inbox", "is", "are", "was", "were", "any", "there", "show",
            "find", "search", "lookup", "look", "for", "about", "with", "and", "or", "the",
            "a", "an", "messages", "message", "date",
        ]

        var collected: [String] = []
        for token in tokens.dropFirst(triggerIndex + 1) {
            if stopWords.contains(token) { break }
            collected.append(token)
        }

        let result = collected.joined(separator: " ").trimmingCharacters(
            in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    func mailQuestionFilters(for query: String) -> MailQuestionFilters {
        let normalized = normalizedDockPillText(query)
        let senderFilter = mailFieldFilter(from: query, triggers: ["from", "sender"]) ?? ""
        let subjectFilter = mailFieldFilter(from: query, triggers: ["subject"]) ?? ""
        let unreadOnly = normalized.contains("unread")

        let relativeDay: String =
            normalized.contains("today")
            ? "today"
            : normalized.contains("yesterday")
                ? "yesterday"
                : ""

        let criteriaSummary: [String] = [
            !senderFilter.isEmpty ? "sender contains “\(senderFilter)”" : nil,
            !subjectFilter.isEmpty ? "subject contains “\(subjectFilter)”" : nil,
            !relativeDay.isEmpty ? "received \(relativeDay)" : nil,
            unreadOnly ? "unread only" : nil,
        ].compactMap { $0 }

        return MailQuestionFilters(
            senderFilter: senderFilter,
            subjectFilter: subjectFilter,
            unreadOnly: unreadOnly,
            relativeDay: relativeDay,
            criteriaSummary: criteriaSummary
        )
    }

    func answerAttachedMailQuestion(for rawScopedQuery: String) -> String? {
        guard isCurrentMailContextAttached(), isQuestionStyleMailQuery(rawScopedQuery) else {
            return nil
        }

        let filters = mailQuestionFilters(for: rawScopedQuery)
        let normalized = normalizedDockPillText(rawScopedQuery)
        let hasUsefulFilters =
            !filters.senderFilter.isEmpty
            || !filters.subjectFilter.isEmpty
            || filters.unreadOnly
            || !filters.relativeDay.isEmpty

        guard hasUsefulFilters || normalized.contains("mail") || normalized.contains("email") else {
            return nil
        }

        guard
            let snapshot = MailAutomation.mailboxSnapshotData(
                senderContains: filters.senderFilter,
                subjectContains: filters.subjectFilter,
                unreadOnly: filters.unreadOnly,
                relativeDay: filters.relativeDay,
                limit: 12,
                maxScan: 150
            )
        else {
            return "Mail context could not be read from the current mailbox."
        }

        let expectsYesNo =
            rawScopedQuery.contains("?")
            || normalized.hasPrefix("is ")
            || normalized.hasPrefix("are ")
            || normalized.hasPrefix("do ")
            || normalized.hasPrefix("does ")
            || normalized.hasPrefix("did ")
            || normalized.hasPrefix("have ")
            || normalized.hasPrefix("has ")
            || normalized.contains("any mail")
            || normalized.contains("any mails")

        let criteriaText = filters.criteriaSummary.joined(separator: ", ")
        let matchCount = snapshot.messages.count

        if matchCount == 0 {
            if expectsYesNo {
                return criteriaText.isEmpty
                    ? "No — I couldn't find matching mail in \(snapshot.mailboxName)."
                    : "No — I couldn't find mail in \(snapshot.mailboxName) matching \(criteriaText)."
            }
            return criteriaText.isEmpty
                ? "No matching mail found in \(snapshot.mailboxName)."
                : "No mail in \(snapshot.mailboxName) matched \(criteriaText)."
        }

        var answer =
            expectsYesNo
            ? "Yes — found \(matchCount) matching \(matchCount == 1 ? "mail" : "mails") in \(snapshot.mailboxName)"
            : "Found \(matchCount) matching \(matchCount == 1 ? "mail" : "mails") in \(snapshot.mailboxName)"
        if !criteriaText.isEmpty {
            answer += " (\(criteriaText))."
        } else {
            answer += "."
        }

        for message in snapshot.messages.prefix(4) {
            answer += "\n- \(message.subject) — \(message.sender) — \(message.dateText)"
        }
        if matchCount > 4 {
            answer += "\n+ \(matchCount - 4) more"
        }

        return answer
    }

    func buildAttachedMailContextBlock(for query: String) -> String? {
        let filters = mailQuestionFilters(for: query)
        guard
            let snapshot = MailAutomation.mailboxSnapshotData(
                senderContains: filters.senderFilter,
                subjectContains: filters.subjectFilter,
                unreadOnly: filters.unreadOnly,
                relativeDay: filters.relativeDay,
                limit: 12,
                maxScan: 150
            )
        else {
            return "\n📧 ACTUAL MAIL DATA:\nMail context could not be read.\n"
        }

        var block = "\n📧 ACTUAL MAIL DATA (recent \(snapshot.mailboxName) scan):\n"
        if !filters.criteriaSummary.isEmpty {
            block += "Criteria: " + filters.criteriaSummary.joined(separator: ", ") + "\n"
        }
        block += "Mailbox: \(snapshot.mailboxName)\n"

        if snapshot.messages.isEmpty {
            block += "No matching messages were found in the recent Mail scan.\n"
            return block
        }

        for message in snapshot.messages {
            block +=
                "- \(message.subject) | From: \(message.sender) | \(message.dateText) | Read: \(message.isRead)\n"
        }
        block +=
            "IMPORTANT: Use this ACTUAL mail data to answer mailbox questions. Do not make up email results.\n"
        return block
    }

    func applicationURL(bundleIdentifier: String, appName: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        if let match = allApplications.first(where: { result in
            Bundle(url: URL(fileURLWithPath: result.subtitle))?.bundleIdentifier == bundleIdentifier
        }) {
            return URL(fileURLWithPath: match.subtitle)
        }
        let fallbackDirectories = [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "\(NSHomeDirectory())/Applications",
        ]
        for directory in fallbackDirectories {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(appName)
                .appendingPathExtension("app")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    func activateOrLaunchSemanticApp(bundleIdentifier: String, appName: String) async
        -> NSRunningApplication?
    {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }) {
            await MainActor.run { runningApp.activate() }
            return runningApp
        }

        guard let appURL = applicationURL(bundleIdentifier: bundleIdentifier, appName: appName)
        else { return nil }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            let launchedApp = try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
            return launchedApp
        } catch {
            NSWorkspace.shared.open(appURL)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
                }) {
                    await MainActor.run { runningApp.activate() }
                    return runningApp
                }
            }
            return nil
        }
    }

    func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    func axStringArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [String] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return [] }
        return ref as? [String] ?? []
    }

    func axChildElements(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
                == .success,
            let children = ref as? [AXUIElement]
        else { return [] }
        return children
    }

    func currentFocusedElement(in pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &ref
            ) == .success, let focused = ref
        else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    func isEditableAXElement(_ element: AXUIElement) -> Bool {
        let role = axStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        return ["AXSearchField", "AXTextField", "AXComboBox", "AXTextArea"].contains(role)
    }

    func findMailSearchField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }

        let role = axStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        if role == "AXSearchField" {
            return element
        }

        let description = axStringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        let title = axStringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let help = axStringAttribute(element, kAXHelpAttribute as CFString) ?? ""
        let metadata = normalizedDockPillText([description, title, help].joined(separator: " "))

        if isEditableAXElement(element),
            metadata.contains("search") || metadata.contains("mailbox")
        {
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

    func findGenericSearchField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 9 else { return nil }

        let role = axStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        if role == "AXSearchField" {
            return element
        }

        let description = axStringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        let title = axStringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let help = axStringAttribute(element, kAXHelpAttribute as CFString) ?? ""
        let placeholder =
            axStringAttribute(element, "AXPlaceholderValue" as CFString) ?? ""
        let metadata = normalizedDockPillText(
            [description, title, help, placeholder].joined(separator: " ")
        )

        if isEditableAXElement(element),
            metadata.contains("search")
                || metadata.contains("find")
                || metadata.contains("filter")
        {
            return element
        }

        for child in axChildElements(element) {
            if let exact = findGenericSearchField(in: child, depth: depth + 1) {
                return exact
            }
        }
        return nil
    }

    func setAXTextValue(_ text: String, on element: AXUIElement) -> Bool {
        let setFocusStatus = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        _ = setFocusStatus
        guard
            AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                text as CFTypeRef
            ) == .success
        else { return false }

        guard let currentValue = axStringAttribute(element, kAXValueAttribute as CFString) else {
            return false
        }

        let normalizedCurrent = normalizedDockPillText(currentValue)
        let normalizedTarget = normalizedDockPillText(text)
        return normalizedCurrent == normalizedTarget
            || normalizedCurrent.contains(normalizedTarget)
    }

    func postKeyCode(_ keyCode: CGKeyCode, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    func postModifiedKeyCode(_ keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    func postUnicodeText(_ text: String, to pid: pid_t) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty,
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    func pasteString(_ text: String, to pid: pid_t) {
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

    func setFindPasteboardString(_ text: String) {
        let findPasteboard = NSPasteboard(name: NSPasteboard.Name("NSFindPboard"))
        findPasteboard.clearContents()
        findPasteboard.setString(text, forType: .string)
    }

    func injectSearchQuery(_ query: String, into pid: pid_t, pressReturn: Bool = false)
        async
        -> Bool
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        for _ in 0..<16 {
            let appElement = AXUIElementCreateApplication(pid)
            if let searchField = findGenericSearchField(in: appElement) {
                let didPasteValue = await typeMailSearchQuery(
                    trimmed,
                    into: searchField,
                    pid: pid
                )
                let didSetAXValue =
                    didPasteValue
                    ? false
                    : setAXTextValue(trimmed, on: searchField)
                if didPasteValue || didSetAXValue {
                    if pressReturn { postKeyCode(36, to: pid) }
                    return true
                }
            }

            if let focusedElement = currentFocusedElement(in: pid),
                isEditableAXElement(focusedElement)
            {
                let didPasteValue = await typeMailSearchQuery(
                    trimmed,
                    into: focusedElement,
                    pid: pid
                )
                let didSetAXValue =
                    didPasteValue
                    ? false
                    : setAXTextValue(trimmed, on: focusedElement)
                if didPasteValue || didSetAXValue {
                    if pressReturn { postKeyCode(36, to: pid) }
                    return true
                }
            }

            try? await Task.sleep(nanoseconds: 90_000_000)
        }

        return false
    }

    func typeMailSearchQuery(_ query: String, into element: AXUIElement, pid: pid_t) async
        -> Bool
    {
        _ = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        try? await Task.sleep(nanoseconds: 60_000_000)
        postModifiedKeyCode(0, flags: .maskCommand, to: pid)
        try? await Task.sleep(nanoseconds: 40_000_000)
        pasteString(query, to: pid)
        try? await Task.sleep(nanoseconds: 80_000_000)

        if let currentValue = axStringAttribute(element, kAXValueAttribute as CFString) {
            let normalizedCurrent = normalizedDockPillText(currentValue)
            let normalizedTarget = normalizedDockPillText(query)
            return normalizedCurrent == normalizedTarget
                || normalizedCurrent.contains(normalizedTarget)
        }

        return true
    }

    func axSearchableStrings(for element: AXUIElement) -> [String] {
        [
            axStringAttribute(element, kAXTitleAttribute as CFString),
            axStringAttribute(element, kAXValueAttribute as CFString),
            axStringAttribute(element, kAXDescriptionAttribute as CFString),
            axStringAttribute(element, kAXHelpAttribute as CFString),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    func axSubtreeSearchableStrings(for element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 2 else { return axSearchableStrings(for: element) }

        var results = axSearchableStrings(for: element)
        for child in axChildElements(element).prefix(12) {
            results.append(contentsOf: axSubtreeSearchableStrings(for: child, depth: depth + 1))
        }
        return results
    }








    func executeMailMailboxSearch(intent: MailSearchIntent, userMessage: String) {
        let searchQuery = intent.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return }

        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.isLoading = false
            l2.activeRequestID = nil
        }

        l2.chatMessages.append(AIChatMessage(role: .user, content: userMessage))
        l2.isLoading = true
        // A shortcut that runs before the model is still a turn that ran something: it
        // records its step like any tool, so the answer and the Corner panel show it
        // instead of "Answered without running anything" (issue #195).
        let requestID = beginL2AIRequest()
        let recorder = ActivityRecorder.active
        let stepID = recorder?.begin(
            kind: .tool, title: "Mail › mail.search", detail: intent.displayLabel)

        l2.currentTask = Task {
            @MainActor func finish(_ answer: String, ok: Bool, isError: Bool = false) {
                if let stepID {
                    recorder?.finish(stepID, status: ok ? .ok : .failed, output: answer)
                }
                l2.chatMessages.append(
                    AIChatMessage(role: .assistant, content: answer, isError: isError))
                finishL2AIRequest(requestID)
            }

            // Headless, as mail.search does it: Mail's window is never raised or typed into
            // (owner, 2026-10-10: the menu-click route was slow, raised Mail and lost the
            // sender token).
            guard AppSettings.shared.mailMCPEnabled else {
                finish("Mail access is disabled in Settings.", ok: false, isError: true)
                return
            }
            // ponytail: mailboxSnapshot filters only sender and subject; "any" and
            // attachment searches match the subject until the adapter grows those fields.
            let bySender = intent.tokenKind == .sender
            let summary = await Task.detached(priority: .userInitiated) {
                MailAutomation.mailboxSnapshot(
                    senderContains: bySender ? searchQuery : "",
                    subjectContains: bySender ? "" : searchQuery)
            }.value
            searchState.query = ""
            l2.focusedPillIndex = nil
            finish(summary, ok: true)
        }
    }

    func selectedTextPayloadForFindIntent() -> String {
        let context = effectiveAXContextForConversation()
        if let selected = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !selected.isEmpty
        {
            return selected
        }

        if case .textSelected(let text) = currentContext {
            let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty {
                return selected
            }
        }

        return ""
    }

    func findIntentPayload(from rawScopedQuery: String) -> String {
        let trimmed = rawScopedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let quoted = firstQuotedPhrase(in: trimmed)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !quoted.isEmpty
        {
            return quoted
        }

        var cleaned = trimmed
        let patterns = [
            #"(?i)\b(search|find|lookup|look\s+for|show|display)\b"#,
            #"(?i)\b(photos?\s+of|pictures?\s+of|images?\s+of)\b"#,
            #"(?i)^\s*of\s+"#,
            #"(?i)\b(selected|selection|this|that|text)\b"#,
            #"(?i)\b(in|inside|within|for|on|with|using|app|application)\b"#,
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        return
            cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isFindIntentCommand(_ rawScopedQuery: String, fullQuery: String) -> Bool {
        let raw = normalizedDockPillText(rawScopedQuery)
        let full = normalizedDockPillText(fullQuery)
        let prefixes = ["find", "search", "lookup", "look for", "show", "display"]
        if prefixes.contains(where: { prefix in
            raw == prefix || raw.hasPrefix(prefix + " ")
                || full == prefix || full.hasPrefix(prefix + " ")
        }) {
            return true
        }
        // "photos of X", "pictures of X" as standalone pattern
        let mediaPatterns = [
            #"(?i)^photos?\s+of\b"#, #"(?i)^pictures?\s+of\b"#, #"(?i)^images?\s+of\b"#,
        ]
        return mediaPatterns.contains { pat in
            raw.range(of: pat, options: .regularExpression) != nil
                || full.range(of: pat, options: .regularExpression) != nil
        }
    }

    func findTokenTitle(for rawScopedQuery: String) -> String {
        let normalized = normalizedDockPillText(rawScopedQuery)
        if normalized == "search" || normalized.hasPrefix("search ") {
            return "Search"
        }
        if normalized == "lookup" || normalized.hasPrefix("lookup ")
            || normalized == "look for" || normalized.hasPrefix("look for ")
        {
            return "Search"
        }
        return "Find"
    }

    func appSearchProfile(
        bundleIdentifier: String,
        appName: String,
        commandTitle: String
    ) -> AppSearchProfile {
        let bundle = bundleIdentifier.lowercased()
        let name = normalizedDockPillText(appName)
        let command = normalizedDockPillText(commandTitle)
        let isSearchCommand = command == "search"

        if bundle == "com.apple.mail" {
            return AppSearchProfile(
                preferredMenuTitles: ["mailbox search", "find..."],
                tryVisibleSearchFieldFirst: false,
                pressReturnAfterInject: true
            )
        }

        if bundle == "com.apple.notes" || name == "notes" {
            return AppSearchProfile(
                preferredMenuTitles: ["note list search...", "note list search", "find..."],
                tryVisibleSearchFieldFirst: false,
                pressReturnAfterInject: false
            )
        }

        if bundle == "com.apple.photos" || name == "photos" {
            return AppSearchProfile(
                preferredMenuTitles: ["search", "find", "find..."],
                tryVisibleSearchFieldFirst: true,
                pressReturnAfterInject: false
            )
        }

        let browserLike =
            name.contains("youtube")
            || name.contains("safari")
            || name.contains("chrome")
            || name.contains("firefox")
            || name.contains("brave")
            || name.contains("edge")
            || bundle.contains("safari")
            || bundle.contains("chrome")
            || bundle.contains("firefox")
            || bundle.contains("brave")
            || bundle.contains("edge")

        if browserLike || isSearchCommand {
            return AppSearchProfile(
                preferredMenuTitles: ["search", "find", "find..."],
                tryVisibleSearchFieldFirst: browserLike,
                pressReturnAfterInject: browserLike
            )
        }

        return AppSearchProfile(
            preferredMenuTitles: ["find", "find..."],
            tryVisibleSearchFieldFirst: false,
            pressReturnAfterInject: false
        )
    }

    func resolvedFindTarget(
        dockScope: DockScopeResolution
    ) -> (bundleId: String, appName: String)? {
        if dockScope.isExplicitAppScope,
            !dockScope.scopedBundleId.isEmpty,
            !dockScope.scopedAppName.isEmpty
        {
            return (dockScope.scopedBundleId, dockScope.scopedAppName)
        }

        if let target = l2.targetApp, !target.bundleId.hasPrefix("scope://") {
            return (target.bundleId, target.name)
        }

        if let app = contextTargetApp(),
            let bundleId = app.bundleIdentifier,
            !bundleId.isEmpty,
            bundleId != Bundle.main.bundleIdentifier
        {
            return (bundleId, app.localizedName ?? frontmost.name)
        }

        return nil
    }

    func leafFindChildren(for parent: AXMenuItem) -> [AXMenuItem] {
        var leaves: [AXMenuItem] = []
        for child in parent.children {
            if child.isLeaf {
                leaves.append(child)
            } else {
                leaves.append(contentsOf: child.children.filter(\.isLeaf))
            }
        }
        return leaves.filter { $0.isEnabled }
    }

    func findMenuParent(
        targetBundleId: String,
        targetAppName: String
    ) -> AXMenuItem? {
        let liveMatches = targetBundleId == frontmost.bundleID ? liveMenuItems : []
        let cachedMatches = GlobalContextEngine.shared.cachedMenuItems(
            bundleIdentifier: targetBundleId,
            appName: targetAppName,
            processIdentifier: 0,
            query: "find",
            maxResults: 32
        )
        let candidates = liveMatches + cachedMatches
        let normalizedFindTitles: Set<String> = ["find", "find..."]

        let parent =
            candidates.first { item in
                !item.children.isEmpty
                    && normalizedFindTitles.contains(normalizedDockPillText(item.title))
                    && !leafFindChildren(for: item).isEmpty
            }
            ?? synthesizedFindParentFromCachedPaths(
                cachedMatches,
                targetBundleId: targetBundleId,
                targetAppName: targetAppName
            )

        guard let parent else { return nil }

        let fallbackPID =
            parent.sourcePID != 0
            ? parent.sourcePID
            : (NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == targetBundleId && !$0.isTerminated
            }?.processIdentifier ?? 0)
        return menuItemWithSourceFallback(parent, pid: fallbackPID, appName: targetAppName)
    }

    func synthesizedFindParentFromCachedPaths(
        _ items: [AXMenuItem],
        targetBundleId: String,
        targetAppName: String
    ) -> AXMenuItem? {
        let placeholder = AXUIElementCreateSystemWide()
        var seen = Set<String>()
        let children: [AXMenuItem] = items.compactMap { item in
            let normalizedPath = item.path.map(normalizedDockPillText)
            guard
                let findIndex = normalizedPath.firstIndex(where: { $0 == "find" || $0 == "find..." }
                )
            else {
                return nil
            }
            guard item.path.count > findIndex + 1 else { return nil }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let key = item.path.joined(separator: " > ").lowercased()
            guard seen.insert(key).inserted else { return nil }
            var child = item
            child.children = []
            child.element = placeholder
            child.sourceAppName = targetAppName
            return child
        }

        guard !children.isEmpty else { return nil }
        return AXMenuItem(
            title: "Find",
            path: ["Edit", "Find"],
            isEnabled: true,
            element: placeholder,
            children: children,
            sourcePID: 0,
            sourceAppName: targetAppName
        )
    }

    func makeFindToken(
        title: String,
        targetBundleId: String,
        targetAppName: String
    ) -> AppFindToken {
        AppFindToken(
            title: title,
            targetBundleId: targetBundleId,
            targetAppName: targetAppName,
            parentMenu: findMenuParent(
                targetBundleId: targetBundleId,
                targetAppName: targetAppName
            ),
            selectedMenu: nil
        )
    }

    @discardableResult
    func activateFindTokenIfNeeded(from rawQuery: String) -> Bool {
        guard showContextInDock, !isGlobalContextActive, !aiMode.isActive,
            lockedFindToken == nil
        else { return false }

        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let scope = resolveDockScope(for: trimmed)
        let rawScopedQuery = rawScopedActionQuery(for: trimmed, scope: scope)
        guard isFindIntentCommand(rawScopedQuery, fullQuery: trimmed),
            let target = resolvedFindTarget(dockScope: scope)
        else { return false }

        let payload = findIntentPayload(from: rawScopedQuery)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            lockedFindToken = makeFindToken(
                title: findTokenTitle(for: rawScopedQuery),
                targetBundleId: target.bundleId,
                targetAppName: target.appName
            )
            showFindTokenMenu = false
            if searchState.query != payload {
                searchState.query = payload
            }
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            listViewHoveredIndex = nil
        }
        l2.appCompletion = nil
        l2.showResultsPopover = false
        cachedDockPills = []
        if scope.isExplicitAppScope,
            l2.targetApp?.bundleId != target.bundleId
        {
            _ = activateInlineDockAppScope(
                bundleIdentifier: target.bundleId,
                appName: target.appName,
                queryOverride: payload,
                preserveGlobalContext: isGlobalContextActive
            )
        }
        return true
    }

    func clearFindToken(preserveQuery: Bool = true) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
            lockedFindToken = nil
            showFindTokenMenu = false
            if !preserveQuery {
                searchState.query = ""
            }
        }
        scheduleDockPillRebuild(query: searchState.query, delayNanoseconds: 0)
    }

    func resolvedFindIntent(
        for query: String,
        dockScope: DockScopeResolution,
        rawScopedQuery: String
    ) -> AppFindIntent? {
        guard isFindIntentCommand(rawScopedQuery, fullQuery: query) else { return nil }

        let directPayload = findIntentPayload(from: rawScopedQuery)
        let selectedPayload = selectedTextPayloadForFindIntent()
        let searchQuery = directPayload.isEmpty ? selectedPayload : directPayload
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard let target = resolvedFindTarget(dockScope: dockScope) else { return nil }
        return AppFindIntent(
            query: searchQuery,
            targetBundleId: target.bundleId,
            targetAppName: target.appName,
            userMessage: query,
            commandTitle: findTokenTitle(for: rawScopedQuery),
            preferMailboxSearch: target.bundleId == "com.apple.mail"
        )
    }

    func openFindInterface(
        in pid: pid_t,
        bundleIdentifier: String,
        appName: String,
        commandTitle: String = "Find"
    ) async -> Bool {
        let profile = appSearchProfile(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            commandTitle: commandTitle
        )
        let preferredTitles = Set(profile.preferredMenuTitles.map { normalizedDockPillText($0) })
        let liveItems = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)

        if let preferredPath = liveItems.first(where: { item in
            let title = normalizedDockPillText(item.title)
            let path = normalizedDockPillText(item.path.joined(separator: " "))
            return preferredTitles.contains(title)
                || profile.preferredMenuTitles.contains(where: { preferred in
                    path.hasSuffix(" " + normalizedDockPillText(preferred))
                })
        })?.path,
            AXMenuReader.shared.clickMenuItem(path: preferredPath, in: pid)
        {
            return true
        }

        AXMenuReader.shared.executeShortcut(char: "f", modifiers: 2, in: pid)
        return true
    }

    func openAppFindInterface(
        targetBundleId: String,
        targetAppName: String,
        userMessage: String
    ) {
        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.activeRequestID = nil
        }

        let actionId = DockActionFeedback.start(
            "Opening Find",
            subject: targetAppName,
            icon: "magnifyingglass",
            tint: .accentColor
        )

        l2.currentTask = Task {
            guard
                let app = await activateOrLaunchSemanticApp(
                    bundleIdentifier: targetBundleId,
                    appName: targetAppName
                )
            else {
                await MainActor.run {
                    DockActionFeedback.fail(actionId, label: "Couldn't open \(targetAppName)")
                    l2.currentTask = nil
                }
                return
            }

            try? await Task.sleep(nanoseconds: 180_000_000)
            let opened = await openFindInterface(
                in: app.processIdentifier,
                bundleIdentifier: targetBundleId,
                appName: targetAppName
            )

            await MainActor.run {
                if opened {
                    DockActionFeedback.complete(actionId)
                    searchState.query = ""
                    l2.focusedPillIndex = nil
                    scheduleDockPillRebuild(query: "", delayNanoseconds: 0)
                } else {
                    DockActionFeedback.fail(actionId, label: "Find unavailable")
                }
                l2.currentTask = nil
            }
        }
    }

    func executeAppFindIntent(_ intent: AppFindIntent) {
        let searchQuery = intent.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return }

        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.activeRequestID = nil
        }

        // Hide the dock BEFORE injecting. The injector opens the app's search with
        // synthetic Cmd+F/paste key events, which go to whatever window is key — while
        // the dock is visible it stays key and eats them, so nothing was typed into any
        // app. Yielding key to the target app lets the keystrokes land.
        resetDockStateAfterAppAction()
        forceHideLauncherAfterResultExecution()

        let searchActionId = DockActionFeedback.start(
            "Searching", subject: "\(intent.targetAppName) for \"\(searchQuery)\"",
            icon: "magnifyingglass", tint: .accentColor)

        l2.currentTask = Task {
            guard
                let app = await activateOrLaunchSemanticApp(
                    bundleIdentifier: intent.targetBundleId,
                    appName: intent.targetAppName
                )
            else {
                await MainActor.run {
                    DockActionFeedback.fail(
                        searchActionId, label: "Couldn't open \(intent.targetAppName)")
                    l2.currentTask = nil
                }
                return
            }

            let message = await AXSearchFieldInjector.shared.inject(query: searchQuery, into: app)
            let injected = message.hasPrefix("✅")

            await MainActor.run {
                if injected {
                    DockActionFeedback.complete(searchActionId)
                    searchState.query = ""
                    clearFindToken(preserveQuery: false)
                    l2.focusedPillIndex = nil
                    scheduleDockPillRebuild(query: "", delayNanoseconds: 0)
                } else {
                    DockActionFeedback.fail(searchActionId, label: "Search field not found")
                }
                l2.currentTask = nil
            }
        }
    }

    func executeFindToken(_ token: AppFindToken, userMessage: String) {
        let searchQuery = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let selectedMenu = token.selectedMenu {
            executeFindTokenMenu(
                selectedMenu,
                token: token,
                searchQuery: searchQuery,
                userMessage: userMessage
            )
            return
        }

        if searchQuery.isEmpty {
            openAppFindInterface(
                targetBundleId: token.targetBundleId,
                targetAppName: token.targetAppName,
                userMessage: userMessage
            )
            return
        }

        executeAppFindIntent(
            AppFindIntent(
                query: searchQuery,
                targetBundleId: token.targetBundleId,
                targetAppName: token.targetAppName,
                userMessage: userMessage,
                commandTitle: token.title,
                preferMailboxSearch: token.targetBundleId == "com.apple.mail"
            )
        )
    }

    func executeFindTokenMenu(
        _ menuItem: AXMenuItem,
        token: AppFindToken,
        searchQuery: String,
        userMessage: String
    ) {
        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.activeRequestID = nil
        }

        let actionId = DockActionFeedback.start(
            searchQuery.isEmpty ? "Opening Find" : "Searching",
            subject: searchQuery.isEmpty
                ? token.targetAppName
                : "\(token.targetAppName) for \"\(searchQuery)\"",
            icon: "magnifyingglass",
            tint: .accentColor
        )

        l2.currentTask = Task {
            guard
                let app = await activateOrLaunchSemanticApp(
                    bundleIdentifier: token.targetBundleId,
                    appName: token.targetAppName
                )
            else {
                await MainActor.run {
                    DockActionFeedback.fail(actionId, label: "Couldn't open \(token.targetAppName)")
                    l2.currentTask = nil
                }
                return
            }

            let pid = app.processIdentifier
            let path = menuItem.path
            let shortcutSent: Bool
            if let sc = menuItem.shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines),
                !sc.isEmpty
            {
                shortcutSent = AXMenuReader.shared.executeShortcut(
                    char: sc,
                    modifiers: menuItem.shortcutModifiers,
                    in: pid
                )
            } else {
                shortcutSent = false
            }
            if !shortcutSent {
                _ = AXMenuReader.shared.clickMenuItem(path: path, in: pid)
            }

            var injected = searchQuery.isEmpty
            if !searchQuery.isEmpty {
                setFindPasteboardString(searchQuery)
                try? await Task.sleep(nanoseconds: 160_000_000)
                injected = await injectSearchQuery(searchQuery, into: pid)
            }

            await MainActor.run {
                if injected {
                    DockActionFeedback.complete(actionId)
                    clearFindToken(preserveQuery: false)
                    l2.focusedPillIndex = nil
                    scheduleDockPillRebuild(query: "", delayNanoseconds: 0)
                } else {
                    DockActionFeedback.fail(actionId, label: "Search field not found")
                }
                l2.currentTask = nil
            }
        }
    }

}
