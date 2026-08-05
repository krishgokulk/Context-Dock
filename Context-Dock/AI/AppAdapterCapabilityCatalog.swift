import Foundation

/// Executable capabilities shown in App Adapter settings and consumed by scoped chat.
/// Both surfaces must read the same registry.
@MainActor
enum AppAdapterCapabilityCatalog {
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

        return capabilities.compactMap { capability in
                let searchable = "\(capability.id) \(capability.title) "
                    + capability.inputSchema.fields
                        .map { "\($0.name) \($0.description)" }.joined(separator: " ")
                let overlap = queryTokens.intersection(significantTokens(searchable))
                let meaningful = overlap.subtracting(["apple", "note", "notes", "current", "file"])
                guard !meaningful.isEmpty else { return nil }
                let coverage = Double(meaningful.count) / Double(max(queryTokens.count, 1))
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
        } else if lower.contains("extract") && (lower.contains("task") || lower.contains("todo")) {
            capabilityID = "notes.extract_tasks"
        } else if lower.contains("related") || lower.contains("similar note") {
            capabilityID = "notes.link_related"
        } else if lower.contains("summarize") || lower.contains("summary") {
            capabilityID = "notes.summarize"
        } else if lower.contains("search") || lower.contains("find note") || lower.contains("find my note") {
            capabilityID = "notes.search"
        } else if lower.contains("read") || lower.contains("show note") || lower.contains("show this note") {
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
