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

        return CapabilityRegistry.shared.capabilities(for: bundleID)
            .filter { $0.appBundleID == bundleID }
            .compactMap { capability in
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
