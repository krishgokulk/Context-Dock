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
    enum ActionType { case sendMessage, sendEmail, shareFile, openInApp, captureToApp }
    enum CaptureKind { case generic, page, link, bookmark }
    var action:         ActionType
    var recipientName:  String?   // "salman", "john doe"
    var messageBody:    String? = nil
    var targetAppName:  String?   // explicit app name when action == .openInApp
    var captureKind:    CaptureKind = .generic
    var shareIntent:    ShareIntent? = nil
}

// MARK: - Resolved result

struct CrossAppResult {
    var intent:             CrossAppIntent
    var resolvedContact:    CNContact?
    var resolvedApp:        NSRunningApplication?
    var resolvedBundleId:   String?
    var confirmationMessage: String
    var shareResolution:    ShareIntentResolution?
}

// MARK: - Handler

@MainActor
final class CrossAppNLHandler {
    static let shared = CrossAppNLHandler()
    private init() {}

    private let store = CNContactStore()
    private let appAliases: [String: String] = [
        "notes": "com.apple.Notes",
        "apple notes": "com.apple.Notes",
        "notion": "com.notion.id",
        "bear": "net.shinyfrog.bear",
        "obsidian": "md.obsidian",
        "reminders": "com.apple.reminders",
        "messages": "com.apple.MobileSMS",
        "mail": "com.apple.mail",
        "safari": "com.apple.Safari"
    ]

    // MARK: Parse

    func parse(_ raw: String) -> CrossAppIntent? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let shareIntent = ShareIntentRouter.shared.parse(q) {
            let action: CrossAppIntent.ActionType
            switch shareIntent.channelHint {
            case .messages:
                action = .sendMessage
            case .mail:
                action = .sendEmail
            case .picker, .airDrop:
                action = .shareFile
            }
            return CrossAppIntent(
                action: action,
                recipientName: shareIntent.recipientQuery,
                targetAppName: nil,
                captureKind: .generic,
                shareIntent: shareIntent
            )
        }

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
        if let app = appName(q, verbs: ["add this page to","save this page to","clip this page to"]) {
            return CrossAppIntent(action: .captureToApp, targetAppName: app, captureKind: .page)
        }
        if let app = appName(q, verbs: ["save this link to","add this link to","clip this link to"]) {
            return CrossAppIntent(action: .captureToApp, targetAppName: app, captureKind: .link)
        }
        if let app = appName(q, verbs: ["bookmark this in","bookmark this to"]) {
            return CrossAppIntent(action: .captureToApp, targetAppName: app, captureKind: .bookmark)
        }
        if let app = appName(q, verbs: ["add this to","save this to","clip this to"]) {
            return CrossAppIntent(action: .captureToApp, targetAppName: app, captureKind: .generic)
        }
        return nil
    }

    func parseMessagesScopedIntent(_ raw: String) -> CrossAppIntent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let quotedPattern = #"^\s*send\s+"([^"]+)"\s+to\s+(.+?)\s*$"#
        if let body = firstMatch(in: trimmed, pattern: quotedPattern, group: 1),
            let recipient = firstMatch(in: trimmed, pattern: quotedPattern, group: 2)
        {
            let cleanedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedBody.isEmpty, !cleanedRecipient.isEmpty else { return nil }
            return CrossAppIntent(
                action: .sendMessage,
                recipientName: cleanedRecipient,
                messageBody: cleanedBody
            )
        }

        let plainPattern = #"^\s*send\s+(.+?)\s+to\s+(.+?)\s*$"#
        if let body = firstMatch(in: trimmed, pattern: plainPattern, group: 1),
            let recipient = firstMatch(in: trimmed, pattern: plainPattern, group: 2)
        {
            let cleanedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextualPayloadMarkers: Set<String> = [
                "this", "that", "selected", "selection", "file", "files", "link", "page", "url",
                "document", "documents"
            ]
            guard !cleanedBody.isEmpty, !cleanedRecipient.isEmpty,
                !contextualPayloadMarkers.contains(cleanedBody.lowercased())
            else { return nil }
            return CrossAppIntent(
                action: .sendMessage,
                recipientName: cleanedRecipient,
                messageBody: cleanedBody
            )
        }

        return nil
    }

    // MARK: Resolve

    func resolve(_ intent: CrossAppIntent) async -> CrossAppResult? {
        var r = CrossAppResult(intent: intent, confirmationMessage: "", shareResolution: nil)

        if let shareIntent = intent.shareIntent {
            let shareResolution = await ShareIntentRouter.shared.resolve(shareIntent)
            r.shareResolution = shareResolution
            r.resolvedContact = shareResolution.resolvedContact
        }

        if r.resolvedContact == nil, let name = intent.recipientName {
            r.resolvedContact = await lookupContact(name)
        }
        if let app = intent.targetAppName {
            r.resolvedBundleId = resolveBundleId(for: app)
            r.resolvedApp = resolvedRunningApp(appName: app, bundleId: r.resolvedBundleId)
        }

        let displayName: String = {
            if let shareResolution = r.shareResolution {
                return shareResolution.recipientDisplayName
            }
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
        case .captureToApp:
            r.confirmationMessage = "Save this in \(displayName)?"
        }
        return r
    }

    // MARK: Execute

    func execute(
        _ result: CrossAppResult,
        axContext: AXContext,
        presentSharingPicker: (([Any]) -> Void)? = nil
    ) async -> String {
        if let shareResolution = result.shareResolution ?? fallbackShareResolution(for: result) {
            return await ShareIntentRouter.shared.execute(
                shareResolution,
                axContext: axContext,
                presentSharingPicker: presentSharingPicker
            )
        }

        switch result.intent.action {
        case .sendMessage: return await sendViaMessages(result, ctx: axContext)
        case .sendEmail:   return sendViaMailto(result, ctx: axContext)
        case .shareFile:
            return shareSheet(ctx: axContext, presentSharingPicker: presentSharingPicker)
        case .openInApp:   return openInApp(result, ctx: axContext)
        case .captureToApp: return captureInApp(result, ctx: axContext)
        }
    }

    private func fallbackShareResolution(for result: CrossAppResult) -> ShareIntentResolution? {
        let channelHint: ShareChannelHint
        switch result.intent.action {
        case .sendMessage:
            channelHint = .messages
        case .sendEmail:
            channelHint = .mail
        case .shareFile:
            channelHint = .picker
        case .openInApp, .captureToApp:
            return nil
        }

        let recipientName = result.intent.recipientName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackHandle: String? = switch channelHint {
        case .messages:
            if let phone = result.resolvedContact?.phoneNumbers.first?.value.stringValue,
                !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                phone
            } else if let email = result.resolvedContact?.emailAddresses.first?.value as String?,
                !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                email
            } else {
                recipientName
            }
        case .mail:
            if let email = result.resolvedContact?.emailAddresses.first?.value as String?,
                !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                email
            } else {
                recipientName
            }
        case .picker, .airDrop:
            nil
        }

        let displayName: String
        if let contact = result.resolvedContact,
            let fullName = CNContactFormatter.string(from: contact, style: .fullName),
            !fullName.isEmpty
        {
            displayName = fullName
        } else if let recipientName, !recipientName.isEmpty {
            displayName = recipientName
        } else if let fallbackHandle, !fallbackHandle.isEmpty {
            displayName = fallbackHandle
        } else {
            displayName = "recipient"
        }

        return ShareIntentResolution(
            intent: ShareIntent(
                rawQuery: result.intent.recipientName ?? "",
                channelHint: channelHint,
                recipientQuery: recipientName
            ),
            resolvedContact: result.resolvedContact,
            recipientHandle: fallbackHandle,
            recipientDisplayName: displayName
        )
    }

    // MARK: - Messages

    private func sendViaMessages(_ r: CrossAppResult, ctx: AXContext) async -> String {
        let address = resolveAddress(r) ?? r.intent.recipientName ?? ""
        guard !address.isEmpty else { return "❌ No address found for \(r.intent.recipientName ?? "?")" }

        let addrEsc = address.replacingOccurrences(of: "\"", with: "\\\"")
        let explicitMessageBody = r.intent.messageBody?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Explicit text intent wins over contextual payloads.
        let script: String
        if let explicitMessageBody, !explicitMessageBody.isEmpty {
            let textEsc = String(explicitMessageBody.prefix(1200)).replacingOccurrences(
                of: "\"",
                with: "\\\""
            )
            script = """
            tell application "Messages"
                set svc to 1st service whose service type = iMessage
                set buddy to buddy "\(addrEsc)" of svc
                send "\(textEsc)" to buddy
            end tell
            """
        } else if let path = ctx.selectedFilePaths.first {
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
        let label = explicitMessageBody.map { "\"\(String($0.prefix(48)))\"" }
            ?? ctx.selectedFilePaths.first.map { ($0 as NSString).lastPathComponent }
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

    private func shareSheet(
        ctx: AXContext,
        presentSharingPicker: (([Any]) -> Void)? = nil
    ) -> String {
        var items: [Any] = ctx.selectedFilePaths.map { URL(fileURLWithPath: $0) }
        if items.isEmpty, let urlStr = ctx.currentURL, let u = URL(string: urlStr) { items.append(u) }
        if items.isEmpty, let t = ctx.selectedText { items.append(t) }
        guard !items.isEmpty else { return "❌ Nothing to share — select a file or text first" }

        if let presentSharingPicker {
            presentSharingPicker(items)
            return "✅ Opening share sheet…"
        }

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
        let app = r.resolvedApp ?? resolvedRunningApp(appName: appName, bundleId: r.resolvedBundleId)
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
        app?.activate()
        return "✅ Opened in \(app?.localizedName ?? appName)"
    }

    private func captureInApp(_ r: CrossAppResult, ctx: AXContext) -> String {
        guard let bundleId = r.resolvedBundleId ?? r.intent.targetAppName.flatMap(resolveBundleId) else {
            return "❌ I couldn't identify the target app."
        }

        guard let payload = capturePayload(for: r.intent.captureKind, ctx: ctx) else {
            return "❌ Nothing to save — select text, a file, or open a page first."
        }

        switch bundleId {
        case "com.apple.Notes":
            return captureInNotes(payload)
        case "com.notion.id":
            return openCaptureURL(
                "notion://new?content=\(payload.encodedBody)",
                success: "✅ Saved to Notion",
                failure: "❌ Couldn't open Notion capture."
            )
        case "net.shinyfrog.bear":
            let url = "bear://x-callback-url/create?title=\(payload.encodedTitle)&text=\(payload.encodedBody)"
            return openCaptureURL(url, success: "✅ Saved to Bear", failure: "❌ Couldn't open Bear capture.")
        case "md.obsidian":
            let url = "obsidian://new?name=\(payload.encodedTitle)&content=\(payload.encodedBody)"
            return openCaptureURL(url, success: "✅ Saved to Obsidian", failure: "❌ Couldn't open Obsidian capture.")
        case "com.apple.reminders":
            let url = "x-apple-reminderkit://"
            return openCaptureURL(url, success: "✅ Opened Reminders", failure: "❌ Couldn't open Reminders.")
        default:
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                return "❌ \(r.intent.targetAppName ?? "That app") is not installed."
            }
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload.body, forType: .string)
            return "✅ Copied content and opened \(r.intent.targetAppName ?? "the app")."
        }
    }

    private func captureInNotes(_ payload: CapturePayload) -> String {
        let api = AppleAppsAPI.shared
        if payload.sourceURL != nil {
            let ok = api.saveLinkToNotes(url: payload.body, title: payload.title, folder: "Web Saves")
            return ok ? "✅ Saved to Notes" : "❌ Couldn't save the link to Notes."
        }

        let ok = api.createNote(title: payload.title, body: payload.body, folder: "ILauncher")
        return ok ? "✅ Created note in Notes" : "❌ Couldn't create the note in Notes."
    }

    private func openCaptureURL(_ raw: String, success: String, failure: String) -> String {
        guard let url = URL(string: raw) else { return failure }
        return NSWorkspace.shared.open(url) ? success : failure
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

    private func resolveBundleId(for appName: String) -> String? {
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = appAliases[normalized] {
            return mapped
        }

        if let running = resolvedRunningApp(appName: normalized, bundleId: nil)?.bundleIdentifier {
            return running
        }

        return nil
    }

    private func resolvedRunningApp(appName: String, bundleId: String?) -> NSRunningApplication? {
        if let bundleId {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first { !$0.isTerminated }
            if let running { return running }
        }

        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().contains(appName.lowercased())
        }
    }

    private struct CapturePayload {
        let title: String
        let body: String
        let sourceURL: String?

        var encodedTitle: String {
            title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }

        var encodedBody: String {
            body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
    }

    private func capturePayload(for kind: CrossAppIntent.CaptureKind, ctx: AXContext) -> CapturePayload? {
        let urlString = ctx.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedText = ctx.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowTitle = (ctx.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        switch kind {
        case .page, .link, .bookmark:
            if let urlString, !urlString.isEmpty {
                let title = windowTitle ?? URL(string: urlString)?.host ?? "Saved Link"
                let body = [title, urlString].joined(separator: "\n")
                return CapturePayload(title: title, body: body, sourceURL: urlString)
            }
            if let selectedText, !selectedText.isEmpty {
                let title = String(selectedText.prefix(60))
                return CapturePayload(title: title, body: selectedText, sourceURL: nil)
            }
        case .generic:
            break
        }

        if let selectedText, !selectedText.isEmpty {
            let title = String(selectedText.prefix(60))
            return CapturePayload(title: title, body: selectedText, sourceURL: nil)
        }

        if let urlString, !urlString.isEmpty {
            let title = windowTitle ?? URL(string: urlString)?.host ?? "Saved Link"
            let body = [title, urlString].joined(separator: "\n")
            return CapturePayload(title: title, body: body, sourceURL: urlString)
        }

        if let path = ctx.selectedFilePaths.first {
            let fileURL = URL(fileURLWithPath: path)
            return CapturePayload(title: fileURL.lastPathComponent, body: path, sourceURL: nil)
        }

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

    private func firstMatch(in value: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
            match.numberOfRanges > group,
            let captureRange = Range(match.range(at: group), in: value)
        else {
            return nil
        }
        return String(value[captureRange])
    }

    @discardableResult
    private func appleScript(_ src: String) -> Bool {
        guard let s = NSAppleScript(source: src) else { return false }
        var err: NSDictionary?
        s.executeAndReturnError(&err)
        return err == nil
    }
}
