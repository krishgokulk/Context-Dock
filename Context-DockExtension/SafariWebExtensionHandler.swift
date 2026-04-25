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

enum SafariBridgeKey {
    static let suiteName   = "group.com.krishgokul.ContextDock"
    static let latestPayload = "safariExtension.latestPayload"
    static let lastUpdated   = "safariExtension.lastUpdated"
}

// MARK: - Handler

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        defer { context.completeRequest(returningItems: nil, completionHandler: nil) }

        guard
            let item = context.inputItems.first as? NSExtensionItem,
            let userInfo = item.userInfo,
            let message = userInfo[SFExtensionMessageKey]
        else {
            os_log("No message in extension request", log: log, type: .debug)
            return
        }

        // message is the JS object passed to sendNativeMessage — a [String: Any] dict
        guard let payload = message as? [String: Any] else {
            os_log("Message is not a dictionary: %{public}@",
                   log: log, type: .error, String(describing: message))
            return
        }

        os_log("Received pageContext from JS: url=%{public}@, trigger=%{public}@",
               log: log, type: .debug,
               payload["url"] as? String ?? "?",
               payload["trigger"] as? String ?? "?")

        // Write into shared App Group so the main app can read without IPC
        if let defaults = UserDefaults(suiteName: SafariBridgeKey.suiteName) {
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                defaults.set(data, forKey: SafariBridgeKey.latestPayload)
                defaults.set(Date().timeIntervalSinceReferenceDate,
                             forKey: SafariBridgeKey.lastUpdated)
            }
        }

        // Post a Darwin notification so the main app wakes up immediately
        // (UserDefaults KVO doesn't cross process boundaries in real-time)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.krishgokul.ContextDock.browserContextDidUpdate" as CFString),
            nil, nil, true
        )
    }
}
