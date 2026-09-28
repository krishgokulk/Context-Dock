// PageMarkdownExport.swift
// Context-Dock
//
// "Save as Markdown": the page in front of the user, as a Markdown file in Downloads.
//
// The page is read through `BrowserPageReader` — what is on screen, signed in, the user's
// own view of it — not fetched again over the network, which could see a different,
// signed-out page. A page `SensitivePageGuard` keeps DoraX out of is refused with its
// reason, never written to disk. A file already there is never overwritten: " 2", " 3".

import AppKit
import Foundation

enum PageMarkdownExport {

    enum Outcome: Equatable {
        case saved(URL)
        case refused(String)
        case unreadable
        case failed(String)
    }

    // MARK: Pure

    /// The Markdown document for a page: its title as the heading, where it came from, the
    /// readable text, and the links the text drops.
    static func markdown(for page: BrowserPageSnapshot, savedAt: Date = Date()) -> String {
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "# \(title.isEmpty ? (URL(string: page.url)?.host ?? "Web page") : title)\n\n"
        if !page.url.isEmpty { out += "Source: <\(page.url)>  \n" }
        let stamp = ISO8601DateFormatter.string(
            from: savedAt, timeZone: .current, formatOptions: [.withFullDate])
        out += "Saved: \(stamp)\n\n"
        let body = page.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { out += body + "\n" }
        let links = page.links.filter {
            !$0.url.isEmpty && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if !links.isEmpty {
            out += "\n## Links\n\n"
            for link in links {
                let text = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "]", with: "\\]")
                out += "- [\(text)](\(link.url))\n"
            }
        }
        return out
    }

    /// A file name from the page's title — what Finder allows, short enough to read — with
    /// the host, then "Web page", when there is no title.
    static func baseName(title: String, url: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        var name = title.components(separatedBy: forbidden).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = URL(string: url)?.host ?? "" }
        if name.isEmpty { name = "Web page" }
        if name.count > 100 {
            name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// The first free file: "Name.md", then "Name 2.md", "Name 3.md" — never one that exists.
    static func freeURL(base: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("md")
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("md")
            n += 1
        }
        return candidate
    }

    /// Why this page may not be saved, or nil. The same guard that keeps DoraX from reading
    /// or driving the page keeps it off the disk.
    static func refusal(for page: BrowserPageSnapshot) -> String? {
        page.refusal?.message
    }

    // MARK: Saving

    /// Writes `page` into `folder`. Nothing is written for a refused or empty page.
    static func save(_ page: BrowserPageSnapshot?, to folder: URL) -> Outcome {
        guard let page else { return .unreadable }
        // Before the emptiness check: the reader empties a refused page, and "refused" is
        // the true answer, not "unreadable".
        if let reason = refusal(for: page) { return .refused(reason) }
        guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unreadable }
        let url = freeURL(
            base: baseName(title: page.title, url: page.url), in: folder,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try markdown(for: page).write(to: url, atomically: true, encoding: .utf8)
            return .saved(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// The action: read the page in `bundleId`'s window, save it, and say where — with
    /// Reveal in Finder — or why not.
    @MainActor
    static func saveCurrentPage(bundleId: String) -> Outcome {
        let outcome = save(
            BrowserPageReader.current(bundleId: bundleId), to: downloadsFolder)
        switch outcome {
        case .saved(let url):
            AppToast.show(
                "Saved “\(url.lastPathComponent)” to Downloads", icon: "arrow.down.doc",
                duration: 5, actionTitle: "Reveal",
                action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        case .refused(let reason):
            AppToast.show(reason, icon: "hand.raised", duration: 4)
        case .unreadable:
            AppToast.show(
                "The page could not be read. Turn on the Context Dock Safari extension and try again.",
                icon: "exclamationmark.triangle", duration: 4)
        case .failed(let message):
            AppToast.show("Could not save the page: \(message)", icon: "exclamationmark.triangle", duration: 4)
        }
        return outcome
    }
}
