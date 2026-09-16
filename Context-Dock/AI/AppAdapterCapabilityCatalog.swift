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
        let queryTokens = significantTokens(query)
        guard !queryTokens.isEmpty else { return [] }

        let capabilities = CapabilityRegistry.shared.capabilities(for: bundleID)
            .filter { $0.appBundleID == bundleID }
        if bundleID == "com.apple.Notes",
            let routed = notesCandidate(
                appName: appName, bundleID: bundleID, query: query,
                capabilities: capabilities)
        {
            return [routed]
        }
        if bundleID == "com.apple.reminders",
            let routed = remindersCandidate(
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

    private static func extractSearchText(_ query: String) -> String {
        var text = query.lowercased()
        let prefixes = ["search apple notes", "search notes", "find my notes", "find notes", "find note"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        for prefix in [" for ", " about ", " containing ", " matching "] where text.hasPrefix(prefix) {
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
