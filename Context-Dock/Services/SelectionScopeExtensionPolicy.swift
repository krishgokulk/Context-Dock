import Foundation

/// Fast, deterministic eligibility and safety policy for user-created Selection Scope
/// extensions.  This deliberately works from the frozen `AXContext` captured when the
/// sheet opened: filtering an action must never trigger another Accessibility read.
enum SelectionScopeExtensionPolicy {

    /// Whether an extension may be offered for this frozen selection.  Non-keyword triggers
    /// are requirements and are combined with AND semantics; keywords are search terms, not
    /// visibility requirements.
    static func isEligible(_ ext: ILExtension, context: AXContext, filePaths: [String]) -> Bool {
        guard ext.enabled, ext.layer == .l2_context, ext.category == "shortcutSheet" else {
            return false
        }

        let paths = filePaths.isEmpty ? context.selectedFilePaths : filePaths
        let text = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = context.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nonKeywordTriggers = ext.triggers.filter {
            if case .keyword = $0 { return false }
            return true
        }

        // Legacy extensions created before Selection Scope gained typed triggers are kept
        // compatible, but still require an actual selected payload.
        guard !nonKeywordTriggers.isEmpty else { return !text.isEmpty || !url.isEmpty || !paths.isEmpty }

        return nonKeywordTriggers.allSatisfy { trigger in
            switch trigger {
            case .always:
                return true
            case .selection:
                return !text.isEmpty || !url.isEmpty || !paths.isEmpty
            case .fileType(let types):
                let normalized = Set(types.map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                })
                return paths.contains { path in
                    normalized.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
                }
            case .appContext(let app):
                let needle = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !needle.isEmpty else { return true }
                return context.appName.lowercased().contains(needle)
                    || context.bundleId.lowercased().contains(needle)
            case .urlPattern(let pattern):
                guard !url.isEmpty else { return false }
                return urlMatches(url, pattern: pattern)
            case .keyword:
                return true
            }
        }
    }

    /// A conservative classification for scripts supplied by a person or an AI.  A click is
    /// enough for pure local read-only transforms; anything that can write, send, automate,
    /// access the network, or requests a permission gets an explicit native confirmation.
    static func needsApproval(_ ext: ILExtension) -> Bool {
        guard !ext.isBuiltIn else { return false }
        if !ext.requiresPermissions.isEmpty || ext.requiresInternet { return true }
        switch ext.scriptType {
        case .applescript, .javascript:
            return true
        case .bash, .python, .swift:
            break
        }
        let script = (ext.scriptContent ?? "").lowercased()
        let sideEffectTokens = [
            "rm ", "mv ", "cp ", "mkdir", "touch ", "ditto ", "zip ", "sips ",
            "ffmpeg", "open ", "osascript", "curl ", "wget ", "scp ", "rsync ",
            "pbcopy", "mailto:", "messages", "send ", "trash",
        ]
        return sideEffectTokens.contains { script.contains($0) }
    }

    static func approvalSummary(_ ext: ILExtension) -> String {
        var effects: [String] = []
        if ext.requiresInternet { effects.append("access the network") }
        if !ext.requiresPermissions.isEmpty { effects.append("use " + ext.requiresPermissions.joined(separator: ", ")) }
        if ext.scriptType == .applescript || ext.scriptType == .javascript { effects.append("control another app") }
        if effects.isEmpty { effects.append("change files, the clipboard, or another app") }
        return effects.joined(separator: " and ")
    }

    private static func urlMatches(_ url: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) {
            let range = NSRange(url.startIndex..., in: url)
            return regex.firstMatch(in: url, options: [], range: range) != nil
        }
        return url.localizedCaseInsensitiveContains(trimmed)
    }
}
