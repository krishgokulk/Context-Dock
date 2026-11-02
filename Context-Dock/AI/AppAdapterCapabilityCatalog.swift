import Foundation

/// Executable capabilities shown in App Adapter settings and consumed by scoped chat.
/// Both surfaces must read the same registry.
@MainActor
enum AppAdapterCapabilityCatalog {

    /// The words people actually use for a capability, beside the one it was named with.
    ///
    /// Matching is token overlap between the sentence and the capability's id, title and
    /// field names. That works when the user speaks API ("append to my note") and fails
    /// exactly when they speak English ("add this to my notes"), which is most of the time.
    static func verbSynonyms(for capabilityID: String) -> String {
        let action = capabilityID.split(separator: ".").last.map(String.init) ?? capabilityID
        switch action {
        case "append": return "add put stick save write include attach"
        case "create": return "add new make save start write"
        case "search": return "find look lookup where which show list"
        case "read": return "open show display get contents"
        case "update": return "edit change amend revise"
        case "delete": return "remove trash erase clear"
        case "extract_tasks": return "todos tasks actions checklist"
        case "topContacts": return "most often frequently ranking top who"
        case "recent": return "latest last lately newest"
        default: return ""
        }
    }
    static func registeredCandidates(
        appName: String, bundleID: String, query: String
    ) -> [DoraXActionCandidate] {
        CapabilityRegistry.shared.refreshBuiltInMCPs()
        // The dictionary rung's cache (P13 #208): launched per scoped turn, but it
        // returns at once when the manifest is current, and a scan is fire-and-forget
        // (sdef is a command-line reader — no launch, no activation).
        AppDictionaryStore.shared.kickScanIfStale(bundleID: bundleID, appName: appName)
        let queryTokens = significantTokens(query)
        guard !queryTokens.isEmpty else { return [] }

        let capabilities = CapabilityRegistry.shared.capabilities(for: bundleID)
            .filter { $0.appBundleID == nil || $0.appBundleID?.caseInsensitiveCompare(bundleID) == .orderedSame }
        let lowerBundle = bundleID.lowercased()
        if lowerBundle == "com.apple.notes",
            let routed = notesCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.reminders",
            let routed = remindersCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.ical",
            let routed = calendarCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.addressbook",
            let routed = contactsCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.music",
            let routed = musicCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.photos",
            let routed = photosCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.mobilesms" || lowerBundle == "com.apple.messages",
            let routed = messagesCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.mail",
            let routed = mailCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.finder",
            let routed = finderCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.safari" || lowerBundle == "com.apple.safaritechnologypreview",
            let routed = safariCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if lowerBundle == "com.apple.terminal",
            let routed = terminalCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }

        return capabilities.compactMap { capability in
                let searchable = "\(capability.id) \(capability.title) "
                    + capability.inputSchema.fields
                        .map { "\($0.name) \($0.description)" }.joined(separator: " ")
                let overlap = queryTokens.intersection(
                    significantTokens(searchable + " " + Self.verbSynonyms(for: capability.id)))
                guard !overlap.isEmpty else { return nil }
                // Words that only say which app this is. Matching on them alone is weak
                // evidence — "notes" in "notes app" names the destination, not the task — so
                // it scores low instead of being discarded.
                //
                // Discarding was the bug. "note" and "notes" were on this list to stop a
                // match on the app's own name, and they are also the only words that
                // identify every Notes capability, so every request containing "note" lost
                // notes.append and notes.create and fell through to clicking Notes' menu bar
                // — where `Edit → Add Link…` is disabled unless a note is already open. A
                // weakly-matched capability still belongs in the ranking, because the thing
                // it was losing to is driving someone's screen.
                let meaningful = overlap.subtracting(["apple", "current", "file"])
                let coverage = meaningful.isEmpty
                    ? 0.1
                    : Double(meaningful.count) / Double(max(queryTokens.count, 1))
                var candidate = DoraXActionCandidate(
                    id: "capability.\(capability.id)", title: capability.title,
                    appName: appName, bundleID: bundleID, source: .mcp, route: .adapter,
                    capabilityID: capability.id,
                    requiredInputs: capability.inputSchema.fields.filter(\.required).map(\.name),
                    riskLevel: capability.riskLevel,
                    confidence: min(0.94, 0.78 + coverage * 0.16),
                    permissionKey: "generalAI.execute.\(bundleID).capability.\(capability.id)",
                    debugReason: "registered App Adapter capability \(capability.id) matched \(meaningful.sorted().joined(separator: ", "))")
                if capability.id == "notes.export" {
                    candidate.inputValues["savePath"] = defaultMarkdownExportPath()
                }
                return candidate
            }
    }

    /// Deterministic Notes routing. An operation phrase selects one tool before generic
    /// token scoring, so `notes.create`, `notes.search`, and `notes.export` never compete
    /// merely because all of them mention Apple Notes.
    private static func notesCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("export") && (lower.contains("markdown") || lower.contains(".md")) {
            capabilityID = "notes.export"
        } else if (lower.contains("task") || lower.contains("todo"))
            && (lower.contains("extract") || lower.contains("this note")
                || lower.contains("current note") || lower.contains("action item")) {
            capabilityID = "notes.extract_tasks"
        } else if lower.contains("related") || lower.contains("similar note") {
            capabilityID = "notes.link_related"
        } else if lower.contains("summarize") || lower.contains("summary") {
            capabilityID = "notes.summarize"
        } else if lower.contains("search") || lower.contains("find note") || lower.contains("find my note") {
            capabilityID = "notes.search"
        } else if lower.contains("read") || lower.contains("show note")
            || lower.contains("show this note") || lower.contains("what does this note say")
            || lower.contains("note contents") {
            capabilityID = "notes.read"
        } else if lower.contains("append") || lower.contains("add to this note") {
            capabilityID = "notes.append"
        } else if lower.contains("delete") || lower.contains("remove this note") {
            capabilityID = "notes.delete"
        } else if lower.contains("update") || lower.contains("rename this note") {
            capabilityID = "notes.update"
        } else if lower.contains("create") || lower.contains("new note") {
            capabilityID = "notes.create"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.96, reason: "Notes intent router selected \(capabilityID)")
        switch capabilityID {
        case "notes.export":
            candidate.inputValues["savePath"] = defaultMarkdownExportPath()
        case "notes.search":
            let searchText = extractSearchText(query)
            guard !searchText.isEmpty else { return nil }
            candidate.inputValues["query"] = searchText
            candidate.inputValues["maxResults"] = "10"
        case "notes.append":
            guard let text = textAfterMarker(query, markers: ["append ", "add "]), !text.isEmpty
            else { return nil }
            candidate.inputValues["text"] = text
        case "notes.create":
            guard let content = textAfterMarker(query, markers: ["titled ", "called ", "named "]),
                !content.isEmpty
            else { return nil }
            candidate.inputValues["title"] = content
            candidate.inputValues["body"] = ""
        case "notes.update":
            guard let title = textAfterMarker(query, markers: ["rename this note to ", "title to "]),
                !title.isEmpty
            else { return nil }
            candidate.inputValues["title"] = title
        default:
            break
        }
        return candidate
    }

    private static func remindersCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("overdue") {
            capabilityID = "reminders.overdue"
        } else if lower.contains("today") || lower.contains("due today") {
            capabilityID = "reminders.today"
        } else if lower.contains("complete") || lower.contains("mark done")
            || lower.contains("finish reminder") {
            capabilityID = "reminders.complete"
        } else if lower.contains("delete") || lower.contains("remove reminder") {
            capabilityID = "reminders.delete"
        } else if lower.contains("create") || lower.contains("add reminder")
            || lower.hasPrefix("remind me") || lower.contains("new reminder") {
            capabilityID = "reminders.create"
        } else if lower.contains("list") || lower.contains("show")
            || lower.contains("what reminders") || lower.contains("my reminders") {
            capabilityID = "reminders.list"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.97, reason: "Reminders intent router selected \(capabilityID)")
        switch capabilityID {
        case "reminders.list":
            candidate.inputValues["limit"] = "30"
        case "reminders.complete", "reminders.delete":
            guard let title = reminderObject(
                query, markers: ["complete ", "mark done ", "finish reminder ",
                                 "delete ", "remove reminder "]), !title.isEmpty
            else { return nil }
            candidate.inputValues["matchTitle"] = title
        case "reminders.create":
            guard let title = reminderObject(
                query, markers: ["remind me to ", "add reminder to ", "add reminder ",
                                 "create reminder to ", "create reminder ", "new reminder "]),
                !title.isEmpty
            else { return nil }
            candidate.inputValues["title"] = title
        default:
            break
        }
        return candidate
    }

    private static func reminderObject(_ query: String, markers: [String]) -> String? {
        textAfterMarker(query, markers: markers)?.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func calendarCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("today") || lower.contains("schedule today") || lower.contains("agenda today") {
            capabilityID = "calendar.today"
        } else if lower.contains("next") || lower.contains("upcoming event") || lower.contains("next meeting") {
            capabilityID = "calendar.next"
        } else if lower.contains("cancel") || lower.contains("delete event") || lower.contains("remove meeting") {
            capabilityID = "calendar.delete"
        } else if lower.contains("update") || lower.contains("reschedule") || lower.contains("change meeting") {
            capabilityID = "calendar.update"
        } else if lower.contains("create") || lower.contains("schedule") || lower.contains("new event") || lower.contains("add event") {
            capabilityID = "calendar.create"
        } else if lower.contains("search") || lower.contains("find event") || lower.contains("find meeting") {
            capabilityID = "calendar.search"
        } else if lower.contains("list") || lower.contains("events") || lower.contains("calendar") || lower.contains("agenda") {
            capabilityID = "calendar.list"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.96, reason: "Calendar intent router selected \(capabilityID)")
        switch capabilityID {
        case "calendar.search":
            let search = extractSearchText(query, customPrefixes: ["search calendar", "search events", "find event", "find meeting", "look up event"])
            guard !search.isEmpty else { return nil }
            candidate.inputValues["query"] = search
        case "calendar.create":
            let title = textAfterMarker(query, markers: ["titled ", "called ", "named ", "to ", "event ", "meeting "]) ?? "New Event"
            candidate.inputValues["title"] = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            candidate.inputValues["startDate"] = "today"
            candidate.inputValues["durationMinutes"] = "30"
        case "calendar.update":
            let match = textAfterMarker(query, markers: ["update event ", "update ", "reschedule ", "change meeting "]) ?? ""
            guard !match.isEmpty else { return nil }
            candidate.inputValues["matchTitle"] = match.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        case "calendar.delete":
            let match = textAfterMarker(query, markers: ["delete event ", "cancel event ", "remove event ", "cancel meeting ", "delete "]) ?? ""
            guard !match.isEmpty else { return nil }
            candidate.inputValues["matchTitle"] = match.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        case "calendar.list":
            candidate.inputValues["limit"] = "20"
            candidate.inputValues["days"] = "7"
        default:
            break
        }
        return candidate
    }

    private static func contactsCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("details") || lower.contains("phone number") || lower.contains("email of") || lower.contains("info for") {
            capabilityID = "contacts.details"
        } else if lower.contains("create") || lower.contains("new contact") || lower.contains("add contact") {
            capabilityID = "contacts.create"
        } else if lower.contains("search") || lower.contains("find") || lower.contains("who is") || lower.contains("look up") || lower.contains("contact") {
            capabilityID = "contacts.search"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.95, reason: "Contacts intent router selected \(capabilityID)")
        switch capabilityID {
        case "contacts.search":
            let search = extractSearchText(query, customPrefixes: ["search contacts", "find contact", "who is", "look up contact", "contact for"])
            guard !search.isEmpty else { return nil }
            candidate.inputValues["query"] = search
        case "contacts.details":
            let name = textAfterMarker(query, markers: ["details for ", "phone number of ", "email of ", "info for ", "for "]) ?? query
            candidate.inputValues["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        case "contacts.create":
            let name = textAfterMarker(query, markers: ["contact named ", "add contact ", "new contact ", "create contact "]) ?? ""
            let parts = name.split(separator: " ").map(String.init)
            candidate.inputValues["firstName"] = parts.first ?? "New"
            if parts.count > 1 {
                candidate.inputValues["lastName"] = parts.dropFirst().joined(separator: " ")
            }
        default:
            break
        }
        return candidate
    }

    private static func musicCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("volume") || lower.contains("sound level") || lower.contains("loudness") {
            capabilityID = "music.volume"
        } else if lower.contains("playing") || lower.contains("song") || lower.contains("track") || lower.contains("music") {
            capabilityID = "music.nowPlaying"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        return makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.96, reason: "Music intent router selected \(capabilityID)")
    }

    private static func photosCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("search") || lower.contains("photos of") || lower.contains("pictures of") || lower.contains("find photo") {
            capabilityID = "photos.search"
        } else if lower.contains("recent") || lower.contains("latest") || lower.contains("new photo") || lower.contains("camera roll") || lower.contains("photos") {
            capabilityID = "photos.recent"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.95, reason: "Photos intent router selected \(capabilityID)")
        switch capabilityID {
        case "photos.search":
            let search = extractSearchText(query, customPrefixes: ["search photos for", "search photos", "find photos of", "find photo", "photos of", "pictures of"])
            guard !search.isEmpty else { return nil }
            candidate.inputValues["query"] = search
            candidate.inputValues["limit"] = "10"
        case "photos.recent":
            candidate.inputValues["limit"] = "10"
        default:
            break
        }
        return candidate
    }

    private static func messagesCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("top contact") || lower.contains("message most") || lower.contains("text most") || lower.contains("frequent") {
            capabilityID = "messages.topContacts"
        } else if lower.contains("compose") || lower.contains("send message") || lower.contains("send text") || lower.hasPrefix("text ") {
            capabilityID = "messages.compose"
        } else if lower.contains("search") || lower.contains("find message") || lower.contains("find text") || lower.contains("messages about") {
            capabilityID = "messages.search"
        } else if lower.contains("recent") || lower.contains("latest") || lower.contains("unread") || lower.contains("messages") || lower.contains("texts") {
            capabilityID = "messages.recent"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.96, reason: "Messages intent router selected \(capabilityID)")
        switch capabilityID {
        case "messages.topContacts":
            candidate.inputValues["limit"] = "10"
        case "messages.recent":
            candidate.inputValues["limit"] = "10"
        case "messages.search":
            let search = extractSearchText(query, customPrefixes: ["search messages for", "search messages", "find message about", "find message", "messages about"])
            guard !search.isEmpty else { return nil }
            candidate.inputValues["query"] = search
            candidate.inputValues["limit"] = "10"
        case "messages.compose":
            let recipient = textAfterMarker(query, markers: ["text ", "message ", "to "]) ?? ""
            candidate.inputValues["recipient"] = recipient.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            candidate.inputValues["body"] = ""
        default:
            break
        }
        return candidate
    }

    private static func mailCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("current email") || lower.contains("this email") || lower.contains("selected message") {
            capabilityID = "mail.currentMessage"
        } else if lower.contains("draft") || lower.contains("compose") || lower.contains("write email") || lower.contains("reply") {
            capabilityID = "mail.createDraft"
        } else if lower.contains("search") || lower.contains("find mail") || lower.contains("unread") || lower.contains("from ") || lower.contains("mail today") {
            capabilityID = "mail.search"
        } else if lower.contains("read email") || lower.contains("read message") || lower.contains("read newest") {
            capabilityID = "mail.read"
        } else if lower.contains("recent") || lower.contains("latest email") || lower.contains("new mail") || lower.contains("inbox") {
            capabilityID = "mail.recent"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.96, reason: "Mail intent router selected \(capabilityID)")
        switch capabilityID {
        case "mail.search":
            if let sender = textAfterMarker(query, markers: ["from "])?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)),
               !sender.isEmpty {
                let cleaned = sender.replacingOccurrences(of: " today", with: "").replacingOccurrences(of: " yesterday", with: "")
                candidate.inputValues["sender"] = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if lower.contains("today") {
                candidate.inputValues["day"] = "today"
            } else if lower.contains("yesterday") {
                candidate.inputValues["day"] = "yesterday"
            }
            if lower.contains("unread") {
                candidate.inputValues["unreadOnly"] = "true"
            }
            candidate.inputValues["limit"] = "20"
        case "mail.createDraft":
            if let recipient = textAfterMarker(query, markers: ["to "])?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) {
                candidate.inputValues["to"] = recipient
            }
            candidate.inputValues["subject"] = ""
            candidate.inputValues["body"] = ""
        default:
            break
        }
        return candidate
    }

    private static func finderCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("folder summary") || lower.contains("summarize folder") || lower.contains("what's in this folder") || lower.contains("describe folder") {
            capabilityID = "finder.summarizeFolder"
        } else if lower.contains("grep") || lower.contains("search inside") || lower.contains("search in files") || lower.contains("find in files") {
            capabilityID = "finder.grepFiles"
        } else if lower.contains("rename plan") || lower.contains("batch rename") {
            capabilityID = "finder.renamePlan"
        } else if lower.contains("reveal") || lower.contains("show in finder") {
            capabilityID = "finder.reveal"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.95, reason: "Finder intent router selected \(capabilityID)")
        switch capabilityID {
        case "finder.grepFiles":
            let search = extractSearchText(query, customPrefixes: ["grep files for", "search in files for", "search inside files for", "find in files"])
            guard !search.isEmpty else { return nil }
            candidate.inputValues["query"] = search
        case "finder.renamePlan":
            let pattern = textAfterMarker(query, markers: ["pattern ", "to "]) ?? "file_{n}"
            candidate.inputValues["pattern"] = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            break
        }
        return candidate
    }

    private static func safariCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        let capabilityID: String?
        if lower.contains("summarize") || lower.contains("tldr") || lower.contains("what does this page say") || lower.contains("page summary") {
            capabilityID = "safari.summarizePage"
        } else if lower.contains("find in page") || lower.contains("find on page") || lower.contains("search page") {
            capabilityID = "browser.findInPage"
        } else if lower.contains("open url") || lower.contains("open link") || lower.contains("go to ") {
            capabilityID = "browser.openURL"
        } else {
            capabilityID = nil
        }
        guard let capabilityID,
            let capability = capabilities.first(where: { $0.id == capabilityID })
        else { return nil }

        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.96, reason: "Safari intent router selected \(capabilityID)")
        switch capabilityID {
        case "browser.findInPage":
            let text = extractSearchText(query, customPrefixes: ["find in page", "find on page", "search page for"])
            guard !text.isEmpty else { return nil }
            candidate.inputValues["text"] = text
        case "browser.openURL":
            if let url = textAfterMarker(query, markers: ["open url ", "go to ", "open link "]) {
                candidate.inputValues["url"] = url.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default:
            break
        }
        return candidate
    }

    private static func terminalCandidate(
        appName: String, bundleID: String, query: String,
        capabilities: [AICapability]
    ) -> DoraXActionCandidate? {
        let lower = query.lowercased()
        guard lower.hasPrefix("run ") || lower.hasPrefix("execute ") || lower.contains("terminal ") else {
            return nil
        }
        guard let capability = capabilities.first(where: { $0.id == "terminal.runCommand" }) else {
            return nil
        }
        let command = textAfterMarker(query, markers: ["run ", "execute ", "terminal "]) ?? query
        var candidate = makeCandidate(
            capability, appName: appName, bundleID: bundleID,
            confidence: 0.95, reason: "Terminal intent router selected terminal.runCommand")
        candidate.inputValues["command"] = command.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.inputValues["purpose"] = query
        return candidate
    }

    private static func makeCandidate(
        _ capability: AICapability, appName: String, bundleID: String,
        confidence: Double, reason: String
    ) -> DoraXActionCandidate {
        DoraXActionCandidate(
            id: "capability.\(capability.id)", title: capability.title,
            appName: appName, bundleID: bundleID, source: .mcp, route: .adapter,
            capabilityID: capability.id,
            requiredInputs: capability.inputSchema.fields.filter(\.required).map(\.name),
            riskLevel: capability.riskLevel, confidence: confidence,
            permissionKey: "generalAI.execute.\(bundleID).capability.\(capability.id)",
            debugReason: reason)
    }

    private static func extractSearchText(_ query: String, customPrefixes: [String] = []) -> String {
        var text = query.lowercased()
        let prefixes = customPrefixes + ["search apple notes", "search notes", "find my notes", "find notes", "find note"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        for prefix in [" for ", " about ", " containing ", " matching ", " of "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func textAfterMarker(_ query: String, markers: [String]) -> String? {
        for marker in markers {
            guard let range = query.range(of: marker, options: [.caseInsensitive]) else { continue }
            return String(query[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return nil
    }

    private static func significantTokens(_ text: String) -> Set<String> {
        let ignored: Set<String> = [
            "a", "an", "the", "to", "as", "in", "on", "of", "for", "with", "my",
            "this", "that", "please", "into", "from", "input", "optional", "required",
        ]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
    }

    private static func defaultMarkdownExportPath() -> String {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return folder.appendingPathComponent("Apple-Note-\(formatter.string(from: Date())).md").path
    }
}
