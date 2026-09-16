// AppControlCapabilities.swift
// Context-Dock
//
// The two things a control layer over macOS has to be able to do: click a menu item, and
// put text somewhere.
//
// Everything else DoraX registers reads state, launches something, or runs a command. None
// of that drives the app in front of you, which is what the product is for. "Minimize
// Safari" resolved to a capability id — app.menu.click — that nothing registered, so the
// invocation parsed, matched no capability, and died. "Paste this as markdown into Code"
// had nowhere to put the text and became a shell pipeline through a binary that isn't
// installed.
//
// Both are more invasive than anything else here, so both are deliberately narrow:
//
// - The menu path is verified live against the running app before anything is clicked.
//   That machinery already exists and is used by the executor's verified-menu route; this
//   is the same call, reachable by capability id.
// - Typing goes through the pasteboard and ⌘V, restores what was on the clipboard, and
//   re-checks the frontmost app immediately before the keystroke — approve for Code and
//   switch to Mail while the sheet is up, and it must not land in Mail.

import AppKit
import Foundation

@MainActor
enum AppControlCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerMenuClick(registry)
        registerInsertText(registry)
    }

    // MARK: - Menu

    private static func registerMenuClick(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "app.menu.click",
                title: "Click an App Menu Item",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "path",
                        description: "Menu path, e.g. \"Window > Minimize\" or \"File > Save\".",
                        required: true),
                    .init(
                        name: "bundleId",
                        description: "Target app; defaults to the frontmost app.",
                        required: false),
                ]),
                // A menu item can be Quit, or Delete. Which one is only knowable from the
                // path, so every menu click is previewed and approved rather than guessed
                // at from a keyword list of "destructive" words.
                riskLevel: .high
            ) { request in
                let raw = request.input["path"] ?? ""
                // Accept the separators a model actually writes, and the unit separator the
                // typed-invocation parser packs a path array into.
                let path = raw
                    .components(separatedBy: CharacterSet(charactersIn: "\u{1F}>›/|"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !path.isEmpty else {
                    throw AICapabilityError.missingInput("path")
                }

                let bundleID = request.input["bundleId"]
                    ?? request.input["bundleID"]
                    ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    ?? ""
                guard !bundleID.isEmpty else {
                    return .init(success: false, output: "I couldn't tell which app to use.")
                }
                guard NSWorkspace.shared.runningApplications.contains(where: {
                    $0.bundleIdentifier == bundleID && !$0.isTerminated
                }) else {
                    return .init(
                        success: false,
                        output: "\(bundleID) isn't running, so it has no menus to click.")
                }

                // Live verification happens inside: the item must exist and be enabled in
                // the running app right now. A cached menu is a hint, never a licence to
                // click.
                let (success, message) = await MenuExecutionCoordinator.shared
                    .executeVerifiedMenuAction(bundleIdentifier: bundleID, path: path)
                return .init(
                    success: success,
                    output: success
                        ? (message.isEmpty ? "Ran \(path.joined(separator: " > "))." : message)
                        : message)
            }
        )
    }

    // MARK: - Text

    private static func registerInsertText(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "app.insertText",
                title: "Insert Text into the Frontmost App",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(name: "text", description: "The exact text to insert", required: true),
                    .init(
                        name: "bundleId",
                        description: "App this text is meant for; defaults to the frontmost app.",
                        required: false),
                ]),
                // The most invasive thing DoraX does. It writes into a real document whose
                // undo stack belongs to the app, not to us, so the approval card shows the
                // whole text and the target, and this is never a candidate for always-allow.
                riskLevel: .high
            ) { request in
                let text = request.input["text"] ?? ""
                guard !text.isEmpty else { throw AICapabilityError.missingInput("text") }

                let intended = request.input["bundleId"] ?? request.input["bundleID"]
                guard let target = NSWorkspace.shared.frontmostApplication,
                    let targetBundle = target.bundleIdentifier
                else {
                    return .init(success: false, output: "No app is frontmost.")
                }
                // The approval sheet takes time, and the user can switch apps while it is
                // up. Approving for Code and typing into whatever came forward afterwards
                // is the failure that would make this capability untrustworthy.
                if let intended, !intended.isEmpty, intended != targetBundle {
                    return .init(
                        success: false,
                        output: "\(target.localizedName ?? targetBundle) is frontmost now, not "
                            + "\(intended). Nothing was typed — bring the right app forward "
                            + "and ask again.")
                }
                guard AXIsProcessTrusted() else {
                    return .init(
                        success: false,
                        output: "Typing into another app needs Accessibility permission for "
                            + "Context-Dock in System Settings → Privacy & Security.")
                }

                let pasteboard = NSPasteboard.general
                let saved = pasteboard.string(forType: .string)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)

                let source = CGEventSource(stateID: .combinedSessionState)
                // 0x09 is "v". Both events carry the command flag; a keyUp without it
                // leaves the modifier stuck down in some apps.
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
                else {
                    if let saved {
                        pasteboard.clearContents()
                        pasteboard.setString(saved, forType: .string)
                    }
                    return .init(success: false, output: "Couldn't synthesise the paste.")
                }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cgAnnotatedSessionEventTap)
                up.post(tap: .cgAnnotatedSessionEventTap)

                // Give the app a moment to take the paste before the clipboard goes back to
                // what the user had. Restoring immediately races the paste and can put the
                // old text in the document instead.
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let saved {
                    pasteboard.clearContents()
                    pasteboard.setString(saved, forType: .string)
                }

                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                let name = target.localizedName ?? targetBundle
                // Honest about what is known: the keystroke was delivered. Whether the app
                // accepted it into a text field is not something this can see, and claiming
                // otherwise would be the same unearned "done" the executor avoids elsewhere.
                return .init(
                    success: true,
                    output: "Sent \(lines) line\(lines == 1 ? "" : "s") to \(name) as a paste. "
                        + "Check it landed where you wanted.")
            }
        )
    }
}
