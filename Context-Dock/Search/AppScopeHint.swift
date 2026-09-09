// AppScopeHint.swift
// Context-Dock
//
// What a scoped field offers, in the app's own terms: "Finder — search files and folders",
// "Code — run tasks, commands, menu cmds".
//
// The dock has said this for a long time, from `dockScopeGhostPrompt` — another rule that
// lived on `LauncherView` and so could not be read anywhere else. The corner scopes into an
// app now too, and a placeholder that said something different there would be two answers to
// "what can I do here".
//
// The dock keeps its own version for the states only it has (a Finder folder being browsed,
// desktop-only mode, a live selection); this is the part both surfaces share.

import Foundation

enum AppScopeHint {

    /// The hint alone, without the app's name.
    static func hint(bundleId: String, appName: String, hasActions: Bool = false) -> String {
        let lowerName = appName.lowercased()

        if bundleId == "com.apple.finder" || lowerName == "finder" {
            return "search files and folders"
        }
        if AXWebReader.shared.isBrowser(bundleId: bundleId) {
            return "tabs, page cmds, menu cmds"
        }
        if bundleId == "com.microsoft.VSCode" || lowerName.contains("code") {
            return "run tasks, commands, menu cmds"
        }
        if bundleId == "com.apple.mail" || lowerName.contains("mail") {
            return "mailboxes, compose, search, menu cmds"
        }
        if bundleId == "com.apple.MobileSMS" || lowerName.contains("message") {
            return "send, search chats, menu cmds"
        }
        if bundleId.hasPrefix("cli://") {
            return "run commands, inspect help"
        }
        return hasActions ? "app actions, menu cmds" : "menu cmds"
    }

    /// "Finder — search files and folders", the whole line a scoped field shows.
    static func placeholder(bundleId: String, appName: String, hasActions: Bool = false)
        -> String
    {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = name.isEmpty ? "Context" : name
        return "\(scope) — \(hint(bundleId: bundleId, appName: scope, hasActions: hasActions))"
    }
}
