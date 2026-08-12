// ResolvedContext.swift
// Context-Dock
//
// What "this" means, resolved once per turn.
//
// Context used to be assembled inline, differently in each caller: one place read the AX
// snapshot, another the browser page, another the app's own window. When an answer was
// wrong there was no way to tell whether the model had reasoned badly or had simply been
// handed nothing — the two look identical from outside.
//
// Resolving into one value with named slots makes the difference visible. Every slot says
// where it came from, and the slots that could not be filled are recorded with the reason,
// so "it didn't know which file I meant" becomes a fact rather than a suspicion.

import AppKit
import Foundation
import OSLog

struct ResolvedContext {

    struct Slot: Identifiable, Equatable {
        let name: String
        let value: String
        /// Where the value came from — AX, the app's own API, the menu cache — so a stale
        /// or wrong value can be traced to its reader rather than to the model.
        let source: String

        var id: String { name }
    }

    /// A slot that could not be filled, and why. Kept rather than dropped: an empty slot
    /// is the most useful thing to know when an answer disappoints.
    struct Gap: Identifiable, Equatable {
        let name: String
        let reason: String

        var id: String { name }
    }

    let scope: GeneralChatScope
    let appName: String
    let bundleId: String
    var slots: [Slot] = []
    var gaps: [Gap] = []

    var isEmpty: Bool { slots.isEmpty }

    func value(_ name: String) -> String? {
        slots.first { $0.name == name }?.value
    }

    /// The facts, as the model receives them. Nothing inferred, nothing summarised — the
    /// prompt says where each line came from so the model can weigh a cached menu against
    /// a live window read.
    func promptBlock() -> String {
        guard !slots.isEmpty || !gaps.isEmpty else { return "" }
        var lines = ["## Current context for \(appName) (read just now, factual)"]
        for slot in slots {
            lines.append("- \(slot.name) [\(slot.source)]: \(slot.value)")
        }
        if !gaps.isEmpty {
            lines.append("")
            lines.append(
                "Not readable right now — say so plainly if the user asks about one; never "
                + "guess a value for it:")
            for gap in gaps {
                lines.append("- \(gap.name): \(gap.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What changed between two resolutions of the same scope. Used after an action to
    /// check the claim against the machine: an empty result means nothing observable
    /// happened, which is worth saying out loud.
    func changes(since earlier: ResolvedContext) -> [String] {
        var out: [String] = []
        for slot in slots {
            let before = earlier.value(slot.name)
            if before != slot.value {
                out.append(
                    before == nil
                        ? "\(slot.name) is now \(slot.value)"
                        : "\(slot.name): \(before ?? "") → \(slot.value)")
            }
        }
        // A slot that was readable and no longer is, is also a change.
        for slot in earlier.slots where value(slot.name) == nil {
            out.append("\(slot.name) is no longer readable")
        }
        return out
    }

    /// One line for the log: what was known, what was missing.
    var summary: String {
        let filled = slots.map(\.name).joined(separator: ", ")
        let missing = gaps.map(\.name).joined(separator: ", ")
        return "filled[\(filled)] missing[\(missing)]"
    }
}

@MainActor
enum ContextResolver {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "ContextResolver")

    /// Resolves everything known about a scope, once, before anything else runs.
    ///
    /// Readers are asked in order of authority: the app's own accessibility element first,
    /// because it is live and specific; the shared AX snapshot second, and only when it
    /// belongs to this app; caches last, labelled as caches.
    static func resolve(scope: GeneralChatScope, appName: String) -> ResolvedContext {
        switch scope {
        case .general:
            return ResolvedContext(scope: scope, appName: appName, bundleId: "")
        case .cli(let command):
            return resolveCLI(scope: scope, command: command)
        case .folder(let path):
            // A folder has no window, document or app state to read — its context is the
            // directory itself, which the prompt already carries as a listing. Resolving
            // it as an app would record gaps ("not running") about something that was
            // never an app.
            var context = ResolvedContext(scope: scope, appName: appName, bundleId: "")
            context.slots.append(
                .init(name: "folder", value: path, source: "user-attached"))
            return context
        case .app(let bundleId):
            return resolveApp(scope: scope, bundleId: bundleId, appName: appName)
        }
    }

    private static func resolveApp(
        scope: GeneralChatScope, bundleId: String, appName: String
    ) -> ResolvedContext {
        var context = ResolvedContext(scope: scope, appName: appName, bundleId: bundleId)

        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId).first
        guard let running, running.processIdentifier > 0 else {
            context.gaps.append(
                .init(name: "window", reason: "\(appName) is not running"))
            context.gaps.append(
                .init(name: "document", reason: "\(appName) is not running"))
            context.slots.append(
                .init(name: "app state", value: "not running", source: "NSWorkspace"))
            appendCapabilityCounts(&context, bundleId: bundleId, appName: appName)
            log.notice("resolved \(bundleId, privacy: .public): \(context.summary, privacy: .public)")
            return context
        }
        context.slots.append(
            .init(name: "app state", value: "running", source: "NSWorkspace"))

        // The app's own AX element: live, and specific to this app whether or not it is
        // the one the global snapshot happens to describe.
        let element = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)

        if let window = focusedWindow(of: element) {
            if let title = axString(window, kAXTitleAttribute as String) {
                context.slots.append(.init(name: "window", value: title, source: "AX"))
            } else {
                context.gaps.append(.init(name: "window", reason: "no window title exposed"))
            }
            if let document = axString(window, kAXDocumentAttribute as String) {
                let path = URL(string: document)?.path ?? document
                context.slots.append(.init(name: "document", value: path, source: "AX"))
            } else {
                context.gaps.append(
                    .init(name: "document", reason: "app exposes no open document"))
            }
        } else {
            context.gaps.append(.init(name: "window", reason: "no focused window"))
            context.gaps.append(.init(name: "document", reason: "no focused window"))
        }

        if let titles = otherWindowTitles(of: element), titles.count > 1 {
            context.slots.append(
                .init(
                    name: "open windows", value: titles.prefix(8).joined(separator: ", "),
                    source: "AX"))
        }

        // Shared snapshot: only when it is about this app. Using it otherwise is how a
        // Preview question came back describing the launcher.
        let snapshot = AXContextReader.shared.current
        if snapshot.bundleId == bundleId {
            if let selection = snapshot.selectedText?.trimmingCharacters(
                in: .whitespacesAndNewlines), !selection.isEmpty
            {
                context.slots.append(
                    .init(
                        name: "selection", value: String(selection.prefix(2_000)),
                        source: "AX snapshot"))
            } else {
                context.gaps.append(.init(name: "selection", reason: "nothing selected"))
            }
            if !snapshot.selectedFilePaths.isEmpty {
                context.slots.append(
                    .init(
                        name: "selected files",
                        value: snapshot.selectedFilePaths.prefix(10).joined(separator: ", "),
                        source: "AX snapshot"))
            }
        } else {
            context.gaps.append(
                .init(
                    name: "selection",
                    reason: "the accessibility snapshot belongs to \(snapshot.appName.isEmpty ? "another app" : snapshot.appName)"))
        }

        if ScopedAppPromptBuilder.isBrowserBundle(bundleId) {
            if let page = AppScopedChatService.browserPageFacts(bundleID: bundleId) {
                context.slots.append(.init(name: "page", value: page, source: "browser"))
            } else {
                context.gaps.append(
                    .init(name: "page", reason: "no readable page — the browser exposed none"))
            }
        }

        appendCapabilityCounts(&context, bundleId: bundleId, appName: appName)
        log.notice("resolved \(bundleId, privacy: .public): \(context.summary, privacy: .public)")
        return context
    }

    private static func resolveCLI(
        scope: GeneralChatScope, command: String
    ) -> ResolvedContext {
        var context = ResolvedContext(scope: scope, appName: command, bundleId: "cli://\(command)")
        guard let package = TerminalPackageManager.shared.packages.first(where: {
            $0.command.caseInsensitiveCompare(command) == .orderedSame
        }) else {
            context.gaps.append(
                .init(name: "tool", reason: "\(command) is not a pinned CLI tool"))
            return context
        }
        context.slots.append(
            .init(
                name: "tool", value: package.installedPath ?? package.command,
                source: "CLI scope"))
        if !package.subcommands.isEmpty {
            context.slots.append(
                .init(
                    name: "subcommands",
                    value: package.subcommands.prefix(20).joined(separator: ", "),
                    source: "help scan"))
        } else {
            context.gaps.append(
                .init(name: "subcommands", reason: "no --help scan has been run for this tool"))
        }
        log.notice("resolved \(command, privacy: .public): \(context.summary, privacy: .public)")
        return context
    }

    /// What DoraX can do here, as counts. The full inventory is in the prompt already; the
    /// counts let the model say "no route exists" with confidence instead of hedging.
    private static func appendCapabilityCounts(
        _ context: inout ResolvedContext, bundleId: String, appName: String
    ) {
        let adapter = AppAdapterManager.shared.adapters.first { $0.bundleId == bundleId }
        let actions = adapter?.actions.count ?? 0
        let menus = AppMenuCapabilityCache.shared.summary(bundleIdentifier: bundleId)?
            .recordCount ?? 0
        let clis = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleId)
        }.count
        let servers = MCPServerManager.shared.servers(forBundleId: bundleId).count
        let builtIns = CapabilityRegistry.shared.all.filter { $0.appBundleID == bundleId }.count

        context.slots.append(
            .init(
                name: "capabilities",
                value:
                    "\(actions) actions, \(menus) menu commands, \(clis) CLI tools, "
                    + "\(servers) MCP servers, \(builtIns) built-in tools",
                source: "capability layer"))
        if actions + menus + clis + servers + builtIns == 0 {
            context.gaps.append(
                .init(
                    name: "capabilities",
                    reason: "nothing is linked to \(appName) yet — offer to add it in Settings → App Adapters"))
        }
    }

    /// An AXContext describing *this* app, not whichever app the shared snapshot belongs to.
    ///
    /// Readers that derive a project or document from the window title get nothing when
    /// handed another app's snapshot, which is how "enable Code" was followed by "the
    /// project name is not readable" — Code was in scope, and the reader was looking at
    /// Safari.
    static func axContext(for bundleId: String, appName: String) -> AXContext {
        let shared = AXContextReader.shared.current
        if shared.bundleId == bundleId { return shared }

        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId).first,
            running.processIdentifier > 0
        else { return AXContext(appName: appName, bundleId: bundleId, pid: 0) }

        let element = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)
        var context = AXContext(
            appName: running.localizedName ?? appName,
            bundleId: bundleId,
            pid: running.processIdentifier)
        if let window = focusedWindow(of: element) {
            context.windowTitle = axString(window, kAXTitleAttribute as String)
            if let document = axString(window, kAXDocumentAttribute as String) {
                context.currentURL = document
            }
        }
        return context
    }

    // MARK: - AX helpers

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &value) == .success
        else { return nil }
        return value as! AXUIElement?
    }

    private static func otherWindowTitles(of app: AXUIElement) -> [String]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        return windows.prefix(8).compactMap { axString($0, kAXTitleAttribute as String) }
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let text = value as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
