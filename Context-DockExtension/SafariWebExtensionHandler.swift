// SafariWebExtensionHandler.swift
// Context-DockExtension
//
// Native messaging bridge: Safari calls this Swift class every time the JS
// background worker calls browser.runtime.sendNativeMessage().
// The handler writes the decoded payload into a shared App Group UserDefaults
// store so the main Context Dock app can read it instantly.

import SafariServices
import os.log

private let log = OSLog(subsystem: "com.krishgokul.ContextDock.SafariExtension",
                        category: "NativeMessaging")

// MARK: - Shared Keys

// IMPORTANT: this enum is mirrored verbatim in Context-Dock/Services/SafariBrowserBridge.swift.
// The two targets can't share a source file (the appex is a separate compilation unit under a
// synchronized group), so any change here must be applied there too.
//
// Why a file and not UserDefaults(suiteName:): the main app is NOT sandboxed while this
// extension IS. For a non-sandboxed process the suite resolves to
// ~/Library/Preferences/<group>.plist, for a sandboxed one to the group container — two
// different files that never meet. A container-relative file is the same path for both.
enum SafariBridgeKey {
    static let groupID = "group.com.krishgokul.ContextDock"

    static let contextDarwinName  = "com.krishgokul.ContextDock.browserContextDidUpdate"
    static let activateDarwinName = "com.krishgokul.ContextDock.browserActivateDock"

    /// Shared group container. `containerURL(forSecurityApplicationGroupIdentifier:)` works for
    /// sandboxed and non-sandboxed processes alike as long as the entitlement is present; the
    /// literal path is a last-resort fallback.
    static var containerURL: URL? {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(groupID)")
    }

    static var bridgeDirectory: URL? {
        containerURL?.appendingPathComponent("SafariBridge", isDirectory: true)
    }

    static var payloadURL: URL? {
        bridgeDirectory?.appendingPathComponent("latest.json")
    }

    /// Command the app has queued for the extension to run on its next action click.
    static var pendingCommandURL: URL? {
        bridgeDirectory?.appendingPathComponent("pending.json")
    }

    static func resultURL(requestId: String) -> URL? {
        bridgeDirectory?
            .appendingPathComponent("results", isDirectory: true)
            .appendingPathComponent("\(requestId).json")
    }
}

// MARK: - Handler

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        guard
            let item = context.inputItems.first as? NSExtensionItem,
            let userInfo = item.userInfo,
            let message = userInfo[SFExtensionMessageKey]
        else {
            os_log("No message in extension request", log: log, type: .debug)
            complete(context, ok: false)
            return
        }

        // message is the JS object passed to sendNativeMessage — a [String: Any] dict
        guard let payload = message as? [String: Any] else {
            os_log("Message is not a dictionary: %{public}@",
                   log: log, type: .error, String(describing: message))
            complete(context, ok: false)
            return
        }

        let type = payload["type"] as? String

        // Toolbar button: no context to store, just wake the app.
        if type == "dockCommand", payload["action"] as? String == "activateDock" {
            os_log("Toolbar activate request", log: log, type: .debug)
            postDarwin(SafariBridgeKey.activateDarwinName)
            complete(context, ok: true)
            return
        }

        // The extension is asking whether the app queued work for it. Hand the command
        // over and consume it — a command must never run twice.
        if type == "fetchPendingCommand" {
            complete(context, ok: true, extra: ["command": takePendingCommand() as Any])
            return
        }

        // Result of a command the extension just ran, on its way back to the app.
        if type == "jsResult" {
            writeResult(payload)
            complete(context, ok: true)
            return
        }

        os_log("Received pageContext from JS: url=%{public}@, trigger=%{public}@",
               log: log, type: .debug,
               payload["url"] as? String ?? "?",
               payload["trigger"] as? String ?? "?")

        // Write into the shared App Group container so the main app can read without IPC
        writePayload(payload)

        // Post a Darwin notification so the main app wakes up immediately
        // (UserDefaults KVO doesn't cross process boundaries in real-time)
        postDarwin(SafariBridgeKey.contextDarwinName)
        complete(context, ok: true)
    }

    // MARK: - Private

    private func writePayload(_ payload: [String: Any]) {
        guard let url = SafariBridgeKey.payloadURL else {
            os_log("No group container — is the app-group entitlement present?",
                   log: log, type: .error)
            return
        }
        var enriched = payload
        // Receipt time from *this* process. The JS timestamp comes from the page's clock and
        // is only used for display; freshness checks must not depend on it.
        enriched["receivedAt"] = Date().timeIntervalSince1970

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: enriched)
            try data.write(to: url, options: .atomic)
        } catch {
            os_log("Failed writing payload: %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }
    }

    /// Read and delete the queued command. Deleting on read is what makes an AX click
    /// idempotent: if the user also clicks the toolbar button, there's nothing left to run.
    private func takePendingCommand() -> [String: Any]? {
        guard let url = SafariBridgeKey.pendingCommandURL,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        try? FileManager.default.removeItem(at: url)

        // Stale commands are dropped rather than run late — the user has moved on.
        if let createdAt = dict["createdAt"] as? Double,
           Date().timeIntervalSince1970 - createdAt > 15 {
            os_log("Dropping stale pending command", log: log, type: .debug)
            return nil
        }
        return dict
    }

    private func writeResult(_ payload: [String: Any]) {
        guard let requestId = payload["requestId"] as? String,
              let url = SafariBridgeKey.resultURL(requestId: requestId)
        else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let body: [String: Any] = [
                "ok": payload["ok"] as? Bool ?? false,
                "result": payload["result"] as? String ?? "",
            ]
            try JSONSerialization.data(withJSONObject: body).write(to: url, options: .atomic)
        } catch {
            os_log("Failed writing result: %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }
    }

    private func postDarwin(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Always return an item — an empty completion leaves the JS-side promise
    /// resolving with `undefined`, which reads like a failed send in logs.
    private func complete(_ context: NSExtensionContext, ok: Bool,
                          extra: [String: Any] = [:]) {
        var body: [String: Any] = ["ok": ok]
        for (k, v) in extra { body[k] = v }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: body]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
