import Foundation

/// Static quality gate shared by built-in evals and user-authored adapter packs.
///
/// Passing this contract means an adapter is structurally safe to load. It does not claim
/// that a third-party app exposes the state needed to verify every action; that is recorded
/// separately by grounded readers and action verifiers.
enum AppAdapterContract {
    enum Severity: String, Equatable { case error, warning }

    struct Finding: Equatable {
        let severity: Severity
        let path: String
        let message: String
    }

    static func evaluate(_ adapter: AppAdapter) -> [Finding] {
        var findings: [Finding] = []
        func add(_ severity: Severity, _ path: String, _ message: String) {
            findings.append(Finding(severity: severity, path: path, message: message))
        }

        if adapter.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.error, "bundleId", "An adapter must identify its owning app.")
        }
        if adapter.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.error, "appName", "An adapter must have a display name.")
        }

        let actionIDs = adapter.actions.map(\.id)
        for id in duplicates(actionIDs) {
            add(.error, "actions.\(id)", "Action ids must be unique inside one adapter.")
        }
        let availableActionIDs = Set(actionIDs)
        for action in adapter.actions {
            let path = "actions.\(action.id.isEmpty ? "<empty>" : action.id)"
            if action.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(.error, path, "An action must have an id.")
            }
            if action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(.error, path, "An action must have a name.")
            }
            if (action.isDestructive || action.type.riskLevel == .high),
               !action.requiresApproval {
                add(.error, path, "Destructive and high-risk actions must require approval.")
            }
            if !hasPayload(action) {
                add(.error, path, "The \(action.type.rawValue) action has no executable payload.")
            }
            for rawLink in action.chain ?? [] {
                let link = rawLink.hasPrefix("!") ? String(rawLink.dropFirst()) : rawLink
                if link == action.id {
                    add(.error, path, "An action cannot chain to itself.")
                } else if !availableActionIDs.contains(link) {
                    add(.error, path, "Chained action '\(link)' does not exist in this adapter.")
                }
            }
        }

        let readerIDs = adapter.contextReaders.map(\.id)
        for id in duplicates(readerIDs) {
            add(.error, "contextReaders.\(id)", "Context reader ids must be unique.")
        }
        for reader in adapter.contextReaders {
            let path = "contextReaders.\(reader.id.isEmpty ? "<empty>" : reader.id)"
            if reader.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(.error, path, "A context reader must have an id.")
            }
            if !["applescript", "jxa", "shell"].contains(reader.type) {
                add(.error, path, "Unknown context reader type '\(reader.type)'.")
            }
            if reader.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(.error, path, "A context reader must have a script.")
            }
        }

        if adapter.actions.isEmpty && adapter.contextReaders.isEmpty {
            add(.warning, "adapter", "This adapter has no actions or context readers yet.")
        }
        return findings
    }

    static func errors(in adapter: AppAdapter) -> [Finding] {
        evaluate(adapter).filter { $0.severity == .error }
    }

    private static func duplicates(_ values: [String]) -> [String] {
        Dictionary(grouping: values, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
    }

    private static func hasPayload(_ action: AdapterAction) -> Bool {
        switch action.type {
        case .menubar: return !(action.menuPath ?? []).isEmpty
        case .applescript, .jxa, .shell, .pageJS:
            return !(action.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .cliTool:
            return !(action.cliToolCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .urlScheme:
            return !(action.urlScheme ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openItem:
            return !(action.urlScheme ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(action.scriptFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .scriptFile:
            return !(action.scriptFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .shortcut:
            return !(action.shortcutName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .aiPrompt:
            return !(action.aiPromptTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
