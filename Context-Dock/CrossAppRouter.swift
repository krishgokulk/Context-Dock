// CrossAppRouter.swift
// ILauncher
//
// Capability-based cross-app communication.
// Detects content type (text / URL / file) from the current context
// and generates smart DockPills routed to the best available running app.
//
// Usage:
//   let pills = CrossAppRouter.shared.buildPills(
//       context: AXContextReader.shared.current,
//       runningBundleIds: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
//       query: searchText
//   )
//

import Foundation
import AppKit

// MARK: - Capability Model

struct CrossAppCapability {
    let bundleId: String
    let appName: String
    let sfSymbol: String
    let badgeColor: String          // accent color name
    let category: CapabilityCategory

    // What content types this app accepts
    var acceptsText: Bool = false
    var acceptsURL: Bool = false
    var acceptsFile: Bool = false
    var acceptsSelection: Bool = false  // highlighted text from frontmost app

    // Routing strategies (tried in order)
    var urlSchemeTemplate: String? = nil    // e.g. "bear://x-callback-url/create?text={text}"
    var appleScriptTemplate: String? = nil  // e.g. "tell app \"Slack\" to ..."
    var shareServicesName: String? = nil    // NSSharingService identifier fallback

    // Human-readable label shown on pill
    var actionLabel: String = "Open"
}

enum CapabilityCategory: String {
    case notes, writing, messaging, browser, code, productivity, media, utility
}

// MARK: - Content Type Detection

enum DetectedContentType {
    case plainText(String)
    case url(URL)
    case filePath(String)
    case selection(String)  // AX-selected text
    case none
}

// MARK: - CrossAppRouter

@MainActor
final class CrossAppRouter {
    static let shared = CrossAppRouter()
    private init() {}

    // MARK: - Capability Database

    private let capabilities: [CrossAppCapability] = [

        // ── Notes & Writing ──────────────────────────────────────────────────

        CrossAppCapability(
            bundleId: "net.shinyfrog.bear",
            appName: "Bear",
            sfSymbol: "note.text",
            badgeColor: "orange",
            category: .notes,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            urlSchemeTemplate: "bear://x-callback-url/create?text={encoded_text}",
            actionLabel: "Create Bear note"
        ),
        CrossAppCapability(
            bundleId: "md.obsidian",
            appName: "Obsidian",
            sfSymbol: "diamond",
            badgeColor: "purple",
            category: .notes,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            urlSchemeTemplate: "obsidian://new?content={encoded_text}",
            actionLabel: "New Obsidian note"
        ),
        CrossAppCapability(
            bundleId: "com.apple.Notes",
            appName: "Notes",
            sfSymbol: "note.text",
            badgeColor: "yellow",
            category: .notes,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            appleScriptTemplate: "tell application \"Notes\" to make new note with properties {body:\"{text}\"}",
            actionLabel: "New Apple Note"
        ),
        CrossAppCapability(
            bundleId: "com.notion.id",
            appName: "Notion",
            sfSymbol: "square.grid.2x2",
            badgeColor: "gray",
            category: .notes,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            urlSchemeTemplate: "notion://new?content={encoded_text}",
            actionLabel: "Add to Notion"
        ),
        CrossAppCapability(
            bundleId: "com.omnigroup.OmniOutliner5",
            appName: "OmniOutliner",
            sfSymbol: "list.bullet.indent",
            badgeColor: "blue",
            category: .notes,
            acceptsText: true,
            acceptsSelection: true,
            actionLabel: "Add to OmniOutliner"
        ),
        CrossAppCapability(
            bundleId: "com.ideasoncanvas.mindnode6",
            appName: "MindNode",
            sfSymbol: "circle.hexagongrid",
            badgeColor: "green",
            category: .notes,
            acceptsText: true,
            acceptsSelection: true,
            urlSchemeTemplate: "mindnode://new?name={encoded_text}",
            actionLabel: "Add to MindNode"
        ),

        // ── Messaging ────────────────────────────────────────────────────────

        CrossAppCapability(
            bundleId: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            sfSymbol: "message.fill",
            badgeColor: "green",
            category: .messaging,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            urlSchemeTemplate: "slack://open",
            appleScriptTemplate: "tell application \"Slack\" to activate",
            actionLabel: "Send via Slack"
        ),
        CrossAppCapability(
            bundleId: "com.hnc.Discord",
            appName: "Discord",
            sfSymbol: "bubble.left.and.bubble.right.fill",
            badgeColor: "purple",
            category: .messaging,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            urlSchemeTemplate: "discord://",
            actionLabel: "Send via Discord"
        ),
        CrossAppCapability(
            bundleId: "com.apple.MobileSMS",
            appName: "Messages",
            sfSymbol: "message.fill",
            badgeColor: "green",
            category: .messaging,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            appleScriptTemplate: "tell application \"Messages\" to activate",
            actionLabel: "Send iMessage"
        ),
        CrossAppCapability(
            bundleId: "com.apple.mail",
            appName: "Mail",
            sfSymbol: "envelope.fill",
            badgeColor: "blue",
            category: .messaging,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            urlSchemeTemplate: "mailto:?body={encoded_text}",
            actionLabel: "Compose Mail"
        ),
        CrossAppCapability(
            bundleId: "ru.keepcoder.Telegram",
            appName: "Telegram",
            sfSymbol: "paperplane.fill",
            badgeColor: "blue",
            category: .messaging,
            acceptsText: true,
            acceptsURL: true,
            acceptsSelection: true,
            urlSchemeTemplate: "tg://",
            actionLabel: "Send via Telegram"
        ),

        // ── Browser ──────────────────────────────────────────────────────────

        CrossAppCapability(
            bundleId: "com.apple.Safari",
            appName: "Safari",
            sfSymbol: "safari.fill",
            badgeColor: "blue",
            category: .browser,
            acceptsText: false,
            acceptsURL: true,
            urlSchemeTemplate: "{url}",
            actionLabel: "Open in Safari"
        ),
        CrossAppCapability(
            bundleId: "com.google.Chrome",
            appName: "Chrome",
            sfSymbol: "globe",
            badgeColor: "red",
            category: .browser,
            acceptsText: false,
            acceptsURL: true,
            urlSchemeTemplate: "googlechrome://{host}",
            actionLabel: "Open in Chrome"
        ),
        CrossAppCapability(
            bundleId: "org.mozilla.firefox",
            appName: "Firefox",
            sfSymbol: "flame.fill",
            badgeColor: "orange",
            category: .browser,
            acceptsText: false,
            acceptsURL: true,
            actionLabel: "Open in Firefox"
        ),
        CrossAppCapability(
            bundleId: "company.thebrowser.Browser",
            appName: "Arc",
            sfSymbol: "circle.hexagonpath",
            badgeColor: "purple",
            category: .browser,
            acceptsText: false,
            acceptsURL: true,
            urlSchemeTemplate: "arc://",
            actionLabel: "Open in Arc"
        ),

        // ── Code ─────────────────────────────────────────────────────────────

        CrossAppCapability(
            bundleId: "com.microsoft.VSCode",
            appName: "VS Code",
            sfSymbol: "chevron.left.forwardslash.chevron.right",
            badgeColor: "blue",
            category: .code,
            acceptsText: false,
            acceptsFile: true,
            urlSchemeTemplate: "vscode://file/{file}",
            actionLabel: "Open in VS Code"
        ),
        CrossAppCapability(
            bundleId: "com.apple.dt.Xcode",
            appName: "Xcode",
            sfSymbol: "hammer.fill",
            badgeColor: "blue",
            category: .code,
            acceptsText: false,
            acceptsFile: true,
            appleScriptTemplate: "tell application \"Xcode\" to open \"{file}\"",
            actionLabel: "Open in Xcode"
        ),
        CrossAppCapability(
            bundleId: "com.apple.Terminal",
            appName: "Terminal",
            sfSymbol: "terminal.fill",
            badgeColor: "gray",
            category: .code,
            acceptsText: true,
            acceptsFile: true,
            appleScriptTemplate: "tell application \"Terminal\" to do script \"{text}\"",
            actionLabel: "Run in Terminal"
        ),
        CrossAppCapability(
            bundleId: "com.googlecode.iterm2",
            appName: "iTerm",
            sfSymbol: "terminal",
            badgeColor: "green",
            category: .code,
            acceptsText: true,
            acceptsFile: true,
            appleScriptTemplate: "tell application \"iTerm\" to tell current window to tell current session to write text \"{text}\"",
            actionLabel: "Run in iTerm"
        ),

        // ── Productivity ─────────────────────────────────────────────────────

        CrossAppCapability(
            bundleId: "com.culturedcode.ThingsMac",
            appName: "Things",
            sfSymbol: "checkmark.circle.fill",
            badgeColor: "blue",
            category: .productivity,
            acceptsText: true,
            acceptsSelection: true,
            urlSchemeTemplate: "things:///add?title={encoded_text}",
            actionLabel: "Add to Things"
        ),
        CrossAppCapability(
            bundleId: "com.omnigroup.OmniFocus3",
            appName: "OmniFocus",
            sfSymbol: "checkmark.square.fill",
            badgeColor: "purple",
            category: .productivity,
            acceptsText: true,
            acceptsSelection: true,
            urlSchemeTemplate: "omnifocus:///add?name={encoded_text}",
            actionLabel: "Add to OmniFocus"
        ),
        CrossAppCapability(
            bundleId: "com.apple.reminders",
            appName: "Reminders",
            sfSymbol: "list.bullet",
            badgeColor: "red",
            category: .productivity,
            acceptsText: true,
            acceptsSelection: true,
            appleScriptTemplate: "tell application \"Reminders\" to make new reminder with properties {name:\"{text}\"}",
            actionLabel: "Add Reminder"
        ),
        CrossAppCapability(
            bundleId: "com.agiletortoise.Drafts-OSX",
            appName: "Drafts",
            sfSymbol: "doc.text.fill",
            badgeColor: "blue",
            category: .productivity,
            acceptsText: true,
            acceptsSelection: true,
            urlSchemeTemplate: "drafts://x-callback-url/create?text={encoded_text}",
            actionLabel: "New Drafts entry"
        ),

        // ── Media ────────────────────────────────────────────────────────────

        CrossAppCapability(
            bundleId: "com.apple.finder",
            appName: "Finder",
            sfSymbol: "folder.fill",
            badgeColor: "blue",
            category: .utility,
            acceptsText: false,
            acceptsFile: true,
            appleScriptTemplate: "tell application \"Finder\" to reveal POSIX file \"{file}\"",
            actionLabel: "Reveal in Finder"
        ),
    ]

    // MARK: - Build Pills

    struct RoutedPill {
        let bundleId: String
        let appName: String
        let icon: String
        let label: String
        let badgeColor: String
        let action: () -> Void
    }

    func buildPills(
        context: AXContext,
        runningBundleIds: Set<String>,
        query: String
    ) -> [RoutedPill] {
        let contentType = detectContentType(context: context, query: query)
        guard contentType != .none else { return [] }

        var pills: [RoutedPill] = []

        for cap in capabilities {
            guard runningBundleIds.contains(cap.bundleId) else { continue }
            guard capabilityMatches(cap, contentType: contentType) else { continue }
            // Don't route to the frontmost app itself
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               front == cap.bundleId { continue }

            let pill = makePill(cap: cap, contentType: contentType, context: context)
            pills.append(pill)
        }

        // Limit to 6 most relevant pills
        return Array(pills.prefix(6))
    }

    // MARK: - Private

    private func detectContentType(context: AXContext, query: String) -> DetectedContentType {
        // 1. Finder-selected file paths
        if let first = context.selectedFilePaths.first {
            return .filePath(first)
        }
        // 2. AX-selected text
        if let sel = context.selectedText, !sel.isEmpty {
            if let url = URL(string: sel), url.scheme != nil { return .url(url) }
            return .selection(sel)
        }
        // 3. Browser current URL
        if let urlStr = context.currentURL, !urlStr.isEmpty,
           let url = URL(string: urlStr) {
            return .url(url)
        }
        // 4. Query looks like a URL
        if let url = URL(string: query), let scheme = url.scheme,
           (scheme == "http" || scheme == "https" || scheme == "ftp") {
            return .url(url)
        }
        // 5. Query looks like a file path
        if query.hasPrefix("/") && FileManager.default.fileExists(atPath: query) {
            return .filePath(query)
        }
        // 4. Non-empty query text
        if !query.isEmpty {
            return .plainText(query)
        }
        // 5. Clipboard
        if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
            if let url = URL(string: clip), let scheme = url.scheme,
               (scheme == "http" || scheme == "https") {
                return .url(url)
            }
            if clip.hasPrefix("/") && FileManager.default.fileExists(atPath: clip) {
                return .filePath(clip)
            }
            return .plainText(clip)
        }
        return .none
    }

    private func capabilityMatches(_ cap: CrossAppCapability, contentType: DetectedContentType) -> Bool {
        switch contentType {
        case .plainText: return cap.acceptsText
        case .url:       return cap.acceptsURL
        case .filePath:  return cap.acceptsFile
        case .selection: return cap.acceptsSelection || cap.acceptsText
        case .none:      return false
        }
    }

    private func makePill(cap: CrossAppCapability, contentType: DetectedContentType, context: AXContext) -> RoutedPill {
        let action: () -> Void = { [weak self] in
            self?.route(cap: cap, contentType: contentType, context: context)
        }
        return RoutedPill(
            bundleId: cap.bundleId,
            appName: cap.appName,
            icon: cap.sfSymbol,
            label: actionLabel(for: cap, contentType: contentType, context: context),
            badgeColor: cap.badgeColor,
            action: action
        )
    }

    private func route(cap: CrossAppCapability, contentType: DetectedContentType, context: AXContext) {
        if executeViaAdapter(cap: cap, contentType: contentType, context: context) {
            return
        }

        let rawText = extractText(from: contentType)
        let encoded = rawText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawText

        // 1. Try URL scheme
        if let template = cap.urlSchemeTemplate {
            let urlString = template
                .replacingOccurrences(of: "{encoded_text}", with: encoded)
                .replacingOccurrences(of: "{text}", with: rawText)
                .replacingOccurrences(of: "{url}", with: rawText)
                .replacingOccurrences(of: "{file}", with: rawText)
                .replacingOccurrences(of: "{host}", with: URL(string: rawText)?.host ?? rawText)
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // 2. Try AppleScript
        if let template = cap.appleScriptTemplate {
            let script = template
                .replacingOccurrences(of: "{text}", with: rawText.replacingOccurrences(of: "\"", with: "\\\""))
                .replacingOccurrences(of: "{file}", with: rawText.replacingOccurrences(of: "\"", with: "\\\""))
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if error == nil { return }
            }
        }

        // 3. Clipboard fallback — copy content and open app
        if case .plainText(let t) = contentType {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
        }
        NSWorkspace.shared.launchApplication(withBundleIdentifier: cap.bundleId,
                                             options: .async,
                                             additionalEventParamDescriptor: nil,
                                             launchIdentifier: nil)
    }

    private func actionLabel(for cap: CrossAppCapability, contentType: DetectedContentType, context: AXContext) -> String {
        switch (cap.bundleId, contentType) {
        case ("com.apple.Notes", .url):
            return context.bundleId == "com.apple.Safari" ? "Save Page to Notes" : "Save Link to Notes"
        case ("com.apple.Notes", .selection), ("com.apple.Notes", .plainText):
            return "Create Note"
        case ("com.apple.mail", .url):
            return "Compose Mail with Link"
        case ("com.apple.mail", .selection), ("com.apple.mail", .plainText):
            return "Compose Mail"
        case ("com.apple.reminders", .selection), ("com.apple.reminders", .plainText):
            return "Add Reminder"
        case ("com.apple.finder", .filePath):
            return "Reveal in Finder"
        default:
            return cap.actionLabel
        }
    }

    private func executeViaAdapter(cap: CrossAppCapability, contentType: DetectedContentType, context: AXContext) -> Bool {
        let api = AppleAppsAPI.shared

        switch cap.bundleId {
        case "com.apple.Notes":
            switch contentType {
            case .url(let url):
                let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                return api.saveLinkToNotes(url: url.absoluteString, title: title, folder: "Web Saves")
            case .plainText(let text), .selection(let text):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return false }
                let title = String(body.prefix(60))
                return api.createNote(title: title, body: body, folder: "ILauncher")
            case .filePath(let path):
                let fileURL = URL(fileURLWithPath: path)
                let body = fileURL.lastPathComponent + "\n" + path
                return api.createNote(title: fileURL.lastPathComponent, body: body, folder: "ILauncher")
            case .none:
                return false
            }

        case "com.apple.mail":
            switch contentType {
            case .url(let url):
                let subject = context.windowTitle ?? "Link"
                return api.composeMail(subject: subject, body: url.absoluteString)
            case .plainText(let text), .selection(let text):
                return api.composeMail(subject: "", body: text)
            case .filePath(let path):
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                return api.composeMail(subject: fileName, body: path)
            case .none:
                return false
            }

        case "com.apple.reminders":
            switch contentType {
            case .plainText(let text), .selection(let text):
                return api.createReminder(title: text)
            case .url(let url):
                let title = context.windowTitle?.isEmpty == false ? context.windowTitle! : url.absoluteString
                return api.createReminder(title: title)
            case .filePath(let path):
                return api.createReminder(title: URL(fileURLWithPath: path).lastPathComponent)
            case .none:
                return false
            }

        case "com.apple.finder":
            if case .filePath(let path) = contentType {
                return api.revealInFinder(path)
            }
            return false

        case "com.apple.Safari":
            if case .url(let url) = contentType {
                return api.openSafariURL(url.absoluteString)
            }
            return false

        default:
            return false
        }
    }

    private func extractText(from contentType: DetectedContentType) -> String {
        switch contentType {
        case .plainText(let t): return t
        case .url(let u):       return u.absoluteString
        case .filePath(let p):  return p
        case .selection(let s): return s
        case .none:             return ""
        }
    }
}

// MARK: - DetectedContentType equality

extension DetectedContentType: Equatable {
    static func == (lhs: DetectedContentType, rhs: DetectedContentType) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.plainText(let a), .plainText(let b)): return a == b
        case (.url(let a), .url(let b)): return a == b
        case (.filePath(let a), .filePath(let b)): return a == b
        case (.selection(let a), .selection(let b)): return a == b
        default: return false
        }
    }
}
