// GlobalContextRow.swift
// Context-Dock
//
// Global Context in the corner: the dock's own index, not a second one.
//
// The first attempt at this scanned running apps' cached menus and ranked them — which is a
// slice of Global Context, and not the layer. The real thing is `GlobalSearchService`:
// running apps, installed apps, pinned and recent items, CLI tools, system commands, browser
// URLs and cached menus, each carrying the action that runs it. `GlobalContextSearchCoordinator`
// is what the dock queries, and it is what the corner queries now — so both surfaces rank the
// same machine the same way.

import AppKit
import Foundation

enum GlobalContextRow {

    /// What the corner offers for a typed query.
    ///
    /// Empty until something is typed, deliberately: Global Context is a search over the
    /// whole machine, and a resting list of "everything" is the one thing it cannot usefully
    /// show. The dock's own global bar rests empty behind its placeholder for the same
    /// reason.
    static func documents(for query: String, limit: Int)
        -> [GlobalSearchService.SearchDocument]
    {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        return Array(
            GlobalContextSearchCoordinator.shared
                .snapshot(query: typed, limit: limit, includeRunningCachedMenus: true)
                .documents
                .prefix(limit))
    }

    /// What the row says under its title — where this result comes from, in the user's words.
    static func subtitle(for doc: GlobalSearchService.SearchDocument) -> String {
        if !doc.subtitle.isEmpty { return doc.subtitle }
        switch doc.action {
        case .activatePID: return "Running app"
        case .launchPath, .launchBundleId: return "Application"
        case .cliScope: return "Command-line tool"
        case .systemCommandScope: return "System command"
        case .cachedMenu(_, let appName, let path, _, _):
            return ([appName] + path.dropLast()).joined(separator: " › ")
        case .adapterAction(_, let appName, _): return "\(appName) · App action"
        case .userExtension: return "Global Extension"
        case .browserURL(_, let browserName, _, _, let domain):
            return domain.isEmpty ? browserName : "\(domain) · \(browserName)"
        }
    }

    /// The symbol shown when a document has no icon of its own.
    static func symbol(for doc: GlobalSearchService.SearchDocument) -> String {
        switch doc.action {
        case .activatePID, .launchPath, .launchBundleId: return "app"
        case .cliScope: return "terminal"
        case .systemCommandScope: return "switch.2"
        case .cachedMenu: return "command"
        case .adapterAction: return "bolt.fill"
        case .userExtension: return "puzzlepiece.extension"
        case .browserURL: return "safari"
        }
    }

    /// Run what the row stands for.
    ///
    /// Launching, activating and opening are done here because they are unambiguous. A menu
    /// command goes through `MenuExecutionCoordinator` and an adapter action through
    /// `AppAdapterManager`, so their consent and verification still apply — the corner is a
    /// place to choose, never a second way to run.
    ///
    /// A CLI tool and a system command are *scopes* rather than one-shot actions: choosing
    /// one means "now work inside it", which is the dock's job and not something to fake
    /// here. Those hand over to the dock rather than half-running in the corner.
    @MainActor
    static func run(_ doc: GlobalSearchService.SearchDocument) {
        switch doc.action {
        case .activatePID(let pid, _, let path):
            if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
                app.activate()
            } else if let path {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }

        case .launchPath(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))

        case .launchBundleId(let bundleId, let path):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }

        case .browserURL(let url, let browserBundleId, _, _, _):
            if let browser = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: browserBundleId)
            {
                NSWorkspace.shared.open(
                    [url], withApplicationAt: browser,
                    configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }

        case .cachedMenu(let bundleId, _, let path, let shortcutChar, let shortcutModifiers):
            let pid = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            }?.processIdentifier ?? 0
            MenuExecutionCoordinator.shared.executeDockMenuAction(
                request: MenuExecutionCoordinator.DockMenuActionRequest(
                    sourcePID: pid,
                    launchBundleId: pid == 0 ? bundleId : nil,
                    path: path,
                    shortcutChar: shortcutChar,
                    shortcutModifiers: shortcutModifiers,
                    knownMenuItems: [],
                    isGlobalContextActive: true,
                    hasActiveDockContextSelection: false,
                    keepsDockFloating: true),
                callbacks: MenuExecutionCoordinator.DockMenuActionCallbacks(
                    hideBeforeExecution: {},
                    refreshRunningApps: {},
                    scheduleTerminationRefresh: { _ in },
                    reloadMenu: { _ in },
                    clearLiveDockMenuState: {},
                    refocusDockInput: {}))

        case .adapterAction(let bundleId, _, let actionId):
            guard let action = AppAdapterManager.shared.adapter(for: bundleId)?
                .actions.first(where: { $0.id == actionId })
            else { return }
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId && !$0.isTerminated
            }) {
                AXContextReader.shared.refreshLightweight(from: app)
            }
            let context = AXContextReader.shared.current
            Task { @MainActor in
                _ = await AppAdapterManager.shared.execute(
                    action, context: context, targetBundleId: bundleId)
            }

        case .userExtension(let id):
            // Opens its own panel, the same way the launcher opens it — the extension owns
            // how it presents itself, and the corner is another place to reach it.
            guard let ext = UserGlobalExtensionStore.shared.extensions.first(where: {
                $0.id == id
            }) else { return }
            ExtensionPanelManager.shared.open(ext)

        case .cliScope:
            // Handled by the field that ran the row — stepping into a tool changes that
            // field's scope, and this function does not know which field asked.
            break

        case .systemCommandScope:
            // Still a scope the dock owns; nothing in the corner runs one yet.
            NotificationCenter.default.post(name: .activateGlobalContext, object: nil)
        }
    }
}
