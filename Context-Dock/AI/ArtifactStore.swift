// ArtifactStore.swift
// Context-Dock
//
// The things an answer builds, kept as files so the panel can already show them.
//
// A model that writes a chart, a tracker, a diagram or a table hands back a fenced code
// block, and a chat renders that as text: the user reads the source of the thing instead
// of the thing. Claude's artifacts solve this by rendering the output live beside the
// conversation, which is the same job the Preview panel already does for files.
//
// So an artifact is written to disk and becomes a file. Nothing new is needed to show it —
// the panel that watches, renders and edits files works unchanged, and the artifact
// survives the session, can be opened in Finder, and can be handed to the chat window from
// the dock the same way any other file is.

import Foundation
import OSLog

enum ArtifactStore {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "Artifacts")

    /// Fenced languages worth rendering rather than reading. Deliberately short: a Swift or
    /// bash block is source the user wants to read as source, and turning it into a file
    /// would bury the answer instead of showing it.
    private static let renderable: Set<String> = ["html", "svg", "mermaid", "csv"]

    /// One directory per thread, named after its scope.
    ///
    /// Sanitised, because a folder thread's key holds a path: appending
    /// "folder:/Users/x/Documents" verbatim buries the artifact several directories deep
    /// under a folder literally named ":", where nothing that lists this scope would look.
    private static func folder(for scope: GeneralChatScope) -> URL {
        directory.appendingPathComponent(
            scope.storageKey
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "-"))
    }

    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Context-Dock/artifacts")
    }

    /// Writes any renderable block in an answer to a file, newest last.
    ///
    /// Content-addressed by hash: the same answer re-rendered — a scope reopened, a
    /// transcript reloaded — must not leave a trail of identical files behind it.
    @discardableResult
    static func extract(from text: String, scope: GeneralChatScope) -> [URL] {
        let pattern = "```([a-zA-Z]+)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let folder = folder(for: scope)
        var written: [URL] = []

        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard match.numberOfRanges >= 3,
                let languageRange = Range(match.range(at: 1), in: text),
                let bodyRange = Range(match.range(at: 2), in: text)
            else { continue }

            let language = String(text[languageRange]).lowercased()
            guard renderable.contains(language) else { continue }

            let body = String(text[bodyRange])
            // A one-line fragment is a mention, not a document. Rendering it as an artifact
            // produces an empty panel next to an answer that explained itself perfectly.
            guard body.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 else { continue }

            let name = "\(abs(body.hashValue)).\(fileExtension(for: language))"
            let url = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                written.append(url)
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                try wrap(body, language: language).write(to: url, atomically: true, encoding: .utf8)
                written.append(url)
                log.notice("wrote \(name, privacy: .public)")
            } catch {
                log.notice("could not write: \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    private static func fileExtension(for language: String) -> String {
        switch language {
        case "svg": return "svg"
        case "csv": return "csv"
        default: return "html"  // html and mermaid both render in a web view
        }
    }

    /// Mermaid is a diagram description, not a document — it needs a page around it before
    /// a web view can draw anything. The renderer is loaded from the network, so a diagram
    /// offline shows its source rather than a blank frame.
    private static func wrap(_ body: String, language: String) -> String {
        guard language == "mermaid" else { return body }
        return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <style>body{margin:0;padding:12px;background:#1c1c1e;color:#eee;
            font:13px -apple-system}</style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"
                    onerror="document.body.classList.add('offline')"></script>
            </head><body>
            <pre class="mermaid">\(body)</pre>
            <script>
            // Without the renderer the <pre> is still the diagram's source, which is
            // readable. A blank frame would not be, and would look like a broken artifact
            // rather than one waiting on a network.
            if (window.mermaid) { mermaid.initialize({startOnLoad:true,theme:'dark'}); }
            else { document.querySelector('.mermaid').style.whiteSpace = 'pre-wrap'; }
            </script>
            </body></html>
            """
    }

    /// Files a document a capability produced, and returns where it went.
    ///
    /// The fenced-block path above exists because a model hands back prose. A capability
    /// hands back a finished report, and printing three hundred duplicate paths into the
    /// transcript to have them extracted again is a worse version of writing the file
    /// directly. The panel lists this directory, so a report written here is already on
    /// screen beside the conversation.
    @discardableResult
    static func file(
        _ body: String, named name: String, scope: GeneralChatScope
    ) -> URL? {
        let folder = folder(for: scope)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            log.notice("filed \(name, privacy: .public)")
            return url
        } catch {
            log.notice("could not file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A timestamped name, so running the same report twice keeps both rather than
    /// overwriting the one the user is still looking at.
    static func reportName(_ stem: String, extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(stem)-\(formatter.string(from: Date())).\(ext)"
    }

    /// Every artifact this thread has produced, oldest first.
    static func artifacts(for scope: GeneralChatScope) -> [URL] {
        let folder = folder(for: scope)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return files.map {
            ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }
}
