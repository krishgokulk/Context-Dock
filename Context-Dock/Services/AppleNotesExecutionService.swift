import Foundation

// MARK: - Errors

enum AppleNotesError: LocalizedError {
    case notEnabled
    case permissionDenied(String)
    case scriptFailed(String)
    case noteNotFound(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Apple Notes MCP is not enabled. Turn it on in Settings › App Adapters › Notes › Tools."
        case .permissionDenied(let reason):
            return "Apple Notes MCP permission denied: \(reason)"
        case .scriptFailed(let msg):
            return "Notes script error: \(msg)"
        case .noteNotFound(let id):
            return "Note not found: \(id)"
        case .parseError(let msg):
            return "Could not parse Notes response: \(msg)"
        }
    }
}

// MARK: - Service

// All methods run osascript via a temp-file approach on a background thread.
// Never call from @MainActor inline — always await.
final class AppleNotesExecutionService {
    static let shared = AppleNotesExecutionService()

    private init() {}

    // MARK: - Core runner

    // Writes script to a temp file and runs `osascript <file>`.
    // This is more reliable than -e for multi-line scripts and avoids
    // shell escaping issues with line continuations.
    func runScript(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("notes_mcp_\(UUID().uuidString).applescript")
                do {
                    try script.write(to: tmpURL, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: tmpURL) }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = [tmpURL.path]
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    try process.run()
                    process.waitUntilExit()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = (String(data: outData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let errText = (String(data: errData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(
                            throwing: AppleNotesError.scriptFailed(errText.isEmpty ? output : errText)
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Fetch all note metadata (title, folder, 500-char snippet — no full body)

    func fetchAllMetadata() async throws -> [NoteMetadata] {
        let script = """
        set delim to "|||"
        set lf to (ASCII character 10)
        set output to ""
        tell application "Notes"
            repeat with n in every note
                set nId to id of n
                set nTitle to name of n
                set nFolder to ""
                set nMod to modification date of n
                set nCreated to creation date of n
                try
                    set nFolder to name of container of n
                end try
                set rawBody to body of n
                set bodyLen to count of rawBody
                if bodyLen > 500 then
                    set nSnippet to text 1 thru 500 of rawBody
                else
                    set nSnippet to rawBody
                end if
                set output to output & nId & delim & nTitle & delim & nFolder & delim & (nMod as string) & delim & (nCreated as string) & delim & nSnippet & lf
            end repeat
        end tell
        return output
        """
        let raw = try await runScript(script)
        return parseMetadataLines(raw)
    }

    // MARK: - Deep body search (case-insensitive, scans full note body — slower than index search)

    func deepSearchBodies(query: String, maxResults: Int = 20) async throws -> [NoteMetadata] {
        let safeQuery = escapeForAppleScript(query)
        let script = """
        set delim to "|||"
        set lf to (ASCII character 10)
        set output to ""
        set resultCount to 0
        set qry to "\(safeQuery)"
        tell application "Notes"
            repeat with n in every note
                if resultCount >= \(maxResults) then exit repeat
                set matched to false
                ignoring case
                    if (name of n) contains qry then
                        set matched to true
                    end if
                    if not matched then
                        if (body of n) contains qry then
                            set matched to true
                        end if
                    end if
                end ignoring
                if matched then
                    set nId to id of n
                    set nTitle to name of n
                    set nFolder to ""
                    set nMod to modification date of n
                    set nCreated to creation date of n
                    try
                        set nFolder to name of container of n
                    end try
                    set rawBody to body of n
                    set bodyLen to count of rawBody
                    if bodyLen > 500 then
                        set nSnippet to text 1 thru 500 of rawBody
                    else
                        set nSnippet to rawBody
                    end if
                    set output to output & nId & delim & nTitle & delim & nFolder & delim & (nMod as string) & delim & (nCreated as string) & delim & nSnippet & lf
                    set resultCount to resultCount + 1
                end if
            end repeat
        end tell
        return output
        """
        let raw = try await runScript(script)
        return parseMetadataLines(raw)
    }

    private func parseMetadataLines(_ raw: String) -> [NoteMetadata] {
        let formatter = AppleScriptDateFormatter.shared
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> NoteMetadata? in
                let parts = String(line).components(separatedBy: "|||")
                guard parts.count >= 6 else { return nil }
                let snippet = parts[5...].joined(separator: "|||").prefix(500)
                return NoteMetadata(
                    id: parts[0],
                    title: parts[1],
                    folder: parts[2],
                    modifiedDate: formatter.date(from: parts[3]) ?? .distantPast,
                    createdDate: formatter.date(from: parts[4]) ?? .distantPast,
                    snippet: stripHTML(String(snippet))
                )
            }
    }

    // MARK: - Read full note body

    func readNote(id: String) async throws -> (title: String, folder: String, body: String, modified: Date) {
        let escapedID = escapeForAppleScript(id)
        let script = """
        tell application "Notes"
            set n to note id "\(escapedID)"
            set nTitle to name of n
            set nBody to body of n
            set nMod to modification date of n
            set nFolder to ""
            try
                set nFolder to name of container of n
            end try
            return nTitle & "|||" & nFolder & "|||" & (nMod as string) & "|||" & nBody
        end tell
        """
        let raw = try await runScript(script)
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 4 else { throw AppleNotesError.parseError(raw) }
        let body = parts.dropFirst(3).joined(separator: "|||")
        return (
            title: parts[0],
            folder: parts[1],
            body: body,
            modified: AppleScriptDateFormatter.shared.date(from: parts[2]) ?? Date()
        )
    }

    // MARK: - Create note

    func createNote(title: String, body: String, folder: String?) async throws -> String {
        let safeTitle = escapeForAppleScript(title)
        let safeBody = escapeForAppleScript(body)
        let script: String
        if let folder, !folder.isEmpty {
            let safeFolder = escapeForAppleScript(folder)
            script = """
            tell application "Notes"
                set targetFolder to first folder whose name is "\(safeFolder)"
                set newNote to make new note in targetFolder with properties {name:"\(safeTitle)", body:"\(safeBody)"}
                return id of newNote
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                set newNote to make new note with properties {name:"\(safeTitle)", body:"\(safeBody)"}
                return id of newNote
            end tell
            """
        }
        return try await runScript(script)
    }

    // MARK: - Append to note

    func appendToNote(id: String, text: String) async throws {
        let escapedID = escapeForAppleScript(id)
        let safeText = escapeForAppleScript(text)
        let script = """
        tell application "Notes"
            set n to note id "\(escapedID)"
            set existingBody to body of n
            set body of n to existingBody & "<br>\(safeText)"
        end tell
        """
        _ = try await runScript(script)
    }

    // MARK: - Update note

    func updateNote(id: String, title: String?, body: String?) async throws {
        let escapedID = escapeForAppleScript(id)
        var statements: [String] = []
        if let title {
            statements.append("set name of n to \"\(escapeForAppleScript(title))\"")
        }
        if let body {
            statements.append("set body of n to \"\(escapeForAppleScript(body))\"")
        }
        guard !statements.isEmpty else { return }
        let script = """
        tell application "Notes"
            set n to note id "\(escapedID)"
            \(statements.joined(separator: "\n    "))
        end tell
        """
        _ = try await runScript(script)
    }

    // MARK: - Delete note

    func deleteNote(id: String) async throws {
        let escapedID = escapeForAppleScript(id)
        let script = """
        tell application "Notes"
            delete (note id "\(escapedID)")
        end tell
        """
        _ = try await runScript(script)
    }

    // MARK: - List folders

    func listFolders() async throws -> [String] {
        let script = """
        set lf to (ASCII character 10)
        set output to ""
        tell application "Notes"
            repeat with f in every folder
                set output to output & (name of f) & lf
            end repeat
        end tell
        return output
        """
        let raw = try await runScript(script)
        return raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Date formatter (locale-tolerant)

private final class AppleScriptDateFormatter {
    static let shared = AppleScriptDateFormatter()
    private let formatters: [DateFormatter]

    private init() {
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
            "EEEE, d MMMM yyyy 'at' HH:mm:ss",
            "MMMM d, yyyy 'at' h:mm:ss a",
            "d MMMM yyyy 'at' HH:mm:ss",
            "M/d/yy, h:mm a",
            "d/M/yy, HH:mm",
        ]
        var fmts: [DateFormatter] = []
        for fmt in formats {
            for locale in [Locale(identifier: "en_US"), Locale.current] {
                let f = DateFormatter()
                f.dateFormat = fmt
                f.locale = locale
                fmts.append(f)
            }
        }
        formatters = fmts
    }

    func date(from string: String) -> Date? {
        for f in formatters {
            if let d = f.date(from: string) { return d }
        }
        return nil
    }
}
