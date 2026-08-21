//
//  SafariExtensionCommandBridge.swift
//  Context-Dock
//
//  Runs JavaScript inside a Safari page *through our own Safari Web Extension*
//  instead of AppleScript.
//
//  Why this exists — AppleScript can't do the job:
//    • Safari Web Apps ("Add to Dock" sites) ship no AppleScript dictionary, so
//      `tell application "Safari"` can't reach them at all. It silently runs the
//      script in the real Safari's front window instead.
//    • AppleScript injection carries no transient user activation, so gated APIs
//      like requestPictureInPicture() reject outright.
//
//  Why it works the way it does — nothing can push to the extension:
//    SFSafariApplication.dispatchMessage only wakes the *native* handler process,
//    not a suspended MV3 service worker, and MV3 forbids a persistent background
//    page. So the JS side must always initiate. We make it initiate by clicking
//    the extension's own menu item:
//
//      app writes pending.json  →  AX-clicks Edit ▸ Extension Actions ▸ Context Dock
//      →  browser.action.onClicked fires (with user activation)
//      →  background.js fetches the command over native messaging
//      →  scripting.executeScript runs it in the page's isolated world
//      →  result comes back as results/<requestId>.json
//

import Foundation
import AppKit

actor SafariExtensionCommandBridge {
    static let shared = SafariExtensionCommandBridge()

    /// Menu path to our extension's action inside any Safari-family app.
    private static let menuPath = ["Edit", "Extension Actions", "Context Dock"]

    /// How long to wait for the extension to answer before giving up. The click,
    /// worker wake, injection and round-trip normally land well inside this.
    private static let timeout: TimeInterval = 5.0

    enum BridgeError: LocalizedError {
        case noContainer
        case extensionNotInMenu
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noContainer:
                return "No shared container — the app-group entitlement is missing."
            case .extensionNotInMenu:
                return "Context Dock isn't enabled as an extension in this app. "
                     + "Turn it on in Settings ▸ Extensions, then allow it for this site."
            case .timedOut:
                return "The Safari extension didn't respond. Make sure Context Dock is "
                     + "enabled and has permission for this site."
            }
        }
    }

    /// Remembered per-app verdicts. Reaching the extension means AX-opening the app's
    /// Edit menu, which the user sees; without a memory every adapter action in an app
    /// that has no Context Dock extension flashed that menu open again for nothing.
    private var verdicts: [String: (available: Bool, checkedAt: Date)] = [:]

    /// Long enough to keep a run of actions quiet, short enough that enabling the
    /// extension takes effect without restarting the app.
    private static let verdictTTL: TimeInterval = 300

    /// True when the target app exposes our extension's action item — i.e. the
    /// extension is installed *and* enabled for it.
    ///
    /// A never-opened submenu is unreadable over AX, so the first call in an app may
    /// have to find out by trying; `run` records what actually happened and every later
    /// call answers from that instead of opening menus again.
    func isAvailable(in app: NSRunningApplication) -> Bool {
        let key = Self.verdictKey(for: app)
        switch AXMenuReader.shared.menuItemPresence(path: Self.menuPath,
                                                    in: app.processIdentifier) {
        case .present:
            verdicts[key] = (true, Date())
            return true
        case .absent:
            verdicts[key] = (false, Date())
            return false
        case .unknown:
            if let cached = verdicts[key],
               Date().timeIntervalSince(cached.checkedAt) < Self.verdictTTL {
                return cached.available
            }
            // Undecidable and no fresh verdict: allow one probing attempt.
            return true
        }
    }

    /// Forget what we learned — call after the user changes extension settings.
    func invalidateVerdicts() {
        verdicts.removeAll()
    }

    private static func verdictKey(for app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    }

    /// Run a userscript in the frontmost tab of `app`.
    func runJavaScript(_ code: String, in app: NSRunningApplication) async throws -> String {
        try await run(command: ["kind": "js", "code": code], in: app)
    }

    /// Put the currently playing video into Picture-in-Picture. Separate from the
    /// generic JS path because it must run as a real function — the click's user
    /// activation is what lets requestPictureInPicture() through.
    func requestPictureInPicture(in app: NSRunningApplication) async throws -> String {
        try await run(command: ["kind": "pip"], in: app)
    }

    // MARK: - Private

    private func run(command: [String: Any], in app: NSRunningApplication) async throws -> String {
        guard let pendingURL = SafariBridgeKey.pendingCommandURL,
              let bridgeDir = SafariBridgeKey.bridgeDirectory
        else { throw BridgeError.noContainer }

        let requestId = UUID().uuidString
        var payload = command
        payload["requestId"] = requestId
        payload["createdAt"] = Date().timeIntervalSince1970

        try FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload).write(to: pendingURL, options: .atomic)

        // Clean up the queued command if we bail out before the extension consumes it,
        // so it can't fire late on some unrelated click.
        defer { try? FileManager.default.removeItem(at: pendingURL) }

        // The verdict was being written and never read. `run` clicked the menu regardless
        // of what the last attempt had learned, so an app without the extension enabled had
        // its Edit menu opened for every single query — a Safari chat answered "hi hello"
        // by opening Edit ▸ Extension Actions and leaving it hanging there, because the
        // Context Dock item does not exist to be clicked. The memory this file already
        // keeps is consulted now, which is what it was built for.
        let key = Self.verdictKey(for: app)
        guard isAvailable(in: app) else { throw BridgeError.extensionNotInMenu }

        guard AXMenuReader.shared.clickMenuItemReliably(path: Self.menuPath,
                                                        in: app.processIdentifier) else {
            // Settles the undecidable case for good: this app has no extension item, so
            // stop opening its menus on every action.
            verdicts[key] = (false, Date())
            // Searching for an item that is not there opens menus on the way. Leaving them
            // open is how the user ends up staring at a submenu nobody asked for.
            AXMenuReader.shared.dismissOpenMenus(in: app.processIdentifier)
            throw BridgeError.extensionNotInMenu
        }
        verdicts[key] = (true, Date())

        guard let result = await awaitResult(requestId: requestId) else {
            throw BridgeError.timedOut
        }
        return result
    }

    /// Poll for the result file. The extension writes it from its own process, so
    /// there's no in-process signal to wait on.
    private func awaitResult(requestId: String) async -> String? {
        guard let url = SafariBridgeKey.resultURL(requestId: requestId) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        let deadline = Date().addingTimeInterval(Self.timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ok = dict["ok"] as? Bool ?? false
                let text = dict["result"] as? String ?? ""
                return ok ? text : "JS error: \(text)"
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return nil
    }
}
