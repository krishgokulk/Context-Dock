// CrossAppNLHandler.swift
// ILauncher
//
// Pattern-based natural language parser for cross-app actions.
// "send this to salman" → Messages file send
// "email this to john"  → Mail compose
// "share this with X"   → NSSharingServicePicker
// "open this in X"      → open in named app
//
// No LLM required — regex patterns cover the common cases.
// On-device AI can plug in later to handle freeform variants.

import Foundation
import AppKit
import Contacts

// MARK: - Intent

struct CrossAppIntent {
    enum ActionType { case sendMessage, sendEmail, shareFile, openInApp }
    var action:         ActionType
    var recipientName:  String?   // "salman", "john doe"
    var targetAppName:  String?   // explicit app name when action == .openInApp
}

// MARK: - Resolved result

struct CrossAppResult {
    var intent:             CrossAppIntent
    var resolvedContact:    CNContact?
    var resolvedApp:        NSRunningApplication?
    var confirmationMessage: String
}

// MARK: - Handler

@MainActor
final class CrossAppNLHandler {
    static let shared = CrossAppNLHandler()
    private init() {}

    private let store = CNContactStore()

    // MARK: Parse

    func parse(_ raw: String) -> CrossAppIntent? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let name = recipient(q, verbs: ["send this to","send to","message to",
                                            "imessage to","text to","sms to"]) {
            return CrossAppIntent(action: .sendMessage, recipientName: name)
        }
        if let name = recipient(q, verbs: ["email this to","email to",
                                            "mail this to","mail to","send email to"]) {
            return CrossAppIntent(action: .sendEmail, recipientName: name)
        }
        if let name = recipient(q, verbs: ["share this with","share with",
                                            "airdrop to","airdrop this to"]) {
            return CrossAppIntent(action: .shareFile, recipientName: name)
        }
        if let app = appName(q, verbs: ["open in","open this in","open with"]) {
            return CrossAppIntent(action: .openInApp, targetAppName: app)
        }
        return nil
    }

    // MARK: Resolve

    func resolve(_ intent: CrossAppIntent) async -> CrossAppResult? {
        var r = CrossAppResult(intent: intent, confirmationMessage: "")

        if let name = intent.recipientName {
            r.resolvedContact = await lookupContact(name)
        }
        if let app = intent.targetAppName {
            r.resolvedApp = NSWorkspace.shared.runningApplications.first {
                ($0.localizedName ?? "").lowercased().contains(app)
            }
        }

        let displayName: String = {
            if let c = r.resolvedContact {
                return CNContactFormatter.string(from: c, style: .fullName) ?? intent.recipientName ?? "?"
            }
            return intent.recipientName ?? intent.targetAppName ?? "?"
        }()

        switch intent.action {
        case .sendMessage: r.confirmationMessage = "Send via Messages to \(displayName)?"
        case .sendEmail:   r.confirmationMessage = "Compose email to \(displayName)?"
        case .shareFile:   r.confirmationMessage = "Share with \(displayName)?"
        case .openInApp:   r.confirmationMessage = "Open in \(displayName)?"
        }
        return r
    }

    // MARK: Execute

    func execute(_ result: CrossAppResult, axContext: AXContext) async -> String {
        switch result.intent.action {
        case .sendMessage: return await sendViaMessages(result, ctx: axContext)
        case .sendEmail:   return sendViaMailto(result, ctx: axContext)
        case .shareFile:   return shareSheet(ctx: axContext)
        case .openInApp:   return openInApp(result, ctx: axContext)
        }
    }

    // MARK: - Messages

    private func sendViaMessages(_ r: CrossAppResult, ctx: AXContext) async -> String {
        let address = resolveAddress(r) ?? r.intent.recipientName ?? ""
        guard !address.isEmpty else { return "❌ No address found for \(r.intent.recipientName ?? "?")" }

        let addrEsc = address.replacingOccurrences(of: "\"", with: "\\\"")

        // Pick payload: file > selected text > current URL
        let script: String
        if let path = ctx.selectedFilePaths.first {
            let pathEsc = path.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Messages"
                set svc to 1st service whose service type = iMessage
                set buddy to buddy "\(addrEsc)" of svc
                send POSIX file "\(pathEsc)" to buddy
            end tell
            """
        } else if let text = ctx.selectedText, !text.isEmpty {
            let textEsc = String(text.prefix(500)).replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Messages"
                set svc to 1st service whose service type = iMessage
                set buddy to buddy "\(addrEsc)" of svc
                send "\(textEsc)" to buddy
            end tell
            """
        } else if let url = ctx.currentURL {
            let urlEsc = url.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "Messages"
                set svc to 1st service whose service type = iMessage
                set buddy to buddy "\(addrEsc)" of svc
                send "\(urlEsc)" to buddy
            end tell
            """
        } else {
            // Just open the conversation
            script = """
            tell application "Messages"
                activate
                set svc to 1st service whose service type = iMessage
                open (buddy "\(addrEsc)" of svc)
            end tell
            """
        }

        let ok = appleScript(script)
        let label = ctx.selectedFilePaths.first.map { ($0 as NSString).lastPathComponent }
                 ?? (ctx.selectedText != nil ? "text" : ctx.currentURL ?? "message")
        return ok ? "✅ Sent \(label) to \(address) via Messages"
                  : "❌ Could not send via Messages — is \(address) an iMessage contact?"
    }

    // MARK: - Mail

    private func sendViaMailto(_ r: CrossAppResult, ctx: AXContext) -> String {
        let email: String = {
            if let c = r.resolvedContact,
               let e = c.emailAddresses.first { return e.value as String }
            return r.intent.recipientName ?? ""
        }()
        let subject: String = {
            if let t = ctx.selectedText, !t.isEmpty { return String(t.prefix(60)) }
            if let url = ctx.currentURL { return ctx.windowTitle ?? url }
            if let p = ctx.selectedFilePaths.first { return (p as NSString).lastPathComponent }
            return ""
        }()
        let body: String = {
            if let t = ctx.selectedText, !t.isEmpty { return t }
            if let url = ctx.currentURL { return url }
            return ""
        }()

        var comps = URLComponents(string: "mailto:\(email)")!
        var qi: [URLQueryItem] = []
        if !subject.isEmpty { qi.append(.init(name: "subject", value: subject)) }
        if !body.isEmpty    { qi.append(.init(name: "body",    value: body)) }
        comps.queryItems = qi.isEmpty ? nil : qi

        guard let url = comps.url else { return "❌ Could not build mailto URL" }
        NSWorkspace.shared.open(url)
        return "✅ Opened Mail compose to \(email.isEmpty ? (r.intent.recipientName ?? "?") : email)"
    }

    // MARK: - Share sheet

    private func shareSheet(ctx: AXContext) -> String {
        var items: [Any] = ctx.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if items.isEmpty, let urlStr = ctx.currentURL, let u = URL(string: urlStr) { items.append(u) }
        if items.isEmpty, let t = ctx.selectedText { items.append(t) }
        guard !items.isEmpty else { return "❌ Nothing to share — select a file or text first" }

        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            if let win = NSApp.keyWindow, let view = win.contentView {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        }
        return "✅ Opening share sheet…"
    }

    // MARK: - Open in app

    private func openInApp(_ r: CrossAppResult, ctx: AXContext) -> String {
        let appName = r.intent.targetAppName ?? ""
        let app = r.resolvedApp ?? NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().contains(appName.lowercased())
        }
        for path in ctx.selectedFilePaths {
            if let appURL = app?.bundleURL {
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: path)],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        }
        if let urlStr = ctx.currentURL, let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
        app?.activate(options: [.activateIgnoringOtherApps])
        return "✅ Opened in \(app?.localizedName ?? appName)"
    }

    // MARK: - Contacts

    func lookupContact(_ name: String) async -> CNContact? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        let contacts = (try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: name),
            keysToFetch: keys
        )) ?? []

        // Prefer exact first-name match
        return contacts.first {
            $0.givenName.lowercased() == name.lowercased() ||
            ($0.givenName + " " + $0.familyName).lowercased() == name.lowercased()
        } ?? contacts.first
    }

    // MARK: - Helpers

    private func resolveAddress(_ r: CrossAppResult) -> String? {
        guard let c = r.resolvedContact else { return nil }
        if let e = c.emailAddresses.first { return e.value as String }
        if let p = c.phoneNumbers.first   { return p.value.stringValue }
        return nil
    }

    private func recipient(_ q: String, verbs: [String]) -> String? {
        for v in verbs {
            if q.hasPrefix(v + " ") {
                let r = String(q.dropFirst(v.count + 1)).trimmingCharacters(in: .whitespaces)
                if !r.isEmpty { return r }
            }
        }
        return nil
    }

    private func appName(_ q: String, verbs: [String]) -> String? {
        for v in verbs {
            if q.hasPrefix(v + " ") {
                let r = String(q.dropFirst(v.count + 1)).trimmingCharacters(in: .whitespaces)
                if !r.isEmpty { return r }
            }
        }
        return nil
    }

    @discardableResult
    private func appleScript(_ src: String) -> Bool {
        guard let s = NSAppleScript(source: src) else { return false }
        var err: NSDictionary?
        s.executeAndReturnError(&err)
        return err == nil
    }
}
