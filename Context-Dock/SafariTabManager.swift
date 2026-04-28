// SafariTabManager.swift
// ILauncher
//
// Fetches all open Safari tabs via AppleScript and provides
// instant tab-switching from the ILauncher panel.

import Foundation
import AppKit

// MARK: - Safari Tab Model

struct SafariTab: Identifiable {
    let id = UUID()
    let title: String
    let url: String
    let windowIndex: Int
    let tabIndex: Int

    /// Display-friendly domain extracted from url
    var domain: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// SF Symbol that best represents the page type
    var icon: String {
        let u = url.lowercased()
        if u.contains("github.com")          { return "chevron.left.forwardslash.chevron.right" }
        if u.contains("youtube.com")         { return "play.rectangle.fill" }
        if u.contains("mail.google.com")     { return "envelope.fill" }
        if u.contains("docs.google.com")     { return "doc.text.fill" }
        if u.contains("notion.so")           { return "square.grid.2x2" }
        if u.contains("figma.com")           { return "paintbrush.fill" }
        if u.contains("stackoverflow.com")   { return "questionmark.circle.fill" }
        if u.contains("twitter.com") ||
           u.contains("x.com")               { return "bird.fill" }
        if u.contains("reddit.com")          { return "bubble.left.and.bubble.right.fill" }
        if u.contains("apple.com")           { return "applelogo" }
        if u.contains("localhost") ||
           u.contains("127.0.0.1")           { return "server.rack" }
        if u.hasPrefix("file://")            { return "doc.fill" }
        return "safari"
    }

    /// Accent color hint for the tab pill
    var accentColor: String {
        let u = url.lowercased()
        if u.contains("github.com")      { return "gray" }
        if u.contains("youtube.com")     { return "red" }
        if u.contains("mail.google")     { return "red" }
        if u.contains("docs.google")     { return "blue" }
        if u.contains("notion.so")       { return "gray" }
        if u.contains("figma.com")       { return "purple" }
        if u.contains("localhost")       { return "green" }
        return "blue"
    }
}

// MARK: - SafariTabManager

final class SafariTabManager {
    static let shared = SafariTabManager()
    private init() {}

    // MARK: Fetch

    /// Fetch all open tabs across all Safari windows.
    /// Returns an empty array if Safari is not running or AppleScript fails.
    func fetchTabs() async -> [SafariTab] {
        let script = """
        tell application "Safari"
            set output to {}
            set winCount to count of windows
            repeat with wi from 1 to winCount
                try
                    set tabCount to count of tabs of window wi
                    repeat with ti from 1 to tabCount
                        try
                            set t to tab ti of window wi
                            set tabTitle to name of t
                            set tabURL to URL of t
                            if tabURL is missing value then set tabURL to ""
                            if tabTitle is missing value then set tabTitle to tabURL
                            set end of output to (wi as string) & "|||" & (ti as string) & "|||" & tabTitle & "|||" & tabURL
                        end try
                    end repeat
                end try
            end repeat
            return output
        end tell
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(returning: []); return
                }
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                guard error == nil else { continuation.resume(returning: []); return }

                var tabs: [SafariTab] = []
                // Result is an AppleScript list; iterate descriptors
                let count = result.numberOfItems
                for i in 1...max(1, count) {
                    guard let item = result.atIndex(i)?.stringValue else { continue }
                    let parts = item.components(separatedBy: "|||")
                    guard parts.count == 4,
                          let wi = Int(parts[0]),
                          let ti = Int(parts[1]) else { continue }
                    let title = parts[2].isEmpty ? parts[3] : parts[2]
                    let url   = parts[3]
                    tabs.append(SafariTab(title: title, url: url,
                                          windowIndex: wi, tabIndex: ti))
                }
                continuation.resume(returning: tabs)
            }
        }
    }

    // MARK: Switch

    /// Bring the given tab to front in Safari and activate the app.
    func switchTo(_ tab: SafariTab) {
        let script = """
        tell application "Safari"
            set current tab of window \(tab.windowIndex) to tab \(tab.tabIndex) of window \(tab.windowIndex)
            set index of window \(tab.windowIndex) to 1
            activate
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    // MARK: Current tab info

    /// Returns the URL of the currently active Safari tab, or nil.
    func currentURL() async -> String? {
        let script = """
        tell application "Safari"
            try
                return URL of current tab of front window
            end try
        end tell
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let s = NSAppleScript(source: script) else {
                    continuation.resume(returning: nil); return
                }
                var err: NSDictionary?
                let res = s.executeAndReturnError(&err)
                continuation.resume(returning: err == nil ? res.stringValue : nil)
            }
        }
    }

    // MARK: Execute JS in current tab

    /// Run arbitrary JavaScript in Safari's frontmost tab and return the result string.
    ///
    /// Writes JS to a temp file so AppleScript reads it with `do shell script cat`,
    /// bypassing all string-escaping issues (newlines, backslashes, double quotes, regex).
    func executeJS(_ js: String) async -> String? {
        guard let tmpURL = writeTempJS(js) else { return nil }
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let path = tmpURL.path
        let script = """
        set jsCode to (do shell script "cat " & quoted form of "\(path)")
        tell application "Safari"
            return execute JavaScript jsCode in current tab of front window
        end tell
        """
        return await runAppleScript(script)
    }

    /// Run JavaScript in a specific tab (by window/tab index) and return the result.
    func executeJS(_ js: String, windowIndex: Int, tabIndex: Int) async -> String? {
        guard let tmpURL = writeTempJS(js) else { return nil }
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let path = tmpURL.path
        let script = """
        set jsCode to (do shell script "cat " & quoted form of "\(path)")
        tell application "Safari"
            return execute JavaScript jsCode in tab \(tabIndex) of window \(windowIndex)
        end tell
        """
        return await runAppleScript(script)
    }

    // MARK: - Private helpers

    private func writeTempJS(_ js: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdock_js_\(UUID().uuidString.prefix(8)).js")
        guard let data = js.data(using: .utf8),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    private func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let s = NSAppleScript(source: source) else {
                    continuation.resume(returning: nil); return
                }
                var err: NSDictionary?
                let res = s.executeAndReturnError(&err)
                if let err {
                    let msg = (err[NSAppleScript.errorMessage] as? String)
                        ?? err.description
                    continuation.resume(returning: "JS error: \(msg)")
                    return
                }
                continuation.resume(returning: res.stringValue)
            }
        }
    }

    // MARK: Fetch page text

    /// Extracts visible plain text from a specific Safari tab via AppleScript.
    /// Capped at 5 000 chars to stay within AI context budgets.
    func fetchTabText(windowIndex: Int, tabIndex: Int) async -> String {
        let script = """
        tell application "Safari"
            try
                set txt to text of tab \(tabIndex) of window \(windowIndex)
                if txt is missing value then return ""
                if (count of txt) > 5000 then set txt to text 1 thru 5000 of txt
                return txt
            on error
                return ""
            end try
        end tell
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let s = NSAppleScript(source: script) else {
                    continuation.resume(returning: ""); return
                }
                var err: NSDictionary?
                let res = s.executeAndReturnError(&err)
                continuation.resume(returning: err == nil ? (res.stringValue ?? "") : "")
            }
        }
    }

    // MARK: Close tab

    func closeTab(_ tab: SafariTab) {
        let script = """
        tell application "Safari"
            close tab \(tab.tabIndex) of window \(tab.windowIndex)
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    // MARK: New tab

    func openURL(_ urlString: String) {
        let escaped = urlString.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Safari"
            make new document
            set URL of current tab of front window to "\(escaped)"
            activate
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}
